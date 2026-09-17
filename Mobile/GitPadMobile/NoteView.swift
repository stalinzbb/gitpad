import SwiftUI
import GitPadCore

/// Read mode by default: each line is a row, checkboxes toggle in place. Edit is a plain
/// TextEditor over the ☐/☑ form; Done converts back to `- [ ]` and saves.
struct NoteView: View {
    @ObservedObject var store: MobileStore
    let path: String
    @State private var body_ = ""       // canonical markdown as last read/saved
    @State private var draft = ""       // editor text (☐/☑ form)
    @State private var editing = false
    @State private var busy = false
    @State private var error: String?
    @State private var conflict = false
    @State private var quick = ""

    private var isDaily: Bool { path.hasPrefix("Daily/") }

    var body: some View {
        Group {
            if editing {
                TextEditor(text: $draft).font(.body.monospaced()).padding(.horizontal, 8)
            } else {
                ScrollView { readView.padding() }
            }
        }
        .navigationTitle(Markdown.title(of: body_, fallback: "")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy { ProgressView() }
                else if editing { Button("Done") { Task { await finishEditing() } } }
                else { Button("Edit") { draft = Markdown.fromMarkdown(body_); editing = true } }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: read mode

    private var readView: some View {
        VStack(alignment: .leading, spacing: 6) {
            let lines = body_.components(separatedBy: "\n")
            ForEach(Array(lines.enumerated()), id: \.offset) { i, raw in
                line(raw, index: i)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ raw: String, index: Int) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix { $0 == " " }.count) * 4
        if t.hasPrefix("# ") { rich(String(t.dropFirst(2))).font(.title2.bold()) }
        else if t.hasPrefix("## ") { rich(String(t.dropFirst(3))).font(.title3.bold()).padding(.top, 4) }
        else if t.hasPrefix("### ") { rich(String(t.dropFirst(4))).font(.headline).padding(.top, 2) }
        else if t == "---" { Divider() }
        else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") {
            let done = t.hasPrefix("- [x] ")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { Task { await toggle(index) } } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square").font(.title3)
                }.buttonStyle(.plain).disabled(busy)
                rich(String(t.dropFirst(6))).foregroundStyle(done ? .secondary : .primary).strikethrough(done)
            }.padding(.leading, indent)
        }
        else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); rich(String(t.dropFirst(2))) }.padding(.leading, indent)
        }
        else if t.isEmpty { Spacer().frame(height: 4) }
        else { rich(t).padding(.leading, indent) }
    }

    /// Inline links/bold/italic/code via Foundation's markdown parser; plain on failure.
    private func rich(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    // MARK: bottom: daily quick-entry or status

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 4) {
            if conflict { Text(GitHubAPI.Error.conflict.localizedDescription).font(.footnote).foregroundStyle(.orange) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if isDaily && !editing {
                HStack {
                    TextField("Add a line…", text: $quick).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await append() } }
                    Button("Add") { Task { await append() } }.disabled(quick.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, conflict || error != nil || isDaily ? 8 : 0)
        .frame(maxWidth: .infinity).background(.bar)
    }

    // MARK: actions

    private func load() async {
        do {
            let f = isDaily && path == MobileStore.dailyPath() ? try await store.daily() : try await store.open(path)
            body_ = f.body; error = nil
        } catch {
            if let cached = store.bodies[path] { body_ = cached.body }
            self.error = error.localizedDescription
        }
    }

    private func write(_ new: String) async {
        busy = true; defer { busy = false }
        do {
            conflict = try await store.save(path, body: new, original: body_)
            body_ = store.bodies[path]?.body ?? new
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func toggle(_ index: Int) async {
        var lines = body_.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return }
        let l = lines[index]
        if let r = l.range(of: "- [ ] ") { lines[index].replaceSubrange(r, with: "- [x] ") }
        else if let r = l.range(of: "- [x] ") { lines[index].replaceSubrange(r, with: "- [ ] ") }
        await write(lines.joined(separator: "\n"))
    }

    private func finishEditing() async {
        editing = false
        let new = Markdown.toMarkdown(draft)
        if new != body_ { await write(new) }
    }

    private func append() async {
        let line = quick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        quick = ""
        let sep = body_.isEmpty || body_.hasSuffix("\n") ? "" : "\n"
        await write(body_ + sep + "- " + line + "\n")
    }
}
