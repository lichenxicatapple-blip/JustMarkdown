import Foundation
import Security

enum ModelAPIProtocol: String, CaseIterable, Sendable {
    case responses
    case chatCompletions

    var title: String {
        switch self {
        case .responses: "Responses"
        case .chatCompletions: "Chat Completions"
        }
    }

    var path: String { self == .responses ? "responses" : "chat/completions" }
}

struct ModelConfiguration: Equatable, Sendable {
    var baseURL = ""
    var model = ""
    var apiProtocol: ModelAPIProtocol = .responses

    func endpoint() throws -> URL {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.configuration }
        return try endpoint(path: apiProtocol.path)
    }

    func modelsEndpoint() throws -> URL { try endpoint(path: "models") }

    private func endpoint(path suffix: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme,
            ["https", "http"].contains(scheme.lowercased()), url.host != nil,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else {
            throw ModelError.configuration
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var path = components.percentEncodedPath
        // Accept a pasted complete endpoint while keeping the explicit protocol authoritative.
        while path.hasSuffix("/") { path.removeLast() }
        for existingSuffix in ["/chat/completions", "/responses", "/models"] where path.hasSuffix(existingSuffix) {
            path.removeLast(existingSuffix.count)
            break
        }
        components.percentEncodedPath = path + "/" + suffix
        guard let endpoint = components.url else { throw ModelError.configuration }
        return endpoint
    }
}

enum ModelError: LocalizedError {
    case configuration, missingKey, invalidResponse, interrupted, incomplete, contextLimit, requestTooLarge,
        generationFailed
    case rateLimited(TimeInterval)
    case service(Int, String)

    var errorDescription: String? {
        switch self {
        case .configuration: "请在模型设置中填写有效的 Base URL 和模型 ID。"
        case .missingKey: "请在模型设置中填写 API Key。"
        case .invalidResponse: "模型服务没有返回可读取的回答，请检查接口与模型 ID。"
        case .interrupted: "回答已中断。"
        case .incomplete: "回答未完成，请重新生成。"
        case .contextLimit: "内容超出模型上下文上限。"
        case .requestTooLarge: "请求内容过大。"
        case .generationFailed: "模型未能生成回答。"
        case .rateLimited: "请求过于频繁，请稍后重试。"
        case .service(let code, let message): "模型服务返回 HTTP \(code)。\(message)"
        }
    }
}

enum ModelKeychain {
    static var service: String {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                return "dev.catli.JustMarkdown.model.ui-testing"
            }
        #endif
        return "dev.catli.JustMarkdown.model"
    }
    static func read(service: String = ModelKeychain.service) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
            let data = value as? Data
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ value: String, service: String = ModelKeychain.service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }

    static func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
        ]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}

struct ChatMessage: Codable, Sendable {
    var role: String
    var content: String
}
