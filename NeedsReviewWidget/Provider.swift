import WidgetKit

struct ReviewEntry: TimelineEntry {
    let date: Date
    let pullRequests: [PullRequest]
    /// Set when the fetch failed, so an expired token never looks like an
    /// empty review queue.
    let error: String?
    let configured: Bool

    static func empty(configured: Bool = true) -> ReviewEntry {
        ReviewEntry(date: Date(), pullRequests: [], error: nil, configured: configured)
    }
}

struct ReviewProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ReviewEntry { .empty() }

    func getSnapshot(in context: Context, completion: @escaping (ReviewEntry) -> Void) {
        completion(.empty())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReviewEntry>) -> Void) {
        Task {
            let next = Date().addingTimeInterval(Self.refreshInterval)

            guard let config = ConfigStore.load(), config.isComplete else {
                completion(Timeline(entries: [.empty(configured: false)], policy: .after(next)))
                return
            }

            let entry: ReviewEntry
            do {
                let pullRequests = try await ReviewQueue.fetch(config: config)
                entry = ReviewEntry(date: Date(), pullRequests: pullRequests, error: nil, configured: true)
            } catch {
                entry = ReviewEntry(date: Date(), pullRequests: [], error: error.localizedDescription, configured: true)
            }
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}
