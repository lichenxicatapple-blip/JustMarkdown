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
        let editor = app.webViews.textViews["Markdown 源码"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(mode.frame.origin.x, originalModeFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(mode.frame.origin.y, originalModeFrame.origin.y, accuracy: 0.5)
        record("source-portrait")
        editor.tap()
        editor.typeText("\n\n## Native UI verification\n\nSaved from the source view.\n\n")
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
        let editor = app.webViews.textViews["Markdown 源码"]
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
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.webViews.textViews["Markdown 源码"]
        XCTAssertTrue(editor.waitForExistence(timeout: 6))
        editor.tap()
        editor.typeText("\n\nUnsaved close verification.\n")
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
        XCTAssertTrue((editor.value as? String)?.contains("Unsaved close verification.") == true)
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
        let editor = app.webViews.textViews["Markdown 源码"]
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
        XCTAssertTrue(app.webViews.staticTexts["请切换到源码后再修改。"].waitForExistence(timeout: 12))
        record("ai-preview-read-only")
        app.webViews.buttons["收起对话"].tap()
        showTools(app)
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(app.webViews.textViews["Markdown 源码"].waitForExistence(timeout: 8))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        input.tap()
        input.typeText("解释这份文档。")
        app.webViews.buttons["发送问题"].tap()
        XCTAssertTrue(app.webViews.staticTexts["通过目录导航"].waitForExistence(timeout: 12))
        record("ai-source-reading")
        input.tap()
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
        paragraph.press(forDuration: 1.2)
        let selection = XCTAttachment(string: app.debugDescription)
        selection.name = "native-selection-menu-hierarchy"
        selection.lifetime = .keepAlways
        add(selection)
        record("native-selection-menu")
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
        if toggle.exists && toggle.label == "展开阅读工具" { toggle.tap() }
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
        input.tap()
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
        app.webViews.buttons["发送问题"].tap()
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

    func testQuestionHardwareKeyboardReturn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "XCTest physical key injection requires iPad")
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUSTMARKDOWN_HARDWARE_KEYBOARD_TESTS"] == "1",
            "Requires a physical-key capable test environment; current simulator drops Shift+Return even in standard UITextView"
        )
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("first")
        // Check UIKit's unmodified cursor movement before relying on this
        // simulator's physical special-key injection to test custom Return.
        input.typeKey(.leftArrow, modifierFlags: [])
        input.typeText("X")
        guard input.value as? String == "firsXt" else {
            throw XCTSkip("Simulator physical ArrowLeft injection failed in standard UIKit text editing")
        }
        input.typeKey(.rightArrow, modifierFlags: [])
        let validation = app.webViews.staticTexts["请检查服务地址和模型"]
        input.typeKey(.return, modifierFlags: .shift)
        XCTAssertFalse(validation.exists)
        input.typeText("second")
        XCTAssertEqual(input.value as? String, "firsXt\nsecond")
        XCTAssertFalse(validation.exists)
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(validation.waitForExistence(timeout: 3), "Physical Return must invoke the send action")
        XCTAssertEqual(
            input.value as? String, "", "A committed question remains in conversation after failure")
        record("question-hardware-return-send")
    }

    func testQuestionKeyboardSendButton() {
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("a question")
        app.webViews.buttons["发送问题"].tap()
        XCTAssertTrue(app.webViews.staticTexts["无法连接到服务"].waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "")
        XCTAssertEqual(app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "a question")).count, 1)
        record("question-send-button")
    }
}
