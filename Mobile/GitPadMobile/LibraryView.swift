import SwiftUI
import GitPadCore

struct LibraryView: View {
    @ObservedObject var store: MobileStore
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var newTitle: String?
    @State private var allDaily = false

    private let dailyPreview = 4

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    Section { todayCard }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    // notes first, the daily log last — days pile up, notes are what you look for
                    ForEach(store.sections.filter { $0.name != "Daily" }, id: \.name) { s in
                        Section { ForEach(s.paths, id: \.self, content: row) } header: { header(s.name, s.paths.count) }
                    }
                    if let daily = store.sections.first(where: { $0.name == "Daily" }) {
                        let past = daily.paths.filter { $0 != MobileStore.dailyPath() }
                        Section {
                            ForEach(allDaily ? past : Array(past.prefix(dailyPreview)), id: \.self, content: row)
                            if past.count > dailyPreview {
                                Button(allDaily ? "Show fewer" : "Show all \(past.count) days") {
                                    withAnimation { allDaily.toggle() }
                                }.font(.subheadline).foregroundStyle(.tint)
                            }
                        } header: { header("Daily", past.count) }
                    }
                } else {
                    let hits = store.matches(query)
                    if hits.isEmpty { Text("No notes match “\(query)”.").foregroundStyle(.secondary).listRowSeparator(.hidden) }
                    ForEach(hits, id: \.self, content: row)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search notes")
            .refreshable { await store.refresh() }
            .navigationTitle("GitPad")
            .navigationDestination(for: String.self) { NoteView(store: store, path: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newTitle = "" } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New note")
                }
            }
            .alert("New note", isPresented: Binding(get: { newTitle != nil }, set: { if !$0 { newTitle = nil } })) {
                TextField("Title", text: Binding(get: { newTitle ?? "" }, set: { newTitle = $0 }))
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) { newTitle = nil }
            }
            .sheet(isPresented: $showSettings) { SettingsView(store: store) }
            .task { await store.refresh() }
        }
    }

    // MARK: today

    private var todayCard: some View {
        let p = MobileStore.dailyPath()
        let meta = store.meta(p)
        return Button { path.append(p) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TODAY").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.tint)
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text(meta.map { $0.snippet.isEmpty ? "Nothing yet — tap to write." : $0.snippet } ?? "Tap to start today's note.")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    syncLine.padding(.top, 4)
                }
                Spacer(minLength: 0)
                if let m = meta, m.total > 0 { TaskRing(done: m.done, total: m.total, size: 34) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var syncLine: some View {
        HStack(spacing: 5) {
            Circle().fill(store.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(store.error ?? store.lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
        }
    }

    // MARK: rows

    private func header(_ name: String, _ count: Int) -> some View {
        HStack {
            Text(name.uppercased()).font(.caption.weight(.semibold)).tracking(0.8)
            Spacer()
            Text("\(count)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        // pinned plain-list headers are transparent; rows would show through while scrolling
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .listRowInsets(EdgeInsets())
    }

    private func row(_ p: String) -> some View {
        NavigationLink(value: p) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.title(p)).font(.body.weight(.medium)).lineLimit(1)
                    if let m = store.meta(p) {
                        Text(m.snippet.isEmpty ? "Empty" : m.snippet)
                            .font(.subheadline).foregroundStyle(m.snippet.isEmpty ? .tertiary : .secondary).lineLimit(1)
                    } else {
                        // body not cached yet — a quiet placeholder, not a filename
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 140, height: 9).padding(.vertical, 4)
                    }
                }
                Spacer(minLength: 0)
                if let m = store.meta(p), m.total > 0 {
                    HStack(spacing: 5) {
                        TaskRing(done: m.done, total: m.total, size: 14)
                        Text("\(m.done)/\(m.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func create() async {
        guard let t = newTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { newTitle = nil; return }
        newTitle = nil
        do { path.append(try await store.create(title: t, in: nil)) }
        catch { store.error = error.localizedDescription }
    }
}

/// Checklist progress: a trimmed circle, filled when everything is done.
struct TaskRing: View {
    let done: Int, total: Int, size: CGFloat
    var body: some View {
        let w = max(2, size / 7)
        ZStack {
            Circle().stroke(.quaternary, lineWidth: w)
            Circle().trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                .stroke(.tint, style: StrokeStyle(lineWidth: w, lineCap: .round)).rotationEffect(.degrees(-90))
            if done == total, size > 20 { Image(systemName: "checkmark").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.tint) }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(done) of \(total) done")
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
                Section("Repository") {
                    LabeledContent("Remote", value: store.api.map { "\($0.owner)/\($0.repo)" } ?? "—")
                    LabeledContent("Branch", value: MobileStore.branch)
                    LabeledContent("Notes", value: "\(store.entries.count)")
                }
                Section {
                    TextField("This phone", text: $device)
                    SecureField("New token (blank keeps the current one)", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save") { Task { await save() } }
                } header: { Text("This phone") } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                    else { Text("The name goes on every commit this phone makes, so your Mac can say who a conflict came from.") }
                }
                Section {
                    Button("Forget this phone", role: .destructive) { confirmForget = true }
                } footer: { Text("Removes the token and every cached note from this phone. The repo is untouched.") }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
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
