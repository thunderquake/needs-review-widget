import SwiftUI
import WidgetKit

struct SettingsView: View {
    @State private var config = ConfigStore.load() ?? Config()
    @State private var teamsText = (ConfigStore.load()?.teams ?? []).joined(separator: ", ")
    @State private var status: Status?

    private enum Status {
        case saved(Int)
        case failed(String)
    }

    var body: some View {
        Form {
            Section("GitHub") {
                SecureField("Personal access token", text: $config.token)
                TextField("Your username", text: $config.username)
                TextField("Organization", text: $config.org)
                TextField("Teams (comma separated)", text: $teamsText)
                Toggle("Include drafts", isOn: $config.showDrafts)
            }

            Section("Reviews") {
                TextField("Repository checkout", text: $config.repoPath)
                Toggle("Review new requests automatically", isOn: $config.autoReview)
                Stepper(value: $config.dailyReviewCap, in: 1...50) {
                    Text(verbatim: "At most \(config.dailyReviewCap) reviews a day · \(ReviewRunner.runsToday) today")
                }
                Text("Reviews only draft. Nothing is posted until you post it from the review window. Automatic reviews start once a request has waited 15 minutes, and keep the app running in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save and test") { saveAndTest() }
                        .keyboardShortcut(.defaultAction)
                    Button("Refresh widget") {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
                if let status { statusLine(status) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusLine(_ status: Status) -> some View {
        switch status {
        case .saved(let count):
            Text("Saved. \(count) PR\(count == 1 ? "" : "s") waiting on you.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    private func saveAndTest() {
        config.teams = teamsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard config.isComplete else {
            status = .failed("Fill in every field first.")
            return
        }
        let wasAutomatic = ConfigStore.load()?.autoReview ?? false
        guard ConfigStore.save(config) else {
            status = .failed("Could not write to the keychain.")
            return
        }
        if config.autoReview != wasAutomatic,
           let problem = AutoReviewer.setOpenAtLogin(config.autoReview) {
            status = .failed(problem)
            return
        }
        AutoReviewer.shared.sync()

        Task {
            do {
                let pullRequests = try await ReviewQueue.fetch(config: config)
                status = .saved(pullRequests.count)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
