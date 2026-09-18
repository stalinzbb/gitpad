import SwiftUI

/// First run, two steps: prove the hotkey + typing, then offer sync. The vault lives in
/// Settings → Advanced; nothing optional gets its own page here.
struct OnboardingView: View {
    @ObservedObject var store: NoteStore
    @State private var step = 0
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if step == 0 { hotkeyStep } else { GitSetupView(store: store, onboarding: finish) }
        }
        .animation(Motion.screen, value: step)
    }

    private var hotkeyStep: some View {
        VStack(spacing: 0) {
            Spacer()
            KeyCaps(combo: Hotkey.display)
            Text("Notes at the speed of thought")
                .font(.title2.weight(.semibold))
                .padding(.top, 22)
            Text("Press it from any app and today's note opens over your work. Type, and it saves itself as a Markdown file in \(store.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
                .padding(.top, Space.l)
            // Today's note, for real: what gets typed here stays.
            MarkdownTextView(text: $store.text, fontSize: CGFloat(editorFontSize),
                             design: fontDesign, theme: theme)
                .frame(width: 300, height: 130)
                .background(Color.primary.opacity(Alpha.inset),
                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.cardStroke, lineWidth: 1))
                .padding(.top, 26)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    Circle().fill(i == step ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            // No .defaultAction here: Return belongs to the editor above.
            Button("Continue") { withAnimation(Motion.pop) { step = 1 } }
                .buttonStyle(.borderedProminent)
                .padding(.top, Space.xxl).padding(.bottom, Space.s)
            Text("Step 2: sync across Macs (optional)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .padding()
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func finish() {
        onboarded = true
        store.screen = .capture
    }
}

/// The bound hotkey as keycaps: modifiers one glyph each, the key on its own cap.
struct KeyCaps: View {
    let combo: String
    private static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    private var caps: [String] {
        var mods: [String] = []
        var rest = Substring(combo)
        while let c = rest.first, Self.modifiers.contains(c) { mods.append(String(c)); rest = rest.dropFirst() }
        return mods + (rest.isEmpty ? [] : [rest.lowercased()])
    }

    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(caps, id: \.self) { cap in
                Text(cap)
                    .font(.system(size: cap.count == 1 ? 18 : 14, weight: .medium))
                    .padding(.horizontal, cap.count == 1 ? 16 : 26).padding(.vertical, Space.l)
                    .background(Color.primary.opacity(Alpha.iconHover),
                                in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .strokeBorder(Color.primary.opacity(Alpha.cardDivider), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 0, y: 2)
            }
        }
    }
}

/// Step-by-step git sync guide, reachable any time from Settings — and, with `onboarding`
/// set, as the second first-run step (no chrome, a "Not now" way out, done on first sync).
struct GitSetupView: View {
    @ObservedObject var store: NoteStore
    var onboarding: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var remote = ""
    @FocusState private var remoteFocused: Bool
    @State private var result: String?
    @State private var working = false
    @State private var ghReady = false
    @State private var usedSignIn = false
    @State private var needsInstall = false

    private var trimmed: String { remote.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            if onboarding == nil {
                ChromeBar(store: store, title: "Set up sync", showSettings: false, showSyncDot: false) {
                    ChromeIcon(symbol: ChromeGlyph.back, help: "Back (Esc)") { store.goBack() }
                }
            } else {
                Text("Sync across Macs?")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 28)
                Text("Optional. A private git repo carries your notes to every Mac you use.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.s)
            }

            VStack(alignment: .leading, spacing: 18) {
                if GitHubAuth.enabled {
                    // preferred over gh: a GitHub App token reaches only the repos GitPad was added to
                    step(1, "Sign in with GitHub",
                         "GitPad makes a private gitpad-notes repo and pushes over HTTPS. No SSH keys, no gh CLI, and the login goes straight into your Keychain.")
                    GitHubSignInButton { signedIn($0) }
                        .padding(.leading, Space.gutter + Space.l)
                        .disabled(working)
                    if needsInstall, let install = GitHubAuth.installURL {
                        Link("Add GitPad to your notes repo ↗", destination: install)
                            .font(.callout).padding(.leading, Space.gutter + Space.l)
                    }
                } else if ghReady {
                    step(1, "Create a private repo — one click",
                         "You're signed in to the gh CLI, so GitPad can make the repo and wire up auth for you. No SSH keys needed.")
                    Button { createRepo() } label: {
                        Label("Create a private repo for me", systemImage: "wand.and.stars")
                    }
                    .padding(.leading, Space.gutter + Space.l)
                    .disabled(working)
                    Text("Uses your gh login's token, which can reach every repo on your account, not just this one. For the narrowest access, paste an SSH URL below instead.")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.leading, Space.gutter + Space.l)
                } else {
                    step(1, "Create a private repository",
                         "Any git host works. On GitHub: New repository → Private.")
                    Link("Open github.com/new ↗", destination: URL(string: "https://github.com/new")!)
                        .font(.callout)
                        .padding(.leading, Space.gutter + Space.l)
                }

                step(2, "Paste the repo URL",
                     "SSH (git@github.com:you/notes.git) uses this Mac's keys — nothing to log into. HTTPS works too if you use the gh CLI or a credential helper.")
                TextField("git@github.com:you/notes.git", text: $remote)
                    .focused($remoteFocused)
                    .fieldStyle(focused: remoteFocused)
                    .padding(.leading, Space.gutter + Space.l)

                step(3, "Save & Sync",
                     "GitPad checks the connection, syncs once, then keeps syncing on every save, every 5 minutes, and on wake.")
            }
            .padding(Space.gutter)
            Spacer()
            if let r = result {
                Text(r).font(.caption)
                    .foregroundStyle(r.hasPrefix("✓") ? Color.statusOK : Color.statusErr)
                    .padding(.bottom, 6)
            }
            if let onboarding {
                HStack(spacing: 6) {
                    Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                    Circle().fill(Color.primary).frame(width: 6, height: 6)
                }
                .padding(.bottom, Space.xxl)
                HStack(spacing: Space.xl) {
                    Button("Not now", action: onboarding).disabled(working)
                    saveButton
                }
                .padding(.bottom, 20)
            } else {
                saveButton.padding(.bottom, 20)
            }
        }
        .onAppear {
            DispatchQueue.global().async {
                let url = GitSync.remoteURL(in: store.dir)
                let gh = GitSync.ghReady()
                DispatchQueue.main.async {
                    if remote.isEmpty { remote = url }
                    ghReady = gh
                }
            }
        }
    }

    private var saveButton: some View {
        Button(working ? "Working…" : "Save & Sync") { saveAndSync() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmed.isEmpty || working)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(theme.selection, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Save remote → reachability check → sync, reporting one friendly line.
    private func saveAndSync() {
        let url = trimmed
        working = true
        result = nil
        DispatchQueue.global().async {
            GitSync.setRemote(url, in: store.dir)
            // let gh's token drive https pushes — unless Sign in with GitHub just stored a narrower one
            if url.hasPrefix("https://"), !usedSignIn { GitSync.enableHTTPSAuth() }
            let ls = GitSync.run(["ls-remote", url], in: store.dir)
            if ls.status != 0 {
                let msg = GitSync.friendlyError(ls.out)
                DispatchQueue.main.async { result = "✗ " + msg; working = false }
                return
            }
            let ok = GitSync.sync(dir: store.dir)
            DispatchQueue.main.async {
                result = ok ? "✓ Synced — you're all set" : "✗ Sync failed — try again"
                working = false
                store.refresh()
                if ok, let onboarding { onboarding() } // first run ends inside the editor
            }
        }
    }

    /// The token is already in git's credential store. Try the one-click repo; a GitHub App
    /// limited to selected repos can't create one, so fall back to pasting the URL.
    private func signedIn(_ token: String) {
        usedSignIn = true
        guard trimmed.isEmpty else { saveAndSync(); return } // they already pasted a repo: just use it
        working = true
        Task { @MainActor in
            let url = await GitHubAuth.notesRepo(token: token)
            working = false
            if let url { remote = url; saveAndSync() }
            else {
                needsInstall = true
                result = "✓ Signed in — now paste your repo's HTTPS URL below"
            }
        }
    }

    private func createRepo() {
        working = true
        result = nil
        DispatchQueue.global().async {
            let url = GitSync.ghCreateRepo("gitpad-notes")
            DispatchQueue.main.async {
                working = false
                if let url { remote = url; saveAndSync() }
                else { result = "✗ Couldn't create the repo — paste an SSH URL instead" }
            }
        }
    }
}
