import SwiftUI
import WebKit

@MainActor
final class ReaderWKWebView: WKWebView {
    var askSelectedText: (() -> Void)?
    var sourceHistoryAction: ((String) -> Void)?
    var sourceEditing = false
    var canUndoSource = false
    var canRedoSource = false

    private var conversationFocused: Bool {
        subviews.contains(where: { $0 is ConversationTextView && $0.isFirstResponder })
    }

    override var keyCommands: [UIKeyCommand]? {
        guard sourceEditing, !conversationFocused else { return super.keyCommands }
        let undo = UIKeyCommand(
            title: String(localized: "Undo"), action: #selector(undoSource), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(
            title: String(localized: "Redo"), action: #selector(redoSource), input: "z",
            modifierFlags: [.command, .shift])
        undo.wantsPriorityOverSystemBehavior = true
        redo.wantsPriorityOverSystemBehavior = true
        return [undo, redo]
    }

    @objc private func undoSource() { sourceHistoryAction?("undo") }
    @objc private func redoSource() { sourceHistoryAction?("redo") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undoSource) { return sourceEditing && !conversationFocused && canUndoSource }
        if action == #selector(redoSource) { return sourceEditing && !conversationFocused && canRedoSource }
        return super.canPerformAction(action, withSender: sender)
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        if conversationFocused { return }
        let ask = UIAction(title: "AI", image: UIImage(systemName: "bubble.left")) { [weak self] _ in
            self?.askSelectedText?()
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [ask]), atEndOfMenu: .standardEdit)
        if sourceEditing {
            let undo = UIAction(
                title: String(localized: "Undo"), image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: canUndoSource ? [] : .disabled
            ) { [weak self] _ in self?.undoSource() }
            let redo = UIAction(
                title: String(localized: "Redo"), image: UIImage(systemName: "arrow.uturn.forward"),
                attributes: canRedoSource ? [] : .disabled
            ) { [weak self] _ in self?.redoSource() }
            builder.insertChild(
                UIMenu(title: "", options: .displayInline, children: [undo, redo]), atEndOfMenu: .standardEdit)
        }
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
        composer = NativeComposerHost(webView: webView)
        composer.call = { [weak self] method, payload in
            _ = try? await self?.call(method, arguments: ["payload": payload])
        }
        configuration.userContentController.add(self, name: "reader")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.accessibilityIdentifier = "ReaderWebView"
        #if DEBUG
            webView.isInspectable = true
        #endif
        webView.askSelectedText = { [weak self] in
            Task { _ = try? await self?.call("askSelection") }
        }
        webView.sourceHistoryAction = { [weak session] action in session?.performSourceHistory(action) }
        session.bridge = self
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            session.errorMessage = String(localized: "Offline rendering resources are missing.")
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    func call(_ method: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard ready else { return nil }
        return try await webView.callAsyncJavaScript(
            "return await window.JustMarkdown[method](payload);",
            arguments: ["method": method, "payload": arguments["payload"] ?? NSNull()],
            in: nil, contentWorld: .page)
    }

    func update() {
        guard ready else { return }
        webView.sourceEditing = session.mode == "source" && !session.agentOpen
        updateTheme()
        guard let document = session.document, loadedToken != session.documentToken else { return }
        loadedToken = session.documentToken
        let token = loadedToken
        Task {
            do {
                _ = try await call(
                    "openDocument",
                    arguments: [
                        "payload": ["text": document.text, "token": token, "name": document.fileURL.lastPathComponent]
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
            if let mode = body["mode"] as? String, session.mode != mode { session.mode = mode }
            if let value = body["outline"] as? Bool, session.outlineExpanded != value {
                session.outlineExpanded = value
            }
        case "documentReady":
            if body["token"] as? String == session.documentToken { session.rendererReady = true }
        case "localResources":
            if let paths = body["paths"] as? [String], let token = body["token"] as? String {
                session.localResourcesChanged(paths, token: token)
            }
        case "source":
            if let text = body["text"] as? String, let token = body["token"] as? String {
                session.sourceChanged(text, token: token)
            }
        case "sourceHistory":
            if let token = body["token"] as? String {
                session.sourceHistoryChanged(
                    canUndo: body["canUndo"] as? Bool == true, canRedo: body["canRedo"] as? Bool == true, token: token)
            }
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
        session.agentTransport.cancel()
        composer.detach()
        webView.askSelectedText = nil
        webView.sourceHistoryAction = nil
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
        session.agentTransport.cancel()
        composer.blur()
        session.agentOpen = false
        session.agentModalActive = false
        ready = false
        loadedToken = ""
        lastTheme = ""
        session.rendererReady = false
        webView.reload()
    }
}

struct ReaderWebView: UIViewRepresentable {
    @ObservedObject var session: ReaderSession
    @Environment(\.dynamicTypeSize) var dynamicType
    @Environment(\.colorScheme) var colorScheme

    func makeCoordinator() -> ReaderBridge { ReaderBridge(session: session) }
    func makeUIView(context: Context) -> ReaderWKWebView { context.coordinator.webView }
    func updateUIView(_ uiView: ReaderWKWebView, context: Context) { context.coordinator.update() }
    static func dismantleUIView(_ uiView: ReaderWKWebView, coordinator: ReaderBridge) { coordinator.detach() }
}
