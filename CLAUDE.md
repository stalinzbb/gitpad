# CLAUDE.md

Guidance for AI coding agents working in this repo. Human docs are the source of
truth — [README.md](README.md) (vision/features), [PROJECT.md](PROJECT.md)
(non-obvious decisions & gotchas), [ROADMAP.md](ROADMAP.md), [SECURITY.md](SECURITY.md),
[GROWTH.md](GROWTH.md). This file is the fast map.

## Build & test

- **Build:** `./build.sh` → `GitPad.app` (SwiftPM release build + ad-hoc codesign; also
  regenerates `Resources/AppIcon.icns` via `make-icns.sh` → `make-icon.swift` when stale).
- **Test:** `./test_gitsync.sh` (plus `./test_vault.sh` and `./test_vault_app.sh` for the encrypted vault) — drives the real binary (`GitPad --sync <dir>`) through a
  bare remote: same-line conflicts, unrelated histories, true-conflict-only copies,
  modify/delete, push retry, new-device adoption (and its negative guard). Run after any
  change near `GitSync.sync` or `NoteStore` save/refresh. `GITPAD_DEVICE_NAME` overrides
  the commit author per invocation.
- **Quick compile:** `swift build -c release`.
- **iOS companion:** `xcodebuild -project Mobile/GitPadMobile.xcodeproj -scheme GitPadMobile
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`. The
  project is a hand-written pbxproj with a synchronized folder group (`Mobile/GitPadMobile/`,
  every `.swift` there is compiled) and a local package dependency on `..` for `GitPadCore`.
- **Release:** merge a prep PR (bump `Info.plist`, date the CHANGELOG section), then
  `./release.sh` on the signing Mac: build, sign, notarize, zip + DMG, and `./publish.sh`
  (GitHub pre-release with the CHANGELOG section + checksums, tap cask bump, digest check).
  `publish.sh` is idempotent — re-run it alone if publishing failed; `DRY_RUN=1` rehearses.
- **Run a dev build safely:** every copy shares bundle id `com.stalinzbb.gitpad`, so `open
  GitPad.app` may just activate an installed one. Launch the binary directly, and point it
  at a scratch notes folder: `GITPAD_DIR=/tmp/gitpad-dev ./GitPad.app/Contents/MacOS/GitPad`.
  Without `GITPAD_DIR` a dev build edits `~/Documents/GitPad` and syncs to the real remote.

## Source map (`Sources/GitPad/` + `Sources/GitPadCore/` + `Mobile/`)

| File | Role |
|------|------|
| `main.swift` | Entry point + `--sync <dir>` CLI mode for tests |
| `GitPadApp.swift` | AppDelegate: status item, main-menu "Note" shortcuts, global hotkey, sync scheduling, URL scheme |
| `PanelWindow.swift` | Floating borderless NSPanel + pill collapse/expand frames |
| `NoteStore.swift` | `ObservableObject`: file listing, load/save, debounced autosave, folders, search index, pinning |
| `GitSync.swift` | Every git op via `Process` on `/usr/bin/git` |
| `EditorView.swift` | All SwiftUI: theme tokens, NavBar chrome, screens, NSTextView markdown editor |
| `OnboardingView.swift` | First-run walkthrough + reusable git-setup guide |
| `Vault.swift` | Optional encrypted vault: hdiutil sparse bundle mounted at the notes path, Keychain passphrase, erase-from-Mac |
| `../GitPadCore/Markdown.swift` | Library target, Foundation only, all `public`: `NoteMeta`/`parseMeta`, `fold`, `to/fromMarkdown`, `title(of:)`, `conflictCopyName`, `parseRemote`. `NoteStore` forwards to it. `Palette.swift` beside it is the theme table (ids + hexes) both apps build their `Theme` from — add a theme there, once. Anything that decides what a note looks like on disk goes here so the phone agrees |
| `Mobile/GitPadMobile/*.swift` | iPhone companion (SwiftUI, iOS 16): `GitHubAPI` (Contents/Trees REST over URLSession, GitHub-only), `MobileStore` (cache in Documents/cache, sections, daily), `Keychain`, `SetupView`/`LibraryView`/`NoteView`, `Intents` (Append to Daily). No git, no merge — the Mac reconciles what the phone commits |

## Invariants — do not break

- **Zero third-party dependencies.** Swift + SwiftUI/AppKit only. A new dependency is a
  last resort that needs its own justification (see the "ladder" in README Contributing).
- **Git only via fixed argument arrays**, never shell strings — user input (titles, remote
  URLs) goes straight to `execve` and can't inject. See `GitSync.exec` and its comment.
- **Notes stay plain Markdown** in `~/Documents/GitPad/` — optionally inside an encrypted sparse
  bundle mounted at that same path (`Vault.swift`); nothing above `NoteStore.dir` knows the
  difference. The editor shows ☐/☑ glyphs;
  `NoteStore.to/fromMarkdown` converts to/from `- [ ]` on disk. No proprietary format,
  no frontmatter, no sidecar index files.
- **Sync never blocks writing** and never shows a merge UI — clean merge first, then
  conflict copies + `-X ours`. Keep it that way.
- **Keyboard shortcuts live in the main-menu "Note" submenu** (`GitPadApp.swift`), so they
  route from every screen. Don't reintroduce zero-opacity SwiftUI `.keyboardShortcut` buttons.
- **LSUIElement app** (`.accessory`): no Dock icon, no visible menu bar. The main menu
  exists only to route key equivalents; `autoenablesItems = false` on the Note submenu.
