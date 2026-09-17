import SwiftUI
import GitPadCore

/// Read mode by default: each line is a row, checkboxes toggle in place. Tap the text (or Edit)
/// for a plain editor over the ☐/☑ form; Done converts back to `- [ ]` and saves.
struct NoteView: View {
    @ObservedObject var store: MobileStore
    let path: String
    @State private var text = ""        // what's on screen (optimistic)
    @State private var saved = ""       // canonical markdown as last read/written
    @State private var draft = ""       // editor text (☐/☑ form)
    @State private var editing = false
    @State private var loaded = false
    @State private var saves = 0        // in-flight writes
    @State private var saveChain: Task<Void, Never>?
    @State private var error: String?
    @State private var conflict = false
    @State private var quick = ""
    @FocusState private var editorFocused: Bool

    private var isToday: Bool { path == MobileStore.dailyPath() }

    var body: some View {
        Group {
            if editing {
                TextEditor(text: $draft)
                    .font(.body).lineSpacing(5)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 15)
            } else {
                ScrollView {
                    readView.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                }
                .refreshable { await load() }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { status }
            ToolbarItem(placement: .topBarTrailing) {
                if editing { Button("Done") { finishEditing() }.fontWeight(.semibold) }
                else { Button("Edit") { startEditing() }.disabled(!loaded) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .task { await load() }
    }

    private var status: some View {
        Group {
            if saves > 0 { Label("Saving…", systemImage: "arrow.triangle.2.circlepath") }
            else if error != nil { Label("Not saved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            else if loaded { Label("Saved", systemImage: "checkmark") }
        }
        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
        .animation(.default, value: saves)
    }

    // MARK: read mode

    private var lines: [String] { text.components(separatedBy: "\n") }

    @ViewBuilder
    private var readView: some View {
        if !loaded && text.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, raw in line(raw, index: i) }
                if lines.dropFirst().allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text(isToday ? "Nothing yet. Add a line below, or tap to write." : "Nothing here yet. Tap to write.")
                        .foregroundStyle(.tertiary).padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { startEditing() } // boxes and links sit above this and win their own taps
        }
    }

    @ViewBuilder
    private func line(_ raw: String, index: Int) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix { $0 == " " || $0 == "\t" }.count) * 8
        if t.hasPrefix("# ") { rich(t.dropFirst(2)).font(.title.bold()).padding(.bottom, 10) }
        else if t.hasPrefix("## ") { rich(t.dropFirst(3)).font(.title2.weight(.semibold)).padding(.top, 18).padding(.bottom, 6) }
        else if t.hasPrefix("### ") { rich(t.dropFirst(4)).font(.headline).padding(.top, 14).padding(.bottom, 4) }
        else if t == "---" || t == "***" { Divider().padding(.vertical, 12) }
        else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") {
            let done = !t.hasPrefix("- [ ] ")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { toggle(index) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21)).foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Mark not done" : "Mark done")
                rich(t.dropFirst(6)).foregroundStyle(done ? .secondary : .primary).strikethrough(done, color: .secondary)
            }
            .padding(.leading, indent)
        }
        else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").foregroundStyle(.secondary).frame(width: 28)
                rich(t.dropFirst(2))
            }
            .padding(.leading, indent).padding(.vertical, 3)
        }
        else if t.hasPrefix("> ") {
            rich(t.dropFirst(2)).foregroundStyle(.secondary).padding(.leading, 12).padding(.vertical, 3)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        }
        else if t.isEmpty { Spacer().frame(height: 10) }
        else { rich(Substring(t)).padding(.leading, indent).padding(.vertical, 3) }
    }

    /// Inline links/bold/italic/code via Foundation's markdown parser; plain on failure.
    private func rich(_ s: Substring) -> Text {
        let str = String(s)
        return Text((try? AttributedString(markdown: str, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(str))
    }

    // MARK: bottom: banners + today's quick-entry

    @ViewBuilder
    private var bottomBar: some View {
        if (isToday && !editing) || conflict || error != nil { bottomContent }
    }

    private var bottomContent: some View {
        VStack(spacing: 8) {
            if conflict { banner(GitHubAPI.Error.conflict.localizedDescription, "arrow.triangle.branch", .orange) }
            if let error { banner(error, "wifi.exclamationmark", .red) }
            if isToday && !editing {
                HStack(spacing: 8) {
                    TextField("Add a line…", text: $quick, axis: .vertical).lineLimit(1...4)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .onSubmit(append)
                    Button(action: append) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                        .disabled(quick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Add line")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func banner(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(.footnote).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: actions

    private func load() async {
        if let cached = store.bodies[path], !loaded { text = cached.body; saved = cached.body; loaded = true } // instant
        do {
            let f = isToday ? try await store.daily() : try await store.open(path)
            if saves == 0 && !editing { text = f.body }
            saved = f.body; error = nil; loaded = true
        } catch {
            self.error = error.localizedDescription
            loaded = true
        }
    }

    /// Optimistic: the screen changes now, the commit follows. Writes queue behind each other so
    /// every PUT carries the sha the previous one produced. A failure rolls the screen back.
    private func write(_ new: String) {
        text = new
        saves += 1
        let prev = saveChain
        saveChain = Task {
            await prev?.value
            do {
                let hit = try await store.save(path, body: new, original: saved)
                saved = store.bodies[path]?.body ?? new
                if hit { conflict = true; text = saved }
                error = nil
            } catch {
                self.error = error.localizedDescription
                if saves == 1 { text = saved }
            }
            saves -= 1
        }
    }

    private func toggle(_ index: Int) {
        var l = lines
        guard l.indices.contains(index) else { return }
        if let r = l[index].range(of: "- [ ] ") { l[index].replaceSubrange(r, with: "- [x] ") }
        else if let r = l[index].range(of: "- [x] ", options: .caseInsensitive) { l[index].replaceSubrange(r, with: "- [ ] ") }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        write(l.joined(separator: "\n"))
    }

    private func startEditing() {
        guard loaded else { return }
        draft = Markdown.fromMarkdown(text)
        editing = true
        editorFocused = true
    }

    private func finishEditing() {
        editing = false
        let new = Markdown.toMarkdown(draft)
        if new != text { write(new) }
    }

    private func append() {
        let line = quick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        quick = ""
        let sep = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        write(text + sep + "- " + line + "\n")
    }
}
