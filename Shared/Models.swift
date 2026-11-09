import Foundation

struct PullRequest: Identifiable, Codable, Hashable {
    var id: String { "\(repo)#\(number)" }

    let number: Int
    let title: String
    let author: String
    /// "owner/name" — taken from the search result, so PRs outside the main
    /// repo resolve correctly rather than being skipped.
    let repo: String
    let isDraft: Bool
    /// Teammates who commented or requested changes but did not approve.
    let engaged: [String]
    let updatedAt: Date

    var ageDays: Int {
        max(0, Calendar.current.dateComponents([.day], from: updatedAt, to: Date()).day ?? 0)
    }
}

struct GitHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
