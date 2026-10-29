import UIKit
import WebKit

extension WKWebView {
    /// Native responders must stay outside WebKit's keyboard/responder hierarchy.
    func hostNativeInput(_ input: UIView, aboveWebContent: Bool) -> UIView? {
        guard let host = superview else { return nil }
        if input.superview !== host {
            if aboveWebContent {
                host.insertSubview(input, aboveSubview: self)
            } else {
                host.insertSubview(input, belowSubview: self)
            }
        }
        return host
    }
}

@MainActor
final class ReaderViewport: UIView {
    let webView: ReaderWKWebView

    init(webView: ReaderWKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        webView.autoresizingMask = []
        addSubview(webView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:)") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Background snapshots temporarily resize the scene. Keep those sizes out
        // of the live document's viewport and composited scrolling layers.
        guard window?.windowScene?.activationState != .background else { return }
        if webView.frame != bounds { webView.frame = bounds }
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }
}

@MainActor
final class ReaderContainer: UIView {
    private var viewportBottom: NSLayoutConstraint?

    init(webView: ReaderWKWebView) {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        keyboardLayoutGuide.followsUndockedKeyboard = true
        keyboardLayoutGuide.usesBottomSafeArea = false
        let viewport = ReaderViewport(webView: webView)
        viewport.translatesAutoresizingMaskIntoConstraints = false
        addSubview(viewport)
        let bottom = viewport.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        viewportBottom = bottom
        NSLayoutConstraint.activate([
            viewport.topAnchor.constraint(equalTo: topAnchor),
            viewport.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
        ])
    }

    override func layoutSubviews() {
        let offset = Self.viewportBottomOffset(keyboard: keyboardLayoutGuide.layoutFrame, in: bounds)
        if viewportBottom?.constant != offset { viewportBottom?.constant = offset }
        super.layoutSubviews()
    }

    /// Only an obstruction spanning the full bottom edge reduces the document viewport.
    static func viewportBottomOffset(keyboard: CGRect, in bounds: CGRect) -> CGFloat {
        let overlap = keyboard.intersection(bounds)
        let docked =
            !overlap.isEmpty && abs(overlap.width - bounds.width) < 1
            && abs(overlap.maxY - bounds.maxY) < 1
        // Keep the viewport constrained to the guide so keyboard movement always
        // drives a native layout pass, including transitions to and from floating UI.
        return docked ? 0 : bounds.maxY - keyboard.minY
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:)") }
}
