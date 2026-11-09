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
    }

    private var header: some View {
        HStack {
            Text("Needs review")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if !entry.configured { return "setup" }
        if entry.error != nil { return "error" }
        return entry.pullRequests.isEmpty ? "clear" : String(entry.pullRequests.count)
    }

    /// Text(_:style: .relative) keeps counting on its own between timeline
    /// reloads, so this stays honest without costing a refresh.
    private var footer: some View {
        HStack(spacing: 3) {
            Text(verbatim: "updated")
            Text(entry.date, style: .relative)
            Text(verbatim: "ago")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(verbatim: "\(pr.ageDays)d")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(ageColor(pr.ageDays))

            Link(destination: forwarded(githubURL(for: pr))) {
                Image(systemName: "arrow.up.forward.square")
            }
            Link(destination: forwarded(claudeURL(for: pr))) {
                Image(systemName: "sparkle")
            }
        }
        .font(.system(size: 11))
    }

    private func subtitle(for pr: PullRequest) -> String {
        var parts = [pr.author]
        if pr.isDraft { parts.append("draft") }
        if !pr.engaged.isEmpty { parts.append(pr.engaged.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func ageColor(_ days: Int) -> Color {
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

    private func claudeURL(for pr: PullRequest) -> URL {
        var components = URLComponents(string: "claude://code/new")!
        components.queryItems = [
            URLQueryItem(name: "prompt", value: "review pr \(pr.number)"),
            URLQueryItem(name: "source", value: "desktop_action"),
        ]
        return components.url!
    }
}
