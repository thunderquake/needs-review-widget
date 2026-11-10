import Foundation

struct GitHubClient {
    let token: String

    struct SearchItem {
        let number: Int
        let title: String
        let author: String
        let repo: String
        let isDraft: Bool
        let updatedAt: Date
    }

    /// Reviews, review-request events and recent activity for one PR, fetched together.
    struct Detail {
        /// Oldest first.
        let reviews: [(login: String, state: String, at: Date?)]
        let requests: [(login: String?, teamSlug: String?, at: Date)]
        /// The viewer's own reviews, asked for separately: on a busy PR they
        /// can sit outside the last hundred reviews.
        let ownReviews: [(state: String, at: Date?)]
        let lastCommitAt: Date?
        /// Plain conversation comments, newest last.
        let comments: [(login: String, at: Date)]
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Transport

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NeedsReviewWidget", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(message: "No response from GitHub")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw GitHubError(message: "Unexpected response shape")
            }
        case 401:
            throw GitHubError(message: "Token rejected — check or renew it")
        case 403, 429:
            throw Self.forbidden(http: http, data: data)
        case 404:
            throw GitHubError(message: "Not found — check org and team names")
        case 422:
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reasons = (body?["errors"] as? [Any])?.map { "\($0)" }.joined(separator: "; ")
            throw GitHubError(message: reasons ?? (body?["message"] as? String) ?? "GitHub refused the request (422)")
        default:
            throw GitHubError(message: "GitHub returned \(http.statusCode)")
        }
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        try await send(URLRequest(url: url), as: type)
    }

    /// 403 covers SSO, rate limits and missing scopes, which need different
    /// fixes — so say which one it is rather than guessing at scopes.
    private static func forbidden(http: HTTPURLResponse, data: Data) -> GitHubError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = (body?["message"] as? String) ?? ""

        if http.value(forHTTPHeaderField: "X-GitHub-SSO") != nil
            || detail.localizedCaseInsensitiveContains("SSO") {
            return GitHubError(message: "Token needs SSO authorization for this org")
        }
        if detail.localizedCaseInsensitiveContains("secondary rate limit") {
            return GitHubError(message: "Hit GitHub's burst limit — retry shortly")
        }
        if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            return GitHubError(message: "Rate limited — resets within the hour")
        }

        let scopes = http.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? ""
        if scopes.isEmpty {
            return GitHubError(message: "Forbidden. Token reports no scopes — needs repo and read:org")
        }
        if !scopes.contains("read:org") && !scopes.contains("admin:org") {
            return GitHubError(message: "Token scopes are [\(scopes)] — read:org is missing")
        }
        return GitHubError(message: detail.isEmpty ? "Forbidden (403)" : detail)
    }

    // MARK: - REST

    func teamMembers(org: String, team: String) async throws -> [String] {
        struct Member: Decodable { let login: String }
        guard let url = URL(string: "https://api.github.com/orgs/\(org)/teams/\(team)/members?per_page=100") else {
            throw GitHubError(message: "Bad org or team name")
        }
        return try await get(url, as: [Member].self).map(\.login)
    }

    func searchPullRequests(query: String) async throws -> [SearchItem] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct User: Decodable { let login: String }
                let number: Int
                let title: String
                let draft: Bool?
                let user: User?
                let updated_at: Date
                let repository_url: String
            }
            let items: [Item]
        }

        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "50"),
        ]
        guard let url = components.url else { throw GitHubError(message: "Bad search query") }

        return try await get(url, as: Response.self).items.map { item in
            SearchItem(
                number: item.number,
                title: item.title,
                author: item.user?.login ?? "",
                // repository_url is ".../repos/OWNER/NAME"
                repo: item.repository_url.split(separator: "/").suffix(2).joined(separator: "/"),
                isDraft: item.draft ?? false,
                updatedAt: item.updated_at
            )
        }
    }

    struct PullRequestInfo {
        let title: String
        let author: String
        let headSha: String
    }

    func pullRequest(repo: String, number: Int) async throws -> PullRequestInfo {
        struct Response: Decodable {
            struct User: Decodable { let login: String }
            struct Head: Decodable { let sha: String }
            let title: String
            let user: User?
            let head: Head
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)") else {
            throw GitHubError(message: "Bad repo name")
        }
        let response = try await get(url, as: Response.self)
        return PullRequestInfo(title: response.title, author: response.user?.login ?? "", headSha: response.head.sha)
    }

    /// Each changed file's patch, keyed by path. Files GitHub sends without a
    /// patch (binary, or too large) are simply absent.
    func pullRequestPatches(repo: String, number: Int) async throws -> [String: String] {
        struct File: Decodable {
            let filename: String
            let patch: String?
        }
        var patches: [String: String] = [:]
        for page in 1...10 {
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)/files?per_page=100&page=\(page)") else {
                throw GitHubError(message: "Bad repo name")
            }
            let files = try await get(url, as: [File].self)
            for file in files { patches[file.filename] = file.patch }
            if files.count < 100 { break }
        }
        return patches
    }

    enum ReviewEvent: String {
        case comment = "COMMENT"
        case approve = "APPROVE"
    }

    /// Posts one review carrying every comment, pinned to the commit that was
    /// reviewed. It is a single request, so either all of it lands or none.
    /// Returns the new review's id.
    func submitReview(
        repo: String,
        number: Int,
        commitId: String,
        event: ReviewEvent,
        body: String?,
        comments: [(path: String, line: Int, body: String)]
    ) async throws -> Int {
        struct Response: Decodable { let id: Int }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)/reviews") else {
            throw GitHubError(message: "Bad repo name")
        }

        var payload: [String: Any] = [
            "commit_id": commitId,
            "event": event.rawValue,
            "comments": comments.map {
                ["path": $0.path, "line": $0.line, "side": "RIGHT", "body": $0.body] as [String: Any]
            },
        ]
        if let body, !body.isEmpty { payload["body"] = body }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await send(request, as: Response.self).id
    }

    // MARK: - GraphQL

    /// Reviews plus review-request events for many PRs at once, keyed by
    /// "owner/name#number".
    ///
    /// REST would need one reviews call and a full paginated timeline per PR —
    /// a busy PR runs to several hundred events across six pages, purely to
    /// find a handful of review requests. GraphQL filters server side, so a
    /// batch of PRs costs a single request.
    func details(for refs: [(repo: String, number: Int)], viewer: String) async throws -> [String: Detail] {
        var collected: [String: Detail] = [:]
        for chunk in stride(from: 0, to: refs.count, by: Self.batchSize).map({
            Array(refs[$0..<min($0 + Self.batchSize, refs.count)])
        }) {
            try await collected.merge(details(forChunk: chunk, viewer: viewer)) { current, _ in current }
        }
        return collected
    }

    private static let batchSize = 10

    private func details(forChunk refs: [(repo: String, number: Int)], viewer: String) async throws -> [String: Detail] {
        var aliases: [String: String] = [:]
        var selections: [String] = []

        for (index, ref) in refs.enumerated() {
            let parts = ref.repo.split(separator: "/")
            guard parts.count == 2 else { continue }
            let alias = "p\(index)"
            aliases[alias] = "\(ref.repo)#\(ref.number)"
            selections.append("""
              \(alias): repository(owner: "\(parts[0])", name: "\(parts[1])") {
                pullRequest(number: \(ref.number)) { ...detail }
              }
            """)
        }
        guard !selections.isEmpty else { return [:] }

        let query = """
        { \(selections.joined(separator: "\n")) }
        fragment detail on PullRequest {
          reviews(last: 100) { nodes { author { login } state submittedAt } }
          own: reviews(last: 30, author: "\(viewer)") { nodes { state submittedAt } }
          commits(last: 1) { nodes { commit { committedDate } } }
          comments(last: 20) { nodes { author { login } createdAt } }
          timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], first: 100) {
            nodes {
              ... on ReviewRequestedEvent {
                createdAt
                requestedReviewer { ... on User { login } ... on Team { slug } }
              }
            }
          }
        }
        """

        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let response = try await send(request, as: GraphQLResponse.self)
        if let message = response.errors?.first?.message {
            throw GitHubError(message: message)
        }

        var result: [String: Detail] = [:]
        for (alias, node) in response.data ?? [:] {
            guard let key = aliases[alias], let pr = node.pullRequest else { continue }
            result[key] = Detail(
                reviews: (pr.reviews?.nodes ?? []).compactMap { review in
                    review.author.map { ($0.login, review.state, review.submittedAt) }
                },
                requests: (pr.timelineItems?.nodes ?? []).compactMap { event in
                    guard let at = event.createdAt else { return nil }
                    return (event.requestedReviewer?.login, event.requestedReviewer?.slug, at)
                },
                ownReviews: (pr.own?.nodes ?? []).map { ($0.state, $0.submittedAt) },
                lastCommitAt: pr.commits?.nodes?.last?.commit.committedDate,
                comments: (pr.comments?.nodes ?? []).compactMap { comment in
                    comment.author.map { ($0.login, comment.createdAt) }
                }
            )
        }
        return result
    }

    private struct GraphQLResponse: Decodable {
        struct Message: Decodable { let message: String }
        struct RepositoryNode: Decodable { let pullRequest: PullRequestNode? }
        struct PullRequestNode: Decodable {
            struct Reviews: Decodable { let nodes: [ReviewNode]? }
            struct ReviewNode: Decodable {
                struct Author: Decodable { let login: String }
                let author: Author?
                let state: String
                let submittedAt: Date?
            }
            struct Commits: Decodable {
                struct Node: Decodable {
                    struct Commit: Decodable { let committedDate: Date }
                    let commit: Commit
                }
                let nodes: [Node]?
            }
            struct Comments: Decodable {
                struct Node: Decodable {
                    struct Author: Decodable { let login: String }
                    let author: Author?
                    let createdAt: Date
                }
                let nodes: [Node]?
            }
            struct Timeline: Decodable { let nodes: [EventNode]? }
            struct EventNode: Decodable {
                struct Reviewer: Decodable {
                    let login: String?
                    let slug: String?
                }
                let createdAt: Date?
                let requestedReviewer: Reviewer?
            }
            struct OwnReviews: Decodable {
                struct Node: Decodable {
                    let state: String
                    let submittedAt: Date?
                }
                let nodes: [Node]?
            }
            let reviews: Reviews?
            let own: OwnReviews?
            let commits: Commits?
            let comments: Comments?
            let timelineItems: Timeline?
        }

        let data: [String: RepositoryNode]?
        let errors: [Message]?
    }
}
