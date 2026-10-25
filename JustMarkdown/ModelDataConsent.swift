import CryptoKit
import Foundation

/// Consent belongs to the normalized service, independently of its model, key or API dialect.
struct ModelDataConsent {
    private let defaults: UserDefaults
    private let storageKey = "model.dataSharing.allowedServices"

    init(defaults: UserDefaults) { self.defaults = defaults }

    static func service(for configuration: ModelConfiguration) throws -> URL {
        let endpoint = try configuration.modelsEndpoint().deletingLastPathComponent()
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ModelError.configuration
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let service = components.url else { throw ModelError.configuration }
        return service
    }

    func allows(_ service: URL) -> Bool {
        (defaults.stringArray(forKey: storageKey) ?? []).contains(identifier(service))
    }

    func allow(_ service: URL) {
        var services = defaults.stringArray(forKey: storageKey) ?? []
        let value = identifier(service)
        guard !services.contains(value) else { return }
        services.append(value)
        defaults.set(services, forKey: storageKey)
    }

    private func identifier(_ service: URL) -> String {
        SHA256.hash(data: Data(service.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
