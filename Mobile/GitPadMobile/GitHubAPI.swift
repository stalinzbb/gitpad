import Foundation
import GitPadCore

/// GitHub REST Contents/Trees over URLSession. The phone is a guest on the remote: it reads
/// blobs, writes blobs, and never merges — the Mac's `GitSync` reconciles whatever lands.
struct GitHubAPI {
    var owner: String
    var repo: String
    var branch: String
    var token: String
    var device: String
    var base = URL(string: "https://api.github.com")!

    enum Error: Swift.Error, LocalizedError, Equatable {
        case unauthorized, notFound, offline, rateLimited, conflict, other(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "GitHub rejected the token — check it has Contents read/write on this repo."
            case .notFound: return "Repo not found — check owner/repo and that the token can see it."
            case .offline: return "Can't reach GitHub — showing what's cached."
            case .rateLimited: return "GitHub rate limit hit — try again in a few minutes."
            case .conflict: return "Saved as a conflict copy — review on your Mac."
            case .other(let s): return s
            }
        }
    }

    struct Entry: Codable, Equatable { var path: String; var sha: String }
    struct File: Equatable { var body: String; var sha: String }

    func repoInfo() async throws -> String {
        let j = try await get("repos/\(owner)/\(repo)")
        guard let b = j["default_branch"] as? String else { throw Error.other("Unexpected reply from GitHub.") }
        return b
    }

    /// Every `.md` in the repo in one request. `.git/` never appears in a tree listing.
    func tree() async throws -> [Entry] {
        let j = try await get("repos/\(owner)/\(repo)/git/trees/\(branch)?recursive=1")
        let items = j["tree"] as? [[String: Any]] ?? []
        return items.compactMap { i in
            guard i["type"] as? String == "blob", let p = i["path"] as? String, p.hasSuffix(".md"),
                  let s = i["sha"] as? String else { return nil }
            return Entry(path: p, sha: s)
        }
    }

    func read(_ path: String) async throws -> File {
        let j = try await get("repos/\(owner)/\(repo)/contents/\(escape(path))?ref=\(branch)")
        guard let raw = j["content"] as? String, let sha = j["sha"] as? String,
              let data = Data(base64Encoded: raw.replacingOccurrences(of: "\n", with: "")),
              let body = String(data: data, encoding: .utf8)
        else { throw Error.other("Unexpected reply from GitHub.") }
        return File(body: body, sha: sha)
    }

    /// Returns the new blob sha. `sha == nil` creates; a stale sha is `.conflict`.
    @discardableResult
    func write(_ path: String, body: String, sha: String?) async throws -> String {
        var payload: [String: Any] = [
            "message": "autosave \(ISO8601DateFormatter().string(from: Date()))",
            "content": Data(body.utf8).base64EncodedString(),
            "branch": branch,
            "committer": ["name": device, "email": "gitpad@localhost"],
        ]
        if let sha { payload["sha"] = sha }
        let j = try await request("PUT", "repos/\(owner)/\(repo)/contents/\(escape(path))", body: payload)
        guard let content = j["content"] as? [String: Any], let new = content["sha"] as? String
        else { throw Error.other("Unexpected reply from GitHub.") }
        return new
    }

    /// Save with the Mac's rules, from the phone's side: if someone else wrote first and
    /// their version isn't what we started from, our text becomes a conflict copy and
    /// theirs stays canonical. ponytail: phone is the guest; no three-way merge on the phone.
    /// Returns the written file (canonical) and whether a copy was made.
    func save(_ path: String, body: String, sha: String?, original: String) async throws -> (File, conflict: Bool) {
        do {
            return (File(body: body, sha: try await write(path, body: body, sha: sha)), false)
        } catch Error.conflict {
            let remote = try await read(path)
            if remote.body == original {
                return (File(body: body, sha: try await write(path, body: body, sha: remote.sha)), false)
            }
            let copy = Markdown.conflictCopyName(path, device: device, date: Date())
            try await write(copy, body: body, sha: nil)
            return (remote, true)
        }
    }

    // MARK: plumbing

    private func escape(_ path: String) -> String {
        path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? String($0)
        }.joined(separator: "/")
    }

    private func get(_ path: String) async throws -> [String: Any] {
        try await request("GET", path, body: nil)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        // path segments are already percent-escaped by `escape`; query strings pass through
        guard let url = URL(string: base.absoluteString + "/" + path) else { throw Error.other("Bad path: \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw Error.offline }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch code {
        case 200...299: return json
        case 401: throw Error.unauthorized
        case 403, 429: throw Error.rateLimited
        case 404: throw Error.notFound
        case 409, 422: throw Error.conflict
        default: throw Error.other((json["message"] as? String).map { "GitHub: \($0)" } ?? "GitHub returned \(code).")
        }
    }
}
