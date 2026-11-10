import Foundation
import UserNotifications
import WidgetKit

/// Runs the review-pr skill headlessly and turns what it writes into a
/// ReviewResult. Nothing here posts to GitHub.
@MainActor
final class ReviewRunner {
    static let shared = ReviewRunner()

    private static let maxConcurrent = 2
    private static let timeout: TimeInterval = 25 * 60

    typealias Completion = (Result<ReviewResult, Error>) -> Void

    private struct Job {
        let repo: String
        let number: Int
        let focus: String?
        let completion: Completion?
        var key: String { ReviewStatusStore.key(repo: repo, number: number) }
    }

    private var running: Set<String> = []
    private var waiting: [Job] = []

    /// Called whenever the last run finishes, so an app that was only alive
    /// for the review can leave.
    var onIdle: (() -> Void)?
    /// Posted after every run and every start, so open windows can refresh.
    static let changed = Notification.Name("ReviewRunnerChanged")

    var isIdle: Bool { running.isEmpty && waiting.isEmpty }

    func isBusy(repo: String, number: Int) -> Bool {
        let key = ReviewStatusStore.key(repo: repo, number: number)
        return running.contains(key) || waiting.contains { $0.key == key }
    }

    /// `focus` narrows a re-run, e.g. to the commits since her last review.
    func start(repo: String, number: Int, focus: String? = nil, completion: Completion? = nil) {
        guard !isBusy(repo: repo, number: number) else { return }
        let job = Job(repo: repo, number: number, focus: focus, completion: completion)

        ReviewStatusStore.set(ReviewStatus(state: .running), repo: repo, number: number)
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: Self.changed, object: job.key)

