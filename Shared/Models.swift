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

    /// Takes a reference date rather than reading the clock: a widget view is
    /// archived when the timeline is built, so Date() inside it would freeze
    /// at build time and the age would drift until the next reload.
    func age(asOf reference: Date) -> TimeInterval {
        max(0, reference.timeIntervalSince(updatedAt))
    }
}

struct GitHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
