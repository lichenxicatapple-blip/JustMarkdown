import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import JustMarkdown

final class WebReaderTests: XCTestCase {
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 35, message: @autoclosure () -> String = "Reader did not reach its expected state",
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTFail(message(), file: file, line: line)
        throw CocoaError(.coderReadCorrupt)
    }

    @MainActor
    private func diagnostics(_ bridge: ReaderBridge) async throws -> [String: Any] {
        let value = try await bridge.call("diagnostics")
        return try XCTUnwrap(value as? [String: Any])
    }

    @MainActor
    private func waitForMode(_ mode: String, bridge: ReaderBridge) async throws {
        try await waitUntil {
            let status = try await self.diagnostics(bridge)
            let transitioning =
                try await bridge.webView.evaluateJavaScript(
                    "Boolean(document.querySelector('.mdv-app').dataset.modeTransition)") as? Bool
            let editorReady =
                mode != "source"
                || (!bridge.sourceEditor.textView.isHidden && bridge.sourceEditor.textView.isUserInteractionEnabled)
            return status["mode"] as? String == mode && transitioning == false && editorReady
        }
    }

    @MainActor
    private func navigationReader() async throws -> (ReaderSession, ReaderBridge, UIWindow, URL) {
        let session = ReaderSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text =
            "# Navigation\n\n"
            + (1...60).map { index in
                "## Section \(index)\n\n" + String(repeating: "Paragraph content for navigation.\n\n", count: 18)
                    + (index == 60 ? "### Detail 60\n\nFinal content.\n" : "")
            }.joined(separator: "\n")
        let url = root.appendingPathComponent("navigation.md")
        try Data(text.utf8).write(to: url)
        await session.grant(root)
        await session.open(url)
        let bridge = ReaderBridge(session: session)
        // A real MediaQueryList, isolated to this test page, exposes preference changes.
        bridge.webView.configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                    (() => {
                      const original = window.matchMedia.bind(window), query = '(prefers-reduced-motion: reduce)';
                      window.readerTestMotion = original(query);
                      window.matchMedia = value => value === query ? window.readerTestMotion : original(value);
                    })();
                    """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        controller.view.addSubview(bridge.webView)
        try await waitUntil { bridge.ready && session.rendererReady }
        if try await diagnostics(bridge)["outline"] as? Bool != true { _ = try await bridge.call("toggleOutline") }
        return (session, bridge, window, root)
    }

    @MainActor
    func testReaderViewportOnlyAvoidsInputCoveringItsEntireBottomEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 1210, height: 802)
        let cases: [(String, CGRect, CGFloat)] = [
            ("Hidden", CGRect(x: 0, y: 802, width: 1210, height: 0), 802),
            ("Left mini toolbar", CGRect(x: 5, y: 724.5, width: 65, height: 52.5), 802),
            ("Right mini toolbar", CGRect(x: 1140, y: 724.5, width: 65, height: 52.5), 802),
            ("Floating at bottom center", CGRect(x: 445, y: 482, width: 320, height: 320), 802),
            ("Floating near top", CGRect(x: 445, y: 0, width: 320, height: 320), 802),
            ("Full-width undocked", CGRect(x: 0, y: 300, width: 1210, height: 320), 802),
            ("Docked", CGRect(x: 0, y: 482, width: 1210, height: 320), 482),
            ("Docked overlapping a smaller window", CGRect(x: -100, y: 482, width: 1400, height: 400), 482),
        ]
        for (name, keyboard, bottom) in cases {
            XCTAssertEqual(
                keyboard.minY + ReaderContainer.viewportBottomOffset(keyboard: keyboard, in: bounds),
                bottom, accuracy: 0.5, name)
        }
    }

    @MainActor
    func testReaderContainerFillsScreenWhileNativeEditorFollowsKeyboardGuide() async throws {
        let session = ReaderSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keyboard.md")
        try Data(("# Keyboard\n\n" + String(repeating: "A line of editable content.\n", count: 100)).utf8).write(
            to: file)
        await session.open(file)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ReaderScreen(session: session))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            session.bridge?.detach()
            window.isHidden = true
        }
        try await waitUntil { session.rendererReady }
        let bridge = try XCTUnwrap(session.bridge)
        let viewport = try XCTUnwrap(bridge.webView.superview as? ReaderViewport)
        let container = try XCTUnwrap(viewport.superview as? ReaderContainer)
        func controlsSurface(in view: UIView) -> ReaderControlsSurface? {
            if let surface = view as? ReaderControlsSurface { return surface }
            return view.subviews.lazy.compactMap { controlsSurface(in: $0) }.first
        }
        let controls = try XCTUnwrap(controlsSurface(in: window))
        let actions = try XCTUnwrap(controls.subviews.first)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        let editor = bridge.sourceEditor.textView
        func layoutFits() -> Bool {
            window.layoutIfNeeded()
            let canvas = container.convert(container.bounds, to: window)
            let source = editor.convert(editor.bounds, to: window)
            let boundary = container.convert(container.keyboardLayoutGuide.layoutFrame.origin, to: window).y
            return abs(canvas.maxY - window.bounds.maxY) < 1 && abs(source.maxY - boundary) < 1
                && source.height > 0
        }
        func controlsFit() -> Bool {
            let safeBottom = controls.safeAreaLayoutGuide.layoutFrame.maxY - 16
            let keyboardTop = controls.keyboardLayoutGuide.layoutFrame.minY - ReaderDesign.floatingGap
            return actions.bounds.height > 0 && abs(actions.frame.maxY - min(safeBottom, keyboardTop)) < 1
        }
        try await waitUntil(timeout: 8) { layoutFits() && controlsFit() }
        XCTAssertTrue(controls.keyboardLayoutGuide.followsUndockedKeyboard)
        XCTAssertTrue(container.keyboardLayoutGuide.followsUndockedKeyboard)
        XCTAssertNil(controls.hitTest(CGPoint(x: controls.bounds.midX, y: 10), with: nil))
        XCTAssertNotNil(controls.hitTest(actions.center, with: nil))
        XCTAssertTrue(editor.becomeFirstResponder())
        try await waitUntil(
            timeout: 8,
            message:
                "Container \(container.convert(container.bounds, to: window)), source \(editor.convert(editor.bounds, to: window)), keyboard guide \(container.keyboardLayoutGuide.layoutFrame), first responder \(editor.isFirstResponder)"
        ) { layoutFits() && controlsFit() && container.keyboardLayoutGuide.layoutFrame.height > 0 }
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        editor.insertText("Last edited line.")
        try await waitUntil(timeout: 8) {
            guard let selection = editor.selectedTextRange else { return false }
            let caret = editor.convert(editor.caretRect(for: selection.end), to: window)
            let source = editor.convert(editor.bounds, to: window)
            return layoutFits() && caret.minY >= source.minY && caret.maxY <= source.maxY + 1
        }
        XCTAssertTrue(editor.resignFirstResponder())
        try await waitUntil(timeout: 8) {
            layoutFits() && controlsFit()
                && abs(editor.convert(editor.bounds, to: window).maxY - window.bounds.maxY) < 1
        }
        await session.closeDocument()
    }

    @MainActor
    func testShortDocumentFillsViewportWithoutClippingOutlineOrAddingEmptyScrollArea() async throws {
        let session = ReaderSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("short.md")
        let markdown = "# Short document\n\n## One\n\nLast paragraph.\n"
        try Data(markdown.utf8).write(to: file)
        await session.grant(root)
        await session.open(file)
        let bridge = ReaderBridge(session: session)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.addSubview(bridge.webView)
        defer {
            bridge.detach()
            window.isHidden = true
        }
        // Both the tall screenshot case and a short landscape/split-screen
        // viewport must fit. A fixed minimum height hides the latter failure.
        for size in [
            CGSize(width: 1024, height: 1366), CGSize(width: 1024, height: 430), CGSize(width: 390, height: 844),
        ] {
            bridge.webView.frame = CGRect(origin: .zero, size: size)
            try await waitUntil { bridge.ready && session.rendererReady }
            try await waitUntil {
                let viewport = try await bridge.webView.evaluateJavaScript("[innerWidth, innerHeight]") as? [Double]
                return viewport == [size.width, size.height]
            }
            if !session.outlineExpanded { _ = try await bridge.call("toggleOutline") }
            try await waitUntil {
                try await bridge.webView.evaluateJavaScript(
                    "!document.querySelector('.mdv-reading-layout').getAnimations().some(a => a.playState === 'running')"
                ) as? Bool == true
            }
            let measured = try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const rect = selector => document.querySelector(selector).getBoundingClientRect();
                  return { height: innerHeight, width: innerWidth,
                    layout: rect('.mdv-reading-layout').height, outline: rect('.mdv-outline').bottom,
                    content: rect('.mdv-article').bottom, scroll: document.documentElement.scrollHeight };
                })()
                """)
            let geometry = try XCTUnwrap(measured as? [String: Double])
            let viewport = try XCTUnwrap(geometry["height"])
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(geometry["layout"]), viewport - 1, "Reader stopped early: \(geometry)")
            // Compact outline has the intended 16px bottom inset.
            XCTAssertEqual(
                try XCTUnwrap(geometry["outline"]), viewport - (size.width <= 560 ? 16 : 0), accuracy: 1,
                "Outline does not cover its viewport: \(geometry)")
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(geometry["scroll"]), viewport + 1,
                "A short document must not create a blank scroll area: \(geometry)")
            XCTAssertLessThan(try XCTUnwrap(geometry["content"]), viewport)
            _ = try await bridge.call("toggleMode")
            try await waitForMode("source", bridge: bridge)
            let sourceGeometry = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-app').getBoundingClientRect().height")
            let sourceHeight = try XCTUnwrap(sourceGeometry as? Double)
            XCTAssertEqual(sourceHeight, viewport, accuracy: 1, "Source must use the same full viewport")
            _ = try await bridge.call("toggleMode")
            try await waitForMode("preview", bridge: bridge)
        }
        XCTAssertEqual(session.document?.text, markdown)
        await session.closeDocument()
    }

    @MainActor
    func testLocalImagePermissionTargetsCommonFolderAndReloadsWithoutReopeningDocument() async throws {
        let session = ReaderSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("文档", isDirectory: true)
        let images = notes.appendingPathComponent("images", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for folder in [images, assets] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let svg = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><circle cx=\"16\" cy=\"16\" r=\"12\"/></svg>"
                .utf8)
        try svg.write(to: images.appendingPathComponent("同级.svg"))
        try svg.write(to: assets.appendingPathComponent("上级.svg"))
        let file = notes.appendingPathComponent("阅读.md")
        let markdown = "# Local images\n\n![Sibling](images/同级.svg)\n\n![Parent](../assets/上级.svg)\n"
        try Data(markdown.utf8).write(to: file)
        await session.open(file)
        let token = session.documentToken
        let bridge = ReaderBridge(session: session)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        controller.view.addSubview(bridge.webView)
        defer {
            bridge.detach()
            window.isHidden = true
        }
        try await waitUntil { session.rendererReady && session.needsResourcePermission }
        XCTAssertEqual(session.resourcePermissionDirectory, root.resolvingSymlinksInPath())
        await session.grant(root)
        session.reloadResources()
        try await waitUntil {
            let images = try await self.diagnostics(bridge)["localImages"] as? [[String: Any]] ?? []
            return images.count == 2 && images.allSatisfy { $0["loaded"] as? Bool == true }
        }
        XCTAssertFalse(session.needsResourcePermission)
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.document?.text, markdown)
        await session.closeDocument()
    }

    @MainActor
    func testSavingBeforeRendererReadyPreservesTheNativeWorkingText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("early-save.md")
        let text = "# Original\n\n尚未完成 Web 渲染时，保存仍必须保留原文。\n"
        try Data(text.utf8).write(to: url)
        let session = ReaderSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await session.open(url)
        let bridge = ReaderBridge(session: session)
        defer { bridge.detach() }
        XCTAssertFalse(bridge.ready)
        let saved = await session.flushChanges()
        XCTAssertTrue(saved)
        XCTAssertEqual(session.document?.text, text)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        await session.closeDocument()
    }

    @MainActor
    func testSwitchingDocumentsSavesNativeBufferWithoutAWebSourceRead() async throws {
        let (session, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let original = try XCTUnwrap(session.document)
        let history = session.recentDocuments.documents
        let incoming = root.appendingPathComponent("next.md")
        try Data("# Next document\n".utf8).write(to: incoming)
        let text = "# Pending native edits\n"
        bridge.sourceEditor.textView.selectedRange = NSRange(location: 0, length: original.text.utf16.count)
        bridge.sourceEditor.textView.insertText(text)
        _ = try await bridge.webView.evaluateJavaScript(
            "window.JustMarkdown.sourceState = () => { throw new Error('renderer unavailable'); }; void 0;")
        await session.open(incoming)
        XCTAssertEqual(session.document?.fileURL, incoming)
        XCTAssertEqual(session.recentDocuments.documents.count, history.count + 1)
        XCTAssertEqual(try String(contentsOf: original.fileURL, encoding: .utf8), text)
        XCTAssertEqual(try String(contentsOf: incoming, encoding: .utf8), "# Next document\n")
        session.bridge = nil
        await session.closeDocument()
    }

    @MainActor
    func testCloseCommitsMarkedNativeTextBeforeSaving() async throws {
        let (session, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let url = try XCTUnwrap(session.document?.fileURL)
        let editor = bridge.sourceEditor.textView
        let text = "# 最新内容\n\n尚在输入法组合中的原生文本。\n"
        editor.selectedRange = NSRange(location: 0, length: editor.text.utf16.count)
        editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        XCTAssertNotEqual(session.document?.text, text)
        await session.closeDocument()
        XCTAssertNil(session.document)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    @MainActor
    func testSourceHistoryGroupsTypingAndKeepsPasteAndAgentTransactionsSeparate() async throws {
        let (session, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let original = try XCTUnwrap(session.document?.text)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        let editor = bridge.sourceEditor.textView
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: original.utf16.count, length: 0)
        editor.insertText("h")
        editor.insertText("i")
        try await waitUntil { session.canUndoSource }
        let typed = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(typed, original + "hi")
        _ = bridge.moveSourceHistory(forward: false)
        let undone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(undone, original)
        XCTAssertTrue(session.canRedoSource)
        _ = bridge.moveSourceHistory(forward: true)
        let afterPaste = original + "hi\nPasted **text**.\n"
        let clipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = clipboard }
        UIPasteboard.general.string = "\nPasted **text**.\n"
        editor.paste(nil)
        try await waitUntil { session.document?.text == afterPaste }
        let afterAgent = afterPaste.replacingOccurrences(of: "Pasted **text**.", with: "Rewritten **text**.")
            .replacingOccurrences(of: "# Navigation", with: "# Changed title")
        _ = bridge.applySourceEdit(before: afterPaste, after: afterAgent, id: "one-agent-batch")
        _ = bridge.moveSourceHistory(forward: false, id: "one-agent-batch")
        let batchUndone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(batchUndone, afterPaste, "All edits in one Agent batch undo together")
        _ = bridge.moveSourceHistory(forward: false)
        let pasteUndone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(pasteUndone, original + "hi", "Paste remains a separate operation")
        _ = try await bridge.call("toggleMode")
        try await waitForMode("preview", bridge: bridge)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        _ = bridge.moveSourceHistory(forward: true)
        let pasteRedone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(pasteRedone, afterPaste)
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: afterPaste + "New branch.")
        let result = bridge.moveSourceHistory(forward: true)
        XCTAssertEqual(result, false)
        await session.flushChanges()
        XCTAssertEqual(session.document?.text, afterPaste + "New branch.")
    }

    @MainActor
    func testOutlineAvailabilityFollowsDocumentEditsAndPreservesEmptyHeadings() async throws {
        let (session, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(session.hasOutline)
        for markdown in [
            "", "Plain reading content.\n", "# Document title\n\nReading content.\n",
            "```markdown\n## This is code, not a heading\n```\n",
        ] {
            _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: markdown)
            try await waitUntil { !session.hasOutline && !session.outlineExpanded }
            _ = try await bridge.call("toggleOutline")
            let status = try await diagnostics(bridge)
            XCTAssertEqual(status["outline"] as? Bool, false)
            XCTAssertEqual(status["source"] as? String, markdown)
            try await waitUntil {
                try await bridge.webView.evaluateJavaScript(
                    """
                    (() => {
                      const outline = document.querySelector('.mdv-outline');
                      const layout = document.querySelector('.mdv-reading-layout');
                      const workspace = document.querySelector('.mdv-workspace');
                      return outline.hidden && !layout.classList.contains('mdv-with-outline')
                        && Math.abs(workspace.getBoundingClientRect().left - layout.getBoundingClientRect().left) < 1;
                    })()
                    """) as? Bool == true
            }
        }

        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        let edited = "Reading content.\n\n## Added section\n\nMore content.\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: edited)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("preview", bridge: bridge)
        try await waitUntil { session.hasOutline && session.outlineExpanded }
        let editedStatus = try await diagnostics(bridge)
        XCTAssertEqual(editedStatus["headings"] as? [String], ["Added section"])

        let emptyHeading = "Reading content.\n\n##\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: emptyHeading)
        try await waitUntil { session.hasOutline }
        let status = try await diagnostics(bridge)
        XCTAssertEqual(status["headings"] as? [String], [""])
        XCTAssertEqual(status["source"] as? String, emptyHeading)
    }

    @MainActor
    func testOutlineNavigationPreservesContentAndDestination() async throws {
        let (_, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let result = try await bridge.webView.callAsyncJavaScript(
            """
            return await new Promise(resolve => {
              const article = document.querySelector('.mdv-article');
              const layout = document.querySelector('.mdv-reading-layout');
              const links = [...document.querySelectorAll('[data-toc-target]')];
              const target = links[31];
              const destination = document.getElementById(target.dataset.tocTarget);
              const originalContent = article.firstElementChild;
              let replaced = 0;
              const observer = new MutationObserver(records => { replaced += records.length; });
              observer.observe(article, { childList: true });
              const started = performance.now(), frames = [];
              target.click();
              const sample = now => {
                frames.push({ ms: now - started, y: window.scrollY,
                  targetY: destination.getBoundingClientRect().top,
                  current: document.querySelector('[aria-current="location"]')?.textContent || '',
                  opacity: Number(getComputedStyle(layout).opacity),
                  visible: article.getClientRects().length > 0,
                  sameContent: article.firstElementChild === originalContent });
                if (now - started < 2200) { requestAnimationFrame(sample); return; }
                observer.disconnect();
                resolve({ target: target.textContent, replaced, frames,
                  tapHighlight: getComputedStyle(target).webkitTapHighlightColor });
              };
              requestAnimationFrame(sample);
            });
            """, arguments: [:], in: nil, contentWorld: .page)
        let probe = try XCTUnwrap(result as? [String: Any])
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: probe, options: .prettyPrinted),
            uniformTypeIdentifier: "public.json")
        attachment.name = "outline-navigation-frame-trace"
        attachment.lifetime = .keepAlways
        add(attachment)
        let frames = try XCTUnwrap(probe["frames"] as? [[String: Any]])
        XCTAssertEqual(
            probe["tapHighlight"] as? String, "rgba(0, 0, 0, 0)",
            "The outline already supplies selection feedback; WebKit must not draw a second gray overlay")
        XCTAssertEqual(probe["replaced"] as? Int, 0)
        XCTAssertTrue(
            frames.allSatisfy {
                $0["visible"] as? Bool == true && $0["sameContent"] as? Bool == true && $0["opacity"] as? Double == 1
            })
        XCTAssertTrue(
            frames.allSatisfy { $0["current"] as? String == probe["target"] as? String },
            "A clicked destination must remain selected throughout navigation")
        XCTAssertLessThan(abs(frames.last?["targetY"] as? Double ?? .infinity), 120)
    }

    @MainActor
    func testOutlineCentersCurrentChapterAndRetargetsSmoothlyWithoutOverridingManualBrowse() async throws {
        let (_, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let result = try await bridge.webView.callAsyncJavaScript(
            """
            const body = document.querySelector('.mdv-outline-body');
            const reader = document.querySelector('.mdv-article');
            const links = [...document.querySelectorAll('[data-toc-target]')];
            const headings = links.map(link => document.getElementById(link.dataset.tocTarget));
            const frame = () => new Promise(requestAnimationFrame);
            const settle = async (ready = () => true) => {
              const started = performance.now();
              let previous = body.scrollTop, stable = 0;
              while (performance.now() - started < 1800) {
                await frame();
                const position = body.scrollTop;
                stable = Math.abs(position - previous) < .2 ? stable + 1 : 0;
                previous = position;
                if (stable >= 5 && performance.now() - started > 100 && ready()) break;
              }
            };
            const measure = () => {
              const selected = document.querySelector('[aria-current="location"]');
              const row = selected.getBoundingClientRect(), pane = body.getBoundingClientRect();
              return { current: selected.textContent, offset: body.scrollTop,
                maximum: body.scrollHeight - body.clientHeight, height: body.clientHeight,
                centerError: row.top + row.height / 2 - (pane.top + body.clientTop + body.clientHeight / 2),
                documentY: window.scrollY };
            };
            const readAt = async (index, following = true) => {
              headings[index].scrollIntoView({ block: 'start', behavior: 'instant' });
              const documentY = window.scrollY;
              await settle(() => {
                const current = measure();
                const target = Math.max(0, Math.min(current.maximum, current.offset + current.centerError));
                return current.current === links[index].textContent && (!following || Math.abs(current.offset - target) < 2);
              });
              return { ...measure(), expectedDocumentY: documentY };
            };
            const centered = await readAt(17);
            body.dispatchEvent(new WheelEvent('wheel', { deltaY: -200, bubbles: true }));
            body.scrollTop = 0;
            window.scrollBy({ top: 12, behavior: 'instant' });
            await settle();
            const manualSameChapter = measure();
            // Momentum may change chapters after the reader starts browsing the outline.
            const manualDuringMomentum = await readAt(18, false);
            reader.dispatchEvent(new WheelEvent('wheel', { deltaY: 200, bubbles: true }));
            const resumed = await readAt(20);
            const trace = [], sequence = [28, 12, 30, 15, 29], started = performance.now();
            let index = 0;
            while (performance.now() - started < 1100) {
              const now = await frame(), elapsed = now - started;
              if (index < sequence.length && elapsed >= index * 75) {
                headings[sequence[index++]].scrollIntoView({ block: 'start', behavior: 'instant' });
              }
              trace.push({ ms: elapsed, offset: body.scrollTop, current: measure().current });
            }
            await settle();
            const rapid = measure();
            const reopenedDocumentY = window.scrollY;
            body.dispatchEvent(new Event('touchstart', { bubbles: true }));
            body.scrollTop = 0;
            window.JustMarkdown.toggleOutline(); window.JustMarkdown.toggleOutline();
            await settle();
            const reopened = measure();
            const end = await readAt(headings.length - 1);
            const start = await readAt(0);
            const query = window.readerTestMotion;
            Object.defineProperty(query, 'matches', { value: true, configurable: true });
            query.dispatchEvent(new MediaQueryListEvent('change', { matches: true, media: query.media }));
            headings[24].scrollIntoView({ block: 'start', behavior: 'instant' });
            const reducedFrames = [body.scrollTop];
            for (let step = 0; step < 4; step++) { await frame(); reducedFrames.push(body.scrollTop); }
            const reduced = measure();
            await readAt(headings.length - 1);
            const parent = links[59], branchToggle = parent.parentElement.querySelector('[data-collapse-heading]');
            branchToggle.click();
            await settle();
            window.JustMarkdown.toggleOutline(); window.JustMarkdown.toggleOutline();
            await settle();
            const collapsed = { ...measure(), expanded: branchToggle.getAttribute('aria-expanded') };
            return { centered, manualSameChapter, manualDuringMomentum, resumed, trace, rapid,
              reopened, reopenedDocumentY, end, start, reduced, reducedFrames, collapsed };
            """, arguments: [:], in: nil, contentWorld: .page)
        let probe = try XCTUnwrap(result as? [String: Any])
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: probe, options: .prettyPrinted),
            uniformTypeIdentifier: "public.json")
        attachment.name = "outline-center-and-rapid-follow-trace"
        attachment.lifetime = .keepAlways
        add(attachment)
        for (name, chapter) in [
            ("centered", "Section 18"), ("resumed", "Section 21"), ("rapid", "Section 30"), ("reopened", "Section 30"),
        ] {
            let state = try XCTUnwrap(probe[name] as? [String: Any])
            XCTAssertEqual(state["current"] as? String, chapter, name)
            XCTAssertEqual(state["centerError"] as? Double ?? .infinity, 0, accuracy: 2, name)
            if let expectedY = state["expectedDocumentY"] as? Double {
                XCTAssertEqual(
                    state["documentY"] as? Double ?? .infinity, expectedY, accuracy: 1,
                    "Following must scroll only the outline pane")
            }
        }
        for name in ["manualSameChapter", "manualDuringMomentum"] {
            let state = try XCTUnwrap(probe[name] as? [String: Any])
            XCTAssertEqual(
                state["offset"] as? Double ?? .infinity, 0, accuracy: 1, "Manual browsing must remain in control")
        }
        let reopened = try XCTUnwrap(probe["reopened"] as? [String: Any])
        XCTAssertEqual(reopened["documentY"] as? Double, probe["reopenedDocumentY"] as? Double)
        let start = try XCTUnwrap(probe["start"] as? [String: Any])
        let end = try XCTUnwrap(probe["end"] as? [String: Any])
        XCTAssertEqual(start["offset"] as? Double ?? .infinity, 0, accuracy: 1)
        XCTAssertEqual(end["offset"] as? Double ?? .infinity, end["maximum"] as? Double ?? -.infinity, accuracy: 1)
        let trace = try XCTUnwrap(probe["trace"] as? [[String: Any]])
        let height = try XCTUnwrap((probe["rapid"] as? [String: Any])?["height"] as? Double)
        let offsets = trace.compactMap { $0["offset"] as? Double }
        XCTAssertGreaterThan(
            Set(offsets.map { Int($0.rounded()) }).count, 12, "Rapid following must show intermediate frames")
        for (previous, next) in zip(trace, trace.dropFirst()) {
            let elapsed = (next["ms"] as? Double ?? 0) - (previous["ms"] as? Double ?? 0)
            if elapsed < 40 {
                XCTAssertLessThan(
                    abs((next["offset"] as? Double ?? 0) - (previous["offset"] as? Double ?? 0)), height / 3,
                    "A frame must not jump across the pane")
            }
        }
        let reduced = try XCTUnwrap(probe["reduced"] as? [String: Any])
        XCTAssertEqual(reduced["current"] as? String, "Section 25")
        XCTAssertEqual(reduced["centerError"] as? Double ?? .infinity, 0, accuracy: 2)
        let reducedFrames = try XCTUnwrap(probe["reducedFrames"] as? [Double])
        XCTAssertEqual(
            Set(reducedFrames).count, 2, "Reduce Motion must position directly without intermediate scrolling")
        let collapsed = try XCTUnwrap(probe["collapsed"] as? [String: Any])
        XCTAssertEqual(collapsed["current"] as? String, "Section 60")
        XCTAssertEqual(
            collapsed["expanded"] as? String, "false",
            "Following and reopening must preserve a manually collapsed branch")
    }

    @MainActor
    func testOfflineRenderingEditingPositionsAndSelection() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://reader.example.test/v1", forKey: "model.baseURL")
        defaults.set("fixture-model", forKey: "model.id")
        let session = ReaderSession(defaults: defaults, modelKey: { "fixture-key" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sample = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Sample"))
        try FileManager.default.copyItem(at: sample, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reading-guide.md")
        // Remote-image loading is independent of the offline document engine.
        let original = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(
                of: "https://cdn.jsdelivr.net/gh/mdn/shared-assets@main/images/examples/balloons.jpg",
                with: "images/market-structure.svg")
        try Data(original.utf8).write(to: url)
        await session.grant(root)
        await session.open(url)
        let bridge = ReaderBridge(session: session)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        bridge.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(bridge.webView)
        defer {
            bridge.detach()
            window.isHidden = true
        }
        try await waitUntil { bridge.ready && session.rendererReady }
        try await waitUntil {
            let status = try await bridge.call("diagnostics") as? [String: Any]
            let images = status?["localImages"] as? [[String: Any]] ?? []
            return !images.isEmpty && images.allSatisfy { $0["loaded"] as? Bool == true }
        }
        var status = try await diagnostics(bridge)
        XCTAssertEqual(status["source"] as? String, original)
        XCTAssertEqual(status["math"] as? Int, 7)
        XCTAssertEqual(status["diagrams"] as? Int, 6)
        XCTAssertEqual(status["diagramErrors"] as? Int, 0)
        XCTAssertGreaterThan(status["tables"] as? Int ?? 0, 0)
        XCTAssertGreaterThan((status["headings"] as? [String])?.count ?? 0, 25)
        XCTAssertEqual(status["overflow"] as? Bool, false)
        XCTAssertFalse(session.needsResourcePermission)

        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 150])
        status = try await diagnostics(bridge)
        let before = try XCTUnwrap((status["anchor"] as? [String: Any])?["line"] as? Double)
        for expected in ["source", "preview", "source", "preview"] {
            _ = try await bridge.call("toggleMode")
            try await waitForMode(expected, bridge: bridge)
            let result = try await diagnostics(bridge)
            let after = try XCTUnwrap((result["anchor"] as? [String: Any])?["line"] as? Double)
            XCTAssertEqual(after, before, accuracy: 0.6, "Repeated switches must not accumulate drift")
        }
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 260])
        _ = try await bridge.call("toggleMode")
        try await waitForMode("preview", bridge: bridge)
        let followed = try await diagnostics(bridge)
        let followedLine = try XCTUnwrap((followed["anchor"] as? [String: Any])?["line"] as? Double)
        XCTAssertEqual(followedLine, 260, accuracy: 1.5)

        let edited =
            original + """

                ## Native edit verification

                <details><summary>HTML summary</summary><p>HTML content</p></details>
                <script>window.jmInjected = true;</script>
                <img src="images/market-structure.svg" onerror="window.jmInjected = true;">
                <iframe src="https://example.test"></iframe>

                """
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: edited)
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited)
        status = try await diagnostics(bridge)
        XCTAssertTrue((status["headings"] as? [String])?.contains("Native edit verification") == true)
        XCTAssertEqual(status["unsafeTags"] as? Int, 0)
        let injection = try await bridge.webView.evaluateJavaScript("Boolean(window.jmInjected)") as? Bool
        XCTAssertEqual(injection, false)
        let eventHandlers =
            try await bridge.webView.evaluateJavaScript("document.querySelectorAll('.mdv-article [onerror]').length")
            as? Int
        XCTAssertEqual(eventHandlers, 0)

        // A system context menu must suppress Ask while preserving the native selection.
        _ = try await bridge.webView.evaluateJavaScript(
            """
            const paragraph = document.querySelector('.mdv-article p');
            const range = document.createRange(); range.selectNodeContents(paragraph);
            const selected = window.getSelection(); selected.removeAllRanges(); selected.addRange(range);
            """)
        _ = try await bridge.call("suppressSelection")
        status = try await diagnostics(bridge)
        XCTAssertEqual(status["questionVisible"] as? Bool, false)
        XCTAssertFalse((status["selectedText"] as? String ?? "").isEmpty)
        _ = try await bridge.call("askSelection")
        try await waitUntil { session.agentOpen }
        let agentResult = try await bridge.call("agentDiagnostics")
        var agent = try XCTUnwrap(agentResult as? [String: Any])
        XCTAssertTrue((agent["reference"] as? String ?? "").contains(status["selectedText"] as? String ?? ""))
        await session.closeAgent()
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        _ = bridge.sourceEditor.replace(
            expected: bridge.sourceEditor.history.text,
            with: "# Earlier section\n\nEarlier text.\n\n## Updated source\n\nSelected phrase.\n")
        bridge.sourceEditor.textView.selectedRange = (bridge.sourceEditor.history.text as NSString).range(
            of: "Selected phrase")
        _ = try await bridge.call("askSelection")
        try await waitUntil { session.agentOpen }
        let sourceAgentResult = try await bridge.call("agentDiagnostics")
        agent = try XCTUnwrap(sourceAgentResult as? [String: Any])
        XCTAssertTrue((agent["reference"] as? String ?? "").contains("Selected phrase"))
        XCTAssertFalse((agent["reference"] as? String ?? "").contains("Earlier text"))
        await session.closeAgent()
        await session.flushChanges()
        let closed = await session.document?.closeSavingChanges()
        XCTAssertEqual(closed, true)
    }
}
