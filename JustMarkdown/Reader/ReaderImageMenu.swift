import UIKit
import WebKit

/// A tap exposes the image's AI action through UIKit. WebKit keeps ownership of
/// long presses, image recognition, copying and sharing.
@MainActor
final class ReaderImageMenu: NSObject, @MainActor UIEditMenuInteractionDelegate {
    private struct Selection {
        let id: String
        let token: String
        let reference: AgentAttachment
        let point: CGPoint
    }
    private weak var webView: WKWebView?
    private lazy var interaction = UIEditMenuInteraction(delegate: self)
    private var selection: Selection?
    var onAsk: ((AgentAttachment, String, CGPoint) -> Void)?
    var onDismiss: ((String) -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.addInteraction(interaction)
    }

    func show(id: String, token: String, reference: AgentAttachment, point: CGPoint) {
        guard let webView, webView.window != nil, point.x.isFinite, point.y.isFinite,
            reference.images?.isEmpty == false, reference.mode == "preview"
        else { return }
        let bounds = webView.bounds
        let anchor = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY))
        selection = Selection(id: id, token: token, reference: reference, point: anchor)
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: id as NSString, sourcePoint: anchor))
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let selection, configuration.identifier as? String == selection.id else { return nil }
        let ask = UIAction(title: String(localized: "Reference in AI Chat…"), image: UIImage(systemName: "bubble.left"))
        {
            [weak self] _ in
            self?.onAsk?(selection.reference, selection.token, selection.point)
        }
        return UIMenu(children: [ask])
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        guard let id = configuration.identifier as? String else { return }
        if selection?.id == id { selection = nil }
        onDismiss?(id)
    }

    func dismiss() {
        let id = selection?.id
        selection = nil
        interaction.dismissMenu()
        if let id { onDismiss?(id) }
    }

    func detach() {
        dismiss()
        webView?.removeInteraction(interaction)
        onAsk = nil
        onDismiss = nil
    }
}
