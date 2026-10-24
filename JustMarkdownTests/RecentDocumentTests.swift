import XCTest

@testable import JustMarkdown

final class RecentDocumentTests: XCTestCase {
    @MainActor
    func testHistoryKeepsTenDistinctDocumentsInLastOpenedOrderAcrossReload() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = RecentDocumentsStore(defaults: defaults)
        for number in 0..<12 {
            let url = root.appendingPathComponent("文档 \(number).md")
            try Data("# \(number)\n".utf8).write(to: url)
            store.record(await RecentDocumentsStore.prepare(url, folders: []))
        }
        XCTAssertEqual(store.documents.map(\.name), (2..<12).reversed().map { "文档 \($0).md" })
        let repeated = try XCTUnwrap(store.documents.first { $0.name == "文档 5.md" })
        store.record(await RecentDocumentsStore.prepare(repeated.file.url, folders: []))
        XCTAssertEqual(store.documents.count, 10)
        XCTAssertEqual(store.documents.first?.id, repeated.id)
        XCTAssertEqual(store.documents.filter { $0.name == repeated.name }.count, 1)
        let loaded = RecentDocumentsStore(defaults: defaults)
        XCTAssertEqual(loaded.documents, store.documents)
        XCTAssertNotNil(loaded.documents.first?.file.bookmark)
        let resolved = try await loaded.resolve(XCTUnwrap(loaded.documents.first))
        XCTAssertEqual(resolved.file.resolvingSymlinksInPath(), repeated.file.url.resolvingSymlinksInPath())
    }

    @MainActor
    func testFailedRecentOpenPreservesCurrentDocumentAndHistory() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let session = ReaderSession(defaults: defaults)
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try Data("# First\n".utf8).write(to: first)
        try Data("# Second\n".utf8).write(to: second)
        await session.open(first)
        await session.closeDocument()
        let missing = try XCTUnwrap(session.recentDocuments.documents.first)
        try FileManager.default.removeItem(at: first)
        await session.open(second)
        let history = session.recentDocuments.documents
        let token = session.documentToken
        do {
            _ = try await session.openRecent(missing)
            XCTFail("A deleted document must not reopen")
        } catch {}
        XCTAssertEqual(session.recentDocuments.documents, history)
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.document?.text, "# Second\n")
        await session.open(root.appendingPathComponent("never-opened.md"))
        XCTAssertEqual(session.recentDocuments.documents, history)
        await session.closeDocument()
    }

    @MainActor
    func testCorruptHistoryDoesNotPreventOpeningAndCanBeReplaced() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid history".utf8), forKey: RecentDocumentsStore.storageKey)
        let store = RecentDocumentsStore(defaults: defaults)
        XCTAssertTrue(store.documents.isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("# Recovered\n".utf8).write(to: file)
        store.record(await RecentDocumentsStore.prepare(file, folders: []))
        XCTAssertEqual(RecentDocumentsStore(defaults: defaults).documents.count, 1)
    }
}
