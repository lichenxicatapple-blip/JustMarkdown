import UIKit
import XCTest

@testable import JustMarkdown

@MainActor
final class ConversationInputTests: XCTestCase {
    func testSoftwareReturnAndMultilineInsertionNeverSubmit() {
        let view = ConversationTextView()
        var submitted = false
        view.onSubmit = { _ in submitted = true }
        view.insertText("first")
        view.insertText("\n")
        view.insertText("second\nthird")
        XCTAssertEqual(view.text, "first\nsecond\nthird")
        XCTAssertFalse(submitted)
    }

    func testHardwareReturnSubmitsOnceUntilKeyRelease() {
        let view = ConversationTextView()
        view.text = "a question"
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0) }
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted, ["a question"])
        view.releaseHardwareReturn()
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted.count, 2)
    }

    func testShiftReturnInsertsANewlineWithoutSubmitting() {
        let view = ConversationTextView()
        view.text = "first"
        view.selectedRange = NSRange(location: 5, length: 0)
        var submitted = false
        view.onSubmit = { _ in submitted = true }
        XCTAssertTrue(view.handleHardwareReturn(modifiers: .shift))
        XCTAssertEqual(view.text, "first\n")
        XCTAssertFalse(submitted)
    }

    func testCandidateConfirmationCannotSubmitOrRepeatIntoASubmit() {
        let view = ConversationTextView()
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0) }
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertFalse(view.handleHardwareReturn(modifiers: []))
        view.unmarkText()
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertTrue(submitted.isEmpty)
        view.releaseHardwareReturn()
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted, ["中文"])
    }

    func testBlankReturnDoesNotSubmit() {
        let view = ConversationTextView()
        view.text = " \n"
        var submitted = false
        view.onSubmit = { _ in submitted = true }
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertFalse(submitted)
    }

    func testModifiedShortcutsRemainAvailableToUIKit() {
        let view = ConversationTextView()
        view.text = "question"
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0) }
        for modifiers: UIKeyModifierFlags in [.control, .alternate, .command, [.command, .shift]] {
            XCTAssertFalse(view.handleHardwareReturn(modifiers: modifiers))
        }
        XCTAssertEqual(view.text, "question")
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted, ["question"])
    }
}
