import AppKit
import Foundation
import WidgetKit

/// One PR's drafted review, as the review window edits and posts it.
@MainActor
final class ReviewModel: ObservableObject {
    let repo: String
    let number: Int

    @Published var result: ReviewResult?
    @Published var included: Set<String> = []
    @Published var edited: [String: String] = [:]
    @Published var includeTopLevel = false
    @Published var topLevel = ""
    @Published var isRunning = false
    @Published var failed = false
    /// The PR has commits the review never saw; posting is refused until a re-run.
    @Published var headMoved = false
    /// path → line number → the diff line, for showing context and for
    /// catching a draft GitHub would reject before it is sent.
    @Published var diffLines: [String: [Int: String]] = [:]
    @Published var diffLoaded = false
    @Published var notice: String?
    @Published var isPosting = false
    @Published var selection = 0
    @Published var editing: String?

    private var shownReview: Date?
    private var observer: NSObjectProtocol?
    private var draftWatch: Timer?

    init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: ReviewRunner.changed, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // The chat rewrites drafts by writing the draft file again.
        draftWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.absorbRewrittenDraft() }
        }
        absorbRewrittenDraft()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        draftWatch?.invalidate()
    }

    private func absorbRewrittenDraft() {
        // While a run is going the draft file is the run's to write.
        guard !ReviewRunner.shared.isBusy(repo: repo, number: number) else { return }
        do {
            guard try ReviewStore.absorbDraft(repo: repo, number: number) else { return }
            notice = nil
            if let result = ReviewStore.load(repo: repo, number: number) {
                ReviewStatusStore.set(
                    ReviewStatus(state: .ready, verdict: result.verdict, drafts: result.comments.count),
                    repo: repo, number: number
                )
                WidgetCenter.shared.reloadAllTimelines()
            }
            reload()
        } catch {
            // Usually a file still being written; say so only if it stays broken.
            let url = ReviewStore.draftURL(repo: repo, number: number)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 10 {
                notice = "The chat wrote drafts the app could not read: \(error.localizedDescription)"
            }
        }
    }

    var isPosted: Bool { result?.postedAt != nil }

    var comments: [ReviewDraft.Comment] { result?.comments ?? [] }

    func text(for comment: ReviewDraft.Comment) -> String {
        edited[comment.id] ?? comment.body
    }

    /// False once the diff is known and the draft's line is not in it.
    func attachable(_ comment: ReviewDraft.Comment) -> Bool {
        !diffLoaded || diffLines[comment.path]?[comment.line] != nil
    }

    var selected: [ReviewDraft.Comment] {
        comments.filter { included.contains($0.id) }
    }

    var canPost: Bool {
        result != nil && !isPosted && !isPosting && !headMoved && !isRunning
    }

    func reload() {
        let status = ReviewStatusStore.load()[ReviewStatusStore.key(repo: repo, number: number)]
        isRunning = ReviewRunner.shared.isBusy(repo: repo, number: number)
        failed = status?.state == .failed && !isRunning
        result = ReviewStore.load(repo: repo, number: number)

        // Only reset her ticks and edits when a different review is on screen.
        guard let result, result.reviewedAt != shownReview else { return }
        shownReview = result.reviewedAt
        edited = [:]
        editing = nil
        selection = 0
        topLevel = result.topLevel ?? ""
        includeTopLevel = false
        included = Set(result.comments.filter { !$0.optional }.map(\.id))
        headMoved = false
        diffLoaded = false
        Task { await refreshRemote() }
    }

    private func refreshRemote() async {
        guard let config = ConfigStore.load(), let result else { return }
        let client = GitHubClient(token: config.token)

        if let info = try? await client.pullRequest(repo: repo, number: number) {
            headMoved = info.headSha != result.headSha
        }
        if let patches = try? await client.pullRequestPatches(repo: repo, number: number) {
            diffLines = patches.mapValues(DiffLines.parse(patch:))
            diffLoaded = true
            // A draft GitHub would refuse should not be ticked by default.
            included = included.filter { id in
                comments.first { $0.id == id }.map(attachable) ?? false
            }
        }
    }

    func toggle(_ comment: ReviewDraft.Comment) {
        guard !isPosted, attachable(comment) else { return }
        if included.contains(comment.id) {
            included.remove(comment.id)
        } else {
            included.insert(comment.id)
        }
    }

    func run(focus: String? = nil) {
        notice = nil
        ReviewRunner.shared.start(repo: repo, number: number, focus: focus)
        reload()
    }

    func post(_ event: GitHubClient.ReviewEvent) async {
        guard var result, let config = ConfigStore.load() else { return }
        isPosting = true
        notice = nil
        defer { isPosting = false }

        let body = includeTopLevel ? topLevel.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        do {
            let id = try await GitHubClient(token: config.token).submitReview(
                repo: repo,
                number: number,
                commitId: result.headSha,
                event: event,
                body: body,
                comments: selected.map { (path: $0.path, line: $0.line, body: text(for: $0)) }
            )
            result.postedAt = Date()
            result.postedEvent = event.rawValue
            result.postedReviewId = id
            try ReviewStore.save(result)
            self.result = result

            Outcomes.record(result, included: included, edited: edited)
            ReviewStatusStore.set(
                ReviewStatus(state: .posted, verdict: result.verdict, drafts: selected.count),
                repo: repo, number: number
            )
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            notice = error.localizedDescription
        }
    }

    func openOnGitHub() {
        if let url = URL(string: "https://github.com/\(repo)/pull/\(number)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Picks the headless session back up in a terminal, for digging further.
    func openChat() {
        guard let session = result?.sessionId, let config = ConfigStore.load() else { return }
        let contract = ReviewRunner.chatContract(draftPath: ReviewStore.draftURL(repo: repo, number: number).path)
        let command = "cd \(config.repoPath) && claude --resume \(session) --append-system-prompt '\(contract)'"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}

/// What became of each draft, for the review knowledge base: it is the one
/// place that knows for certain which drafts she posted, reworded or dropped.
enum Outcomes {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/review-kb/outcomes.jsonl")
    }

    static func record(_ result: ReviewResult, included: Set<String>, edited: [String: String]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())

        let lines = result.comments.compactMap { comment -> String? in
            let outcome: String
            if !included.contains(comment.id) {
                outcome = "dropped"
            } else if let text = edited[comment.id], text != comment.body {
                outcome = "edited"
            } else {
                outcome = "posted"
            }
            let record: [String: Any] = [
                "pr": result.number, "path": comment.path, "line": comment.line,
                "entries": comment.entries, "outcome": outcome, "date": date,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
