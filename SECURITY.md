# Security

## Threat model & posture

GitPad is a local-first app with no backend of its own. Its security story is
mostly about what it *doesn't* do.

- **Local plain files.** Notes are Markdown files in `~/Documents/GitPad/`. There is no proprietary store and no hidden state.
- **No telemetry.** No analytics, no crash reporting. The only network calls are the git remote *you* configure and a release check: about once a day GitPad fetches `https://api.github.com/repos/stalinzbb/GitPad/releases` to see whether a newer version exists. It is an ordinary unauthenticated `GET` — no identifiers, no note data, nothing about you beyond what any HTTP request unavoidably reveals to the server. Turn it off in Settings → General → Updates and the app never contacts github.com on its own. The one other call is one you start: **Sign in with GitHub** talks to `github.com/login/device` and, once, `api.github.com` (to find or create your `gitpad-notes` repo). The token it receives is piped into `git credential approve` on stdin — it lands in the macOS Keychain through git's own helper, never in argv, a file or GitPad's preferences. A GitHub App token reaches only the repos you add GitPad to, which is narrower than the gh shortcut below.
- **Auth is delegated to the system.** Sync uses your existing SSH setup (`~/.ssh`). GitPad never sees, prompts for, or stores credentials. `GIT_TERMINAL_PROMPT=0` ensures it fails fast rather than hanging on an auth prompt — it can't silently capture one.
- **The gh shortcut is wider than GitPad needs.** Onboarding's "Create a private repo for me" and Fix Sync's "Switch to HTTPS" run `gh auth setup-git`, which lets git push with your gh login's token — typically `repo` scope across every repository on the account, not just the notes repo. Both buttons say so; an SSH URL with a per-repo deploy key is the narrowest option.
- **Commit author is the Mac's name by default** ("Stalin's MacBook Pro"), so it is visible to anyone who can read the remote. Settings → Sync → "This Mac" replaces it.
- **SSH host keys: trust on first use.** Git runs with `GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"`, and only when you haven't set `GIT_SSH_COMMAND` yourself. A host you've never contacted is accepted unverified — the tradeoff that keeps sync from silently wedging on a fresh Mac — but a *changed* key on an already-known host still hard-fails, which is the case that actually signals an attack. GitPad surfaces that as "the server's SSH key changed — verify it before trusting".
- **Only Markdown is ever committed.** Every sync writes a per-clone git exclude (`.git/info/exclude`, never a file in your notes folder) that ignores everything except `*.md` and folders. A screenshot, a `.DS_Store` or an `.env` that lands in `~/Documents/GitPad` by mistake stays on your Mac and never reaches the remote. Files a repo already tracked before GitPad met it are left alone.
- **No arbitrary shell.** Every git call runs `/usr/bin/git` (and the optional `gh`) via `Process` with a **fixed argument array**. No user input — note titles, remote URLs — is ever interpolated into a shell string, so there is no command-injection surface. See the `exec` invariant comment in `GitSync.swift`.
- **No raw error leakage.** Subprocess stderr is never rendered verbatim in the UI; git failures are mapped to friendly messages (`GitSync.friendlyError`).
- **Release hardening.** `build.sh` codesigns with the Hardened Runtime (`--options runtime`). Signed distribution builds should additionally be notarized with a Developer ID.
- **Updates verify before they install, and fail closed.** "Update" downloads the release zip and refuses it unless *every* check passes, in order: the bytes match the SHA-256 digest GitHub publishes for that asset; the expanded bundle satisfies a codesign requirement pinning Apple's chain, a Developer ID leaf, team `7X256UY552` and bundle id `com.stalinzbb.gitpad`; `spctl --assess` confirms Apple notarized it; and the bundle really is GitPad. A missing digest is a refusal, not a warning. Nothing on disk is touched until all of that passes, so a failed or tampered download leaves the running app exactly as it was. The requirement deliberately says nothing about the version — it checks *who signed this*, not what it claims to be.
- **Expansion uses `ditto`, never `unzip`.** `unzip` drops the extended attributes the signature seals over, which silently turns a genuine release into "a sealed resource is missing or invalid". Using it would make verification fail for the wrong reason.
- **A Homebrew install is updated by Homebrew.** If the cask is present, GitPad never replaces the bundle itself — brew's receipt would then describe a version that isn't there. "Update" instead runs `brew upgrade --cask gitpad` (a fixed argument array, like every subprocess here) and relaunches only after the version on disk has actually changed. Background staging is off for cask installs, since brew has no stage-now-install-at-quit equivalent.
- **Staged updates are re-verified at the moment they're installed.** With auto-update on, the release is downloaded and verified in the background into `~/Library/Application Support/GitPad/Update/`, then installed when you quit. That directory is writable by anything running as you, so the signature chain is run *again* against the staged bundle immediately before it replaces the app — an earlier pass is not treated as still true. A stage that no longer verifies, or that is older than the running version, is discarded and the quit proceeds untouched. Turning auto-update off also stops installing on quit.
- **`GITPAD_ALLOW_DEV_UPDATE=1`** (alongside `GITPAD_DIR` / `GITPAD_UPDATE_FEED` / `GITPAD_DEVICE_NAME`) lifts the two *policy* refusals — "this is a dev build" and "brew owns this" — so the install path can be exercised on the machine that builds GitPad. It lifts nothing about the download: hash, Developer ID and notarization are enforced with or without it.

