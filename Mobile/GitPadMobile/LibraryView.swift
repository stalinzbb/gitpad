import SwiftUI

struct LibraryView: View {
    @ObservedObject var store: MobileStore
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var newTitle: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    ForEach(store.sections, id: \.name) { s in
                        Section(s.name) { ForEach(s.paths, id: \.self, content: row) }
                    }
                } else {
                    ForEach(store.matches(query), id: \.self, content: row)
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableCompat(store.error ?? "No notes yet — pull to refresh.")
                }
            }
            .searchable(text: $query)
            .refreshable { await store.refresh() }
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { NoteView(store: store, path: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") { path.append(MobileStore.dailyPath()) }
                    Button { newTitle = "" } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .alert("New note", isPresented: Binding(get: { newTitle != nil }, set: { if !$0 { newTitle = nil } })) {
                TextField("Title", text: Binding(get: { newTitle ?? "" }, set: { newTitle = $0 }))
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) { newTitle = nil }
            }
            .sheet(isPresented: $showSettings) { SettingsView(store: store) }
            .task { await store.refresh() }
        }
    }

    private func row(_ p: String) -> some View {
        NavigationLink(value: p) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title(p)).lineLimit(1)
                if let m = store.meta(p), !m.snippet.isEmpty || m.total > 0 {
                    HStack {
                        Text(m.snippet).lineLimit(1)
                        if m.total > 0 { Spacer(); Text("\(m.done)/\(m.total)") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        Group {
            if let e = store.error {
                Text(e).font(.footnote).foregroundStyle(.red)
            } else if let d = store.lastSync {
                Text("Synced \(d.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(6).frame(maxWidth: .infinity).background(.bar)
    }

    private func create() async {
        guard let t = newTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { newTitle = nil; return }
        newTitle = nil
        do { path.append(try await store.create(title: t, in: nil)) }
        catch { store.error = error.localizedDescription }
    }
}

/// iOS 16 has no ContentUnavailableView; a centred secondary line does the job.
struct ContentUnavailableCompat: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
    }
}

struct SettingsView: View {
    @ObservedObject var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var device = MobileStore.device
    @State private var confirmForget = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") { Text(MobileStore.remote).foregroundStyle(.secondary) }
                Section {
                    SecureField("Leave blank to keep the current token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("This phone", text: $device)
                    Button("Save") { Task { await save() } }
                } footer: { if let error { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Forget this phone", role: .destructive) { confirmForget = true }
                } footer: { Text("Removes the token and every cached note from this phone. The repo is untouched.") }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Forget this phone?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { store.forget(); dismiss() }
            }
        }
    }

    private func save() async {
        let t = token.isEmpty ? (Keychain.token ?? "") : token
        do {
            try await store.connect(remote: MobileStore.remote, token: t, device: device.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
