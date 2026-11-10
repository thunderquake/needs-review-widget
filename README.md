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

Or `./scripts/install.sh`, which builds, installs to `/Applications` and restarts the
widget host. Either way the widget extension gets registered with macOS, after which it appears under right-click desktop →
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

## Drafted reviews

The ✦ on a row runs the `review-pr` skill headlessly (`claude -p`, in the checkout set
under Reviews in the app) and the row then shows the verdict. Clicking a row opens the
review window: the approve call, each draft with its diff line, and the buttons that post.

- The run only drafts. It is told never to write to GitHub and the posting commands are
  denied to it; the result lands in `~/.claude/review-kb/reviews/<owner>-<repo>-<n>.json`.
- Posting is one GitHub review pinned to the commit that was reviewed. If the PR has moved
  on, posting is refused until a re-run. A draft whose line is not in the diff is flagged
  and cannot be ticked.
- What became of each draft (posted, edited, dropped) is appended to
  `~/.claude/review-kb/outcomes.jsonl`.
- PRs you reviewed without approving come back as follow-ups, in amber, once the author
  pushes or replies.
- "Review new requests automatically" keeps the app running in the background (it opens
  at login) and drafts a review once a request has waited 15 minutes, up to the daily cap.

The standalone `claude` CLI has its own sign-in, separate from the desktop app:
`claude auth login`. Two entry points help when checking the pieces without the widget:

```
/Applications/NeedsReview.app/Contents/MacOS/NeedsReview --check-config
/Applications/NeedsReview.app/Contents/MacOS/NeedsReview --review Redocly/redocly 33228
```

The host app is not sandboxed, because it has to start `claude`; the widget extension is.

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
