import SwiftUI

/// A presentation keeps its own list while the connection cache refreshes.
struct ModelSelectionView: View {
    let catalog: ModelCatalogCache
    let baseURL: String
    let key: String
    @Binding var model: String
    @Binding var custom: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var models: [CatalogModel]?
    @State private var failed = false
    @State private var currentID: String

    init(catalog: ModelCatalogCache, baseURL: String, key: String, model: Binding<String>, custom: Binding<Bool>) {
        self.catalog = catalog
        self.baseURL = baseURL
        self.key = key
        _model = model
        _custom = custom
        _currentID = State(initialValue: model.wrappedValue)
    }

    private var current: CatalogModel? {
        guard !currentID.isEmpty else { return nil }
        return models?.first { $0.id == currentID } ?? CatalogModel(id: currentID)
    }

    private var matches: [CatalogModel] {
        return (models ?? []).filter {
            $0.id != currentID && $0.matches(search: search)
        }
    }

    var body: some View {
        List {
            if let current {
                Section("Current Model") {
                    choice(current, selected: true) { dismiss() }
                }
            }
            Section {
                if models != nil {
                    if matches.isEmpty {
                        Text(
                            search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? (current == nil
                                    ? String(localized: "No models available") : String(localized: "No other models"))
                                : String(localized: "No matching models")
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { item in
                            choice(item, selected: false) {
                                model = item.id
                                custom = false
                                dismiss()
                            }
                        }
                    }
                } else if failed {
                    HStack {
                        Text("Unable to Load Models").foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") {
                            failed = false
                            catalog.prefetch(baseURL: baseURL, key: key)
                        }
                        .accessibilityIdentifier("RetryModelList")
                    }
                } else {
                    HStack {
                        Spacer()
                        ProgressView().accessibilityLabel("Loading models")
                        Spacer()
                    }
                    .accessibilityIdentifier("ModelListLoading")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Custom…") {
                    custom = true
                    dismiss()
                }
                .accessibilityIdentifier("CustomModelEntry")
            }
        }
        .task(id: failed) {
            guard models == nil, !failed else { return }
            do {
                let result = try await catalog.models(baseURL: baseURL, key: key)
                guard !Task.isCancelled else { return }
                models = result
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private func choice(_ item: CatalogModel, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = item.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        name != item.id
                    {
                        Text(name)
                        Text(item.id).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(item.id)
                    }
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ModelChoice." + item.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
