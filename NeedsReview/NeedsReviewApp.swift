import AppKit
import SwiftUI
import UserNotifications

@main
struct NeedsReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Settings is the one scene type that does not open a window by itself.
    // The real windows are built in the delegate, so a link-driven launch can
    // skip them entirely.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var settingsWindow: NSWindow?
    private var reviewWindows: [String: NSWindow] = [:]
    private var handledLink = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleCommandLine() { return }

        ReviewRunner.shared.onIdle = { [weak self] in self?.exitIfIdle() }
        UNUserNotificationCenter.current().delegate = self

        AutoReviewer.shared.sync()

        // Opened at login to keep the automatic reviews going: stay out of sight.
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if launchedAtLogin { return }

        // A link launch delivers its URL just after this point, so give it a
        // moment before deciding anyone wanted to see the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.handledLink else { return }
            self.showSettings()
        }
    }

    // MARK: - Command line

    /// `--check-config` and `--review <owner/name> <number>`, for checking the
    /// pieces without the widget in the loop.
    private func handleCommandLine() -> Bool {
        let arguments = CommandLine.arguments

        if arguments.contains("--check-config") {
            // Says whether the shared keychain item is readable, never what is in it.
            let config = ConfigStore.load()
            print("config readable: \(config != nil), complete: \(config?.isComplete ?? false)")
            exit(config?.isComplete == true ? 0 : 1)
        }

        if let index = arguments.firstIndex(of: "--review"), arguments.count > index + 2,
           let number = Int(arguments[index + 2]) {
            handledLink = true
            ReviewRunner.shared.start(repo: arguments[index + 1], number: number) { outcome in
                switch outcome {
                case .success(let result):
                    print("verdict: \(result.verdict)")
                    print("summary: \(result.summary)")
                    print("drafts: \(result.comments.count)")
                    print("file: \(ReviewStore.resultURL(repo: result.repo, number: result.number).path)")
                    exit(0)
                case .failure(let error):
                    print("failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return true
        }

        return false
    }

    // MARK: - Links

    /// Widget links arrive here because macOS routes them to the containing
    /// app. Unless a window is asked for, the app stays an accessory
    /// throughout: no Dock icon, no window.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledLink = true
        for url in urls where url.scheme == "needsreview" {
            route(url)
        }
    }

    private func route(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        switch url.host {
        case "open":
            guard let target = value("url"), let destination = URL(string: target),
                  destination.scheme != "needsreview" else { return }
            NSWorkspace.shared.open(destination, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { self.exitIfIdle() }
            }

        case "review":
            guard let repo = value("repo"), let number = value("number").flatMap(Int.init) else { return }
            ReviewRunner.shared.start(
                repo: repo, number: number,
                focus: value("followup") == nil ? nil : ReviewRunner.followUpFocus
            )

        case "show":
            guard let repo = value("repo"), let number = value("number").flatMap(Int.init) else { return }
            showReview(repo: repo, number: number)

        default:
            return
        }
    }

    // MARK: - Lifetime

    /// The app has no business staying around once nothing is on screen and
    /// no review is running — unless it is the one starting them.
    private func exitIfIdle() {
        guard !AutoReviewer.shared.isEnabled else { return }
        guard ReviewRunner.shared.isIdle, !NSApp.windows.contains(where: \.isVisible) else { return }
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow {
            reviewWindows = reviewWindows.filter { $0.value !== closing }
        }
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: \.isVisible) { NSApp.setActivationPolicy(.accessory) }
            self.exitIfIdle()
        }
    }

    /// Clicking the app in Finder while it lingers.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Windows

    private func showSettings() {
        if settingsWindow == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Needs Review"
            created.contentView = NSHostingView(rootView: SettingsView())
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            settingsWindow = created
        }
        present(settingsWindow)
    }

    private func showReview(repo: String, number: Int) {
        let key = ReviewStatusStore.key(repo: repo, number: number)
        if reviewWindows[key] == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "#\(number)"
            created.contentView = NSHostingView(rootView: ReviewView(model: ReviewModel(repo: repo, number: number)))
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            reviewWindows[key] = created
        }
        present(reviewWindows[key])
    }

    /// Clicking a "reviewed" notification opens that review.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let repo = info["repo"] as? String, let number = info["number"] as? Int else { return }
        await MainActor.run {
            self.handledLink = true
            self.showReview(repo: repo, number: number)
        }
    }

    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
