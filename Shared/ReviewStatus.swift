import Foundation

/// Where a PR's drafted review stands. The widget extension is sandboxed and
/// cannot see the result files, so the app mirrors this much into the shared
/// keychain group for it.
struct ReviewStatus: Codable, Equatable {
    enum State: String, Codable {
        case running, ready, failed, posted
    }

    var state: State
    var verdict: String?
    var drafts: Int = 0
    var updatedAt: Date = Date()
}

enum ReviewStatusStore {
    private static let account = "review-status"
    private static let keepFor: TimeInterval = 14 * 86_400

    static func key(repo: String, number: Int) -> String { "\(repo)#\(number)" }

    static func load() -> [String: ReviewStatus] {
        KeychainStore.load([String: ReviewStatus].self, account: account) ?? [:]
    }

    static func set(_ status: ReviewStatus?, repo: String, number: Int) {
        var all = load().filter { Date().timeIntervalSince($0.value.updatedAt) < keepFor }
        all[key(repo: repo, number: number)] = status
        KeychainStore.save(all, account: account)
    }
}
