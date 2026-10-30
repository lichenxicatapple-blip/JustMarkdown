import UIKit

/// Software Return edits normally; only physical Return presses submit.
final class ConversationTextView: UITextView {
    var onSubmit: ((String) -> Void)?
    var onFocusReadinessChange: (() -> Void)?
    private var returnIsDown = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onFocusReadinessChange?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onFocusReadinessChange?()
    }

    /// False lets UIKit handle unrelated shortcuts or candidate confirmation.
    func handleHardwareReturn(modifiers: UIKeyModifierFlags) -> Bool {
        guard modifiers.intersection([.control, .alternate, .command]).isEmpty else { return false }
        if returnIsDown { return true }
        returnIsDown = true
        guard markedTextRange == nil else { return false }
        if modifiers.contains(.shift) {
            insertText("\n")
            return true
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSubmit?(text) }
        return true
    }

    func releaseHardwareReturn() { returnIsDown = false }

    private func isReturn(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        return key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { press in
            guard isReturn(press), let key = press.key else { return true }
            return !handleHardwareReturn(modifiers: key.modifierFlags)
        }
        if !remaining.isEmpty { super.pressesBegan(Set(remaining), with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: isReturn) { releaseHardwareReturn() }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: isReturn) { releaseHardwareReturn() }
        super.pressesCancelled(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { releaseHardwareReturn() }
        return resigned
    }
}
