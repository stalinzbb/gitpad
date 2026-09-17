import Foundation

/// What a Library row needs beyond the title: a preview line and the checklist tally.
public struct NoteMeta {
    public var snippet = ""
    public var done = 0
    public var total = 0
    public init() {}
}

/// Pure, Foundation-only helpers shared by the Mac app and the iOS companion. Anything
/// that decides what a note *looks like on disk* lives here so both ends agree.
public enum Markdown {
    /// First line minus `#` and whitespace; `fallback` (the filename) when the note is untitled.
    public static func title(of body: String, fallback: String) -> String {
        let first = body.split(separator: "\n").first.map(String.init) ?? ""
        let clean = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return clean.isEmpty ? fallback : clean
    }

    /// Pure so `GitPad --selftest` can check it without touching the notes directory.
    public static func parseMeta(_ body: String) -> NoteMeta {
        var m = NoteMeta()
        for raw in body.split(separator: "\n").dropFirst() { // first non-empty line is the title
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- [x] ") { m.done += 1; m.total += 1 }
            else if line.hasPrefix("- [ ] ") { m.total += 1 }
            guard m.snippet.isEmpty else { continue }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#-*+> "))
            if line.hasPrefix("[x] ") || line.hasPrefix("[ ] ") { line.removeFirst(4) }
            if !line.isEmpty { m.snippet = line }
        }
        return m
    }

    /// Case- and diacritic-insensitive, so "cafe" finds "Café" and "Cafe".
    public static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    // MARK: files keep standard markdown; the editors show ☐/☑ glyphs

    public static func fromMarkdown(_ s: String) -> String {
        // tolerant on read (`* [X]` from other editors); toMarkdown writes canonical `- [ ]`/`- [x]`
        s.replacingOccurrences(of: #"(?m)^(\s*)[-*+] \[ \] "#, with: "$1☐ ", options: .regularExpression)
         .replacingOccurrences(of: #"(?m)^(\s*)[-*+] \[[xX]\] "#, with: "$1☑ ", options: .regularExpression)
    }

    public static func toMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?m)^(\s*)☐ "#, with: "$1- [ ] ", options: .regularExpression)
         .replacingOccurrences(of: #"(?m)^(\s*)☑ "#, with: "$1- [x] ", options: .regularExpression)
    }

    /// "Inbox/a.md" → "Inbox/a (conflict from iPhone 2026-09-12 1030).md". The one shape
    /// every writer (Mac sync, Mac autosave, phone) uses, so `conflictDevice` parses them all.
    public static func conflictCopyName(_ file: String, device: String, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let base = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        return base + " (conflict from \(device) \(f.string(from: date))).md"
    }

    /// GitHub owner/repo from the remote shapes git accepts:
    /// `git@github.com:o/r.git`, `https://github.com/o/r(.git)`, `ssh://git@github.com/o/r`.
    public static func parseRemote(_ url: String) -> (owner: String, repo: String)? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let host = "github.com"
        guard let r = s.range(of: host) else { return nil }
        let before = s[..<r.lowerBound]
        guard before.isEmpty || before.hasSuffix("@") || before.hasSuffix("://") || before.hasSuffix("://git@") else { return nil }
        var path = s[r.upperBound...]
        guard let sep = path.first, sep == ":" || sep == "/" else { return nil }
        path.removeFirst()
        let parts = path.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}
