import SwiftUI
import GitPadCore

/// Repo URL + fine-grained token + device name → Connect. The user types their own token;
/// it goes to the Keychain and nowhere else.
struct SetupView: View {
    @ObservedObject var store: MobileStore
    @State private var remote = MobileStore.remote
    @State private var token = ""
    @State private var device = MobileStore.device.isEmpty ? UIDevice.current.name : MobileStore.device
    @State private var busy = false
    @State private var error: String?
    @Environment(\.theme) private var theme

    private var parsed: (owner: String, repo: String)? { Markdown.parseRemote(remote) }

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "note.text").font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                        Text("Your notes, from your repo.").font(.title2.bold())
                        Text("GitPad Mobile reads and writes the same Markdown files your Mac syncs. No GitPad server — just GitHub.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                Section {
                    TextField("git@github.com:you/notes.git", text: $remote)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: { Text("Repository") } footer: {
                    if remote.isEmpty { Text("The remote your Mac pushes to (Settings → Sync on the Mac).") }
                    else if let p = parsed { Text("\(p.owner)/\(p.repo)") }
                    else { Text("Not a GitHub URL. v1 speaks GitHub's API only.").foregroundStyle(.red) }
                }
                Section {
                    SecureField("github_pat_…", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Fine-grained token") } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repository access: just this repo. Permission: Contents → Read and write. Stored in this phone's Keychain only.")
                        Link("Create one on GitHub", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    }
                }
                Section("This phone") {
                    TextField("iPhone", text: $device)
                }
                Section {
                    Button { Task { await connect() } } label: {
                        HStack { Spacer(); if busy { ProgressView().padding(.trailing, 6) }; Text(busy ? "Connecting…" : "Connect").fontWeight(.semibold); Spacer() }
                    }
                        .disabled(busy || parsed == nil || token.isEmpty || device.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.listRowBackground(theme.card) } // cells on the theme surface, not system grey
            .themedSurface(theme)
            .navigationTitle("GitPad").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func connect() async {
        busy = true; error = nil
        do { try await store.connect(remote: remote, token: token, device: device.trimmingCharacters(in: .whitespaces)) }
        catch { self.error = error.localizedDescription }
        busy = false
    }
}
