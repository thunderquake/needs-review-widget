import WidgetKit

struct ReviewEntry: TimelineEntry {
    /// When this entry should be shown.
    let date: Date
    /// When the data in it was actually fetched. The gap between the two is
    /// what the footer reports.
    let fetchedAt: Date
    let pullRequests: [PullRequest]
    /// Set when the fetch failed, so an expired token never looks like an
    /// empty review queue.
    let error: String?
    let configured: Bool
    /// Drafted-review state per PR, mirrored into the keychain by the app.
    var statuses: [String: ReviewStatus] = [:]

    static func empty(configured: Bool = true) -> ReviewEntry {
        let now = Date()
        return ReviewEntry(date: now, fetchedAt: now, pullRequests: [], error: nil, configured: configured)
    }
}

struct ReviewProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    /// One entry per step, all sharing the same fetched data. WidgetKit shows
    /// each at its own date without a reload, which is how the footer can
    /// count in whole minutes without spending refresh budget.
    private static var displayOffsets: [TimeInterval] {
        Array(stride(from: 0.0, through: 600.0, by: 60.0))
            + Array(stride(from: 900.0, through: 3600.0, by: 300.0))
    }

    func placeholder(in context: Context) -> ReviewEntry { .empty() }

    func getSnapshot(in context: Context, completion: @escaping (ReviewEntry) -> Void) {
        completion(.empty())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReviewEntry>) -> Void) {
        Task {
            let now = Date()
            let next = now.addingTimeInterval(Self.refreshInterval)

            guard let config = ConfigStore.load(), config.isComplete else {
                completion(Timeline(entries: [.empty(configured: false)], policy: .after(next)))
                return
            }

            var pullRequests: [PullRequest] = []
            var errorText: String?
            do {
                pullRequests = try await ReviewQueue.fetch(config: config)
            } catch let fetchError {
                errorText = fetchError.localizedDescription
            }

            let statuses = ReviewStatusStore.load()
            let entries = Self.displayOffsets.map { offset in
                ReviewEntry(
                    date: now.addingTimeInterval(offset),
                    fetchedAt: now,
                    pullRequests: pullRequests,
                    error: errorText,
                    configured: true,
                    statuses: statuses
                )
            }
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}
