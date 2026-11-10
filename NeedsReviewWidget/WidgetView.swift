import AppIntents
import SwiftUI
import WidgetKit

struct ReviewWidgetView: View {
    var entry: ReviewEntry
    @Environment(\.widgetFamily) private var family

    private var rowLimit: Int { family == .systemLarge ? 8 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            content
            Spacer(minLength: 0)
            if entry.configured { footer }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Needs review")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button(intent: RefreshIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if !entry.configured { return "setup" }
        if entry.error != nil { return "error" }
        return entry.pullRequests.isEmpty ? "clear" : String(entry.pullRequests.count)
    }

    /// Whole minutes only. The value comes from the entry's own date rather
    /// than a live clock, so each stepped timeline entry renders the next
    /// figure without a reload.
    private var footer: some View {
        Text(verbatim: ageLabel)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ageLabel: String {
        let minutes = Int(entry.date.timeIntervalSince(entry.fetchedAt) / 60)
        switch minutes {
        case ..<1: return "updated just now"
        case 1: return "updated 1 min ago"
        case ..<60: return "updated \(minutes) min ago"
        case ..<120: return "updated 1 hr ago"
        default: return "updated \(minutes / 60) hrs ago"
        }
    }

    @ViewBuilder
    private var content: some View {
        if !entry.configured {
            note("Open Needs Review to add your token.", color: .secondary)
        } else if let error = entry.error {
            note(error, color: .orange)
        } else if entry.pullRequests.isEmpty {
            note("Nothing waiting on you.", color: .secondary)
        } else {
            ForEach(entry.pullRequests.prefix(rowLimit)) { row($0) }
            if entry.pullRequests.count > rowLimit {
                Text(verbatim: "+\(entry.pullRequests.count - rowLimit) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ pr: PullRequest) -> some View {
        HStack(spacing: 6) {
            // The row itself opens the drafted review in the app.
            Link(destination: appURL("show", for: pr)) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(verbatim: "#\(pr.number)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(pr.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    Text(subtitle(for: pr))
                        .font(.system(size: 9))
                        .foregroundStyle(pr.followUp == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)

            reviewState(for: pr)

            Text(verbatim: age(of: pr))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(ageColor(days: days(of: pr)))

            Link(destination: forwarded(githubURL(for: pr))) {
                Image(systemName: "arrow.up.forward.square")
            }
        }
        .font(.system(size: 11))
    }

    /// Sparkle starts a review; once one exists the same spot reports on it.
    @ViewBuilder
    private func reviewState(for pr: PullRequest) -> some View {
        switch entry.statuses[ReviewStatusStore.key(repo: pr.repo, number: pr.number)] {
        case nil:
            Link(destination: appURL("review", for: pr)) {
                Image(systemName: "sparkle")
            }
        case let status?:
            switch status.state {
            case .running:
                Text(verbatim: "reviewing")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            case .failed:
                Link(destination: appURL("review", for: pr)) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .foregroundStyle(.orange)
                }
            case .posted:
                Text(verbatim: "posted")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            case .ready:
                Link(destination: appURL("show", for: pr)) {
                    Text(verbatim: verdictLabel(status))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(verdictColor(status).opacity(0.18), in: Capsule())
                        .foregroundStyle(verdictColor(status))
                }
            }
        }
    }

    private func verdictLabel(_ status: ReviewStatus) -> String {
        let drafts = status.drafts == 1 ? "1 draft" : "\(status.drafts) drafts"
        switch status.verdict {
        case "can approve": return status.drafts == 0 ? "can approve" : "approve · \(drafts)"
        case "needs a real look": return "real look · \(drafts)"
        default: return drafts
        }
    }

    private func verdictColor(_ status: ReviewStatus) -> Color {
        switch status.verdict {
        case "can approve": return .green
        case "needs a real look": return .orange
        default: return .blue
        }
    }

    private func appURL(_ action: String, for pr: PullRequest) -> URL {
        var components = URLComponents()
        components.scheme = "needsreview"
        components.host = action
        components.queryItems = [
            URLQueryItem(name: "repo", value: pr.repo),
            URLQueryItem(name: "number", value: String(pr.number)),
        ]
        if pr.followUp != nil {
            components.queryItems?.append(URLQueryItem(name: "followup", value: "1"))
        }
        return components.url!
    }

    private func subtitle(for pr: PullRequest) -> String {
        if let followUp = pr.followUp { return "\(pr.author) · \(followUp)" }
        var parts = [pr.author]
        if pr.isDraft { parts.append("draft") }
        if !pr.engaged.isEmpty { parts.append(pr.engaged.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Scaled to whatever reads smallest: minutes for something just pushed,
    /// days for something that has been sitting.
    private func age(of pr: PullRequest) -> String {
        let minutes = Int(pr.age(asOf: entry.date) / 60)
        switch minutes {
        case ..<1: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(60 * 24): return "\(minutes / 60)h"
        default: return "\(minutes / (60 * 24))d"
        }
    }

    private func days(of pr: PullRequest) -> Int {
        Int(pr.age(asOf: entry.date) / 86_400)
    }

    private func ageColor(days: Int) -> Color {
        if days > 45 { return .red }
        if days > 14 { return .orange }
        return .secondary
    }

    /// macOS hands a widget Link to the containing app rather than opening it,
    /// so every destination is wrapped in our own scheme and the app reopens it.
    private func forwarded(_ target: URL) -> URL {
        var components = URLComponents()
        components.scheme = "needsreview"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
        return components.url ?? target
    }

    private func githubURL(for pr: PullRequest) -> URL {
        URL(string: "https://github.com/\(pr.repo)/pull/\(pr.number)")!
    }

}
