import WebKit
import XCTest

@testable import JustMarkdown

private final class SchemeRequest: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var data = Data()
    var response: URLResponse?
    var finished = false
    var error: Error?
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}

final class ResourceHandlerTests: XCTestCase {
    @MainActor
    func testRecentDocumentRestoresGrantedImageFolderInANewSession() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for folder in [notes, assets] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = notes.appendingPathComponent("readme.md")
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"/>".utf8)
        try Data("# Images\n\n![Figure](../assets/figure.svg)\n".utf8).write(to: file)
        try svg.write(to: assets.appendingPathComponent("figure.svg"))
        var first: ReaderSession? = ReaderSession(defaults: defaults)
        await first?.open(file)
        await first?.grant(root)
        await first?.closeDocument()
        first = nil
        let restored = ReaderSession(defaults: defaults)
        let record = try XCTUnwrap(restored.recentDocuments.documents.first)
        let opened = try await restored.openRecent(record)
        XCTAssertTrue(opened)
        var components = URLComponents()
        components.scheme = "jm-resource"
        components.host = restored.documentToken
        components.path = "/image"
        components.queryItems = [URLQueryItem(name: "path", value: "../assets/figure.svg")]
        let request = SchemeRequest(try XCTUnwrap(components.url))
        restored.resources.webView(WKWebView(), start: request)
        let deadline = Date().addingTimeInterval(5)
        while !request.finished && request.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(request.finished)
        XCTAssertNil(request.error)
        XCTAssertEqual(request.data, svg)
        await restored.closeDocument()
    }

    func testPrivacyManifestIsIncludedInTheAppBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        let declarations = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let defaults = try XCTUnwrap(
            declarations.first {
                $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
            })
        XCTAssertEqual(defaults["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    @MainActor
    func testResourceResponseAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        try content.write(to: root.appendingPathComponent("figure.svg"))
        let handler = LocalResourceHandler()
        handler.configure(
            ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [root], token: "test"))
        let webView = WKWebView()
        let url = try XCTUnwrap(URL(string: "jm-resource://test/image?path=figure.svg"))
        let request = SchemeRequest(url)
        handler.webView(webView, start: request)
        let deadline = Date().addingTimeInterval(3)
        while !request.finished && request.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(request.finished)
        XCTAssertNil(request.error)
        XCTAssertEqual(request.data, content)
        XCTAssertEqual(request.response?.mimeType, "image/svg+xml")
        let canceled = SchemeRequest(url)
        handler.webView(webView, start: canceled)
        handler.webView(webView, stop: canceled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(canceled.finished)
        XCTAssertNil(canceled.response)
        XCTAssertTrue(canceled.data.isEmpty)
        XCTAssertNil(canceled.error, "WebKit forbids every callback after cancellation")
        let stale = SchemeRequest(try XCTUnwrap(URL(string: "jm-resource://another-document/image?path=figure.svg")))
        handler.webView(webView, start: stale)
        XCTAssertNotNil(stale.error)
        XCTAssertTrue(stale.data.isEmpty)
        var permissionPrompts = 0
        handler.onPermissionDenied = { token, source in
            XCTAssertEqual(token, "test")
            XCTAssertEqual(source, "figure.svg")
            permissionPrompts += 1
        }
        handler.configure(
            ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [], token: "test"))
        handler.webView(webView, start: SchemeRequest(url))
        handler.webView(webView, start: SchemeRequest(url))
        XCTAssertEqual(permissionPrompts, 1)
        handler.configure(
            ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [root], token: "test"))
        let missing = SchemeRequest(try XCTUnwrap(URL(string: "jm-resource://test/image?path=missing.svg")))
        handler.webView(webView, start: missing)
        let missingDeadline = Date().addingTimeInterval(3)
        while missing.error == nil && Date() < missingDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(missing.error)
        XCTAssertEqual(permissionPrompts, 1, "A missing file is not a folder-permission failure")
    }
}
