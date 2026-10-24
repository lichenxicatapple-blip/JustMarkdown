import UIKit
import WebKit

/// UIKit owns editable text and physical keys; the shared surface owns composer layout.
@MainActor
final class NativeComposerHost: NSObject, UITextViewDelegate {
    private struct Input {
        let view: ConversationTextView
        var epoch = 0
        var metrics: [Double] = []
    }
    private var inputs: [String: Input] = [:]
    private weak var webView: WKWebView?
    private var focusRevision = 0
    var call: (@MainActor (String, [String: Any]) async -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        for id in ["question"] {
            let view = ConversationTextView()
            view.isHidden = true
            view.backgroundColor = .clear
            view.textColor = .label
            view.tintColor = .tintColor
            view.returnKeyType = .default
            view.textContainer.lineFragmentPadding = 0
            view.delegate = self
            view.accessibilityLabel = "输入 AI 消息"
            view.accessibilityIdentifier = "QuestionInput"
            view.onSubmit = { [weak self] _ in self?.submit(id) }
            webView.addSubview(view)
            inputs[id] = Input(view: view)
        }
    }

    func updateLayout(_ states: [[String: Any]]) {
        for state in states {
            guard let id = state["id"] as? String, var input = inputs[id] else { continue }
            let visible = state["visible"] as? Bool == true
            let view = input.view
            if !visible && view.isFirstResponder { _ = view.resignFirstResponder() }
            view.isHidden = !visible
            view.alpha = state["opacity"] as? Double ?? 1
            view.frame = CGRect(
                x: state["x"] as? Double ?? 0, y: state["y"] as? Double ?? 0,
                width: state["width"] as? Double ?? 0, height: state["height"] as? Double ?? 0)
            let metrics = ["fontSize", "lineHeight", "top", "right", "bottom", "left"].map { state[$0] as? Double ?? 0 }
            if input.metrics != metrics && view.markedTextRange == nil {
                input.metrics = metrics
                let font = UIFont.systemFont(ofSize: max(12, metrics[0]))
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = max(font.lineHeight, metrics[1])
                paragraph.maximumLineHeight = paragraph.minimumLineHeight
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .paragraphStyle: paragraph, .foregroundColor: UIColor.label,
                ]
                view.font = font
                view.typingAttributes = attributes
                view.textContainerInset = UIEdgeInsets(
                    top: metrics[2], left: metrics[5], bottom: metrics[4], right: metrics[3])
                if !view.text.isEmpty {
                    view.textStorage.addAttributes(
                        attributes, range: NSRange(location: 0, length: view.text.utf16.count))
                }
            }
            inputs[id] = input
            if visible { webView?.bringSubviewToFront(view) }
        }
    }

    func setText(id: String, text: String, epoch: Int) {
        guard var input = inputs[id], epoch >= input.epoch else { return }
        input.epoch = epoch
        input.view.text = text
        input.view.selectedRange = NSRange(location: text.utf16.count, length: 0)
        inputs[id] = input
    }

    func focus(_ id: String) {
        guard let input = inputs[id] else { return }
        focusRevision += 1
        let revision = focusRevision
        Task { @MainActor [weak self] in
            // Layout is reported on the next animation frame when a panel opens.
            for _ in 0..<12 {
                guard let self, self.focusRevision == revision, let input = self.inputs[id] else { return }
                if !input.view.isHidden, input.view.window != nil {
                    input.view.becomeFirstResponder()
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        if !input.view.isHidden { input.view.becomeFirstResponder() }
    }

    func blur() {
        focusRevision += 1
        for input in inputs.values { _ = input.view.resignFirstResponder() }
    }

    func submit(_ id: String) {
        guard let input = inputs[id] else { return }
        input.view.unmarkText()
        let payload: [String: Any] = ["id": id, "text": input.view.text ?? "", "epoch": input.epoch]
        Task { await call?("commitAgentInput", payload) }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let (id, input) = inputs.first(where: { $0.value.view === textView }) else { return }
        let payload: [String: Any] = ["id": id, "text": textView.text ?? "", "epoch": input.epoch]
        Task { await call?("updateAgentInput", payload) }
    }

    func detach() {
        blur()
        for input in inputs.values {
            input.view.removeFromSuperview()
            input.view.delegate = nil
            input.view.onSubmit = nil
        }
        inputs.removeAll()
        call = nil
    }
}
