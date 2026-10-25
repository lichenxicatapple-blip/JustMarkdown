import SwiftUI
import WebKit

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PrivacyPolicyContent()
                .navigationTitle("Privacy Policy").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("ClosePrivacyPolicy")
                    }
                }
        }
        .presentationSizing(.form)
        .presentationBackgroundInteraction(.disabled)
    }
}

/// A bundled, pre-rendered policy needs neither JavaScript nor access to reader state.
private struct PrivacyPolicyContent: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicType

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "PrivacyPolicyContent"
        let language = Bundle.main.preferredLocalizations.first == "zh-Hans" ? "zh-Hans" : "en"
        if let url = Bundle.main.url(forResource: "privacy-" + language, withExtension: "html", subdirectory: "Web") {
            context.coordinator.url = url
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if let previous = context.coordinator.dynamicType, previous != dynamicType { view.reload() }
        context.coordinator.dynamicType = dynamicType
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var url: URL?
        var dynamicType: DynamicTypeSize?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            guard let target = navigationAction.request.url else { return .cancel }
            if target.isFileURL, target.path == url?.path { return .allow }
            if navigationAction.navigationType == .linkActivated,
                ["mailto", "https", "http"].contains(target.scheme?.lowercased() ?? "")
            {
                await UIApplication.shared.open(target)
            }
            return .cancel
        }
    }
}
