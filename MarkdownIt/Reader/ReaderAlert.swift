import SwiftUI
import UIKit

/// Run actions after the native dismissal completes, before presenting another modal.
struct ReaderAlert: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    struct Action {
        let id: String
        let title: String
        var style: UIAlertAction.Style = .default
        var preferred = false
        let perform: () -> Void
    }

    let title: String
    var message: String? = nil
    let actions: [Action]

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(
            isPresented: isPresented, dismiss: { isPresented = false }, title: title,
            message: message, actions: actions)
    }

    final class Controller: UIViewController {
        private var requested = false
        private var alert: UIAlertController?
        private var dismissing = false
        private var dismissRequested: () -> Void = {}
        private var alertTitle = ""
        private var message: String?
        private var actions: [Action] = []

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentIfNeeded()
        }

        func update(
            isPresented: Bool, dismiss: @escaping () -> Void, title: String, message: String?,
            actions: [Action]
        ) {
            requested = isPresented
            dismissRequested = dismiss
            alertTitle = title
            self.message = message
            self.actions = actions
            if !requested, alert != nil { finish(updateBinding: false) } else { presentIfNeeded() }
        }

        private func presentIfNeeded() {
            guard requested, alert == nil, !dismissing, viewIfLoaded?.window != nil else { return }
            let alert = UIAlertController(title: alertTitle, message: message, preferredStyle: .alert)
            for action in actions {
                let item = UIAlertAction(title: action.title, style: action.style) { [weak self] _ in
                    guard let self else { return }
                    self.finish(action: self.actions.first { $0.id == action.id }?.perform)
                }
                alert.addAction(item)
                if action.preferred { alert.preferredAction = item }
            }
            self.alert = alert
            present(alert, animated: true)
        }

        private func finish(action: (() -> Void)? = nil, updateBinding: Bool = true) {
            guard let alert, !dismissing else { return }
            dismissing = true
            requested = false
            if updateBinding { dismissRequested() }
            alert.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.alert = nil
                self.dismissing = false
                action?()
                self.presentIfNeeded()
            }
        }
    }
}
