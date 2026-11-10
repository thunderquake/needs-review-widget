import Foundation

/// What the headless review writes: the approve call and the drafts, nothing
/// the app can work out for itself.
struct ReviewDraft: Decodable {
    struct Comment: Codable, Identifiable, Equatable {
        var path: String
        var line: Int
        var body: String
        var rank: Int
        var optional: Bool
        var entries: [String]
        /// Why the comment is worth raising, written for her. Never posted;
        /// missing from reviews made before it existed.
        var why: String?

        var id: String { "\(path):\(line)#\(rank)" }

        init(path: String, line: Int, body: String, rank: Int, optional: Bool, entries: [String], why: String? = nil) {
            self.path = path
            self.line = line
            self.body = body
            self.rank = rank
            self.optional = optional
            self.entries = entries
            self.why = why
        }

        /// Lenient about what a model tends to vary: a line given as a string,
        /// or the ranking fields left out.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            body = try values.decode(String.self, forKey: .body)
            if let number = try? values.decode(Int.self, forKey: .line) {
                line = number
            } else if let text = try? values.decode(String.self, forKey: .line), let number = Int(text) {
                line = number
            } else {
                throw DecodingError.dataCorruptedError(forKey: .line, in: values, debugDescription: "line is not a number")
            }
            rank = (try? values.decode(Int.self, forKey: .rank)) ?? 99
            optional = (try? values.decode(Bool.self, forKey: .optional)) ?? false
            entries = (try? values.decode([String].self, forKey: .entries)) ?? []
            why = (try? values.decodeIfPresent(String.self, forKey: .why)) ?? nil
        }
    }

    let verdict: String
    let summary: String
    let topLevel: String?
    /// The why for the top-level comment, for her only.
    let topLevelWhy: String?
    let comments: [Comment]
}

/// A finished review as the app keeps it.
struct ReviewResult: Codable {
    var repo: String
    var number: Int
    var title: String
    var author: String
    /// The commit that was reviewed. Posting is refused once the PR has moved on.
    var headSha: String
    var reviewedAt: Date
    var verdict: String
    var summary: String
    var topLevel: String?
    var topLevelWhy: String?
    var comments: [ReviewDraft.Comment]
    var sessionId: String?
    var postedAt: Date?
    var postedEvent: String?
    var postedReviewId: Int?
}

enum ReviewStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/review-kb/reviews", isDirectory: true)
    }

    private static func slug(repo: String, number: Int) -> String {
        "\(repo.replacingOccurrences(of: "/", with: "-"))-\(number)"
    }

    static func resultURL(repo: String, number: Int) -> URL {
        directory.appendingPathComponent("\(slug(repo: repo, number: number)).json")
    }

    /// Written by the review run, read once, then folded into the result.
    static func draftURL(repo: String, number: Int) -> URL {
        directory.appendingPathComponent("\(slug(repo: repo, number: number)).draft.json")
    }

    static func logURL(repo: String, number: Int) -> URL {
        directory.appendingPathComponent("\(slug(repo: repo, number: number)).log")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load(repo: String, number: Int) -> ReviewResult? {
        guard let data = try? Data(contentsOf: resultURL(repo: repo, number: number)) else { return nil }
        return try? decoder.decode(ReviewResult.self, from: data)
    }

    static func save(_ result: ReviewResult) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(result).write(to: resultURL(repo: result.repo, number: result.number), options: .atomic)
    }

    /// Folds a draft the chat rewrote into the saved review. The chat opened
    /// from the review window writes to the same draft file the run did, so
    /// asking it to reword the comments shows up here. Returns whether the
    /// review changed; throws if the file is there but unreadable.
    static func absorbDraft(repo: String, number: Int) throws -> Bool {
        let url = draftURL(repo: repo, number: number)
        guard FileManager.default.fileExists(atPath: url.path),
              var result = load(repo: repo, number: number),
              result.postedAt == nil else { return false }

        let draft = try readDraft(repo: repo, number: number)
        result.verdict = draft.verdict
        result.summary = draft.summary
        result.topLevel = draft.topLevel
        result.topLevelWhy = draft.topLevelWhy
        result.comments = draft.comments.sorted { $0.rank < $1.rank }
        // A new timestamp is what tells an open window its ticks are stale.
        result.reviewedAt = Date()
        try save(result)
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// A draft that is missing or does not parse is a failed review, with the
    /// reason — never an empty list of comments.
    static func readDraft(repo: String, number: Int) throws -> ReviewDraft {
        let url = draftURL(repo: repo, number: number)
        guard let data = try? Data(contentsOf: url) else {
            throw GitHubError(message: "The review finished without writing its result")
        }
        do {
            return try JSONDecoder().decode(ReviewDraft.self, from: data)
        } catch {
            throw GitHubError(message: "The review result could not be read: \(error.localizedDescription)")
        }
    }
}
