import Foundation

/// Everything the widget and the app need. Stored in the keychain so the
/// widget extension can read it without an app group (free Personal Teams can
/// sign keychain sharing, but not app groups).
struct Config: Codable, Equatable {
    var token: String = ""
    var username: String = ""
    var org: String = ""
    var teams: [String] = []
    var showDrafts: Bool = false
    /// Checkout the review skill runs in.
    var repoPath: String = "~/redocly"
    var autoReview: Bool = false
    var dailyReviewCap: Int = 15

    var isComplete: Bool {
        !token.isEmpty && !username.isEmpty && !org.isEmpty && !teams.isEmpty
    }

    init() {}

    /// Every key is optional on the way in, so a config saved by an older
    /// build still loads instead of sending the widget back to "setup".
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        token = try values.decodeIfPresent(String.self, forKey: .token) ?? defaults.token
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        org = try values.decodeIfPresent(String.self, forKey: .org) ?? defaults.org
        teams = try values.decodeIfPresent([String].self, forKey: .teams) ?? defaults.teams
        showDrafts = try values.decodeIfPresent(Bool.self, forKey: .showDrafts) ?? defaults.showDrafts
        repoPath = try values.decodeIfPresent(String.self, forKey: .repoPath) ?? defaults.repoPath
        autoReview = try values.decodeIfPresent(Bool.self, forKey: .autoReview) ?? defaults.autoReview
        dailyReviewCap = try values.decodeIfPresent(Int.self, forKey: .dailyReviewCap) ?? defaults.dailyReviewCap
    }
}

/// JSON values in the keychain group both targets share.
enum KeychainStore {
    private static let service = "com.thunderquake.NeedsReview"

    /// kSecUseDataProtectionKeychain is what makes keychain-access-groups
    /// actually apply on macOS. Without it items land in the legacy file-based
    /// login keychain, which is ACL-gated per binary: every rebuild prompts for
    /// the login password, and the widget extension — which cannot show a
    /// prompt — would simply fail to read the token.
    ///
    /// No kSecAttrAccessGroup is set, so items land in the first entry of
    /// keychain-access-groups, which both targets declare identically.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func load<Value: Decodable>(_ type: Value.Type, account: String) -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    @discardableResult
    static func save<Value: Encodable>(_ value: Value, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        SecItemDelete(baseQuery(account: account) as CFDictionary)

        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

enum ConfigStore {
    static func load() -> Config? { KeychainStore.load(Config.self, account: "config") }

    @discardableResult
    static func save(_ config: Config) -> Bool { KeychainStore.save(config, account: "config") }
}
