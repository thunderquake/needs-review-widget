import Foundation

/// Open PRs where your review (or your team's) is requested and nobody on the
/// team has approved yet. A teammate's comment leaves the PR in the list; a
/// teammate's approval removes it.
enum ReviewQueue {
    private static let maxPullRequests = 25

    /// Each reviewer's standing, the way GitHub itself decides it: a plain
    /// comment leaves their position unchanged, and a dismissed approval is
    /// withdrawn. So the last decisive review wins, not merely any approval —
    /// otherwise someone who approves and later requests changes would keep
    /// the PR hidden while it is actually blocked.
    ///
    /// Reviews must arrive oldest first, which is what GraphQL's
    /// reviews(last:) returns.
    static func effectiveStates(of reviews: [(login: String, state: String)]) -> [String: String] {
        var latest: [String: String] = [:]
        for review in reviews {
            switch review.state {
            case "APPROVED", "CHANGES_REQUESTED", "DISMISSED":
                latest[review.login] = review.state
            default:
                continue // COMMENTED and PENDING leave the standing alone
            }
        }
        return latest
    }

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
            for: shortlist.map { (repo: $0.repo, number: $0.number) },
            viewer: config.username
        )

        let teams = Set(config.teams)
        var open: [PullRequest] = []

        for item in shortlist {
            guard let detail = details["\(item.repo)#\(item.number)"] else { continue }

            let byTeam = detail.reviews
                .filter { members.contains($0.login) }
                .map { (login: $0.login, state: $0.state) }
            guard !effectiveStates(of: byTeam).values.contains("APPROVED") else { continue }

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

        // Longest wait first, then the ones that came back to you.
        let waiting = open.sorted { $0.waitingSince < $1.waitingSince }
        let listed = Set(waiting.map(\.id))
        let returned = try await followUps(config: config, client: client).filter { !listed.contains($0.id) }
        return waiting + returned
    }

    /// PRs you reviewed without approving where the author has since pushed
    /// or replied. Once a review request is cleared these drop out of every
    /// "review requested" search, which is how a PR with your comments on it
    /// gets forgotten.
    private static func followUps(config: Config, client: GitHubClient) async throws -> [PullRequest] {
        let candidates = try await client
            .searchPullRequests(query: "is:pr is:open reviewed-by:\(config.username) -author:\(config.username)")
            .filter { config.showDrafts || !$0.isDraft }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxPullRequests)

        let details = try await client.details(
            for: candidates.map { (repo: $0.repo, number: $0.number) },
            viewer: config.username
        )

        var found: [PullRequest] = []
        for item in candidates {
            guard let detail = details["\(item.repo)#\(item.number)"] else { continue }

            let mine = detail.ownReviews
            guard let lastReview = mine.compactMap(\.at).max() else { continue }

            let standing = effectiveStates(of: mine.map { (login: config.username, state: $0.state) })[config.username]
            guard standing != "APPROVED" else { continue }

            let pushedAt = detail.lastCommitAt.flatMap { $0 > lastReview ? $0 : nil }
            // A reply in a review thread arrives as a review of the author's own.
            let repliedAt = (detail.reviews.filter { $0.login == item.author }.compactMap(\.at)
                + detail.comments.filter { $0.login == item.author }.map(\.at))
                .filter { $0 > lastReview }
                .max()

            let reason: String
            switch (pushedAt, repliedAt) {
            case (nil, nil): continue
            case (_?, nil): reason = "author pushed since your review"
            case (nil, _?): reason = "author replied to you"
            case (_?, _?): reason = "author pushed and replied"
            }

            found.append(
                PullRequest(
                    number: item.number,
                    title: item.title,
                    author: item.author,
                    repo: item.repo,
                    isDraft: item.isDraft,
                    engaged: [],
                    updatedAt: item.updatedAt,
                    requestedAt: [pushedAt, repliedAt].compactMap { $0 }.min(),
                    followUp: reason
                )
            )
        }
        return found.sorted { $0.waitingSince < $1.waitingSince }
    }
}
