import UIKit
import WebKit
import XCTest

@testable import JustMarkdown

final class WebReaderTests: XCTestCase {
    @MainActor
    private func waitUntil(timeout: TimeInterval = 35, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTFail("Reader did not reach its expected state")
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
            return status["mode"] as? String == mode && transitioning == false
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
    func testFailedSourceSynchronizationKeepsCurrentDocumentAndRecentHistory() async throws {
        let (session, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let original = try XCTUnwrap(session.document)
        let token = session.documentToken
        let history = session.recentDocuments.documents
        let incoming = root.appendingPathComponent("next.md")
        try Data("# Next document\n".utf8).write(to: incoming)
        _ = try await bridge.webView.evaluateJavaScript(
            """
            window.readerTestFlushSource = window.JustMarkdown.flushSource;
            document.querySelector('.mdv-source-editor').value = '# Pending edits\\n';
            window.JustMarkdown.flushSource = () => { throw new Error('source unavailable'); };
            void 0;
            """)

        await session.open(incoming)
        XCTAssertTrue(session.document === original, "A failed source read must not close the current document")
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.recentDocuments.documents, history)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(original.documentState.contains(.closed))
        XCTAssertEqual(try String(contentsOf: incoming, encoding: .utf8), "# Next document\n")

        _ = try await bridge.webView.evaluateJavaScript(
            "window.JustMarkdown.flushSource = window.readerTestFlushSource; void 0;")
        // Retry after the source bridge recovers; no failed-open entry was recorded.
        await session.open(incoming)
        XCTAssertEqual(session.document?.fileURL, incoming)
        XCTAssertEqual(session.recentDocuments.documents.count, history.count + 1)
        XCTAssertEqual(try String(contentsOf: original.fileURL, encoding: .utf8), "# Pending edits\n")
        session.bridge = nil
        await session.closeDocument()
    }

    @MainActor
    func testCloseFlushesLatestSourceBufferBeforeDebounceFires() async throws {
        let (session, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let url = try XCTUnwrap(session.document?.fileURL)
        let text = "# Latest buffer\n\nNot yet delivered by the source debounce.\n"
        _ = try await bridge.webView.callAsyncJavaScript(
            "document.querySelector('.mdv-source-editor').value = text;",
            arguments: ["text": text], in: nil, contentWorld: .page)
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
        // Use WebKit's editing operation, so actual input events create history.
        _ = try await bridge.webView.evaluateJavaScript(
            "const s=document.querySelector('.mdv-source-editor'); s.focus(); s.setSelectionRange(s.value.length,s.value.length); document.execCommand('insertText',false,'h'); document.execCommand('insertText',false,'i');"
        )
        try await waitUntil { session.canUndoSource }
        let typed = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(typed, original + "hi")
        _ = try await bridge.call("historyAction", arguments: ["payload": ["action": "undo"]])
        let undone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(undone, original)
        XCTAssertTrue(session.canRedoSource)
        _ = try await bridge.call("historyAction", arguments: ["payload": ["action": "redo"]])
        let afterPaste = original + "hi\nPasted **text**.\n"
        _ = try await bridge.webView.callAsyncJavaScript(
            "const s=document.querySelector('.mdv-source-editor'); s.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertFromPaste'})); s.value=text; s.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertFromPaste'}));",
            arguments: ["text": afterPaste], in: nil, contentWorld: .page)
        let afterAgent = afterPaste.replacingOccurrences(of: "Pasted **text**.", with: "Rewritten **text**.")
            .replacingOccurrences(of: "# Navigation", with: "# Changed title")
        _ = try await bridge.call(
            "applyDocumentEdit",
            arguments: ["payload": ["before": afterPaste, "after": afterAgent, "id": "one-agent-batch"]])
        _ = try await bridge.call("historyAction", arguments: ["payload": ["action": "undo", "id": "one-agent-batch"]])
        let batchUndone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(batchUndone, afterPaste, "All edits in one Agent batch undo together")
        _ = try await bridge.call("historyAction", arguments: ["payload": ["action": "undo"]])
        let pasteUndone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(pasteUndone, original + "hi", "Paste remains a separate operation")
        _ = try await bridge.call("toggleMode")
        try await waitForMode("preview", bridge: bridge)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        _ = try await bridge.call("historyAction", arguments: ["payload": ["action": "redo"]])
        let pasteRedone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(pasteRedone, afterPaste)
        _ = try await bridge.call("setSource", arguments: ["payload": afterPaste + "New branch."])
        let result = try await bridge.call("historyAction", arguments: ["payload": ["action": "redo"]]) as? Bool
        XCTAssertEqual(result, false)
        await session.flushChanges()
        XCTAssertEqual(session.document?.text, afterPaste + "New branch.")
    }

    @MainActor
    func testOutlineSkipsEmptyHeadingsWhileReadingAndOverscrollingAtDocumentEnd() async throws {
        let (_, bridge, window, root) = try await navigationReader()
        defer {
            bridge.detach()
            window.isHidden = true
            try? FileManager.default.removeItem(at: root)
        }
        let markdown =
            "# Outline\n\n## First named section\n\n"
            + String(repeating: "A paragraph of reading content.\n\n", count: 35)
            + "###\n\n#### &nbsp;\n\n<h5> \t<br> </h5>\n\n"
            + "### Named *child*\n\nChild content.\n\n"
            + "## Last **named** section\n\nLast paragraph.\n\n##\n\n<h2> &nbsp; </h2>\n"
        _ = try await bridge.call("setSource", arguments: ["payload": markdown])
        try await waitUntil {
            let height = try await bridge.webView.evaluateJavaScript("document.documentElement.scrollHeight") as? Double
            return abs((height ?? 0) - bridge.webView.scrollView.contentSize.height) < 1
        }
        let bottom = max(0, bridge.webView.scrollView.contentSize.height - bridge.webView.scrollView.bounds.height)
        XCTAssertGreaterThan(bottom, 0)
        var frames: [[String: Any]] = []
        for overscroll in [CGFloat(0), 80, 160, 0] {
            bridge.webView.scrollView.setContentOffset(CGPoint(x: 0, y: bottom + overscroll), animated: false)
            let result = try await bridge.webView.callAsyncJavaScript(
                """
                for (let index = 0; index < 8; index++) await new Promise(requestAnimationFrame);
                const links = [...document.querySelectorAll('[data-toc-target]')];
                const selected = links.filter(link => link.getAttribute('aria-current') === 'location');
                return { offset: window.scrollY, maximum: document.documentElement.scrollHeight - innerHeight,
                  labels: links.map(link => link.textContent), selected: selected.map(link => link.textContent),
                  blankArticleHeadings: [...document.querySelectorAll('.mdv-article :is(h1,h2,h3,h4,h5,h6)')]
                    .filter(heading => !heading.textContent.trim()).length };
                """, arguments: [:], in: nil, contentWorld: .page)
            let frame = try XCTUnwrap(result as? [String: Any])
            frames.append(frame)
            XCTAssertEqual(frame["labels"] as? [String], ["First named section", "Named child", "Last named section"])
            XCTAssertEqual(frame["selected"] as? [String], ["Last named section"])
            XCTAssertEqual(frame["blankArticleHeadings"] as? Int, 5, "Preview must preserve the document's headings")
        }
        XCTAssertTrue(
            frames.contains { ($0["offset"] as? Double ?? 0) > ($0["maximum"] as? Double ?? .infinity) + 20 },
            "Exercise WebKit's native bottom overscroll, not just a clamped JavaScript scroll")
        let source = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(source, markdown)
        let trace = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: frames, options: .prettyPrinted),
            uniformTypeIdentifier: "public.json")
        trace.name = "outline-document-end-overscroll"
        trace.lifetime = .keepAlways
        add(trace)
        let snapshot = try await bridge.webView.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "outline-at-document-end"
        attachment.lifetime = .keepAlways
        add(attachment)

        let unnamed = "#\n\n##\n\n<h3> &nbsp; </h3>\n"
        _ = try await bridge.call("setSource", arguments: ["payload": unnamed])
        let emptyOutline = try await diagnostics(bridge)
        XCTAssertEqual(emptyOutline["headings"] as? [String], [])
        XCTAssertEqual(emptyOutline["source"] as? String, unnamed)
        let emptyRows =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('[data-toc-target]').length") as? Int
        XCTAssertEqual(emptyRows, 0, "A document with only empty headings must not create empty outline controls")
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
        _ = try await bridge.call("setSource", arguments: ["payload": edited])
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
        _ = try await bridge.call(
            "setSource",
            arguments: ["payload": "# Earlier section\n\nEarlier text.\n\n## Updated source\n\nSelected phrase.\n"])
        _ = try await bridge.webView.evaluateJavaScript(
            """
            const editor = document.querySelector('.mdv-source-editor');
            const start = editor.value.indexOf('Selected phrase');
            editor.setSelectionRange(start, start + 'Selected phrase'.length);
            """)
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