        if running.count < Self.maxConcurrent {
            run(job)
        } else {
            waiting.append(job)
        }
    }

    /// For a PR she has already reviewed: look at what changed, not at everything again.
    static let followUpFocus = """
    She has already reviewed this PR and left comments without approving. Review only what \
    changed since her last review, and start the summary by saying which of her earlier \
    comments were addressed and which were not.
    """

    /// Given to the chat opened from the review window, on one line so it
    /// survives being passed through a terminal command.
    static func chatContract(draftPath: String) -> String {
        "You are continuing a review started by the Needs Review app. Whenever she asks you to change, "
            + "reword, add or drop draft comments, write the complete updated result to \(draftPath) in the same "
            + "JSON shape as before (verdict, summary, topLevel, topLevelWhy, comments with path, line, body, rank, "
            + "optional, entries, why) so the app shows it. Keep a why for every draft, the pr-comments why line, "
            + "updated when the comment changes; it is for her only and never goes into a body. Never post to GitHub."
    }

    // MARK: - Daily count

    private static var todayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "runs-\(formatter.string(from: Date()))"
    }

    static var runsToday: Int { UserDefaults.standard.integer(forKey: todayKey) }

    // MARK: - Running

    private func run(_ job: Job) {
        running.insert(job.key)
        UserDefaults.standard.set(Self.runsToday + 1, forKey: Self.todayKey)

        Task {
            let outcome: Result<ReviewResult, Error>
            do {
                outcome = .success(try await perform(job))
            } catch {
                outcome = .failure(error)
            }
            finish(job, outcome)
        }
    }

    private func finish(_ job: Job, _ outcome: Result<ReviewResult, Error>) {
        running.remove(job.key)

        switch outcome {
        case .success(let result):
            ReviewStatusStore.set(
                ReviewStatus(state: .ready, verdict: result.verdict, drafts: result.comments.count),
                repo: job.repo, number: job.number
            )
            notify(
                title: "#\(job.number) reviewed",
                body: "\(result.verdict.prefix(1).uppercased())\(result.verdict.dropFirst()) · \(Self.draftCount(result.comments.count))",
                job: job
            )
        case .failure(let error):
            ReviewStatusStore.set(ReviewStatus(state: .failed), repo: job.repo, number: job.number)
            notify(title: "#\(job.number) review failed", body: error.localizedDescription, job: job)
        }

        WidgetCenter.shared.reloadAllTimelines()
        job.completion?(outcome)
        NotificationCenter.default.post(name: Self.changed, object: job.key)

        if !waiting.isEmpty, running.count < Self.maxConcurrent {
            run(waiting.removeFirst())
        }
        if isIdle { onIdle?() }
    }

    static func draftCount(_ count: Int) -> String {
        switch count {
        case 0: return "no drafts"
        case 1: return "1 draft"
        default: return "\(count) drafts"
        }
    }

    private func perform(_ job: Job) async throws -> ReviewResult {
        guard let config = ConfigStore.load(), config.isComplete else {
            throw GitHubError(message: "Open Needs Review and finish setup first")
        }

        let checkout = URL(fileURLWithPath: NSString(string: config.repoPath).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: checkout.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitHubError(message: "No checkout at \(config.repoPath) — set it in Needs Review")
        }

        // Read before the run: this is the commit the drafts will belong to.
        let info = try await GitHubClient(token: config.token).pullRequest(repo: job.repo, number: job.number)

        let draftURL = ReviewStore.draftURL(repo: job.repo, number: job.number)
        let logURL = ReviewStore.logURL(repo: job.repo, number: job.number)
        try FileManager.default.createDirectory(at: ReviewStore.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: draftURL)

        var prompt = "/review-pr \(job.number)"
        if let focus = job.focus { prompt += "\n\n\(focus)" }

        let run = try await Self.launch(
            prompt: prompt,
            contract: Self.contract(draftPath: draftURL.path),
            directory: checkout,
            log: logURL
        )

        let draft: ReviewDraft
        do {
            draft = try ReviewStore.readDraft(repo: job.repo, number: job.number)
        } catch {
            // Say why the run produced nothing, when it told us.
            if let reason = run.failure { throw GitHubError(message: reason) }
            throw error
        }
        try? FileManager.default.removeItem(at: draftURL)

        let result = ReviewResult(
            repo: job.repo,
            number: job.number,
            title: info.title,
            author: info.author,
            headSha: info.headSha,
            reviewedAt: Date(),
            verdict: draft.verdict,
            summary: draft.summary,
            topLevel: draft.topLevel,
            topLevelWhy: draft.topLevelWhy,
            comments: draft.comments.sorted { $0.rank < $1.rank },
            sessionId: run.sessionId
        )
        try ReviewStore.save(result)
        return result
    }

    /// The skills stay as they are; this only adds where the result goes.
    private static func contract(draftPath: String) -> String {
        """
        This is a headless run started from the Needs Review app. Nobody is reading the chat, \
        so never stop to ask a question; make the call you would recommend.

        Do the review exactly as the skill says. Never post, comment, approve, request changes, \
        label or otherwise write to GitHub: she posts everything herself from the app.

        When the review is done, write the result as JSON to \(draftPath) and nothing else to \
        that file:

        {
          "verdict": "can approve" | "comment first" | "needs a real look",
          "summary": "one line saying why",
          "topLevel": "a top-level comment worth posting, or null",
          "topLevelWhy": "the why line for the top-level comment, or null",
          "comments": [
            { "path": "repo-relative path", "line": 123, "body": "the exact text to post",
              "why": "the why line, for her only",
              "rank": 1, "optional": false, "entries": ["review-kb ids, if any"] }
          ]
        }

        Include every draft you would have shown her, worded by pr-comments so she can post it \
        unedited. "why" is the pr-comments why line: what goes wrong, and for whom, if she skips \
        the comment, in plain words for her rather than the author. It is never posted, so keep \
        it out of "body". "line" is the line number in the new version of the file and must be a line \
        that appears in the PR diff (added or context); for a finding about a removed line, use \
        the nearest line that is in the diff. "rank" starts at 1 for the most important. \
        "optional" is true for drafts she can skip. With nothing to raise, "comments" is [].

        End with the verdict as your final message.
        """
    }

    private struct RunOutput {
        let sessionId: String?
        let failure: String?
    }

    private static func launch(prompt: String, contract: String, directory: URL, log: URL) async throws -> RunOutput {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell, so claude, gh, mise and jq resolve the way they do in
        // her terminal rather than through the bare PATH an app is given.
        process.arguments = [
            "-lic", "exec claude \"$@\"", "claude",
            "-p", prompt,
            "--output-format", "json",
            "--permission-mode", "auto",
            "--append-system-prompt", contract,
            "--disallowedTools",
            "Bash(gh pr review:*)", "Bash(gh pr comment:*)", "Bash(gh pr merge:*)",
            "Bash(gh pr close:*)", "Bash(gh pr edit:*)", "Bash(gh api -X:*)", "Bash(gh api --method:*)",
        ]
        process.currentDirectoryURL = directory
        process.environment = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": "/bin/zsh",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitHubError(message: "Could not start claude: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
        try? output.close()

        // --output-format json ends with one object; a login shell may print
        // lines of its own before it.
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let summary = text.split(separator: "\n").reversed().lazy
            .compactMap { line -> [String: Any]? in
                guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            .first

        var failure: String?
        if status != 0 {
            failure = status == 15 ? "The review ran past 25 minutes and was stopped" : "claude exited with status \(status)"
        }
        if summary?["is_error"] as? Bool == true, let message = summary?["result"] as? String {
            failure = String(message.prefix(200))
        }
        return RunOutput(sessionId: summary?["session_id"] as? String, failure: failure)
    }

    // MARK: - Notifications

    private func notify(title: String, body: String, job: Job) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["repo": job.repo, "number": job.number]
            center.add(UNNotificationRequest(identifier: job.key, content: content, trigger: nil))
        }
    }
}