## Privacy of your notes

Your notes are exactly as private as the git remote you point GitPad at. A
private repo on a host you trust keeps them private; a public repo makes them
public. GitPad adds no layer of its own — that's the point.

### Clipboard notes (optional, off by default)

With Settings → Advanced → *Save copied text to Clipboard notes* on, GitPad polls the
pasteboard and appends copied **text** to `Clipboard/<day>.md`. The folder is in the
per-clone git exclude, so it is never committed or pushed. Copies marked
`org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` (1Password,
Bitwarden, Keychain) are skipped — but a password copied from a web page or a terminal
carries no such marker and **will** be written to that file in plain text, on disk only.

### Encrypted vault (optional)

Settings → General → *Encrypt notes…* (or the last onboarding step) moves the notes
folder into an AES-256 APFS sparse bundle (`~/Library/Application Support/GitPad/Vault.sparsebundle`)
that macOS mounts **at** `~/Documents/GitPad`. Inside, the notes are still plain Markdown
and the git repo is untouched. The vault is detached whenever the screen locks, the Mac
sleeps, GitPad quits, or (opt-in, Settings → *Lock when idle*) nobody has touched the Mac for a chosen number of minutes: while locked, the folder is empty and unwritable and only ciphertext
exists on disk. The passphrase is kept in your login Keychain so unlocking is silent; it is
handed to `hdiutil` over stdin, never on the command line. Ceilings, stated plainly:

- While the vault is unlocked, anything running as you — or as root, e.g. an MDM agent — can
  read the notes, and screen recording sees what you type. The vault protects the disk when
  you are not at the machine, not a compromised session.
- Notes that existed as plain files before you turned the vault on may survive in APFS local
  snapshots, Time Machine, or a corporate backup agent until those age out.
- The Keychain item is exactly as safe as your login password. Settings → *Require Touch ID
  to unlock* (opt-in) closes that gap: the passphrase is then sealed to a Secure Enclave key
  created with user-presence protection, so releasing it needs Touch ID, or the account
  password on a Mac without it, and no process running as you — root included — can read
  it otherwise. The cost is a prompt at launch and after every screen unlock. The sealed
  blob (`~/Library/Application Support/GitPad/vault.key`) is useless off this Mac's Enclave.
- There is no recovery. A forgotten passphrase means the notes are gone unless a git remote
  has them.

Deleting the app by hand does **not** delete your notes (the plain folder, or the vault
image). Settings → General → *Erase GitPad from this Mac…* syncs, removes the notes folder,
the vault image, its Keychain entry and settings, and moves the app to the Trash. It refuses
to run if the final sync fails, so an unpushed note is never lost. Repo-level encryption
(age / git-crypt) is deliberately not built in: the vault protects the disk; the remote is
your choice.

## Reporting a vulnerability

Please report security issues privately by opening a
[GitHub security advisory](../../security/advisories/new) rather than a public
issue. We'll acknowledge and work a fix before any disclosure.
