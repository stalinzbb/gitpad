# Changelog

All notable changes to GitPad. Dates are release dates; format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- **Open at login.** Settings → Advanced → Startup. GitPad starts with your Mac in the menu
  bar without opening its window; it appears in System Settings › Login Items like any
  other login item and can be turned off from either place.
- **Note links.** Type `[[` and pick a note — the card that serves slash commands lists your
  titles, narrowing as you type. `[[Title]]` renders as a link; clicking it opens that note,
  or creates it if there's none. The status line shows "N linked" on any note that others
  link to, with a menu to jump back. Plain Markdown on disk, as always.
- **`gitpad://note?title=…`** opens a note by title — it's what a `[[link]]` click uses, and
  scripts can use it too.

### Fixed

- **The selection bar and slash menu really close when the panel collapses to the pill.**
  The previous fix watched the editor's width, but collapsing removes the editor from the
  window entirely, so it never fired; they now close when the editor leaves the window or
  the window resizes.

## [0.15.0] — 2026-09-11

A new icon, links that open, placeholders that say what goes where, and a day of editor
polish: code as tokens, markers the caret can't get stuck in, and nothing pasted or
slashed into a second checkbox.

### Changed

- **Inline code is a rounded token** with a hairline edge instead of a square wash.
- **Bold, italic, strike and code work across several lines**: each line gets the mark
  after its list marker or heading; tapping again on an all-marked selection removes them.
- **The editor's breadcrumb names the note.** "Today" is reserved for daily notes (by the
  file's date); every other note shows its title.
- **Dev builds show the DEV tag in the editor's status line** too, next to ⌘K.

- **Slash commands answer to other names.** "/checkbox", "/checklist" or "/task" find
  To-do; "/h1" finds Title; "/bullets", "/numbered", "/hr" and friends work too.
- **Dev builds get their own glyph.** A hollow ring in the menu-bar icon's corner, on top
  of the "dev" label.

### Fixed

- **Pasting a copied list item or heading mid-line puts it on its own line** instead of
  splicing a second checkbox into the current one. A ☐ that does end up mid-line shows as
  a plain glyph, never as a box.
- **Inline code no longer shows its backticks**, which read as stray quotes; the chip
  hugs the code itself. A code span that wraps gets one chip per line rather than a block
  covering both lines edge to edge.
- **Links open on click.** A plain click on link text opens it; the caret goes into a
  link with the arrow keys.
- **No more double checkboxes.** A slash block command typed in front of an existing
  marker replaces that marker.
- **The selection bar drops below the selection** when placing it above would cover the
  title or the header.
- **Selecting a blank line no longer paints a bar to the right edge**; the highlight
  stops a few points past the text, as in Notes.
- **The caret can't rest inside a checkbox or heading marker** any more, where it sat on
  top of the drawn box. It lands on the text instead; one Left from there goes to the
  previous line's end.
- **The selection bar and slash menu close when the panel collapses to the pill** or is
  resized, instead of floating loose next to it.

- **New icon.** A new app icon, and a matching menu-bar glyph drawn from an SVG as a
  template image, so it stays crisp and adapts to light and dark menu bars. The sync-problem
  state badges it with a notched dot instead of switching to a different symbol.
- **Placeholders.** An empty note shows "Untitled" in title weight where the title will
  land and "Start typing. / for commands." where the body will; each disappears the moment
  that part has text. Drawn over the editor, never inserted into the note.
- **Links work.** `[text](url)` renders as a link — accent, underlined, click opens it —
  with the brackets and target receding. The selection bar's Link button fills the target
  from a URL on the clipboard, or leaves the placeholder selected so typing or ⌘V replaces it.
- **Inline code is a chip.** Backticked text sits on a tinted monospace chip instead of
  only changing colour; the backticks stay editable but fade.
- **Slash commands replace the marker you're in.** "☐ /title" turns the to-do into a title
  and "- /numbered" converts the bullet, instead of nesting one marker inside another.
- **The selection bar reads as enabled.** Its glyphs and paragraph menu are primary
  colour, not the grey that looked disabled.

## [0.14.0] — 2026-09-11

A sync can no longer overwrite the note you have open; Homebrew installs update from the
button; and the vault, the folder and the remote each got one more guard.

### Changed

