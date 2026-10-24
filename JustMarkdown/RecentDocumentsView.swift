import SwiftUI

struct RecentDocumentsView: View {
    @ObservedObject var store: RecentDocumentsStore
    let compact: Bool
    let open: (RecentDocument) async throws -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var opening: UUID?
    @State private var failed = false
    @ScaledMetric(relativeTo: .body) private var rowHeight = 68

    var body: some View {
        NavigationStack {
            Group {
                if store.documents.isEmpty {
                    Text("暂无记录").font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("RecentDocumentsEmpty")
                } else {
                    List(store.documents) { document in
                        Button {
                            opening = document.id
                            Task {
                                defer { opening = nil }
                                do {
                                    if try await open(document) { dismiss() }
                                } catch { failed = true }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(document.name).font(.body).foregroundStyle(.primary)
                                        .lineLimit(2).truncationMode(.middle)
                                    Text(document.parent).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if opening == document.id { ProgressView().accessibilityLabel("正在打开") }
                            }
                            .padding(.vertical, 4).frame(minHeight: ReaderDesign.hitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(document.name).accessibilityValue(document.parent)
                        .accessibilityIdentifier("RecentDocument-\(document.id)")
                        .disabled(opening != nil)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("最近打开").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if compact {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("CloseRecentDocuments")
                            .disabled(opening != nil)
                    }
                }
            }
        }
        .frame(
            width: compact ? nil : ReaderDesign.recentsWidth,
            height: compact
                ? nil : min(ReaderDesign.recentsMaxHeight, 56 + rowHeight * CGFloat(max(2, store.documents.count)))
        )
        .interactiveDismissDisabled(opening != nil)
        .alert("无法打开文档", isPresented: $failed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法访问这份文档，请通过“打开文档”重新选择。")
        }
    }
}
