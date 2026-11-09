import AppKit
import SwiftUI

@main
struct NeedsReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Settings is the one scene type that does not open a window by itself.
    // The real window is built in the delegate, so a link-driven launch can
    // skip it entirely.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var handledLink = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A link launch delivers its URL just after this point, so give it a
        // moment before deciding anyone wanted to see the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.handledLink else { return }
            self.showWindow()
        }
    }

    /// Widget links arrive here because macOS routes them to the containing
    /// app. The app stays an accessory throughout: no Dock icon, no window.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledLink = true
        let launchedForLink = window == nil

        for url in urls {
            guard url.scheme == "needsreview",
                  let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?
                      .first(where: { $0.name == "url" })?
                      .value,
                  let destination = URL(string: target),
                  destination.scheme != "needsreview"
            else { continue }

            NSWorkspace.shared.open(
                destination,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in
                guard launchedForLink else { return }
                // Nothing was on screen, so there is nothing to return to.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    /// Clicking the app in the Dock or Finder while it lingers.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Needs Review"
            created.contentView = NSHostingView(rootView: SettingsView())
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
