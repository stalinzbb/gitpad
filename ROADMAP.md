# Roadmap

**The goal:** GitPad should be productive, fast, accessible, scalable, usable, and
powerful — but never complicated. There is one obvious way to do everything, and
nothing that needs explaining. Every item below earns its place against that bar
or it doesn't ship.

## Now — quality

- [x] **Theming v2** — appearance-driven themes (each flips the whole window light/dark so every control adapts), live swatch picker.
- [x] **Navigation v2** — one NavBar on every screen; chevron.left always means back, xmark only on Capture, Esc mirrors the clicks.
- [ ] Conflict-resolution UX polish (inline diff when comparing copies).
- [x] **Keyboard-shortcut customization** — the global hotkey is rebindable in Settings (Settings → Global Hotkey → record a combo), so ⌥Space collisions with Raycast/Alfred are fixable.

## Next — power, still lazy

- [ ] Full-text search hotkey.
- [x] **`[[note linking]]` + backlinks** — `[[` completion card, click opens or creates, "N linked" menu in the status line.
- [ ] Note templates.
- [x] **`gitpad://` URL scheme** — `new?text=`, `daily`, `daily?append=`. Unlocks Raycast/Alfred/Shortcuts/scripts.
- [x] **Clipboard quick-capture** — "Append Clipboard to Daily" in the status menu (and `gitpad://daily?append=`).
- [x] **Pinned notes** — Pin/Unpin in a note's ⋯ menu; a "Pinned" group leads the library.

## Later — reach

- [x] **Encrypted vault** — notes folder inside an AES-256 sparse bundle mounted at the same
      path, locks with the screen (Settings → General, or onboarding). Repo-level age/git-crypt
      stays out: the vault protects the disk, the remote is your choice.
- [x] **iOS companion** (`Mobile/`) — read, toggle, edit, append-to-Daily over the GitHub
      API; GitHub remotes only in v1 (no git on iOS, and a git library would break the
      dependency rule). GitLab has the same API shape if asked.
- [ ] CLI companion (`gitpad new "…"`).
- [ ] Spotlight importer.
- [ ] Launch at login.
- [x] **Built-in updates** — daily check, one-click install, and an optional
      auto-update that stages in the background and installs on quit. No Sparkle: a
      dependency-free updater is ~300 lines against GitHub Releases, and the zero
      third-party dependency rule is worth more than the saved effort.
- [ ] Homebrew cask.
- [ ] Localization.

## Non-goals

Databases. Electron. Subscriptions. If a feature needs any of these, it's not GitPad.

- **Accounts** — the app never requires one. The optional "email me on new releases"
  field (see [GROWTH.md](GROWTH.md) §4) is a mailing-list subscription, not an account:
  no password, no profile, no login, nothing the app depends on. Skip it and nothing changes.
- **Servers** — you never run one and never sign into one. Sync is a git remote *you*
  choose. The only server the app might ever touch is the opt-in analytics endpoint below.
- **Non-consensual telemetry** — nothing is sent without an explicit yes. An opt-in,
  off-by-default, fully inspectable anonymous ping *may* exist (see [GROWTH.md](GROWTH.md)
  §3): ~4 events, no note content, no filenames, a random regenerable install id, and a
  "See exactly what's sent" button showing the literal payload before you enable it. Off
  by default means off — declining is the default and changes nothing.
