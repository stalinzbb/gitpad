import SwiftUI

/// "Sign in with GitHub" via the OAuth device flow: GitPad asks for a short code, you type
/// it on github.com, GitPad polls until GitHub hands back a token. No redirect URI, no client
/// secret, no GitPad server. The token is handed straight to git's own credential store
/// (the macOS Keychain, via `git credential approve`) — GitPad never writes it anywhere else,
/// and HTTPS pushes then work with no gh CLI and no SSH keys.
///
/// Network: talks to github.com only when the user clicks Sign in. See SECURITY.md.
enum GitHubAuth {
    /// Public client ID of GitPad's GitHub App (not a secret — it ships in every build).
    /// Empty hides every "Sign in with GitHub" button; SSH and gh keep working as before.
    /// Register a *GitHub App* (not an OAuth App) so access is per-repo: enable Device Flow,
    /// Repository permissions → Contents: Read and write, and turn OFF "Expire user
    /// authorization tokens". ponytail: no refresh-token handling — if expiry is left on, pushes
    /// fail after 8 hours and Fix Sync offers sign-in again; add refresh if that ever ships.
    static let clientID = ""
    /// The app's URL slug (github.com/apps/<slug>): where a user adds GitPad to their notes repo.
    static let appSlug = ""
    static var enabled: Bool { !clientID.isEmpty }
    static var installURL: URL? {
        appSlug.isEmpty ? nil : URL(string: "https://github.com/apps/\(appSlug)/installations/new")
    }

    struct Code {
        let device: String, user: String
        let url: URL
        var interval: Int
        let expires: Date
    }

    enum Failure: Error, LocalizedError {
        case offline, expired, denied, other(String)
        var errorDescription: String? {
            switch self {
            case .offline: return "Can't reach GitHub — check your network"
            case .expired: return "That code expired — try again"
            case .denied: return "Sign-in was cancelled on GitHub"
            case .other(let s): return s
            }
        }
    }

    static func start() async throws -> Code {
        // `scope` only matters to an OAuth App; a GitHub App ignores it and uses its own permissions
        let j = try await post("https://github.com/login/device/code", form: ["client_id": clientID, "scope": "repo"])
        guard let d = j["device_code"] as? String, let u = j["user_code"] as? String,
              let v = (j["verification_uri"] as? String).flatMap(URL.init(string:)), v.scheme == "https"
        else { throw Failure.other((j["error_description"] as? String) ?? "Unexpected reply from GitHub") }
        return Code(device: d, user: u, url: v, interval: j["interval"] as? Int ?? 5,
                    expires: Date().addingTimeInterval(Double(j["expires_in"] as? Int ?? 900)))
    }

    /// Polls until the user approves. Cancelling the task stops it (the sleep throws).
    static func token(for code: Code) async throws -> String {
        var code = code
        while Date() < code.expires {
            try await Task.sleep(nanoseconds: UInt64(code.interval) * 1_000_000_000)
            guard let j = try? await post("https://github.com/login/oauth/access_token", form: [
                "client_id": clientID, "device_code": code.device,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]) else { continue } // a dropped poll is just "not yet"
            if let t = j["access_token"] as? String { return t }
            switch j["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": code.interval = j["interval"] as? Int ?? code.interval + 5
            case "expired_token": throw Failure.expired
            case "access_denied": throw Failure.denied
            default: throw Failure.other((j["error_description"] as? String) ?? "GitHub sign-in failed")
            }
        }
        throw Failure.expired
    }

    /// Hand the token to git's credential store, so every later fetch/push over HTTPS finds it.
    /// Goes in on stdin — argv is visible to `ps`. GitHub ignores the username for token auth.
    /// Blocking; call off the main thread.
    static func store(token: String) -> Bool {
        GitSync.exec("/usr/bin/git", ["credential", "approve"],
                     stdin: "protocol=https\nhost=github.com\nusername=x-access-token\npassword=\(token)\n\n").status == 0
    }

    /// The signed-in account's private `gitpad-notes` repo, created if it isn't there yet.
    /// nil when the token may not create repos (a GitHub App installed on selected repos only) —
    /// the caller falls back to "paste your repo URL".
    static func notesRepo(token: String, name: String = "gitpad-notes") async -> String? {
        if let made = try? await post("https://api.github.com/user/repos", token: token,
                                      json: ["name": name, "private": true]),
           let url = made["clone_url"] as? String { return url }
        // 422 = already exists: use it
        guard let me = try? await post("https://api.github.com/user", token: token, method: "GET"),
              let login = me["login"] as? String,
              let repo = try? await post("https://api.github.com/repos/\(login)/\(name)", token: token, method: "GET")
        else { return nil }
        return repo["clone_url"] as? String
    }

    private static func post(_ url: String, token: String? = nil, method: String = "POST",
                             form: [String: String]? = nil, json: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let form {
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = body.percentEncodedQuery.map { Data($0.utf8) }
        }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { throw Failure.offline }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // the device-flow endpoints answer 200 with an `error` field; the REST API uses status codes
        if token != nil, let code = (resp as? HTTPURLResponse)?.statusCode, !(200...299).contains(code) {
            throw Failure.other((j["message"] as? String) ?? "GitHub returned \(code)")
        }
        return j
    }
}

/// The button, then the code to type while GitPad polls. `onToken` runs once the token is
/// already in git's credential store. Used by the setup guide and Fix Sync.
struct GitHubSignInButton: View {
    var label = "Sign in with GitHub"
    let onToken: (String) -> Void
    @State private var code: GitHubAuth.Code?
    @State private var polling: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let code {
                HStack(spacing: Space.m) {
                    Text(code.user).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        .accessibilityLabel("Code: " + code.user.map(String.init).joined(separator: " "))
                    ProgressView().controlSize(.small)
                }
                Text("Enter this code on GitHub. It's on your clipboard.").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Space.m) {
                    Button("Open GitHub again") { NSWorkspace.shared.open(code.url) }
                    Button("Cancel") { polling?.cancel(); self.code = nil }
                }
            } else {
                Button { begin() } label: { Label(label, systemImage: "person.badge.key") }
                if let error { Text(error).font(.caption).foregroundStyle(Color.statusErr) }
            }
        }
        .onDisappear { polling?.cancel() }
    }

    private func begin() {
        error = nil
        polling = Task { @MainActor in
            do {
                let c = try await GitHubAuth.start()
                code = c
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.user, forType: .string)
                NSWorkspace.shared.open(c.url)
                let token = try await GitHubAuth.token(for: c)
                let stored = await Task.detached { GitHubAuth.store(token: token) }.value
                code = nil
                if stored { onToken(token) } else { error = "Couldn't save the login to the Keychain" }
            } catch is CancellationError {
            } catch { code = nil; self.error = error.localizedDescription }
        }
    }
}
