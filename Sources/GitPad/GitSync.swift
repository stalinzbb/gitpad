import Foundation

enum GitSync {
    /// Runs a subprocess with a FIXED argument array — never a shell string.
    /// SECURITY INVARIANT: no user input is ever interpolated into a shell;
    /// args go straight to execve, so note titles / remote URLs can't inject.
    ///
    /// Internal rather than private so `Updater` and `Vault` run ditto/codesign/hdiutil through
    /// this same audited primitive. There is exactly one way to start a process in this app.
    /// `stdin` is for secrets (the vault passphrase): argv is visible to `ps`, a pipe is not.
    /// Written byte-for-byte — no trailing newline, hdiutil would make it part of the passphrase.
    static func exec(_ exe: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe { p.standardInput = inPipe }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0" // never hang on auth prompts
        // accept-new = trust a host we've never seen, but still hard-fail if a known
        // host's key CHANGED (the case that actually matters). See SECURITY.md.
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o StrictHostKeyChecking=accept-new"
        }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "") }
        if let stdin, let inPipe { // a passphrase is far below the pipe buffer: write-then-read can't deadlock
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, out)
    }

    @discardableResult
    static func run(_ args: [String], in dir: URL) -> (status: Int32, out: String) {
        exec("/usr/bin/git", ["-C", dir.path] + args)
    }

    static func remoteURL(in dir: URL) -> String {
        let r = run(["remote", "get-url", "origin"], in: dir)
        return r.status == 0 ? r.out : "" // never leak git's stderr ("fatal: …") into the UI
    }

    /// (unpushed, unpulled) commit counts vs origin, or nil if unknown.
    static func aheadBehind(in dir: URL) -> (ahead: Int, behind: Int)? {
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir).out
        let r = run(["rev-list", "--left-right", "--count", "HEAD...origin/\(branch)"], in: dir)
        let parts = r.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard r.status == 0, parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static func setRemote(_ url: String, in dir: URL) {
        guard !url.isEmpty else { return }
        if run(["remote", "get-url", "origin"], in: dir).status == 0 {
            run(["remote", "set-url", "origin", url], in: dir)
        } else {
            run(["remote", "add", "origin", url], in: dir)
        }
    }

    /// Turn raw git stderr into one friendly line — never shown verbatim.
    static func friendlyError(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("terminal prompts disabled") || s.contains("could not read username")
            || s.contains("authentication failed") {
            return GitHubAuth.enabled
                ? "This HTTPS URL needs a login — sign in with GitHub above, or use the SSH URL (git@…)"
                : "This HTTPS URL needs a login — use the SSH URL (git@…), or install & sign in to the gh CLI"
        }
        if s.contains("permission denied") || s.contains("publickey") {
            return "SSH key not authorized — add this Mac's key to the repo host"
        }
        if s.contains("host key verification") || s.contains("host identification has changed") {
            return "The server's SSH key changed — verify it before trusting (could be an attack)"
        }
        if s.contains("could not read from remote") || s.contains("not found")
            || s.contains("does not exist") || s.contains("repository") {
            return "Repository not found — double-check the URL"
        }
        return "Can't reach the repo — check the URL and your network"
    }

    // MARK: gh CLI (optional convenience)

    /// Homebrew installs gh outside the sandbox PATH, so probe the usual spots.
    private static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func ghReady() -> Bool {
        guard let gh = ghPath else { return false }
        return exec(gh, ["auth", "status"]).status == 0
    }

    /// Configure git to push over HTTPS using gh's stored token (no SSH needed).
    static func enableHTTPSAuth() {
        guard let gh = ghPath else { return }
        _ = exec(gh, ["auth", "setup-git"])
    }

    /// Create a private repo and return an HTTPS URL that pushes via gh's token
    /// (works without any SSH setup), or nil on failure.
    static func ghCreateRepo(_ name: String) -> String? {
        guard let gh = ghPath else { return nil }
        guard exec(gh, ["repo", "create", name, "--private"]).status == 0 else { return nil }
        enableHTTPSAuth()
        let u = exec(gh, ["repo", "view", name, "--json", "url", "-q", ".url"])
        guard u.status == 0, !u.out.isEmpty else { return nil }
        return u.out.hasSuffix(".git") ? u.out : u.out + ".git"
    }

    /// Commit local edits, reconcile with origin, push. Never surfaces a merge UI:
    /// clean merges happen silently; a real same-file conflict keeps the local
    /// version and writes the remote version alongside as "<name> (conflict <date>).md".
    /// Returns true if the repo is left in a consistent, pushed (or no-remote) state.
    static func sync(dir: URL) -> Bool {
        if run(["rev-parse", "--git-dir"], in: dir).status != 0 {
            run(["init", "-b", "main"], in: dir)
        }
        // unconditional (idempotent) so existing repos pick up the device name too —
        // commit authors are how the conflict UI names "the other Mac"
        run(["config", "user.name", deviceName], in: dir)
        run(["config", "user.email", "gitpad@localhost"], in: dir)
        // Only Markdown ever reaches the remote: a screenshot, a .DS_Store or an .env dropped
        // into the folder by mistake is never committed, let alone pushed. Per-clone exclude,
        // not a .gitignore — nothing extra appears in the notes folder. Files a repo already
        // tracks (a README, say) are unaffected; exclude only governs what's *new*.
        let exclude = URL(fileURLWithPath: run(["rev-parse", "--git-path", "info/exclude"], in: dir).out,
                          relativeTo: dir)
        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? "*\n!*/\n!*.md\n".write(to: exclude, atomically: true, encoding: .utf8)

        // 1. commit local changes
        run(["add", "-A"], in: dir)
        if run(["diff", "--cached", "--quiet"], in: dir).status != 0 {
            let stamp = ISO8601DateFormatter().string(from: Date())
            run(["commit", "-m", "autosave \(stamp)"], in: dir)
        }

        // no remote configured → local-only mode, still fine
        guard run(["remote", "get-url", "origin"], in: dir).status == 0 else { return true }

        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir).out
        // ponytail: one blind retry covers the common push race (someone pushed between
        // our fetch and our push); a truly offline machine fails fast at fetch again.
        for _ in 0..<2 {
            if reconcileAndPush(dir: dir, branch: branch) { return true }
        }
        return false
    }

    /// This Mac's name, used as the git author so conflict copies can say who they came from.
    /// Settings → Sync → "This Mac" overrides the Mac's own name, which otherwise goes into
    /// every commit on the remote ("Stalin's MacBook Pro") — a small identity leak on a
    /// shared or public repo. The env var stays on top for the tests.
    static var deviceName: String {
        let custom = UserDefaults.standard.string(forKey: "deviceName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = ProcessInfo.processInfo.environment["GITPAD_DEVICE_NAME"]
            ?? custom.flatMap { $0.isEmpty ? nil : $0 }
            ?? Host.current().localizedName ?? "GitPad"
        return raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// fetch → adopt-or-merge → push. Returns true only if the push landed.
    private static func reconcileAndPush(dir: URL, branch: String) -> Bool {
        guard run(["fetch", "origin"], in: dir).status == 0 else { return false } // offline

        let remote = "origin/\(branch)"
        if run(["rev-parse", "--verify", remote], in: dir).status == 0 {
            if run(["merge-base", "HEAD", remote], in: dir).status != 0, isPristine(dir) {
                // Fresh device pointed at an existing notes repo: unrelated histories AND
                // every local file is still generated boilerplate. Merging here would
                // manufacture conflict copies of the user's real notes, so adopt instead.
                // ponytail: the only destructive line in the app — guarded by isPristine,
                // which fails on a single user-typed character (test S8 covers it).
                run(["reset", "--hard", remote], in: dir)
            } else if run(["merge", "--no-edit", "--allow-unrelated-histories", remote], in: dir).status != 0 {
                guard resolveConflict(dir: dir, remote: remote) else { return false }
            }
        }
        return run(["push", "-u", "origin", branch], in: dir).status == 0
    }

    /// Merge failed: keep this Mac's version, save the other Mac's alongside, finish the merge.
    private static func resolveConflict(dir: URL, remote: String) -> Bool {
        // only genuinely unmerged paths — a file that merged cleanly never gets a copy
        let unmerged = run(["diff", "--name-only", "--diff-filter=U"], in: dir).out
            .split(separator: "\n").map(String.init)
        run(["merge", "--abort"], in: dir)

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HHmm"
        for file in unmerged where file.hasSuffix(".md") {
            let show = run(["show", "\(remote):\(file)"], in: dir)
            guard show.status == 0 else { continue } // remote deleted it → nothing to copy
            let who = run(["log", "-1", "--format=%an", remote, "--", file], in: dir)
            let device = who.status == 0 && !who.out.isEmpty ? who.out : "other device"
            let copy = file.replacingOccurrences(
                of: ".md", with: " (conflict from \(device) \(date.string(from: Date()))).md")
            try? show.out.write(to: dir.appendingPathComponent(copy),
                                atomically: true, encoding: .utf8)
        }
        run(["add", "-A"], in: dir)
        run(["commit", "-m", "conflict copies"], in: dir)

        // ponytail: -X ours keeps local hunks; remote hunks live on in the copies
        if run(["merge", "--no-edit", "--allow-unrelated-histories", "-X", "ours", remote], in: dir).status == 0 {
            return true
        }
        // -X ours can't auto-resolve modify/delete. Completing the merge with whatever
        // is in the worktree resurrects a locally-deleted but remotely-edited note —
        // ponytail: data-safe by design; a lost note beats a wedged repo.
        run(["add", "-A"], in: dir)
        guard run(["commit", "--no-edit"], in: dir).status == 0 else {
            run(["merge", "--abort"], in: dir)
            return false
        }
        return true
    }

    /// True when every tracked file is still GitPad-generated boilerplate: a `.md`
    /// whose body, minus a leading `#` heading line, is empty. One typed character fails it.
    private static func isPristine(_ dir: URL) -> Bool {
        let files = run(["ls-files"], in: dir).out.split(separator: "\n").map(String.init)
        for file in files {
            guard file.hasSuffix(".md") else { return false }
            let raw = (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? ""
            var lines = raw.components(separatedBy: "\n")
            if lines.first?.hasPrefix("#") == true { lines.removeFirst() }
            guard lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        return true
    }

    // MARK: diagnosis (Settings "Fix sync")

    enum SyncProblem: Equatable {
        case ok, noRemote, offline, sshAuth(key: String), hostKeyChanged, repoMissing, httpsNeedsLogin
    }

    /// Classify why the remote is unreachable. Blocking — call it off the main thread:
    /// `ls-remote` can sit for a long time on a routable-but-dead host.
    static func diagnose(dir: URL) -> SyncProblem {
        guard !remoteURL(in: dir).isEmpty else { return .noRemote }
        let r = run(["ls-remote", "origin"], in: dir)
        guard r.status != 0 else { return .ok }
        let s = r.out.lowercased()
        if s.contains("host key verification") || s.contains("host identification has changed") {
            return .hostKeyChanged
        }
        if s.contains("permission denied") || s.contains("publickey") {
            return .sshAuth(key: offeredSSHKey(in: dir))
        }
        if s.contains("terminal prompts disabled") || s.contains("could not read username")
            || s.contains("authentication failed") {
            return .httpsNeedsLogin
        }
        if s.contains("not found") || s.contains("does not exist") || s.contains("repository") {
            return .repoMissing
        }
        return .offline
    }

    /// `git@github.com:you/n.git` / `ssh://git@github.com/you/n.git` → `github.com`.
    static func sshHost(_ url: String) -> String? {
        if url.hasPrefix("ssh://") {
            return URL(string: url)?.host
        }
        guard url.contains("@"), let at = url.firstIndex(of: "@") else { return nil }
        let rest = url[url.index(after: at)...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return String(rest[..<colon])
    }

    /// The private key ssh would actually offer this host — names the file the user must fix.
    static func offeredSSHKey(in dir: URL) -> String {
        guard let host = sshHost(remoteURL(in: dir)) else { return "~/.ssh/id_ed25519" }
        let g = exec("/usr/bin/ssh", ["-G", host])
        let line = g.out.split(separator: "\n").first { $0.hasPrefix("identityfile ") }
        let path = line.map { String($0.dropFirst("identityfile ".count)) } ?? "~/.ssh/id_ed25519"
        return NSString(string: path).expandingTildeInPath
    }

    /// `git@github.com:you/notes.git` → `https://github.com/you/notes.git`.
    static func httpsURL(from ssh: String) -> String? {
        guard !ssh.contains("://"), let host = sshHost(ssh), // scp-style only
              let colon = ssh.firstIndex(of: ":") else { return nil }
        let path = ssh[ssh.index(after: colon)...]
        return "https://\(host)/\(path)"
    }
}

/// The last few sync runs, one line each — the Settings Sync tab's activity list. A record
/// beats a verdict: "pulled 1 from the iMac, Tue 18:02" is what makes sync trustworthy.
/// ponytail: five dicts in UserDefaults; a file in the repo if cross-Mac history is wanted.
enum SyncLog {
    struct Entry { let date: Date; let ok: Bool; let text: String }
    private static let key = "syncLog", keep = 5

    static var entries: [Entry] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap {
            guard let d = $0["date"] as? Date, let ok = $0["ok"] as? Bool, let t = $0["text"] as? String
            else { return nil }
            return Entry(date: d, ok: ok, text: t)
        }
    }

    /// Call around `GitSync.sync`: `before` is HEAD when the run started (may be empty on a
    /// fresh repo). Counts what landed by commit author — this Mac's commits were pushed,
    /// everyone else's were pulled.
    static func record(ok: Bool, dir: URL, before: String) {
        var text: String
        if ok {
            let authors = before.isEmpty ? [] : GitSync.run(["log", "--format=%an", "\(before)..HEAD"], in: dir)
                .out.split(separator: "\n").map(String.init)
            let mine = authors.filter { $0 == GitSync.deviceName }.count
            let theirs = authors.filter { $0 != GitSync.deviceName }
            var parts: [String] = []
            if mine > 0 { parts.append("Pushed \(mine)") }
            if !theirs.isEmpty { parts.append("pulled \(theirs.count) from \(theirs[0])") }
            text = parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
            if text.hasPrefix("pulled") { text = "P" + text.dropFirst() }
        } else {
            text = "Couldn't reach remote"
        }
        let entry: [String: Any] = ["date": Date(), "ok": ok, "text": text]
        let all = Array(([entry] + (UserDefaults.standard.array(forKey: key) ?? [])).prefix(keep))
        UserDefaults.standard.set(all, forKey: key)
    }
}