- **Vault: lock when idle.** Settings → Encrypted vault → "Lock when idle" (5 min to 1 h,
  off by default) detaches the vault when nobody has touched the Mac for that long, on top
  of the existing sleep and screen-lock triggers. Opening GitPad again unlocks the same
  way a screen unlock does: silently from the Keychain, or with a Touch ID prompt.
- **Dev builds say so.** A locally built or ad-hoc-signed copy shows "dev" beside the
  menu-bar glyph, a DEV tag in the panel header, and "dev build" on the Settings version
  row, so it can't be mistaken for the installed release.
- **Notes edited elsewhere show up immediately.** GitPad now watches the notes folder,
  so a note written by another app, a script or a sync merge appears in the library
  within a second instead of at the next timer tick or panel open.
- **Name this Mac.** Settings → Sync → "This Mac" sets the commit author and the
  "conflict from …" label instead of always using the Mac's own name.
- **The gh shortcut says what it grants.** Onboarding's one-click repo and Fix Sync's
  "Switch to HTTPS" both note that the gh login token reaches every repo on the account,
  with SSH as the narrower option.
- **Nothing writes while the vault is locked.** ⌘N, ⌥Space, Undo Delete and the status
  menu's Recent list are no-ops until unlock instead of creating phantom notes.
- **Only Markdown reaches the remote.** Sync now ignores everything except `.md` files and
  folders via a per-clone exclude (no `.gitignore` in your notes folder). A screenshot, a
  `.DS_Store` or an `.env` dropped into the folder by mistake stays local instead of being
  committed and pushed on the next tick.
- **Conflicts show what differs.** The Conflicts screen highlights the lines that exist
  on only one side, so "Keep Mine / Use Theirs" is a glance, not a read-through.

### Fixed

- **A sync can no longer erase the other Mac's edit to the note you have open.** When a
  merge rewrote the open note on disk, the editor kept its stale copy and the next
  keystroke saved it over the merged file — silently, with no conflict copy. Now a clean
  buffer reloads from disk after sync, and a buffer with typing in flight keeps the
  on-disk version as a "(conflict from another device …)" copy instead of overwriting it.
- **Update on a Homebrew install actually updates.** The button used to stop at a
  "run brew upgrade" note; it now runs `brew upgrade --cask gitpad` itself, then
  restarts into the new version like a direct-download install does.

## [0.13.0] — 2026-09-09

The editor says where you are and whether you're saved; settings and first run stop
asking for setup before you've written a word.

### Changed

- **The editor has its own header.** A breadcrumb saying which note and folder you're
  in, New and Search, and one ··· menu — instead of a header that repeated the note's
  first line and held buttons the keyboard already covers.
- **Status line instead of a word count:** "Saved · Synced 2m ago · 1 to push". The
  stale-sync warning folds into its orange state rather than adding a second strip.
- **Selection bar** shows five inline marks and a paragraph-type menu with the active
  marks lit, so bold-on-bold no longer looks the same as bold-on-plain. It opens on
  mouse-up rather than after a delay, and stays put while the selection lives.
- **First run is two steps, not four.** Step 1 shows the bound hotkey as keycaps over a
  live editor (it's today's note — what you type stays); step 2 is the sync guide with a
  clear "Not now". The vault moved to Settings → Advanced behind one row; the Touch ID
  toggle lives there too.
- **Settings regrouped by decision:** Writing (font, size, theme) · Sync · Shortcuts ·
  Advanced (updates, vault, quit, erase — destructive, last).
- **Sync tab tells the record, not a verdict:** a problem card with one primary fix,
  the repo as a value with "Change…", this Mac's name, and the last five sync runs
  ("Pushed 2 · pulled 1 from the iMac, Tue 18:02").
- **Themed text selection** and a more visible unchecked box; a checked item's text now
  recedes.

### Fixed

- **The slash menu accepts typing.** It ran its own event loop, so any keystroke
  dismissed it and "/da⏎" for Date could never work. It's now a filtering card, and the
  "/" and your query stay in the document as ordinary text.

## [0.12.0] — 2026-09-04

The vault can now demand your fingerprint.

### Features

