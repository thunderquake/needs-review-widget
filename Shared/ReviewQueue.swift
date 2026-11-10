import Foundation

/// Open PRs where your review (or your team's) is requested and nobody on the
/// team has approved yet. A teammate's comment leaves the PR in the list; a
/// teammate's approval removes it.
enum ReviewQueue {
    private static let maxPullRequests = 25

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

        let details = try await client.details(
            for: shortlist.map { (repo: $0.repo, number: $0.number) }
        )

        let teams = Set(config.teams)
        var open: [PullRequest] = []

        for item in shortlist {
            guard let detail = details["\(item.repo)#\(item.number)"] else { continue }

            let byTeam = detail.reviews.filter { members.contains($0.login) }
            guard !byTeam.contains(where: { $0.state == "APPROVED" }) else { continue }

            let engaged = byTeam
                .filter { $0.state == "COMMENTED" || $0.state == "CHANGES_REQUESTED" }
                .map(\.login)

            // The first time it landed in your queue, by name or by team. That
            // is the clock worth watching — a PR can be updated hourly and
            // still have been waiting on you for a week.
            let askedAt = detail.requests
                .filter { $0.login == config.username || teams.contains($0.teamSlug ?? "") }
                .map(\.at)
                .min()

            open.append(
                PullRequest(
                    number: item.number,
                    title: item.title,
                    author: item.author,
                    repo: item.repo,
                    isDraft: item.isDraft,
                    engaged: Array(Set(engaged)).sorted(),
                    updatedAt: item.updatedAt,
                    requestedAt: askedAt
                )
            )
        }

        // Longest wait first.
        return open.sorted { $0.waitingSince < $1.waitingSince }
    }
}
