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

    struct Review: Decodable {
        struct User: Decodable { let login: String }
        let user: User?
        let state: String
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
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
        default:
            throw GitHubError(message: "GitHub returned \(http.statusCode)")
        }
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

    func reviews(repo: String, number: Int) async throws -> [Review] {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)/reviews?per_page=100") else {
            throw GitHubError(message: "Bad repo name")
        }
        return try await get(url, as: [Review].self)
    }
}
