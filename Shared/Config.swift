import Foundation

/// Everything the widget needs to talk to GitHub. Stored in the keychain so the
/// widget extension can read it without an app group (free Personal Teams can
/// sign keychain sharing, but not app groups).
struct Config: Codable, Equatable {
    var token: String = ""
    var username: String = ""
    var org: String = ""
    var teams: [String] = []
    var showDrafts: Bool = false

    var isComplete: Bool {
        !token.isEmpty && !username.isEmpty && !org.isEmpty && !teams.isEmpty
    }
}

enum ConfigStore {
    private static let service = "com.thunderquake.NeedsReview"
    private static let account = "config"

    /// kSecUseDataProtectionKeychain is what makes keychain-access-groups
    /// actually apply on macOS. Without it items land in the legacy file-based
    /// login keychain, which is ACL-gated per binary: every rebuild prompts for
    /// the login password, and the widget extension — which cannot show a
    /// prompt — would simply fail to read the token.
    ///
    /// No kSecAttrAccessGroup is set, so items land in the first entry of
    /// keychain-access-groups, which both targets declare identically.
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func load() -> Config? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    @discardableResult
    static func save(_ config: Config) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }
        SecItemDelete(baseQuery as CFDictionary)

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
