import XCTest

@testable import JustMarkdown

final class CredentialTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let service = "dev.catli.JustMarkdown.model.unit-testing." + UUID().uuidString
        addTeardownBlock { try ModelKeychain.delete(service: service) }
        XCTAssertTrue(ModelKeychain.read(service: service).isEmpty)
        try ModelKeychain.write("keychain-test-only", service: service)
        XCTAssertEqual(ModelKeychain.read(service: service), "keychain-test-only")
        try ModelKeychain.write("updated-test-only", service: service)
        XCTAssertEqual(ModelKeychain.read(service: service), "updated-test-only")
        try ModelKeychain.delete(service: service)
        XCTAssertTrue(ModelKeychain.read(service: service).isEmpty)
        try ModelKeychain.delete(service: service)
    }
}
