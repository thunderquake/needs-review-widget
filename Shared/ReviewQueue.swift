import Foundation

/// Open PRs where your review (or your team's) is requested and nobody on the
/// team has approved yet. A teammate's comment leaves the PR in the list; a
/// teammate's approval removes it.
enum ReviewQueue {
    /// Reviews are fetched per PR, so cap the fan-out to stay inside the
    /// widget extension's time budget.
    private static let maxPullRequests = 25
    private static let maxConcurrentRequests = 4

    static func fetch(config: Config) async throws -> [PullRequest] {
        let client = GitHubClient(token: config.token)

        var members = Set<String>()
        for team in config.teams {
            members.formUnion(try await client.teamMembers(org: config.org, team: team))
        }
        guard !members.isEmpty else {
            throw GitHubError(message: "No team members found — check the team slug")
        }

        var queries = ["is:pr is:open review-requested:\(config.username)"]
        queries += config.teams.map { "is:pr is:open team-review-requested:\(config.org)/\($0)" }

        var candidates: [String: GitHubClient.SearchItem] = [:]
        for query in queries {
            for item in try await client.searchPullRequests(query: query) {
                candidates["\(item.repo)#\(item.number)"] = item
            }
        }

        let shortlist = candidates.values
            .filter { $0.author != config.username }
            .filter { config.showDrafts || !$0.isDraft }
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(maxPullRequests)

        var open: [PullRequest] = []
        try await withThrowingTaskGroup(of: PullRequest?.self) { group in
            var queued = 0
            for item in shortlist {
                // GitHub asks for serial requests per user and answers bursts
                // with a secondary-rate-limit 403, so keep the fan-out small.
                if queued >= maxConcurrentRequests {
                    if let pullRequest = try await group.next() ?? nil { open.append(pullRequest) }
                    queued -= 1
                }
                queued += 1
                group.addTask {
                    let reviews = try await client.reviews(repo: item.repo, number: item.number)
                    let byTeam = reviews.compactMap { review -> (login: String, state: String)? in
                        guard let login = review.user?.login, members.contains(login) else { return nil }
                        return (login, review.state)
                    }

                    guard !byTeam.contains(where: { $0.state == "APPROVED" }) else { return nil }

                    let engaged = byTeam
                        .filter { $0.state == "COMMENTED" || $0.state == "CHANGES_REQUESTED" }
                        .map(\.login)

                    return PullRequest(
                        number: item.number,
                        title: item.title,
                        author: item.author,
                        repo: item.repo,
                        isDraft: item.isDraft,
                        engaged: Array(Set(engaged)).sorted(),
                        updatedAt: item.updatedAt
                    )
                }
            }
            for try await pullRequest in group {
                if let pullRequest { open.append(pullRequest) }
            }
        }

        return open.sorted { $0.updatedAt < $1.updatedAt }
    }
}
