import XCTest

@testable import JustMarkdown

final class CredentialTests: XCTestCase {
    func testSendingPermissionPersistsForTheServiceAcrossModelsAndProtocols() throws {
        let name = "dev.catli.JustMarkdown.consent-testing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = ModelDataConsent(defaults: defaults)
        let service = try ModelDataConsent.service(
            for: ModelConfiguration(baseURL: "https://API.Example.test:443/v1/", model: "first"))
        XCTAssertEqual(service.absoluteString, "https://api.example.test/v1")
        XCTAssertFalse(consent.allows(service))
        consent.allow(service)
        consent.allow(service)

        let restored = ModelDataConsent(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        for base in [
            "https://api.example.test/v1", "https://api.example.test/v1/responses",
            "https://api.example.test/v1/chat/completions/", "https://api.example.test/v1/models",
        ] {
            let configuration = ModelConfiguration(baseURL: base, model: "another", apiProtocol: .chatCompletions)
            XCTAssertTrue(try restored.allows(ModelDataConsent.service(for: configuration)))
        }
        let stored = try XCTUnwrap(defaults.persistentDomain(forName: name))
        let values = try XCTUnwrap(stored["model.dataSharing.allowedServices.images"] as? [String])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].count, 64)
        XCTAssertFalse(values[0].contains("example"))
    }

    func testSendingPermissionDoesNotExtendToAnotherDestination() throws {
        let name = "dev.catli.JustMarkdown.consent-testing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = ModelDataConsent(defaults: defaults)
        consent.allow(try ModelDataConsent.service(for: ModelConfiguration(baseURL: "https://example.test/v1")))
        for base in [
            "https://other.test/v1", "https://example.test/other/v1", "http://example.test/v1",
            "https://example.test:8443/v1", "https://example.test/V1",
        ] {
            XCTAssertFalse(try consent.allows(ModelDataConsent.service(for: ModelConfiguration(baseURL: base))))
        }
        for base in [
            "file:///tmp/private", "https://user:password@example.test/v1", "https://example.test/v1?key=test",
        ] {
            XCTAssertThrowsError(try ModelDataConsent.service(for: ModelConfiguration(baseURL: base)))
        }
    }

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
    func testTextOnlyConsentDoesNotAuthorizeSharingImagePixels() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = try ModelDataConsent.service(for: ModelConfiguration(baseURL: "https://example.test/v1"))
        let consent = ModelDataConsent(defaults: defaults)
        consent.allow(service)
        let imageGrant = try XCTUnwrap(defaults.stringArray(forKey: "model.dataSharing.allowedServices.images"))
        defaults.removeObject(forKey: "model.dataSharing.allowedServices.images")
        defaults.set(imageGrant, forKey: "model.dataSharing.allowedServices")
        let restored = ModelDataConsent(defaults: defaults)
        XCTAssertFalse(restored.allows(service), "An earlier text-only grant must not silently expand to image sharing")
        XCTAssertNil(defaults.object(forKey: "model.dataSharing.allowedServices"))
    }

}
