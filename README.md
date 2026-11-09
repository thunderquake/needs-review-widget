# Needs Review

A macOS desktop widget listing open pull requests where your review — or your
team's — is requested and **nobody on your team has approved yet**. A teammate's
comment leaves the PR in the list; a teammate's approval removes it.

Each row links out to the PR on GitHub, or opens a new Claude Code session
pre-filled with `review pr <number>`.

## Build

Requires Xcode and an Apple ID signed in under Settings → Apple Accounts. A free
Personal Team is enough; no paid developer account is needed.

```
brew install xcodegen
xcodegen generate
open NeedsReview.xcodeproj
```

Build and run the `NeedsReview` scheme once. That installs the widget extension
and registers it with macOS, after which it appears under right-click desktop →
Edit Widgets.

## Setup

Launch the app and fill in:

| Field | Example |
| --- | --- |
| Token | a classic PAT with `repo` and `read:org` |
| Username | `thunderquake` |
| Organization | `Redocly` |
| Teams | `blips-and-chitz` |

If the org enforces SAML SSO, authorize the token for it on the token page,
otherwise GitHub answers 403 and the widget says so.

The config is stored in the keychain under a Team-ID-prefixed access group, which
is how the widget extension reads it. App groups are deliberately avoided —
free Personal Teams can sign keychain sharing but not app groups.

## Why the app is an agent

macOS does not let a widget open a URL itself — WidgetKit hands every `Link`
destination to the containing app. So each row's buttons point at
`needsreview://open?url=…`, and the app reopens the real target.

To keep that invisible, the app is `LSUIElement` and builds its window in the
app delegate rather than from a SwiftUI scene. A link launch stays an accessory
process: no Dock icon, no window, and it exits once the URL is handed off.
Opening the app normally shows the settings window as usual.

## Notes

- The widget asks to refresh every 15 minutes. WidgetKit decides the real
  cadence from its own daily budget, so treat it as approximate — the refresh
  button in the header forces one, and being user-initiated it does not spend
  budget.
- A single fetch is published as many timeline entries, one per display step.
  That is what lets the footer count up in whole minutes between reloads
  instead of freezing at the value it was rendered with.
- Fetches are capped at 25 PRs to stay inside the extension's time budget.
- Reviews are read one page deep (100 per PR), which no real PR exceeds.
- A failed fetch renders as an error, never as an empty list — an expired token
  must not look like a clear review queue.
