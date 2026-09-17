# GitPad Mobile: handoff

State as of 2026-09-17. Read this before touching `Mobile/`.

## Where things live

- **Branch:** `mobile-companion`. All phone work goes here and nowhere else.
- **Draft PR:** [#84](https://github.com/stalinzbb/gitpad/pull/84). It stays a draft. The owner
  merges it when they decide to release. Do not merge it, and do not mark it ready.
- **`main` has no phone code.** #80 put the first version on `main` by accident of timing; #83
  reverted it exactly (`git diff ba77223 20950e6` is empty). `main` was then merged into this
  branch, so #84 shows the full diff and merges cleanly.
- The Mac release (`release.sh`) never packages anything under `Mobile/`.

## What it is

An iPhone companion for GitPad. iOS has no git binary and the project allows no third-party
dependencies, so the phone talks to the **GitHub REST API** (Contents + Trees) over `URLSession`.
The phone is a guest: it reads and writes blobs and never merges. The Mac's `GitSync` reconciles
whatever the phone commits. GitHub remotes only.

## Layout

| Path | Role |
|------|------|
| `Sources/GitPadCore/Markdown.swift` | Shared, Foundation only: `parseMeta`, `fold`, `to/fromMarkdown`, `title(of:)`, `conflictCopyName`, `parseRemote`. The Mac's `NoteStore` forwards to these |
| `Sources/GitPadCore/Palette.swift` | The five theme presets as ids + hexes. Mac `Theme.all` and phone `Theme.all` both build from it |
| `Mobile/GitPadMobile.xcodeproj` | Hand-written pbxproj. Synchronized folder group: every `.swift` in `GitPadMobile/` compiles, no file list to maintain. Local package dependency on `..` for `GitPadCore`. Info.plist is generated from build settings |
| `GitHubAPI.swift` | REST client. Commits as `<device name> <gitpad@localhost>` with message `autosave <ISO date>`, the Mac's convention. `save()` holds the conflict rule |
| `MobileStore.swift` | Tree + body cache in `Documents/cache/` (one file per note: sha on line 1, body after; `tree.json`). Sections, search, daily note, background prefetch |
| `Keychain.swift` | The token. One generic-password item |
| `Theme.swift` | Phone `Theme`, environment key, `themedSurface`, swatch picker |
| `SetupView` / `LibraryView` (+ `SettingsView`, `TaskRing`) / `NoteView` | Screens |
| `Intents.swift` | "Append to Daily" App Intent. Lives in the app target, no extension |

## Rules that are easy to break

- **Conflict rule.** A write with a stale sha returns 409/422. Re-read: if the remote body equals
  the body the edit started from, retry with the new sha. Otherwise write the phone's text as
  `Markdown.conflictCopyName(...)` and leave the remote canonical. The name shape must stay
  identical to the Mac's, or the Mac's Conflicts screen will not recognise phone copies.
- **Saves are optimistic and queued** (`NoteView.write`). Each save awaits the previous one so it
  carries the sha that save produced. A failure rolls the screen back to the last saved text.
- **Prefetch** fetches every uncached body after a refresh, one request each, sequentially. A row
  has no real title, snippet or task count until its body is cached. A changed sha evicts the
  cached body. Fine for hundreds of notes; thousands would need GraphQL batching.
- **On-disk shapes belong in `GitPadCore`**, never duplicated in `Mobile/`.
- **Themes:** add or change a preset in `Palette.swift` only.
- **Never write to the owner's real notes repo from the simulator.** Toggling a checkbox, editing,
  quick entry and New Note all commit. Use a throwaway repo.
- Nobody but the owner types the GitHub token.

## Build and run

```bash
xcodebuild -project Mobile/GitPadMobile.xcodeproj -scheme GitPadMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Token: fine-grained, "Only select repositories" = the notes repo, Contents = Read and write
(Metadata read-only is added automatically).

After any `GitPadCore` change also run the Mac checks: `./build.sh`,
`./GitPad.app/Contents/MacOS/GitPad --selftest`, `./test_gitsync.sh`, `./test_vault.sh`.
To preview a theme without tapping: `xcrun simctl spawn <udid> defaults write com.stalinzbb.gitpad.mobile theme Nord`.

## Verified

- Mac: build, selftest (covers `parseRemote`, `conflictCopyName`, `title(of:)`), sync and vault tests.
- iOS: builds. On screen: Setup errors (non-GitHub URL, 401), Library, Settings, a checklist
  note, System dark, Nord, Sepia.

## Not verified

- Any write path against a real repo: checkbox toggle, edit, quick entry, New Note, the conflict
  copy, the App Intent. The owner reported the first build "works" after connecting.
- Offline behaviour (cached reads, failed-save rollback).
- Dracula, Solarized Light, inline-code colour, themed Setup screen, the editor screen, iPad.

## Known gaps, by choice

No offline write queue. No "Recent" section (the tree API has no mtimes). No GitLab. No rename,
move, delete or pin. No folders in New Note (Inbox only). No `[[links]]` rendering. No app icon.
No TestFlight or signing setup. No share extension or widget (both need extension targets).

## Before release

1. Owner runs the unverified write paths against a throwaway repo, then their own.
2. App icon and signing team in the Xcode project.
3. Merge `main` into the branch, run the Mac checks, mark #84 ready, merge.
4. The README "On your phone" section, ROADMAP item and CHANGELOG entry ride along in this branch.
