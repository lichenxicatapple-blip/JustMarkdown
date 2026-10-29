import SwiftUI

struct RecentDocumentsView: View {
    @ObservedObject var store: RecentDocumentsStore
    let compact: Bool
    let open: (RecentDocument) async throws -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var opening: UUID?
    @State private var failed = false
    @ScaledMetric(relativeTo: .body) private var rowHeight = 68

    private var preferredHeight: CGFloat? {
        compact ? nil : min(ReaderDesign.recentsMaxHeight, 56 + rowHeight * CGFloat(max(2, store.documents.count)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.documents.isEmpty {
                    Text("No recent documents").font(.body).foregroundStyle(.secondary)
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
                                if opening == document.id { ProgressView().accessibilityLabel("Opening document") }
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
            .navigationTitle("Recent Documents").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if compact {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("CloseRecentDocuments")
                            .disabled(opening != nil)
                    }
                }
            }
        }
        .frame(width: compact ? nil : ReaderDesign.recentsWidth)
        // A popover can be shorter than its preferred size near a screen edge.
        // Let the navigation stack and list shrink with the actual viewport.
        .frame(minHeight: compact ? nil : 0, idealHeight: preferredHeight, maxHeight: preferredHeight)
        .interactiveDismissDisabled(opening != nil)
        .alert("Unable to Open Document", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This document is unavailable. Select it again using Open Document.")
        }
    }
}
