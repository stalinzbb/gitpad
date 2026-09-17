import Foundation
import GitPadCore

/// The phone's view of the repo: a cached tree + cached bodies under Documents/cache/,
/// refreshed from GitHub on demand. Reads work offline from the cache; writes need the network.
/// ponytail: no write queue — an offline save fails with a message; add a queue only if people ask.
@MainActor
final class MobileStore: ObservableObject {
    @Published var entries: [GitHubAPI.Entry] = []
    @Published var lastSync: Date?
    @Published var error: String?
    @Published private(set) var bodies: [String: GitHubAPI.File] = [:]

    private let cacheDir: URL
    private(set) var api: GitHubAPI?

    init() {
        cacheDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadCache()
        api = Self.savedAPI()
    }

    // MARK: settings

    static var remote: String {
        get { UserDefaults.standard.string(forKey: "remote") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "remote") }
    }
    static var branch: String {
        get { UserDefaults.standard.string(forKey: "branch") ?? "main" }
        set { UserDefaults.standard.set(newValue, forKey: "branch") }
    }
    static var device: String {
        get { UserDefaults.standard.string(forKey: "device") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "device") }
    }

    static func savedAPI() -> GitHubAPI? {
        guard let (owner, repo) = Markdown.parseRemote(remote), let token = Keychain.token else { return nil }
        return GitHubAPI(owner: owner, repo: repo, branch: branch, token: token, device: device)
    }

    var isConnected: Bool { api != nil }

    /// Setup's Connect: validate, then persist. Throws the API's one-line messages.
    func connect(remote: String, token: String, device: String) async throws {
        guard let (owner, repo) = Markdown.parseRemote(remote) else {
            throw GitHubAPI.Error.other("Not a GitHub repo URL — expected github.com/owner/repo.")
        }
        var candidate = GitHubAPI(owner: owner, repo: repo, branch: "main", token: token, device: device)
        candidate.branch = try await candidate.repoInfo()
        Self.remote = remote; Self.branch = candidate.branch; Self.device = device
        Keychain.token = token
        api = candidate
        await refresh()
    }

    /// "Forget this phone": token, settings and every cached note. The repo is untouched.
    func forget() {
        Keychain.token = nil
        for k in ["remote", "branch", "device", "lastSync"] { UserDefaults.standard.removeObject(forKey: k) }
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        entries = []; bodies = [:]; lastSync = nil; api = nil
    }

    // MARK: tree + sections

    func refresh() async {
        guard let api else { return }
        do {
            let fresh = try await api.tree()
            // a changed sha means the cached body is stale — drop it, the next open re-reads
            for e in fresh where bodies[e.path]?.sha != e.sha && bodies[e.path] != nil {
                bodies[e.path] = nil
                try? FileManager.default.removeItem(at: cacheURL(e.path))
            }
            let gone = Set(bodies.keys).subtracting(fresh.map(\.path))
            for p in gone { bodies[p] = nil; try? FileManager.default.removeItem(at: cacheURL(p)) }
            entries = fresh
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "lastSync")
            try? JSONEncoder().encode(fresh).write(to: cacheDir.appendingPathComponent("tree.json"))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Daily first (newest day on top), Inbox (repo root), then folders A–Z. Mirrors the Mac's
    /// Library. ponytail: no "Recent" — the tree API has no mtimes; add if missed.
    var sections: [(name: String, paths: [String])] {
        var byFolder: [String: [String]] = [:]
        for e in entries {
            let parts = e.path.split(separator: "/")
            let folder = parts.count > 1 ? String(parts[0]) : ""
            byFolder[folder, default: []].append(e.path)
        }
        var out: [(String, [String])] = []
        if let d = byFolder.removeValue(forKey: "Daily") { out.append(("Daily", d.sorted(by: >))) }
        if let root = byFolder.removeValue(forKey: "") { out.append(("Inbox", root.sorted())) }
        for k in byFolder.keys.sorted() { out.append((k, byFolder[k]!.sorted())) }
        return out
    }

    func title(_ path: String) -> String {
        let name = String(path.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "")
        guard let f = bodies[path] else { return name }
        return Markdown.title(of: f.body, fallback: name)
    }

    func meta(_ path: String) -> NoteMeta? { bodies[path].map { Markdown.parseMeta($0.body) } }

    /// Every token must hit the title, or the body when cached — same rule as the Mac.
    func matches(_ query: String) -> [String] {
        let tokens = Markdown.fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return entries.map(\.path) }
        return entries.map(\.path).filter { p in
            let hay = Markdown.fold(title(p) + " " + (bodies[p]?.body ?? ""))
            return tokens.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: bodies

    /// Cached copy first (instant, works offline); then the network, if we have it.
    func open(_ path: String) async throws -> GitHubAPI.File {
        guard let api else { throw GitHubAPI.Error.other("Not connected.") }
        do {
            let f = try await api.read(path)
            store(path, f)
            return f
        } catch GitHubAPI.Error.offline {
            if let cached = bodies[path] { return cached }
            throw GitHubAPI.Error.offline
        }
    }

    /// Returns true when the edit became a conflict copy instead of the canonical file.
    @discardableResult
    func save(_ path: String, body: String, original: String) async throws -> Bool {
        guard let api else { throw GitHubAPI.Error.other("Not connected.") }
        let (file, conflict) = try await api.save(path, body: body, sha: bodies[path]?.sha, original: original)
        store(path, file)
        if !entries.contains(where: { $0.path == path }) || conflict { await refresh() }
        return conflict
    }

    /// "Inbox/Title.md" or "Folder/Title.md"; body starts as the Mac's new-note shape.
    func create(title: String, in folder: String?) async throws -> String {
        let safe = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let path = (folder.map { "\($0)/" } ?? "") + safe + ".md"
        try await save(path, body: "# \(safe)\n\n", original: "")
        return path
    }

    // MARK: daily

    static func dailyPath(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "Daily/\(f.string(from: date)).md"
    }

    /// Read-or-create today's note with the Mac's header. Returns the file.
    func daily() async throws -> GitHubAPI.File {
        let path = Self.dailyPath()
        do { return try await open(path) }
        catch GitHubAPI.Error.notFound {
            let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM yyyy"
            let body = "# \(f.string(from: Date()))\n\n"
            try await save(path, body: body, original: "")
            return bodies[path] ?? GitHubAPI.File(body: body, sha: "")
        }
    }

    func appendToDaily(_ raw: String) async throws {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let f = try await daily()
        let sep = f.body.isEmpty || f.body.hasSuffix("\n") ? "" : "\n"
        try await save(Self.dailyPath(), body: f.body + sep + line + "\n", original: f.body)
    }

    // MARK: cache files — one file per note: sha on line 1, body after

    private func cacheURL(_ path: String) -> URL {
        cacheDir.appendingPathComponent(path.replacingOccurrences(of: "/", with: "%2F"))
    }

    private func store(_ path: String, _ f: GitHubAPI.File) {
        bodies[path] = f
        try? (f.sha + "\n" + f.body).write(to: cacheURL(path), atomically: true, encoding: .utf8)
    }

    private func loadCache() {
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent("tree.json")),
           let t = try? JSONDecoder().decode([GitHubAPI.Entry].self, from: d) { entries = t }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        for n in names where n != "tree.json" {
            guard let s = try? String(contentsOf: cacheDir.appendingPathComponent(n), encoding: .utf8),
                  let nl = s.firstIndex(of: "\n") else { continue }
            bodies[n.replacingOccurrences(of: "%2F", with: "/")] =
                GitHubAPI.File(body: String(s[s.index(after: nl)...]), sha: String(s[..<nl]))
        }
    }
}
