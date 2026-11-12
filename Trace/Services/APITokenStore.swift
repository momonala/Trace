import Foundation
import Security

/// The Trace server's API token, kept in the iOS Keychain and sent as a Bearer header on every request.
@MainActor
enum APITokenStore {
    private static let service = "org.mnalavadi.Trace.api-token"
    private static var cached: String?

    /// Retries the Keychain while empty: before the first unlock after a reboot the item can't be read yet.
    static var token: String? {
        if cached == nil {
            cached = load()
        }
        return cached
    }

    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        cached = nil

        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        // Uploads and heartbeats run in the background while the phone is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }

        cached = trimmed
        return true
    }

    static func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
