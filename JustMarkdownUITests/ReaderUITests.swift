import UIKit
import XCTest

@MainActor
final class ReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func record(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertTextIsPainted(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        // Accessibility nodes survive a missing WebKit backing store. Check the
        // actual screen pixels so DOM presence alone cannot pass this regression.
        let image = try XCTUnwrap(element.screenshot().image.cgImage, file: file, line: line)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                file: file, line: line)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var brightness: [Int] = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            brightness.append((red + green + blue) / 3)
        }
        let background = brightness.sorted()[brightness.count / 2]
        XCTAssertGreaterThan(
            brightness.filter { abs($0 - background) > 40 }.count, 12,
            "The outline element exists but its text has not been painted", file: file, line: line)
    }

    private func allowDataSharingIfRequested(_ app: XCUIApplication) {
        let allow = app.alerts.buttons["AllowModelDataSharing"].firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    func testFloatingToolsRemainInteractiveAfterCollapseAndRapidReversal() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--sample-document", "--reset-sample-document"]
        app.launch()
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        let toggle = app.buttons["ToolsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for cycle in 0..<3 {
            showTools(app)
            XCTAssertTrue(app.buttons["GlobalAI"].isHittable)
            record("tools-expanded-cycle-\(cycle)")
            toggle.tap()
            guard app.buttons["GlobalAI"].waitForNonExistence(timeout: 5) else {
                record("tools-failed-to-collapse-cycle-\(cycle)")
                XCTFail("The expanded tools must actually disappear after collapsing")
                return
            }
            XCTAssertTrue(toggle.isHittable)
            toggle.doubleTap()
        }
        showTools(app)
        toggle.tap()
        XCTAssertTrue(app.buttons["ModeToggle"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
    }

    func testNativeSourceFillsViewportAndFoldsControlsDuringInput() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let web = app.webViews.firstMatch
        XCTAssertEqual(editor.frame.minX, web.frame.minX, accuracy: 1)
        XCTAssertEqual(editor.frame.maxX, web.frame.maxX, accuracy: 1)
        XCTAssertEqual(editor.frame.maxY, web.frame.maxY, accuracy: 1)
        XCTAssertEqual(editor.frame.maxY, app.frame.maxY, accuracy: 1)
        record("native-source-full-page")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["GlobalAI"].exists)
        editor.typeText("Native source input.\n")
        record("native-source-keyboard-folded-tools")
        let inserted = editor.value as? String
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        let foldedTools = app.buttons["ToolsToggle"].frame
        showTools(app)
        for id in ["ToolsToggle", "SourceUndo", "SourceRedo", "GlobalAI", "ModeToggle", "More"] {
            let action = app.buttons[id]
            XCTAssertTrue(action.exists, "Missing action: \(id)")
            XCTAssertEqual(action.frame.midY, foldedTools.midY, accuracy: 1, "Unfolding must preserve the anchor")
            XCTAssertFalse(action.frame.intersects(app.keyboards.firstMatch.frame))
        }
        app.buttons["SourceUndo"].tap()
        XCTAssertTrue(editor.value as? String == inserted, "Consecutive keyboard deletions undo together")
        showTools(app)
        XCTAssertTrue(app.buttons["SourceUndo"].isEnabled)
        XCTAssertGreaterThanOrEqual(app.buttons["SourceUndo"].frame.minX, 0)
        record("native-source-keyboard-expanded-tools")
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(
            app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Native source input."))
                .firstMatch.waitForExistence(timeout: 10))
    }

    func testNativeSourceEditingSurvivesRotation() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        let web = app.webViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        editor.typeText("RotationProbe")
        var text = editor.value as? String
        for (orientation, name) in [
            (UIDeviceOrientation.landscapeLeft, "landscape-left"), (.landscapeRight, "landscape-right"),
            (.portrait, "portrait"),
        ] {
            XCUIDevice.shared.orientation = orientation
            let layout = NSPredicate { _, _ in
                let frame = editor.frame
                let viewport = web.frame
                let keyboard = app.keyboards.firstMatch
                let bottomFits =
                    abs(frame.maxY - viewport.maxY) < 1
                    // XCUI's keyboard frame excludes the input assistant bar.
                    // Native hosting tests assert the exact keyboard guide boundary.
                    || (keyboard.exists && frame.maxY <= keyboard.frame.minY + 1)
                return (app.frame.width > app.frame.height) == orientation.isLandscape
                    && abs(frame.minX - viewport.minX) < 1 && abs(frame.maxX - viewport.maxX) < 1
                    && bottomFits && frame.height > 0
            }
            let settled = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: layout, object: editor)], timeout: 8)
            record("native-source-layout-" + name)
            XCTAssertEqual(
                settled, .completed,
                "Rotated source \(editor.frame), viewport \(web.frame), app \(app.frame), keyboard \(app.keyboards.firstMatch.frame)"
            )
            XCTAssertTrue(editor.value as? String == text, "Rotation must preserve the working text")
            XCTAssertTrue(app.buttons["ToolsToggle"].exists)
            XCTAssertFalse(app.buttons["GlobalAI"].exists)
            editor.typeText("x")
            XCTAssertEqual((editor.value as? String)?.utf16.count, (text?.utf16.count ?? 0) + 1)
            text = editor.value as? String
            record("native-source-input-" + name)
        }
        showTools(app)
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(
            app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "RotationProbe"))
                .firstMatch.waitForExistence(timeout: 10))
    }

    func testPrivacyPolicyHomeEntryAndLocalizedContent() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        for (language, locale, title, firstSection, lastSection) in [
            ("zh-Hans", "zh_CN", "隐私政策", "1. 适用范围", "9. 政策更新与联系"),
            ("en", "en_US", "Privacy Policy", "1. Scope", "9. Updates and contact"),
        ] {
            app.launchArguments = [
                "--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            ]
            app.launch()
            let entry = app.buttons["PrivacyPolicy"]
            XCTAssertTrue(entry.waitForExistence(timeout: 8))
            let open = app.buttons["OpenDocument"]
            XCTAssertGreaterThanOrEqual(entry.frame.width, 44)
            XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
            XCTAssertGreaterThan(entry.frame.minY, open.frame.maxY)
            XCTAssertGreaterThan(entry.frame.midX, app.frame.midX)
            record("home-privacy-\(language)")
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
            let policy = app.scrollViews["PrivacyPolicyContent"]
            XCTAssertTrue(policy.staticTexts[firstSection].waitForExistence(timeout: 8))
            XCTAssertFalse(open.isHittable)
            XCTAssertTrue(
                policy.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "lichenxi.catapple@gmail.com"))
                    .firstMatch.exists)
            record("privacy-policy-\(language)")
            let last = policy.staticTexts[lastSection]
            for _ in 0..<20 {
                if last.isHittable { break }
                policy.swipeUp()
            }
            XCTAssertTrue(last.isHittable, "The complete policy must be readable inside the modal")
            record("privacy-policy-bottom-\(language)")
            app.buttons["ClosePrivacyPolicy"].tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            XCTAssertTrue(entry.isHittable)
            app.terminate()
        }
    }

    func testSendingConsentCancelAllowAndPersistence() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        for (language, locale, title, send, allow, cancel) in [
            ("zh-Hans", "zh_CN", "允许发送到此 AI 服务？", "发送问题", "允许", "取消"),
            ("en", "en_US", "Allow Sending to This AI Service?", "Send message", "Allow", "Cancel"),
        ] {
            app.launchArguments = [
                "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
                "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            ]
            app.launch()
            XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
            showTools(app)
            app.buttons["GlobalAI"].tap()
            let input = app.textViews["QuestionInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            XCTAssertFalse(app.alerts[title].exists, "Opening AI must not ask for sending permission")
            input.tap()
            input.typeText("Explain Markdown.")
            app.webViews.buttons[send].tap()
            let alert = app.alerts[title]
            XCTAssertTrue(alert.waitForExistence(timeout: 6))
            XCTAssertEqual(alert.buttons["AllowModelDataSharing"].firstMatch.label, allow)
            XCTAssertEqual(alert.buttons["CancelModelDataSharing"].firstMatch.label, cancel)
            XCTAssertTrue(
                alert.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS %@", "https://ui-fixture.justmarkdown.invalid/v1")
                ).firstMatch.exists)
            record("ai-sending-consent-\(language)")
            alert.buttons["CancelModelDataSharing"].firstMatch.tap()
            XCTAssertEqual(input.value as? String, "Explain Markdown.")
            app.webViews.buttons[send].tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 6), "Cancel must not store permission")
            alert.buttons["AllowModelDataSharing"].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts["通过目录导航"].waitForExistence(timeout: 12))
            XCTAssertEqual(input.value as? String, "")

            app.terminate()
            app.launchArguments.append("--ui-test-keep-state")
            app.launch()
            XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
            showTools(app)
            app.buttons["GlobalAI"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            input.tap()
            input.typeText("Explain Markdown again.")
            app.webViews.buttons[send].tap()
            XCTAssertTrue(app.webViews.staticTexts["通过目录导航"].waitForExistence(timeout: 12))
            XCTAssertFalse(alert.exists, "The same service must remain authorized after relaunch")
            app.terminate()
        }
    }

    func testEnglishInterfaceAcrossReaderSettingsAndRecents() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        let outline = app.buttons["OutlineToggle"]
        let firstChapter = app.webViews.links["1. 从纯文本到可阅读的文档"]
        if !firstChapter.exists { outline.tap() }
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 8))
        XCTAssertEqual(outline.label, "Hide contents")
        record("english-reader-preview")
        outline.tap()

        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(app.alerts["Model Not Configured"].waitForExistence(timeout: 5))
        app.alerts.buttons["Open Settings"].tap()
        XCTAssertTrue(app.navigationBars["Model Settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["API Type"].exists)
        app.buttons["ModelPicker"].tap()
        XCTAssertTrue(app.buttons["CustomModelEntry"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["CustomModelEntry"].label, "Custom…")
        app.buttons["CustomModelEntry"].tap()
        XCTAssertTrue(app.textFields["ModelID"].waitForExistence(timeout: 5))
        record("english-model-settings")
        app.buttons["Cancel"].tap()

        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("# Markdown 长文阅读与技术笔记"))
        showTools(app)
        XCTAssertEqual(app.buttons["SourceUndo"].label, "Undo")
        XCTAssertEqual(app.buttons["SourceRedo"].label, "Redo")
        app.buttons["CloseDocument"].tap()
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertEqual(open.label, "Open Document")
        XCTAssertEqual(app.buttons["RecentDocuments"].label, "Recent Documents...")
        app.buttons["RecentDocuments"].tap()
        XCTAssertTrue(app.navigationBars["Recent Documents"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RecentDocument-")).firstMatch
        XCTAssertEqual(row.label, "reading-guide.md")
    }

    func testEnglishAgentUsesLocalizedControls() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(input.label, "AI message")
        XCTAssertTrue(app.webViews.buttons["Collapse conversation"].exists)
        XCTAssertTrue(app.webViews.buttons["Remove reference"].exists)
        XCTAssertTrue(app.webViews.buttons["Send message"].exists)
        XCTAssertTrue(app.webViews.buttons["Expand reference"].exists)
        record("english-agent")
    }

    func testUnsupportedSystemLanguageFallsBackToEnglish() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launch()
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertEqual(open.label, "Open Document")
        app.buttons["RecentDocuments"].tap()
        let empty = app.staticTexts["RecentDocumentsEmpty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(empty.label, "No recent documents")
    }

    func testReaderNavigationEditingSettingsAndRotation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let mode = app.buttons["ModeToggle"]
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25) || mode.exists)
        if app.buttons["ToolsToggle"].exists {
            XCTAssertFalse(mode.exists, "Collapsed tools must leave the view and accessibility trees")
            record("phone-tools-collapsed")
        }
        showTools(app)
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        let heading = app.webViews.staticTexts["Markdown 长文阅读与技术笔记"]
        XCTAssertTrue(heading.waitForExistence(timeout: 25))
        let originalModeFrame = mode.frame
        XCTAssertLessThan(app.buttons["GlobalAI"].frame.midX, mode.frame.midX)
        XCTAssertLessThan(mode.frame.midX, app.buttons["More"].frame.midX)
        XCTAssertLessThanOrEqual(app.buttons["More"].frame.maxX, app.frame.width)
        let outline = app.buttons["OutlineToggle"]
        let outlineFrame = outline.frame
        if outline.label == "收起文章目录" { outline.tap() }
        outline.tap()
        let firstChapter = app.webViews.links["1. 从纯文本到可阅读的文档"]
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 5))
        XCTAssertEqual(outline.frame.origin.x, outlineFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(outline.frame.origin.y, outlineFrame.origin.y, accuracy: 0.5)
        record("outline-portrait")
        firstChapter.tap()
        if outline.label == "收起文章目录" { outline.tap() }
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "切换到预览"), object: mode)],
                timeout: 5), .completed)
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(mode.frame.origin.x, originalModeFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(mode.frame.origin.y, originalModeFrame.origin.y, accuracy: 0.5)
        record("source-portrait")
        editor.tap()
        typeSource("\n\n## Native UI verification\n\nSaved from the source view.\n\n", into: editor)
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertTrue(outline.waitForExistence(timeout: 8))
        outline.tap()
        XCTAssertTrue(app.webViews.links["Native UI verification"].waitForExistence(timeout: 8))
        outline.tap()

        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let base = app.textFields["ModelBaseURL"]
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        XCTAssertFalse(mode.isHittable, "Settings must block the document controls")
        mode.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(mode.label, "切换到源码")
        base.tap()
        base.typeText("https://example.test/v1")
        app.buttons["ModelPicker"].tap()
        app.buttons["自定义…"].tap()
        let model = app.textFields["ModelID"]
        model.tap()
        model.typeText("test-model")
        let key = app.secureTextFields["ModelAPIKey"]
        key.tap()
        key.typeText("ui-test-only-key")
        record("model-settings")
        app.buttons["SettingsDone"].tap()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 5) || mode.exists)
        record("after-settings-dismissal")
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "label == %@", "切换到预览"), object: mode)
                ],
                timeout: 8),
            .completed, "Mode switching must work after the dismissal transition")
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertTrue(outline.waitForExistence(timeout: 8))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        outline.tap()
        record("outline-landscape")
        XCTAssertEqual(outline.label, "收起文章目录")
        XCTAssertGreaterThanOrEqual(outline.frame.width, 44)
        XCTAssertGreaterThanOrEqual(outline.frame.height, 44)
        outline.tap()
        record("reader-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    func testModelSelectionLoadsProviderChoicesAndKeepsCustomEntryAfterFailure() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        XCTAssertFalse(app.textFields["ModelID"].exists)
        picker.tap()
        let choice = app.buttons["ModelChoice.catalog-only-model"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["自定义…"].exists)
        choice.tap()
        XCTAssertEqual(picker.value as? String, "catalog-only-model")
        app.buttons["SettingsDone"].tap()
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        XCTAssertEqual(picker.value as? String, "catalog-only-model")
        let base = app.textFields["ModelBaseURL"]
        base.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        base.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (base.value as? String ?? "").count))
        base.typeText("https://ui-fixture.justmarkdown.invalid/unavailable/v1")
        picker.tap()
        XCTAssertTrue(app.staticTexts["无法获取模型列表"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        app.buttons["自定义…"].tap()
        let custom = app.textFields["ModelID"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertEqual(custom.value as? String, "catalog-only-model")
        custom.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        custom.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "catalog-only-model".count))
        custom.typeText("my-custom-model")
        app.buttons["SettingsDone"].tap()
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        XCTAssertEqual(picker.value as? String, "my-custom-model")
        record("model-selection-custom-saved")
    }

    func testModelSelectionSearchesNamesAndIDsAndKeepsCurrentChoiceFirst() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        picker.tap()
        let current = app.buttons["ModelChoice.ui-test-model"]
        let choice = app.buttons["ModelChoice.catalog-only-model"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        XCTAssertLessThan(current.frame.minY, choice.frame.minY)
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("CATALOG CHOICE")
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(current.exists)
        XCTAssertFalse(app.buttons["ModelChoice.provider/advanced-model"].exists)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "CATALOG CHOICE".count))
        search.typeText("advanced-model")
        let advanced = app.buttons["ModelChoice.provider/advanced-model"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        XCTAssertFalse(choice.exists)
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        record("model-selection-search")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "advanced-model".count))
        search.typeText("gpt6.1")
        XCTAssertTrue(app.buttons["ModelChoice.openai/gpt-6.1-sol"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ModelChoice.provider/compact-name"].exists)
        XCTAssertFalse(advanced.exists)
        XCTAssertTrue(current.exists)
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        record("model-selection-compact-search")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "gpt6.1".count))
        search.typeText("gpt61")
        XCTAssertTrue(app.staticTexts["无匹配模型"].waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "gpt61".count))
        search.typeText("no-such-model")
        XCTAssertTrue(app.staticTexts["无匹配模型"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "no-such-model".count))
        search.typeText("advancedmodel")
        advanced.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "provider/advanced-model")
        XCTAssertFalse(app.textFields["ModelID"].exists)
        picker.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertLessThan(advanced.frame.minY, choice.frame.minY, "Reopening must pin the newly selected model")
        advanced.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "provider/advanced-model")
        picker.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("no-such-model")
        XCTAssertTrue(app.staticTexts["无匹配模型"].waitForExistence(timeout: 5))
        app.buttons["CustomModelEntry"].tap()
        let customInput = app.textFields["ModelID"]
        XCTAssertTrue(customInput.waitForExistence(timeout: 5))
        customInput.typeText("-custom")
        XCTAssertEqual(customInput.value as? String, "provider/advanced-model-custom")
        app.buttons["SettingsDone"].tap()
    }

    func testModelSelectionAllowsCustomInputWhileCatalogIsLoading() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let base = app.textFields["ModelBaseURL"]
        XCTAssertTrue(base.waitForExistence(timeout: 6))
        base.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        base.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (base.value as? String ?? "").count))
        base.typeText("https://ui-fixture.justmarkdown.invalid/slow/v1")
        app.buttons["ModelPicker"].tap()
        let loading = app.descendants(matching: .any).matching(identifier: "ModelListLoading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 4))
        let custom = app.buttons["CustomModelEntry"]
        XCTAssertTrue(custom.isHittable)
        custom.tap()
        let input = app.textFields["ModelID"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "ui-test-model")
        input.typeText("-custom")
        record("model-selection-loading-custom")
        app.buttons["SettingsDone"].tap()
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "ui-test-model-custom")
    }

    func testWelcomePresentsNativeFilePicker() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        record("welcome")
        open.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
        record("native-file-picker")
    }

    func testRecentDocumentsEmptyStateAndSecondaryPlacement() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let recent = app.buttons["RecentDocuments"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        let open = app.buttons["OpenDocument"]
        XCTAssertEqual(recent.label, "最近打开...")
        XCTAssertGreaterThanOrEqual(recent.frame.height, 44)
        XCTAssertGreaterThan(recent.frame.minY, open.frame.maxY)
        XCTAssertEqual(recent.frame.midX, open.frame.midX, accuracy: 1)
        record("home-recent-secondary-action")
        recent.tap()
        let empty = app.staticTexts["RecentDocumentsEmpty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        record("recent-documents-empty")
        let close = app.buttons["CloseRecentDocuments"]
        if close.exists {
            close.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: empty)],
                timeout: 5), .completed)
    }

    func testRecentDocumentsSurviveRelaunchAndOpenInPlace() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let title = app.webViews.staticTexts["Markdown 长文阅读与技术笔记"]
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        app.buttons["CloseDocument"].tap()
        let recent = app.buttons["RecentDocuments"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        recent.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RecentDocument-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "reading-guide.md")
        record("recent-documents-list")
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        app.buttons["CloseDocument"].tap()
        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--ui-test-keep-state", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        recent.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "reading-guide.md")
        record("recent-documents-after-relaunch")
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        XCTAssertFalse(app.buttons["CloseRecentDocuments"].exists)
    }

    func testCloseFromSourceReturnsHomeAndOpensAnotherDocumentPicker() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        let close = app.buttons["CloseDocument"]
        XCTAssertTrue(close.exists)
        XCTAssertEqual(close.frame.midY, app.buttons["OutlineToggle"].frame.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        record("reader-native-liquid-glass-close")
        showTools(app)
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["模型设置"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["打开文档"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 6))
        editor.tap()
        editor.typeText("\n\nSaved by closing the document.\n")
        close.tap()
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertFalse(close.exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        record("closed-document-home")
        open.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
    }

    func testFailedCloseOffersRetryDiscardAndCancel() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-save-failure",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Save recovery"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 6))
        editor.tap()
        typeSource("Close check.", into: editor)
        // Persistent write failure also affects autosave. Handle that error before
        // testing the separate close/retry/discard flow, regardless of runner speed.
        let autosaveAlert = app.alerts["无法完成操作"]
        XCTAssertTrue(autosaveAlert.waitForExistence(timeout: 8))
        autosaveAlert.buttons["好"].tap()
        app.buttons["CloseDocument"].tap()
        let alert = app.alerts["未能保存文档"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(alert.buttons["重试"].exists)
        XCTAssertTrue(alert.buttons["放弃修改并关闭"].exists)
        XCTAssertTrue(alert.buttons["取消"].exists)
        record("close-save-failed-native-alert")
        alert.buttons["重试"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        alert.buttons["取消"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Close check.") == true)
        app.buttons["CloseDocument"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        alert.buttons["放弃修改并关闭"].tap()
        XCTAssertTrue(app.buttons["OpenDocument"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        record("discarded-document-home")
    }

    func testOutlineCentersChapterAndFollowsFastReading() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let outline = app.buttons["OutlineToggle"]
        XCTAssertTrue(outline.waitForExistence(timeout: 25))
        waitForEnabled(outline)
        if outline.label == "展开文章目录" { outline.tap() }
        let chapter = app.webViews.links["10. 连续阅读与位置检查"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 8))
        chapter.tap()
        if outline.label == "展开文章目录" { outline.tap() }
        let centered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(chapter.frame.midY - app.frame.midY) < app.frame.height * 0.15
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        record("outline-chapter-10-centered")
        if outline.label == "收起文章目录" { outline.tap() }
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.82))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.28))
        lower.press(forDuration: 0.01, thenDragTo: upper, withVelocity: .fast, thenHoldForDuration: 0)
        upper.press(forDuration: 0.01, thenDragTo: lower, withVelocity: .fast, thenHoldForDuration: 0)
        outline.tap()
        record("outline-after-fast-reading-and-reversal")
    }

    func testBackgroundWindowSnapshotsPreserveLongDocumentRendering() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        let toggle = app.buttons["OutlineToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 25))
        waitForEnabled(toggle)
        XCTAssertEqual(app.webViews.firstMatch.frame.maxY, app.frame.maxY, accuracy: 1)
        let chapter = app.webViews.links["10. 连续阅读与位置检查"]
        if !chapter.exists { toggle.tap() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 8))
        chapter.tap()
        if !chapter.exists { toggle.tap() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 8))
        try assertTextIsPainted(chapter)
        record("long-document-before-background")

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        for index in 1...3 {
            settings.activate()
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 8))
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
            XCTAssertTrue(chapter.waitForExistence(timeout: 8))
            try assertTextIsPainted(chapter)
            record("long-document-after-background-\(index)")
        }
    }

    func testTouchUndoRedoAndNewEditingBranch() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25) || app.buttons["ModeToggle"].exists)
        showTools(app)
        XCTAssertFalse(app.buttons["SourceUndo"].exists)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        showTools(app)
        XCTAssertFalse(app.buttons["SourceUndo"].isEnabled)
        XCTAssertFalse(app.buttons["SourceRedo"].isEnabled)
        let original = editor.value as? String
        editor.tap()
        editor.typeText("undo-check ")
        showTools(app)
        let undo = app.buttons["SourceUndo"]
        let redo = app.buttons["SourceRedo"]
        XCTAssertTrue(undo.isEnabled)
        XCTAssertGreaterThanOrEqual(undo.frame.width, 44)
        XCTAssertLessThan(undo.frame.midX, redo.frame.midX)
        XCTAssertLessThan(redo.frame.midX, app.buttons["GlobalAI"].frame.midX)
        XCTAssertGreaterThanOrEqual(undo.frame.minX, 0)
        let edited = editor.value as? String
        XCTAssertNotEqual(edited, original)
        record("touch-source-history-with-keyboard")
        undo.tap()
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", original ?? ""), object: editor)
                ], timeout: 5), .completed)
        XCTAssertTrue(redo.isEnabled)
        record("touch-source-undone")
        redo.tap()
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", edited ?? ""), object: editor)
                ], timeout: 5), .completed)
        record("touch-source-redone")
        undo.tap()
        editor.tap()
        editor.typeText("new-branch ")
        showTools(app)
        XCTAssertFalse(redo.isEnabled)
    }

    func testUnifiedAIReadingEditingAndTouchHistory() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("请修改第一段，让它更简洁。")
        app.webViews.buttons["发送问题"].tap()
        allowDataSharingIfRequested(app)
        XCTAssertTrue(app.webViews.staticTexts["请切换到源码后再修改。"].waitForExistence(timeout: 12))
        record("ai-preview-read-only")
        app.webViews.buttons["收起对话"].tap()
        showTools(app)
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(app.textViews["SourceEditor"].waitForExistence(timeout: 8))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        input.tap()
        input.typeText("解释这份文档。")
        app.webViews.buttons["发送问题"].tap()
        XCTAssertTrue(app.webViews.staticTexts["通过目录导航"].waitForExistence(timeout: 12))
        record("ai-source-reading")
        let viewport = app.webViews.firstMatch
        let inputTrailingInset = viewport.frame.maxX - input.frame.maxX
        for (orientation, name) in [
            (UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait"),
        ] {
            XCUIDevice.shared.orientation = orientation
            // Interface orientation can change before the native input's frame.
            // Resolve the completed layout before synthesizing the next touch.
            let layout = NSPredicate { _, _ in
                let frame = input.frame
                let window = app.frame
                let viewportFrame = viewport.frame
                return (window.width > window.height) == orientation.isLandscape
                    && abs(viewportFrame.maxX - frame.maxX - inputTrailingInset) < 1
                    && frame.width > 0 && frame.height > 0 && viewportFrame.contains(frame)
                    && input.isHittable
            }
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: layout, object: input)], timeout: 8),
                .completed, "Rotated input \(input.frame), app \(app.frame)")
            record("ai-source-reading-" + name)
        }
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        input.typeText("请修改第一段，让它更简洁。")
        app.webViews.buttons["发送问题"].tap()
        XCTAssertTrue(app.webViews.staticTexts["已修改这句话，其余内容保持原样。"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.webViews.buttons["撤销这次修改"].exists)
        record("ai-source-edit-applied")
        app.webViews.buttons["收起对话"].tap()
        showTools(app)
        app.buttons["SourceUndo"].tap()
        XCTAssertTrue(app.buttons["SourceRedo"].isEnabled)
        record("ai-source-edit-undone")
        app.buttons["SourceRedo"].tap()
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(app.webViews.buttons["撤销这次修改"].waitForExistence(timeout: 6))
        record("ai-source-edit-redone")
    }

    func testNativeSelectionQuestionMenu() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-model-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "这是一份可以实际滚动"))
            .firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 25))
        waitForEnabled(app.buttons["OutlineToggle"])
        paragraph.press(forDuration: 1.2)
        let selection = XCTAttachment(string: app.debugDescription)
        selection.name = "native-selection-menu-hierarchy"
        selection.lifetime = .keepAlways
        add(selection)
        record("native-selection-menu")
        // Selection handles can remain visible with the system edit menu hidden.
        // Tapping the selected text requests that menu through UIKit's normal gesture.
        if !app.menuItems.firstMatch.waitForExistence(timeout: 6) {
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let ask = app.menuItems["AI"]
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        ask.tap()
        XCTAssertTrue(app.descendants(matching: .any)["QuestionInput"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.webViews.buttons["发送问题"].exists)
        record("selection-question")
        app.webViews.buttons["收起对话"].tap()
    }

    private func showTools(_ app: XCUIApplication) {
        let toggle = app.buttons["ToolsToggle"]
        let mode = app.buttons["ModeToggle"]
        if !toggle.exists && !mode.exists {
            XCTAssertTrue(
                toggle.waitForExistence(timeout: 5) || mode.waitForExistence(timeout: 5),
                "Reading controls become available after the foreground closing transition")
        }
        waitForEnabled(toggle.exists ? toggle : mode)
        if toggle.exists && !mode.exists { toggle.tap() }
    }

    private func waitForEnabled(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed, file: file, line: line)
    }

    /// WebKit commits injected text asynchronously. Acknowledge each line before sending the next Return.
    private func typeSource(
        _ text: String, into editor: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        for (index, part) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                let before = editor.value as? String
                editor.typeText("\n")
                let newline = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in (editor.value as? String) != before }, object: nil)
                guard XCTWaiter.wait(for: [newline], timeout: 8) == .completed else {
                    XCTFail("The editor did not commit the newline", file: file, line: line)
                    return
                }
            }
            guard !part.isEmpty else { continue }
            editor.typeText(part)
            let committed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in (editor.value as? String)?.contains(part) == true }, object: nil)
            guard XCTWaiter.wait(for: [committed], timeout: 8) == .completed else {
                XCTFail("The editor did not commit the complete input line", file: file, line: line)
                return
            }
        }
    }

    private func openQuestionInput(_ app: XCUIApplication) -> XCUIElement {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "--ui-testing", "--ui-test-model-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "")
        return input
    }

    func testQuestionSoftwareKeyboardReturn() {
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("first")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let returnKey = keyboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["return", "Return", "换行"]))
            .firstMatch
        XCTAssertTrue(returnKey.waitForExistence(timeout: 3), keyboard.debugDescription)
        returnKey.tap()
        input.typeText("second")
        XCTAssertEqual(input.value as? String, "first\nsecond")
        let validation = app.webViews.staticTexts["无法连接到服务"]
        XCTAssertFalse(validation.exists)
        record("question-software-return-newline")
    }

    func testUnconfiguredAIShowsPromptAndSettingsReturnsToInput() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let alert = app.alerts["尚未配置模型"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["QuestionInput"].exists)
        record("unconfigured-ai-prompt")
        alert.buttons["取消"].tap()
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["前往设置"].tap()
        let base = app.textFields["ModelBaseURL"]
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        base.tap()
        base.typeText("http://127.0.0.1:1/v1")
        app.buttons["ModelPicker"].tap()
        app.buttons["自定义…"].tap()
        let model = app.textFields["ModelID"]
        model.tap()
        model.typeText("ui-test-model")
        let key = app.secureTextFields["ModelAPIKey"]
        key.tap()
        key.typeText("ui-test-only-key")
        app.buttons["SettingsDone"].tap()
        XCTAssertTrue(app.textViews["QuestionInput"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.webViews.buttons["发送问题"].exists)
        XCTAssertFalse(app.webViews.buttons["发送问题"].isEnabled)
        XCTAssertEqual(app.webViews.otherElements.matching(identifier: "用户提问").count, 0)
        record("configured-return-to-input")
    }

    func testAgentFailureRetryPreservesDraftAndConversation() {
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("Explain Markdown.")
        XCTAssertEqual(input.value as? String, "Explain Markdown.")
        app.webViews.buttons["发送问题"].tap()
        allowDataSharingIfRequested(app)
        let retry = app.webViews.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        input.typeText("unsent next question")
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "unsent next question")
        XCTAssertEqual(
            app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "Explain Markdown.")).count, 1)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(app.buttons["ToolsToggle"].exists)
            XCTAssertFalse(app.buttons["CloseDocument"].exists)
            XCTAssertFalse(app.buttons["OutlineToggle"].exists)
        }
        record("agent-failure-retry-draft")
        app.webViews.buttons["收起对话"].tap()
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "unsent next question")
        record("agent-reopened-history")
    }

    func testQuestionKeyboardSendButton() {
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("a question")
        app.webViews.buttons["发送问题"].tap()
        allowDataSharingIfRequested(app)
        XCTAssertTrue(app.webViews.staticTexts["无法连接到服务"].waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "")
        XCTAssertEqual(app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "a question")).count, 1)
        record("question-send-button")
    }
}