- **Require Touch ID to unlock the vault** (opt-in, Settings → General → Encrypted
  vault). The passphrase is sealed to a Secure Enclave key that only releases after
  Touch ID — or your account password on a Mac without it — so nothing running as
  you, root included, can read it otherwise. Turning it off prompts once as proof of
  presence; turning it on needs no typing. Expect a prompt at launch and after every
  screen unlock; the lock screen gains an "Unlock with Touch ID" button with the
  passphrase as fallback.

## [0.11.0] — 2026-09-04

Notes can now be unreadable on disk whenever you're not at the keyboard — for the
work laptop you don't fully trust.

### Features

- **Encrypted vault (opt-in).** Settings → General → *Encrypt notes…* moves your
  notes folder into an AES-256 disk image that macOS mounts at the same path,
  `~/Documents/GitPad`. Inside, notes are still plain Markdown and git sync is
  unchanged. The vault detaches whenever the screen locks, the Mac sleeps, or
  GitPad quits: while locked, the folder is empty and unwritable and only
  ciphertext exists on disk. The passphrase lives in your login Keychain so
  unlocking is silent; if it's missing, GitPad shows a lock screen and asks.
  Native `hdiutil` and Security.framework — no dependencies, no new file format.
  Existing notes are moved in and the plain copies deleted; *Decrypt notes…*
  reverses it. (#50)
- **Onboarding can encrypt from the first note.** An optional last page sets a
  passphrase so a fresh install on a work machine never writes plaintext. (#50)
- **Erase GitPad from this Mac.** Dragging an app to the Trash can't run code, so
  it never deleted your notes. The new Settings button does: it syncs first and
  refuses to continue if that push fails, then removes the notes folder, the
  vault, its Keychain entry and settings, and moves the app to the Trash. (#50)

### Security

- SECURITY.md states the vault's ceilings plainly: while unlocked, anything running
  as you can read the notes; notes that were plain before you enabled the vault
  may survive in APFS snapshots or backups; the Keychain item is exactly as safe as
  your login password; there is no recovery beyond your git remote. The passphrase
  reaches `hdiutil` over stdin, never on the command line.

### Under the hood

- Keychain reads run off the main thread — `SecItemCopyMatching` blocks for
  several seconds while securityd validates the caller, which froze the panel at
  launch during testing.
- `test_vault.sh` (disk-image mechanics, ciphertext-only on disk) and
  `test_vault_app.sh` (the real binary: Keychain auto-unlock, detach on quit,
  a locked launch writes nothing) join `test_gitsync.sh`.

## [0.10.0] — 2026-08-01

GitPad can update itself now — and every theme finally reaches every control.

### Features

- **Check for updates.** GitPad now notices when a newer version is published: a
  "Update to X.Y.Z…" item appears at the top of the menu-bar menu, and Settings →
  General → Updates shows the running version, a manual Check button, and an
  opt-out. The check is an unauthenticated `GET` of the public releases list about
  once a day, sends nothing about you, and can be turned off entirely. (#40)
- **One-click update.** "Update" downloads the release, verifies it, swaps the app
  in place and relaunches — no Sparkle, no helper process, no shell. It refuses
  before downloading anything on a Homebrew install (brew keeps the job) or a dev
  build, and refuses after downloading unless the bytes match GitHub's published
  SHA-256 *and* the bundle is Developer-ID-signed by us *and* Apple notarized it.
  Any failure leaves the running app untouched. (#45)
- **Optional auto-update**, off by default. With it on, a new release is downloaded
  and verified in the background and installed when you next quit — or immediately
  with "Restart to Update". Nothing ever pops up over the editor, and nothing
  installs while you're writing. The staged bundle is verified again at the instant
  it's installed, not just when it was downloaded, and is discarded rather than
  installed if anything about it stopped adding up.

### Design

- **Themes now reach every control.** Selected rows — the source rail, folder
  rows, the ⌘K palette — and the setup step badge were drawn with the *system*
  accent, which `.tint()` never touches, so Nord, Dracula and Sepia showed
  system-blue selection on an otherwise fully themed panel. They follow the
  theme now. (PR #47)
- **Text fields stop fighting the theme.** The rounded-border style is a system
  control that answers to the window's appearance, not the theme: a white well
  on Sepia, near-black on Nord. Settings, the setup guide and onboarding now use
  one field style built on the panel's own surface, with a theme-accent focus
  ring. (PR #47)
- **Theme swatches are uniform.** They sat in a slot that compressed on a narrow
  panel and clipped them into different shapes; they're a fixed-size row now,
  and the current theme is named below them.
- **Sync settings, reordered.** One thing per row: Repository (the URL, what it
  accepts, and a Save that's live only when there's something to save), then
  Status — which now says "2 to push · 1 to pull" instead of `↑2 ↓1`.
- **Settings → Shortcuts is now Hotkeys**, and the global hotkey is labelled for
  what it does: "Summon GitPad".
- Under it: one design-token file (`DesignSystem.swift`) that the SwiftUI chrome
  and the AppKit editor/panel both read, so radii, spacing, opacities and the
  pill's motion curve can no longer drift apart between the two.

### Changed

- **The editor's bottom bar keeps the word count and Pin.** Move-to-folder and
  delete are gone from it — those are filing, not writing, and a destructive
  control one slip from the text is the wrong trade. Both are still on every
  Library row's ⋯ menu, on ⌘⌫, and in the ⌘K palette. (Reverses part of #20.)

### Bug fixes

- **Quitting mid-typing no longer drops the last second.** Quit inside the 1s
  autosave debounce and that text used to be lost; every quit path now flushes
  first. Found while making the updater's relaunch safe.

## [0.9.3] — 2026-07-31

Undo you can trust, a selection bar that actually toggles, and ⌘K everywhere.

### Features

- **Command palette.** ⌘K from any screen: fuzzy-matched actions and note jumping,
  plus Settings sub-sections, a shortcuts list, and leaner scrollbars. (#36)
- **Bottom bar on the editor** — live word count on the left; pin, move-to-folder,
  and delete on the right, so acting on the note you're writing no longer means a
  trip to the Library. Delete routes through the same path as ⌘⌫, so the undo
  banner still catches it. (#20, PR #33)
- **Selection bar v2.** Bold/italic are real toggles (no more `****text****`),
  plus H1/H2 headings, bullet/numbered/to-do lists that convert across families,
  and link insertion that picks a URL up off the clipboard. The bar finally reads
  the theme accent instead of OS blue. (#24, PR #32)

### Bug fixes

- **Undo actually undoes.** Four defects: the deferred list-renumber re-registered
  during ⌘Z (undo ping-ponged and wiped redo), no-op Shift-Tab pushed an empty
  undo group that swallowed a ⌘Z, wholesale text replacement left the undo stack
  pointing at dead ranges, and ⌥Space could silently revert text typed within the
  autosave debounce. Switching notes mid-debounce can no longer drop the outgoing
  note's text. Known limit: a list edit is still two undo groups, so ⌘Z after
  Enter-mid-list takes two presses — each makes progress. (#26, PR #31)
- **Pill survives display changes.** The panel now watches screen-parameter
  changes and clamps the pill (and expanded frame) back onto a live screen, so
  unplugging a monitor no longer strands or mangles it. (#21, PR #30)
- **Selecting a list line no longer reveals the markdown backing text** (`2.`,
  `-`) behind the display markers — selection now recolors only the background,
  not the glyphs. (#22, PR #29)

### Project

- `GITPAD_DIR` env var points a dev build at a throwaway notes folder, so
  verifying anything near autosave/sync doesn't touch real notes or the real
  remote. Documented in `CLAUDE.md`. UserDefaults (hotkey, theme, pins) are
  still shared. (PR #28)
- Release artifacts (`*.dmg`, `*.zip`) gitignored. (#27)

## [0.9.2] — 2026-07-25 · first public beta

The writing experience, rebuilt — plus fuzzy search and the open-source beta itself.
(Ships everything listed under 0.9 and 0.9.1 below.)

### Editor overhaul

- **Hanging indents.** Wrapped list lines align under the item's text, and every
  nest level gets a real visual indent instead of a ~7pt two-space shuffle.
- **Display markers.** Bullets render • → ◦ → ▪ and ordered lists 1. → a. → i. by
  depth — drawn over the markdown source, which stays plain `-` / `1. 2. 3.` on disk.
- **Auto-renumbering.** Insert, delete, indent, paste, or undo inside a numbered
  list and the ordinals fix themselves.
- **Tab/Shift-Tab that behave**: caret and multi-line selections survive
  indent/outdent, and Tab outside a list inserts spaces (never a code-block tab).
- **Checkboxes redrawn.** ☐/☑ are pinned to a fixed layout advance (their fallback
  fonts — emoji for ☑ — used to shift text and line height on every toggle), sized
  to the body font with breathing room, and only the box itself toggles on click.
- **Smart Backspace** removes a whole list or heading marker in one stroke.
- **Enter** on an empty nested item outdents one level before exiting the list.
- **Headings** get air above them; the `#` marker hides without the line jumping;
  fresh notes open focused with a visible full-height caret in the title.
- The selection toolbar stays inside the panel (it used to float above the window
  for text near the top). Fixed a crash when it fired after the panel closed.

### Features & fixes

- **Fuzzy search** folds case and diacritics — "cafe" finds "Café".
- Daily-note titles normalized (older daily notes backfilled).
- Denser Library sidebar; pill gets a one-click expand glyph.
- **⌘Q quits from any screen**, plus a quit button in Settings.
- Checkbox variants from other editors (`* [X]`, `+ [ ]`) are recognized.

### Project

- Open-source beta: public repo, CI (build + full sync test suite) on every PR,
  notarized releases via `release.sh` with a published SHA-256.
- New `--uitest` harness drives the real editor headless (Tab/Enter/Backspace/
  renumber/toggle) with layout assertions, wired into `test_gitsync.sh`.

## [0.9.1] — unreleased

Cross-device sync, an icon that behaves, and setup that explains itself.

- **App icon.** A real Dock/Finder icon (`make-icon.swift` → `make-icns.sh`, regenerated
  by `build.sh`). The menu-bar glyph is now an explicit **template** image, so it adapts
  to light/dark menu bars and Increase Contrast; a sync failure switches it to a badged
  symbol instead of signalling with color alone.
- **True-conflict detection.** Conflict copies are written only for genuinely unmerged
  files (`--diff-filter=U`), not for every file that differed.
- **Device names.** Each Mac commits under its own name, and copies are named
  `<note> (conflict from <device> <date>).md`. Old-format copies still work.
- **New-device adoption.** A Mac whose notes are all still generated boilerplate adopts
  an existing remote instead of manufacturing conflict copies of your real notes. One
  typed character disables it.
- **Conflict screen.** An orange ⚠ in the header of every screen opens a dedicated
  review screen: both versions side by side, *Keep Mine* / *Use Theirs* / *Keep Both*.
  Shown once automatically the first time a conflict appears.
- **Sync doctor.** When sync fails, Settings names the cause — rejected SSH key (naming
  the key ssh actually offered), changed host key, missing repo, HTTPS login, no network
  — and offers the fix, including a one-click switch to HTTPS via the `gh` CLI.
- **Modify/delete no longer wedges the repo**; a note edited on one Mac and deleted on
  the other survives.
- **Push retry.** A push that loses a race is retried once instead of being reported as
  "offline".
- **Fetch on show.** Opening the panel syncs (debounced to 30s), so what you see is fresh.
- The menu bar's "Set Remote…" NSAlert is gone — it's now "Set Up Sync…", routing to the
  real setup screen. Onboarding's Test button reports the same friendly errors as
  everything else.
- Docs: `SYNCING.md` added; SECURITY.md documents the `StrictHostKeyChecking=accept-new`
  tradeoff. `test_gitsync.sh` grows to 8 scenarios.
- **Fixed: "Quit GitPad" was greyed out.** The status menu auto-enables its items, and
  every item's target was being set to the AppDelegate — which doesn't implement
  `terminate:`, so AppKit disabled it. Quit now targets `NSApp`. (The only way to quit
  was Activity Monitor or `pkill`.)

## [0.9] — unreleased

- Menu-driven shortcuts: ⌘N / ⌘L / ⌘S / ⌘⌫ / ⌘M / ⌘, now work from **every** screen
  (Library, Settings, onboarding), not just the capture editor. Replaces the old
  zero-opacity SwiftUI button hack with a real (hidden) main-menu "Note" submenu.
- Event-driven sync status — Settings updates the moment a sync finishes instead of
  guessing with a fixed 2-second delay; "Sync Now" shows a live "Syncing…" state.
- Faster search — file bodies are cached (mtime-validated, like titles) so typing in
  the Library no longer re-reads every note on each keystroke.
- Library: Esc clears an active search before leaving the screen.
- Docs: `CHANGELOG.md`, `CLAUDE.md`, and `GROWTH.md` added; README architecture,
  shortcuts, and screenshots sections refreshed.

### Readability, chrome & delete UX

- **Fixed: the panel was unreadable over light backgrounds.** It blended
  `.behindWindow` with only a 0.20-opacity tint — and *no* tint at all on the System
  theme — so text effectively rendered against the desktop while its color was picked
  from the window's appearance. Every theme now paints a real surface (~0.92 opaque,
  System follows the OS window color), so contrast holds over white, dark, or video.
  macOS **Reduce Transparency** makes it fully opaque.
- **One chrome icon system.** All nav controls are now a single `ChromeIcon` — identical
  28×28 container, one glyph size/weight, consistent hover background — so alignment
  comes from geometry instead of each SF Symbol's optical center. The two heavy glyphs
  were swapped for symmetric ones: new-note `square.and.pencil` → `plus`, and the busy
  four-arrow minimize → `minus`.
- **Roomier editor** — text inset 12×8 → 20×14, plus real leading (1.25 line height,
  6pt paragraph spacing). The style rides in the highlighter's base attributes, so it
  survives syntax highlighting instead of resetting as you type.
- Info-bearing metadata (dates, folders, group headers, sync counts) moved from tertiary
  to secondary — tertiary is the first thing to fail contrast over a translucent surface.
- **Undo delete.** Deleting a note shows a self-dismissing "Note deleted — Undo" banner,
  and there's an Undo Delete item in the Note menu. Restores the file and its pin. No
  confirmation dialog: delete already goes to the Trash, so undo beats taxing every
  intentional delete. The folder-delete confirmation stays — that one is destructive.

### Bug fixes (testing pass)

- Library now has a **New Note** button (next to Back); it creates the note where
  you're browsing — a folder → that folder, Daily → today's note, Recent/Inbox → Inbox.
- `newNote(in:)` is folder-aware; ⌘N still creates in Inbox, and the empty-scratch reuse
  is scoped to the same folder so a new note in folder B doesn't reuse an empty note in A.
- Folder ⋯ menu is now **vertical (⋮)** and uses the secondary chrome color instead of
  rendering accent-blue; sized to a nav-icon hit box so it lines up.
- Daily-note title carries the **full date incl. year** ("Friday, 18 July 2026").
- More breathing room between the Library chrome bar and the search field.
- Nav-bar glyphs use a square box + fixed weight so the left (library/new) and right
  (settings/minimize/close) icon clusters align exactly.
- Pill collapse/expand is **snappier** — ~0.2s strong ease-out instead of the mushy
  built-in ease-in-out (still instant under Reduce Motion). Also reachable via ⌘M and
  a double-click on the title bar.
- Themes refactored to hex-preset rows (base + 3 colors) so adding one is a one-liner;
  no behavior change to the five shipping themes.

## [0.8] — 2026-07-18

- Appearance-driven themes (each flips the whole window light/dark so every native
  control adapts), unified NavBar on every screen, pill mode, sync fixes, OSS docs.
- Follow-ups: fixed pill expand, persistent chrome + 2-column library, hardened git
  setup; folder edit/delete, pill tap+drag, drawn checkboxes, fixed daily title, Inbox;
  double-tap title bar to pill, full-width search, sync dot beside title, folder ⋯ menu.

## [0.7] — 2026-07-18

- Edit-menu shortcuts, header type scale, titled new notes, daily-note prefix,
  scalable folder picker.

## [0.6] — 2026-07-17

- Caret-anchored selection toolbar, themes, nav hierarchy, git-setup guide, ⌘S.

## [0.5] — 2026-07-17

- Sync settings with status/conflict tooling, inline folder creation.

## [0.4] — 2026-07-17

- Borderless refined panel, real header hiding, divider fix, font library,
  grouped settings.

## [0.3] — 2026-07-17

- Liquid glass, portrait panel, folders, rendered checkboxes, settings, polish.

## [0.2] — 2026-07-17

- Minimal UI overhaul — daily-note capture, library view, onboarding, smart editor.

## [0.1] — 2026-07-17

- First release: menu-bar markdown notes with git sync.
