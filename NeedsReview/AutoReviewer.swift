import Foundation
import ServiceManagement

/// Starts reviews for new requests without being asked, so the verdict is
/// already there by the time she looks. It only ever drafts.
@MainActor
final class AutoReviewer {
    static let shared = AutoReviewer()

    private static let interval: TimeInterval = 10 * 60
    /// The rotation bot hands requests out and takes many back within minutes;
    /// waiting this long keeps most of those from costing a run.
    private static let settleTime: TimeInterval = 15 * 60
    private static let retryFailedAfter: TimeInterval = 60 * 60

    private var timer: Timer?

    var isEnabled: Bool { ConfigStore.load()?.autoReview ?? false }

    /// Follows the saved setting: polls while it is on, stops when it is off.
    func sync() {
        guard isEnabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in await AutoReviewer.shared.tick() }
        }
        Task { await tick() }
    }

    /// Opening at login is what keeps the poller alive across restarts.
    static func setOpenAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not change the login item: \(error.localizedDescription)"
        }
    }

    private func tick() async {
        guard let config = ConfigStore.load(), config.isComplete, config.autoReview else { return }
        guard let queue = try? await ReviewQueue.fetch(config: config) else { return }

        let client = GitHubClient(token: config.token)
        let statuses = ReviewStatusStore.load()

        for pr in queue where pr.followUp == nil && !pr.isDraft {
            guard ReviewRunner.runsToday < config.dailyReviewCap else { return }
            guard Date().timeIntervalSince(pr.waitingSince) >= Self.settleTime else { continue }
            guard !ReviewRunner.shared.isBusy(repo: pr.repo, number: pr.number) else { continue }

            if let status = statuses[ReviewStatusStore.key(repo: pr.repo, number: pr.number)] {
                if status.state == .posted { continue }
                if status.state == .failed, Date().timeIntervalSince(status.updatedAt) < Self.retryFailedAfter { continue }
            }

            // Already drafted for the commit the PR is on now.
            guard let info = try? await client.pullRequest(repo: pr.repo, number: pr.number) else { continue }
            if ReviewStore.load(repo: pr.repo, number: pr.number)?.headSha == info.headSha { continue }

            ReviewRunner.shared.start(repo: pr.repo, number: pr.number)
        }
    }
}
