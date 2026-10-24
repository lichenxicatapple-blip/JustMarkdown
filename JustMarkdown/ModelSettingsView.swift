import SwiftUI
import UIKit

struct ModelSettingsView: View {
    @ObservedObject var session: ReaderSession
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var model = ""
    @State private var customModel = false
    @FocusState private var customModelFocused: Bool
    @State private var key = ""
    @State private var apiProtocol: ModelAPIProtocol = .responses
    @State private var error: String?

    init(session: ReaderSession, onSaved: @escaping () -> Void = {}) {
        self.session = session
        self.onSaved = onSaved
        _baseURL = State(initialValue: session.configuration.baseURL)
        _model = State(initialValue: session.configuration.model)
        _apiProtocol = State(initialValue: session.configuration.apiProtocol)
        _key = State(initialValue: ModelKeychain.read())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("接口类型", selection: $apiProtocol) {
                        ForEach(ModelAPIProtocol.allCases, id: \.self) { api in
                            Text(api.title).tag(api)
                        }
                    }
                    .accessibilityIdentifier("ModelAPIProtocol")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Base URL").font(.subheadline).foregroundStyle(.secondary)
                        TextField("", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textContentType(.URL)
                            .accessibilityLabel("Base URL").accessibilityIdentifier("ModelBaseURL")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            // iOS has no API-token content type. Code semantics
                            // preserve secure entry without login-password saving;
                            // an empty type still invokes heuristics on iOS 26.
                            .textContentType(.oneTimeCode)
                            .keyboardType(.asciiCapable)
                            .accessibilityLabel("API Key").accessibilityIdentifier("ModelAPIKey")
                    }
                    NavigationLink {
                        ModelSelectionView(
                            catalog: session.modelCatalog, baseURL: baseURL, key: key, model: $model,
                            custom: $customModel)
                    } label: {
                        LabeledContent("模型") {
                            Text(customModel ? "自定义" : model.isEmpty ? "选择" : model)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .accessibilityIdentifier("ModelPicker")
                    .accessibilityLabel("模型")
                    .accessibilityValue(model)
                    if customModel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("模型 ID").font(.subheadline).foregroundStyle(.secondary)
                            TextField("", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textContentType(UITextContentType(rawValue: ""))
                                .focused($customModelFocused)
                                .accessibilityLabel("模型 ID").accessibilityIdentifier("ModelID")
                        }
                    }
                } footer: {
                    Text("API Key 保存在本机钥匙串。提问时向所配服务发送当前文档与对话。")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("模型设置").navigationBarTitleDisplayMode(.inline)
            .background {
                SettingsAppearanceObserver {
                    if customModel { customModelFocused = true }
                }
                .accessibilityHidden(true)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        do {
                            try session.saveConfiguration(
                                ModelConfiguration(
                                    baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                    model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                                    apiProtocol: apiProtocol), key: key)
                            onSaved()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("SettingsDone")
                }
            }
        }
        .onAppear { session.modelCatalog.prefetch(baseURL: baseURL, key: key) }
        .onChange(of: baseURL) { _, _ in prefetchAfterInput() }
        .onChange(of: key) { _, _ in prefetchAfterInput() }
        .onDisappear {
            session.modelCatalog.cancel()
            key = ""
        }
    }

    private func prefetchAfterInput() {
        session.modelCatalog.prefetch(baseURL: baseURL, key: key, debounce: .milliseconds(500))
    }
}

/// SwiftUI's onAppear precedes completion of the navigation transition.
/// Request text focus once the settings controller is actually on screen.
private struct SettingsAppearanceObserver: UIViewControllerRepresentable {
    var onDidAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onDidAppear = onDidAppear
    }

    final class Controller: UIViewController {
        var onDidAppear: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onDidAppear?()
        }
    }
}
