import SwiftUI
import UIKit

/// Shared SwiftUI controls follow system input geometry through native constraints.
struct ReaderFloatingControls<Content: View>: UIViewControllerRepresentable {
    var trailingInset: CGFloat
    @ViewBuilder var content: Content

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: content, trailingInset: trailingInset)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        // Each hosting root supplies its own environment.
        // Forward the animation transaction without replacing the entire environment.
        withTransaction(context.transaction) { controller.host.rootView = content }
        context.animate {
            controller.trailingConstraint.constant = -trailingInset
            controller.view.layoutIfNeeded()
        }
    }

    @MainActor
    final class Controller: UIViewController {
        fileprivate let host: UIHostingController<Content>
        fileprivate var trailingConstraint: NSLayoutConstraint!
        private let trailingInset: CGFloat

        init(content: Content, trailingInset: CGFloat) {
            host = UIHostingController(rootView: content)
            self.trailingInset = trailingInset
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(content:trailingInset:)") }

        override func loadView() { view = ReaderControlsSurface() }

        override func viewDidLoad() {
            super.viewDidLoad()
            host.sizingOptions = .intrinsicContentSize
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)

            let safeArea = view.safeAreaLayoutGuide
            let keyboard = view.keyboardLayoutGuide
            keyboard.followsUndockedKeyboard = true
            keyboard.usesBottomSafeArea = false
            trailingConstraint = host.view.trailingAnchor.constraint(
                equalTo: safeArea.trailingAnchor, constant: -trailingInset)
            let inset = ReaderDesign.floatingInset
            let preferredBottom = host.view.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -inset)
            preferredBottom.priority = .defaultLow
            NSLayoutConstraint.activate([
                trailingConstraint,
                host.view.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: inset),
                host.view.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor, constant: inset),
                host.view.bottomAnchor.constraint(lessThanOrEqualTo: safeArea.bottomAnchor, constant: -inset),
                preferredBottom,
            ])
            // A floating keyboard near the top must not push the controls offscreen.
            // Vertical avoidance is independent of the mini toolbar's horizontal edge.
            keyboard.setConstraints(
                [
                    host.view.bottomAnchor.constraint(
                        lessThanOrEqualTo: keyboard.topAnchor,
                        constant: -ReaderDesign.floatingGap)
                ],
                activeWhenAwayFrom: .top)
        }
    }
}

/// The full-size positioning surface must leave document touches and scrolling alone.
@MainActor
final class ReaderControlsSurface: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}
