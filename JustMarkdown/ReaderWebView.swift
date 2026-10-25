import SwiftUI
import WebKit

@MainActor
final class ReaderWKWebView: WKWebView {
    var askSelectedText: (() -> Void)?
    weak var sourceView: SourceTextView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let sourceView, !sourceView.isHidden, sourceView.isUserInteractionEnabled,
            sourceView.alpha > 0.01, sourceView.frame.contains(point)
        {
            return sourceView.hitTest(sourceView.convert(point, from: self), with: event)
        }
        return super.hitTest(point, with: event)
    }
    private var nativeInputFocused: Bool {
        subviews.contains(where: { ($0 is ConversationTextView || $0 is SourceTextView) && $0.isFirstResponder })
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        if nativeInputFocused { return }
        let ask = UIAction(title: "AI", image: UIImage(systemName: "bubble.left")) { [weak self] _ in
            self?.askSelectedText?()
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [ask]), atEndOfMenu: .standardEdit)
    }
}

@MainActor
final class ReaderBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let session: ReaderSession
    let webView: ReaderWKWebView
    private(set) var ready = false
    private var loadedToken = ""
    private var lastTheme = ""
    private(set) var composer: NativeComposerHost!
    let sourceEditor = SourceEditor()
    private var sourceToken = ""
    private var projectedRevision = -1
    private var sourceEvents: [[String: String]] = []
    private var projectionTask: Task<Void, Error>?
    private var projectionGeneration = 0

    init(session: ReaderSession) {
        self.session = session
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(session.resources, forURLScheme: "jm-resource")
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let languages =
            (try? JSONSerialization.data(withJSONObject: Bundle.main.preferredLocalizations)) ?? Data("[]".utf8)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.JustMarkdownLanguages = \(String(decoding: languages, as: UTF8.self));",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = ReaderWKWebView(frame: .zero, configuration: configuration)
        super.init()
        if let document = session.document {
            sourceToken = session.documentToken
            sourceEditor.load(document.text)
        }
        // The transparent Web source surface lets its agent panel and scrim
        // composite above the native document without duplicating document text.
        webView.insertSubview(sourceEditor.textView, at: 0)
        webView.sourceView = sourceEditor.textView
        sourceEditor.onChange = { [weak self] id, status in self?.sourceDidChange(id: id, status: status) }
        sourceEditor.onFocusChange = { [weak session] focused in session?.sourceFocused = focused }
        sourceEditor.onAsk = { [weak self] range in
            Task { try? await self?.askSourceSelection(range) }
        }
        composer = NativeComposerHost(webView: webView)
        composer.call = { [weak self] method, payload in
            _ = try? await self?.call(method, arguments: ["payload": payload])
        }
        configuration.userContentController.add(self, name: "reader")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.accessibilityIdentifier = "ReaderWebView"
        #if DEBUG
            webView.isInspectable = true
        #endif
        webView.askSelectedText = { [weak self] in
            Task { _ = try? await self?.call("askSelection") }
        }
        session.bridge = self
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            session.errorMessage = String(localized: "Offline rendering resources are missing.")
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    func flushSource() -> String? {
        guard sourceToken == session.documentToken else { return session.document?.text }
        sourceEditor.commitInput()
        return sourceEditor.history.text
    }

    func applySourceEdit(before: String, after: String, id: String) -> Bool {
        guard sourceToken == session.documentToken, session.mode == "source" else { return false }
        return sourceEditor.replace(expected: before, with: after, id: id)
    }

    func moveSourceHistory(forward: Bool, id: String? = nil) -> Bool {
        guard sourceToken == session.documentToken, session.mode == "source" else { return false }
        sourceEditor.commitInput()
        return sourceEditor.history.move(forward: forward, id: id)
    }

    func call(_ method: String, arguments: [String: Any] = [:]) async throws -> Any? {
        let payload = arguments["payload"]
        switch method {
        case "askSelection" where session.mode == "source":
            try await askSourceSelection(sourceEditor.textView.selectedRange)
            return nil
        case "toggleMode", "toggleAgent", "commitAgentInput", "resolveAgentConsent":
            try await synchronizeProjection()
        case "diagnostics":
            startProjection()
            try await projectionTask?.value
        default: break
        }
        if method == "toggleMode", session.mode == "source" {
            let anchor = sourceEditor.capturePosition()
            sourceEditor.textView.resignFirstResponder()
            return try await rawCall(method, payload: ["anchor": anchor.payload])
        }
        if method == "scrollToSourceLine", session.mode == "source", let line = payload as? NSNumber {
            sourceEditor.restore(SourceReadingPosition(line: line.doubleValue, y: ReaderDesign.sourceTopInset))
            return try await call("diagnostics")
        }
        let result = try await rawCall(method, payload: payload)
        if method == "diagnostics", var status = result as? [String: Any] {
            status["history"] = ["canUndo": sourceEditor.history.canUndo, "canRedo": sourceEditor.history.canRedo]
            status["source"] = sourceEditor.history.text
            if status["mode"] as? String == "source" { status["anchor"] = sourceEditor.capturePosition().payload }
            return status
        }
        return result
    }

    private func rawCall(_ method: String, payload: Any? = nil) async throws -> Any? {
        guard ready else { return nil }
        return try await webView.callAsyncJavaScript(
            "return await window.JustMarkdown[method](payload);",
            arguments: ["method": method, "payload": payload ?? NSNull()], in: nil, contentWorld: .page)
    }

    private func sourceDidChange(id: String?, status: String?) {
        guard sourceToken == session.documentToken else { return }
        session.sourceChanged(sourceEditor.history.text, token: sourceToken)
        session.sourceHistoryChanged(
            canUndo: sourceEditor.history.canUndo, canRedo: sourceEditor.history.canRedo, token: sourceToken)
        if let id, let status {
            let event = ["transactionID": id, "status": status]
            if sourceEvents.last != event { sourceEvents.append(event) }
        }
        startProjection()
    }

    private func startProjection() {
        guard ready, sourceToken == loadedToken, projectionTask == nil else { return }
        let token = sourceToken
        let generation = projectionGeneration
        projectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.projectionGeneration { self.projectionTask = nil } }
            while !Task.isCancelled, generation == self.projectionGeneration,
                token == self.sourceToken && token == self.session.documentToken,
                self.projectedRevision != self.sourceEditor.history.revision
            {
                let revision = self.sourceEditor.history.revision
                let events = self.sourceEvents
                let text = self.sourceEditor.history.text
                let accepted = try await self.rawCall(
                    "sourceState", payload: ["token": token, "text": text, "events": events])
                guard generation == self.projectionGeneration, token == self.sourceToken, accepted as? Bool == true
                else { return }
                self.sourceEvents.removeFirst(min(events.count, self.sourceEvents.count))
                self.projectedRevision = revision
            }
        }
    }

    private func synchronizeProjection() async throws {
        sourceEditor.commitInput()
        startProjection()
        try await projectionTask?.value
    }

    private func askSourceSelection(_ range: NSRange) async throws {
        guard session.mode == "source", range.length > 0 else { return }
        let token = sourceToken
        try await synchronizeProjection()
        guard token == sourceToken, token == session.documentToken,
            NSMaxRange(range) <= sourceEditor.history.text.utf16.count
        else { return }
        let view = sourceEditor.textView
        let position = view.position(from: view.beginningOfDocument, offset: NSMaxRange(range))
        let rect = position.map { view.convert(view.caretRect(for: $0), to: webView) } ?? .zero
        view.resignFirstResponder()
        _ = try await rawCall(
            "askSourceSelection",
            payload: [
                "start": range.location, "end": NSMaxRange(range),
                "rect": ["left": rect.minX, "right": rect.maxX, "top": rect.minY, "bottom": rect.maxY],
            ])
    }

    func update() {
        guard ready else { return }
        updateTheme()
        guard let document = session.document, loadedToken != session.documentToken else { return }
        loadedToken = session.documentToken
        let token = loadedToken
        if sourceToken != token {
            projectionGeneration += 1
            projectionTask?.cancel()
            projectionTask = nil
            sourceToken = token
            sourceEvents.removeAll()
            sourceEditor.load(document.text)
        }
        projectedRevision = sourceEditor.history.revision
        Task {
            do {
                _ = try await call(
                    "openDocument",
                    arguments: [
                        "payload": [
                            "text": sourceEditor.history.text, "token": token,
                            "name": document.fileURL.lastPathComponent,
                        ]
                    ])
            } catch {
                session.errorMessage = String(
                    localized: "Unable to render this document: \(error.localizedDescription)")
            }
        }
    }

    func updateTheme() {
        let traits = webView.traitCollection
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: traits) / 16
        let names = [
            "chevron-right": "chevron.right", "chevron-down": "chevron.down", "quote": "quote.opening",
            "code": "chevron.left.forwardslash.chevron.right", "file-text": "doc.text", "x": "xmark",
            "arrow-up": "arrow.up", "square": "stop.fill",
        ]
        var symbols: [String: String] = [:]
        for (name, symbol) in names {
            if let image = UIImage(
                systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))?
                .withTintColor(.white, renderingMode: .alwaysOriginal), let data = image.pngData()
            {
                symbols[name] = "data:image/png;base64," + data.base64EncodedString()
            }
        }
        var palette: [String: String] = [:]
        for (name, color) in [
            "paper": UIColor.systemBackground, "chrome": .secondarySystemBackground, "ink": .label,
            "muted": .secondaryLabel, "line": .separator, "accent": webView.tintColor ?? .systemBlue,
        ] {
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            palette[name] = "rgba(\(r * 255),\(g * 255),\(b * 255),\(a))"
        }
        let fingerprint =
            "\(traits.userInterfaceStyle.rawValue)-\(traits.preferredContentSizeCategory.rawValue)-\(scale)"
        guard fingerprint != lastTheme else { return }
        lastTheme = fingerprint
        Task {
            _ = try? await call(
                "theme",
                arguments: ["payload": ["fontScale": scale, "symbols": symbols, "palette": palette]])
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
            let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }
        switch type {
        case "ready":
            ready = true
            update()
        case "state":
            guard body["token"] as? String == session.documentToken else { return }
            if let mode = body["mode"] as? String, session.mode != mode { session.mode = mode }
            if let value = body["outline"] as? Bool, session.outlineExpanded != value {
                session.outlineExpanded = value
            }
            if let value = body["hasOutline"] as? Bool, session.hasOutline != value { session.hasOutline = value }
        case "documentReady":
            if body["token"] as? String == session.documentToken { session.rendererReady = true }
        case "localResources":
            if let paths = body["paths"] as? [String], let token = body["token"] as? String {
                session.localResourcesChanged(paths, token: token)
            }
        case "sourceLayout":
            guard body["token"] as? String == sourceToken else { return }
            sourceEditor.updateLayout(
                frame: CGRect(
                    x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                    width: body["width"] as? Double ?? 0, height: body["height"] as? Double ?? 0),
                visible: body["visible"] as? Bool == true, opacity: body["opacity"] as? Double ?? 1,
                interactive: body["interactive"] as? Bool == true)
        case "sourceRestore":
            guard body["token"] as? String == sourceToken, let anchor = body["anchor"] as? [String: Any] else { return }
            sourceEditor.restore(SourceReadingPosition(anchor))
        case "agentPresentation":
            session.agentOpen = body["open"] as? Bool == true
            session.agentModalActive = body["modal"] as? Bool == true
        case "agentEntry":
            if let id = body["id"] as? String, let token = body["token"] as? String {
                session.requestAgentEntry(id: id, token: token)
            }
        case "agentRequest":
            guard body["token"] as? String == session.documentToken, let id = body["id"] as? String,
                let intent = body["intent"] as? String, let snapshot = body["snapshot"],
                let data = try? JSONSerialization.data(withJSONObject: snapshot),
                let request = try? JSONDecoder().decode(AgentSnapshot.self, from: data)
            else { return }
            session.requestAgent(id: id, token: session.documentToken, snapshot: request, intent: intent)
        case "agentConsent":
            if let id = body["id"] as? String, let token = body["token"] as? String {
                session.requestDataSharingConsent(id: id, token: token)
            }
        case "agentCancel":
            if body["token"] as? String == session.documentToken {
                session.agentTransport.cancel(id: body["id"] as? String)
            }
        case "agentUndo":
            if let id = body["id"] as? String, let change = body["change"] as? String,
                let token = body["token"] as? String, token == session.documentToken
            {
                session.undoAgentChange(id: change, requestID: id, token: token)
            }
        case "inputLayout":
            composer.updateLayout(body["inputs"] as? [[String: Any]] ?? [])
        case "inputSetText":
            if let id = body["id"] as? String, let text = body["text"] as? String, let epoch = body["epoch"] as? Int {
                composer.setText(id: id, text: text, epoch: epoch)
            }
        case "inputFocus":
            if let id = body["id"] as? String { composer.focus(id) }
        case "inputBlur": composer.blur()
        case "inputSubmit":
            if let id = body["id"] as? String { composer.submit(id) }
        case "link":
            if let href = body["href"] as? String { Task { await session.resolveLink(href) } }
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.isFileURL, let root = Bundle.main.resourceURL, url.path.hasPrefix(root.path + "/Web/") { return .allow }
        if url.scheme == "about" { return .allow }
        if navigationAction.navigationType == .linkActivated {
            await session.resolveLink(url.absoluteString)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, willPresentEditMenuWithAnimator animator: any UIEditMenuInteractionAnimating) {
        Task { _ = try? await call("suppressSelection") }
    }

    func webView(_ webView: WKWebView, contextMenuWillPresentForElement elementInfo: WKContextMenuElementInfo) {
        Task { _ = try? await call("suppressSelection") }
    }

    func detach() {
        session.finishDataSharingConsent(allowed: false)
        session.agentTransport.cancel()
        composer.detach()
        webView.askSelectedText = nil
        webView.sourceView = nil
        sourceEditor.detach()
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        sourceEvents.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        session.errorMessage = String(localized: "Unable to load the reader: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        session.finishDataSharingConsent(allowed: false)
        session.agentTransport.cancel()
        composer.blur()
        sourceEditor.textView.resignFirstResponder()
        sourceEditor.textView.isHidden = true
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        session.agentOpen = false
        session.agentModalActive = false
        ready = false
        loadedToken = ""
        lastTheme = ""
        session.rendererReady = false
        webView.reload()
    }
}

@MainActor
final class ReaderViewport: UIView {
    let webView: ReaderWKWebView

    init(webView: ReaderWKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        webView.autoresizingMask = []
        addSubview(webView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:)") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Background snapshots temporarily resize the scene. Keep those sizes out
        // of the live document's viewport and composited scrolling layers.
        guard window?.windowScene?.activationState != .background else { return }
        if webView.frame != bounds { webView.frame = bounds }
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }
}

struct ReaderWebView: UIViewRepresentable {
    @ObservedObject var session: ReaderSession
    @Environment(\.dynamicTypeSize) var dynamicType
    @Environment(\.colorScheme) var colorScheme

    func makeCoordinator() -> ReaderBridge { ReaderBridge(session: session) }
    func makeUIView(context: Context) -> ReaderViewport { ReaderViewport(webView: context.coordinator.webView) }
    func updateUIView(_ uiView: ReaderViewport, context: Context) { context.coordinator.update() }
    static func dismantleUIView(_ uiView: ReaderViewport, coordinator: ReaderBridge) { coordinator.detach() }
}
