# GitPad — internal working notes

_User-facing docs are the source of truth: see [README.md](README.md) (vision,
features, architecture, shortcuts), [ROADMAP.md](ROADMAP.md) (what's next), and
[SECURITY.md](SECURITY.md) (threat model). This file is scratch: decisions,
gotchas, and things that would surprise a contributor._

## Design decisions that aren't obvious from the code

- **Themes flip window appearance, not a color wash.** Each `Theme` sets `panel.appearance` (`.aqua` / `.darkAqua` / follow-system) via the `store.applyAppearance` callback wired in `AppDelegate` — same pattern as `onHide`. That's what makes native controls (text fields, lists, forms, popovers) render correctly per theme instead of all looking identical. `editorTint` is only a subtle (~0.2 opacity) layer over the material; the appearance switch does the real work.
- **One NavBar for every screen** (`NavBar(left:center:right:)` in `EditorView.swift`). `chevron.left` always means "back one level"; `xmark` only on Capture (home has nowhere to go back to). Esc mirrors the clicks — see `PanelWindow.cancelOperation`.
- **Pill mode replaced compact mode.** `store.pill` + `PanelWindow.applyPill(_:)` save/restore the expanded frame and animate the corner radius to height/2. Compact mode (and its 12pt font path and menu item) was deleted — one mode fewer.
- **The panel needs a real surface, not just a tint.** The window blends `.behindWindow`
  with a clear background, and `labelColor` resolves from the window's *appearance*, not
  from what's actually behind it. A low-opacity tint therefore can't guarantee contrast —
  over a white backdrop the material washes out while the text color stays put. `Theme.surface`
  + `PanelSurface.opacity` (~0.92, 1.0 under Reduce Transparency) paint a real background so
  text always sits on a known color. Don't reintroduce a low-opacity wash. Note System's
  surface must stay `windowBackgroundColor` (dynamic) — it has no hex of its own.
- **Chrome alignment comes from containers, not glyphs.** SF Symbols have different optical
  centers, so framing each one identically is not enough — `square.and.pencil` next to
  `xmark` reads as misaligned no matter the box. `ChromeIcon` gives every control the same
  28×28 container/weight/hover, and `ChromeGlyph` keeps the set symmetric. Adding a chrome
  button means adding a `ChromeGlyph` entry, not a bare `Image(systemName:)`.
- **Editor leading lives in the highlighter's `base` attributes.** `highlight()` calls
  `storage.setAttributes(base:range:)`, which *replaces* every attribute on the range. A
  paragraph style set only via `defaultParagraphStyle` gets wiped on the first keystroke,
  so `Coordinator.paragraphStyle` is included in `base` too.
- **Delete = Trash + Undo, deliberately no confirmation.** `delete()` trashes the file
  (already recoverable) and records the restore URL, so `undoDelete()` can put it back with
  its pin. A modal on every delete taxes the intentional case and trains click-through; the
  actual risk is an accidental ⌘⌫ (which shadows delete-to-line-start in the editor), and
  undo covers exactly that. There is deliberately **no Archive folder** — folders + "Move to"
  already do that job. The folder-delete alert stays: it touches many notes at once.
- **Sync never blocks writing.** `GitSync.sync` does a clean merge first (with `--allow-unrelated-histories`, since a repo created with a README has history unrelated to our fresh `init`), then falls back to conflict copies + `-X ours`. See `GitSync.swift` comments.
- **List rendering is a display pipeline over untouched CommonMark.** Disk keeps `- ` bullets
  and `1. 2. 3.` ordinals at every depth. The editor clears the source marker's color and tags
  it with `markerKey`; `DividerLayoutManager` draws the display marker (• ◦ ▪ / `1.` `a.` `i.`
  by depth) right-aligned to the source marker's trailing edge, so caret/content positions
  never move even though `iii.` is wider than `3.`. Hanging indents come from per-paragraph
  styles built in `applyListLayout` (cached per depth+prefix width). Ordered lists renumber in
  a deferred pass (`renumberListBlock`, pure logic in `ListLogic.renumber`) that runs from
  `didProcessEditing` — so Enter/Tab/Backspace/paste/undo all renumber without per-command code.
- **`typingAttributes` are set explicitly** (from paragraph context, in `refreshTypingAttributes`).
  NSTextView otherwise derives them from the character before the caret — right after a hidden
  `# ` marker that's `clear` + 0.1pt, which made the first typed character invisible for a frame.

## Gotchas / known issues

- **Fresh-app indexing**: until copied to `/Applications`, Spotlight/automation don't know the app exists.
- **Rebase vs merge**: `-X ours/theirs` swap meaning under rebase; sync uses plain merge deliberately to keep semantics predictable.
- **SwiftUI `TextEditor`** is too limited for highlighting → wrapped `NSTextView` (`MarkdownTextView`).
- **⌥Space** may collide with other launchers (Raycast/Alfred); it's now rebindable in Settings → Global Hotkey. The binding is swapped via Carbon `Unregister`/`Register` (see `Hotkey.apply`); the shared event handler is installed once so re-registering never double-fires. On collision (`eventHotKeyExistsErr`) the old binding is restored and the recorder shows "already in use".
- **Ad-hoc signing** with Hardened Runtime — fine locally; distribution needs Developer ID + notarization.
- **Empty folders don't sync**: folders are plain directories and git can't represent one
  without a file inside, so an empty folder exists only on the Mac that created it (and
  deleting one is likewise local-only). It reaches the remote once its first note saves.
  Accepted behavior — the alternative (`.gitkeep` placeholders) would put sidecar files
  in the notes repo.
- **`unzip` silently breaks a signed bundle.** It drops the extended attributes the signature seals over, so a perfectly good release then fails `codesign --verify` with "a sealed resource is missing or invalid" — a message that reads like tampering. `Updater` expands with `/usr/bin/ditto -x -k`, which preserves them. Same trap applies to any by-hand check of a release zip: extract with `ditto` or you'll be debugging a signature that was never broken.
- **`GET /releases/latest` 404s for this repo.** Every GitPad release so far is marked *pre-release*, and that endpoint only ever returns a full release. `Updater` lists `?per_page=5` and takes the first non-draft entry, which works either way. Tags are v-prefixed (`v0.9.3`), assets are not (`GitPad-0.9.3.zip`) — the updater strips the `v` before matching.
- **Replacing the running app** uses move-aside (rename the live bundle out of the way, move the new one in), not `replaceItemAt`. Renaming a running bundle is safe — the executable keeps running from the renamed inode — and both renames are same-volume, hence atomic. `Hotkey.stop()` must run before the replacement launches, or the new instance can't register ⌥Space while this one still holds it.
- **A cask install is a symlink.** `Caskroom/gitpad/<ver>/GitPad.app` points at `/Applications/GitPad.app`; the only real thing brew holds is a receipt with the version. Swapping the bundle ourselves would leave that receipt lying, so `Updater.install` shells out to `brew upgrade --cask gitpad` on a cask install (and relaunches after). `GITPAD_ALLOW_DEV_UPDATE=1` bypasses that so the swap path can be tested on the dev machine, which necessarily has the cask.
- **The staged-update directory is user-writable**, so `Updater.verifiedStagedApp()` re-runs the *full* signature chain at the moment of use rather than trusting the check done at download time.
- **The vault mounts *at* `~/Documents/GitPad`**, so `NoteStore.dir` never changes and nothing above it knows about encryption. Locked = the mountpoint is an empty dir at mode 500, so every `try?` write in NoteStore fails instead of leaking plaintext there; `Vault.unlock` chmods it back to 700 before attaching. `NoteStore.init` starts in `locked` and `open()` (the old init body) runs after the mount.
- **`hdiutil -stdinpass` takes the passphrase byte-for-byte** — a trailing newline becomes part of it. `GitSync.exec(stdin:)` writes exactly the string; `test_vault.sh` asserts the `\n`-suffixed variant is rejected. Never pass `-passphrase`: argv is visible to `ps`.
- **Detach is retried, never `-force`d.** Spotlight/Finder let go within a second; a git child would not survive a force. Every vault op runs on `syncQueue` (serial with sync), so no GitPad git process can be mid-write, and `applicationShouldTerminate` does `syncQueue.sync { Vault.lock() }` to wait for the flush-triggered push before detaching.
- **Keychain reads stay off main.** An item the app created itself reads instantly; one created by the `security` tool took 3–8 s of securityd ACL evaluation before it worked at all (and then only by luck — see the next item), and the Touch ID path waits on a human. Every Keychain/Enclave read or write runs on `syncQueue`, never on main — on main it froze the panel and hotkey at launch until the vault mounted. hdiutil attach itself is 0.5 s.
- **A Keychain item made by `security add-generic-password` prompts the app forever**, even with `-A` — partition lists since 10.12 — and the read just hangs on `SecurityAgent` until a human clicks. Sampled it twice before believing it. `test_vault_app.sh` therefore seeds the item *through the app* (`GITPAD_VAULT_PASS`, honored only with `GITPAD_VAULT`), which puts this binary in the ACL.
- **Touch ID uses a CryptoKit Secure Enclave key, not the data-protection keychain.** `kSecUseDataProtectionKeychain` returns `errSecMissingEntitlement` from an ad-hoc build, and a Developer-ID build carrying `com.apple.application-identifier` + `keychain-access-groups` without a provisioning profile is killed at launch (exit 137). `SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: .userPresence)` needs no entitlement and works in every build; its `dataRepresentation` is safe in a plain file because it's bound to this Mac's Enclave. Hand-rolled ECIES (ephemeral P256 + HKDF + AES-GCM) because the Enclave key only does key agreement.
- **Ad-hoc dev builds change signature every rebuild**, so macOS may prompt "GitPad wants to use your confidential information in the Keychain" for the vault passphrase. Signed releases don't. `GITPAD_DIR` disables the vault entirely — a dev build must never attach the real bundle onto a scratch dir.

## Release

`./release.sh` does the whole thing on the signing Mac and ends by calling `./publish.sh`,
which creates the GitHub release (notes = the CHANGELOG section for the version plus a
"Verify your download" checksum block), bumps `Casks/gitpad.rb` in `stalinzbb/homebrew-tap`,
and checks GitHub's zip digest against the local file — the in-app updater refuses a zip
without one. Every step skips itself when already done, so a failed publish is re-run with
`./publish.sh` alone. `DRY_RUN=1 ./publish.sh` prints the mutating commands instead.
The prep PR (version bump + dated CHANGELOG section) must be merged first: `publish.sh`
refuses without a `## [x.y.z]` section, and `release.sh` reads the version from Info.plist.
Both scripts refuse a dirty tree or a HEAD that isn't `origin/main`, and the release is
tagged at the built commit (`--target`), so a tag always describes the bytes in the zip.
Releases are full releases, not pre-releases: `/releases/latest` (the README link, the
"Latest" badge) skips pre-releases — that's how 0.14.0 and 0.15.0 shipped while the README
kept serving 0.13.0. `publish.sh` also runs the built bundle's `--selftest` before publishing.
Rollback: `gh release delete vX.Y.Z --yes --cleanup-tag`, then bump the cask back by hand
(version + sha256 of the previous zip); the in-app updater never downgrades on its own.

## Verify

- `swift build -c release && ./test_gitsync.sh` — the test drives the real binary through a bare remote: same-line conflict resolution and README/unrelated-histories scenarios.
- `./test_vault.sh` — encrypted sparse bundle: stdin passphrase is byte-exact, `--sync` works inside the mounted volume, the detached mountpoint is empty/unwritable, the bundle holds no plaintext.
- `./test_vault_app.sh` — launches the real binary with `GITPAD_DIR` + `GITPAD_VAULT` (scratch dir, scratch bundle, a `-A` test Keychain item): Keychain auto-unlock mounts and opens the notes, a real Quit event detaches, a launch with no passphrase stays locked and writes nothing. Pops the panel for a few seconds; the installed app is untouched. Still manual: the Settings/onboarding encrypt + decrypt + erase flows, and screen-lock/sleep auto-lock.
- `./build.sh` → `GitPad.app`, then copy to `/Applications` and relaunch.
