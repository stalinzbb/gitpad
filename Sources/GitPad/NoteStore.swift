import Foundation
import AppKit
import GitPadCore

typealias NoteMeta = GitPadCore.NoteMeta

enum Screen { case onboarding, capture, library, settings, gitSetup, conflicts }

enum SyncStatus: Equatable {
    case unknown, noRemote, synced(Date), offline

    var label: String {
        switch self {
        case .unknown: return "—"
        case .noRemote: return "Local only — no remote set"
        case .synced(let d): return "Synced \(d.formatted(date: .omitted, time: .shortened))"
        case .offline: return "Can't reach remote — will retry"
        }
    }
}

final class NoteStore: ObservableObject {
    /// `GITPAD_DIR` points a build at a throwaway notes folder — a dev build run from the
    /// worktree shares this app's bundle id, notes dir and defaults with an installed copy,
    /// so without it every test edit lands in the real notes and syncs to the real remote.
    /// Same escape-hatch shape as `GITPAD_DEVICE_NAME` in GitSync.
    // realpath'd: /tmp and /var are symlinks, and directory enumeration hands back the
    // resolved form — a `dir` that doesn't match its own listing makes every path
    // comparison (selected-note survival in refresh, the watcher's paths) silently miss.
    // The folder itself may not exist yet (the store creates it), and realpath needs an
    // existing path — so resolve the parent, which is where /tmp and /var live anyway.
    static let defaultDir = ProcessInfo.processInfo.environment["GITPAD_DIR"].map { raw -> URL in
        let url = URL(fileURLWithPath: raw)
        guard let r = realpath(url.deletingLastPathComponent().path, nil) else { return url }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r)).appendingPathComponent(url.lastPathComponent)
    }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitPad")
    let dir = NoteStore.defaultDir

    /// The encrypted vault is unmounted: `dir` is an empty, unwritable directory and the UI
    /// shows `LockedView`. See `Vault`.
    @Published var locked = false
    /// Run a block on the app's serial sync queue — vault mount/unmount must never overlap a
    /// git process. Set by AppDelegate next to `requestSync`.
    var onSyncQueue: ((@escaping () -> Void) -> Void)?

    @Published var notes: [URL] = []
    @Published var folders: [String] = []
    @Published var selected: URL? {
        willSet {
            // Switching notes with an edit still in the 1s debounce would drop it: the work
            // item fires later and writes the new note's text over the old note's URL —
            // or gets cancelled by the reload. Flush first, while `selected`/`text` still
            // refer to the outgoing note. Same-path reassignment is a deliberate reload
            // (see resolveKeep) and must not flush.
            if newValue?.path != selected?.path, saveWork != nil { saveNow() }
        }
        didSet { loadSelected() }
    }
    @Published var text = "" {
        didSet { if !loading { scheduleSave() } }
    }
    @Published var pill = false
    @Published var screen: Screen = .capture
    // ponytail: per-Mac pins (paths relative to `dir`); move to a .pinned file in the repo if cross-Mac requested
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinned") ?? []
    /// Set by `delete`, cleared by `undoDelete` — drives the "Note deleted — Undo" banner.
    @Published var lastDeleted: (original: URL, trashed: URL, pinned: Bool)?
    private var settingsReturn: Screen = .capture

    /// Open Settings from any screen, remembering where to return.
    func openSettings() {
        if screen != .settings && screen != .gitSetup { settingsReturn = screen }
        screen = .settings
    }

    /// ⌘L: flip between the note and the library (no-op during onboarding).
    func toggleLibrary() {
        switch screen {
        case .library: screen = .capture
        case .onboarding: break
        default: screen = .library
        }
    }

    /// ⌘K: the command palette overlay (see `CommandPalette`). Rendered above every screen.
    @Published var paletteOpen = false

    /// Library with the search field focused — the palette's "Search Library" command.
    /// The counter is the signal, so it also re-focuses when the Library is already open
    /// (where `onAppear` won't fire again).
    @Published var searchRequest = 0
    func searchNotes() {
        screen = .library
        searchRequest += 1
    }

    /// One step back for Esc / the back chevron.
    func goBack() {
        switch screen {
        case .gitSetup: screen = .settings
        case .settings: screen = settingsReturn
        case .library, .conflicts: screen = .capture
        default: onHide?() // capture / onboarding: nothing above → hide
        }
    }

    var onSaved: (() -> Void)?
    var onHide: (() -> Void)?
    var requestSync: (() -> Void)?
    var setPill: ((Bool) -> Void)?
    var pillDrag: (() -> Void)?      // fires on each drag tick; AppDelegate reads the mouse
    /// Returns true if the pill was actually dragged. The gesture can't tell: the window
    /// tracks the mouse, so the cursor never moves relative to the pill and the gesture's
    /// own translation stays ~0. Only the AppDelegate sees the screen-space delta.
    var pillDragEnded: (() -> Bool)?
    var applyAppearance: ((NSAppearance.Name?) -> Void)?
    @Published var syncStatus: SyncStatus = .unknown
    @Published var syncing = false
    /// Commits waiting to move, refreshed by each background sync. Drives the status line's
    /// "1 to push" — the one fact the old word count wasn't answering.
    @Published var pending: (ahead: Int, behind: Int) = (0, 0)
    /// An edit is sitting in the 1s autosave debounce. The status line reads it as "Saving…".
    @Published var dirty = false
    /// Set by the AppDelegate's release check and by the Settings button. Drives the
    /// status-menu item and the Settings row; never pops anything over the editor.
    @Published var update: Updater.State = .none
    private var loading = false
    private var saveWork: DispatchWorkItem?
    private var titleCache: [URL: (title: String, mtime: Date)] = [:]
    // ponytail: main-thread reads; background index only if libraries hit thousands of notes
    private var contentCache: [URL: (text: String, mtime: Date)] = [:]
    private var metaCache: [URL: (meta: NoteMeta, mtime: Date)] = [:]
    private var mtimeCache: [URL: Date] = [:]
    private var lastNew = Date.distantPast
    /// mtime of `selected` as of the last load or save — i.e. the version the editor
    /// buffer was derived from. Anything else on disk got there behind our back (a sync
    /// merge, another editor), and the buffer must not be allowed to overwrite it.
    private var loadedMtime: Date = .distantPast
    private var watcher: FolderWatcher?

    init() {
        if Vault.isLocked { locked = true } else { open() }
    }

    /// First read of the notes folder — at launch, and again after every vault unlock.
    func open() {
        locked = false
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backfillDailyTitles() // before refresh()/dailyNote(): nothing is loaded yet, so no buffer to clobber
        uncacheAll()
        refresh()
        if !UserDefaults.standard.bool(forKey: "onboarded") { screen = .onboarding }
        selected = dailyNote()
        // Edits from anything else — another editor, a script, `gitpad://`, a sync merge —
        // show up within a second instead of at the next timer tick or panel open.
        watcher = FolderWatcher(dir) { [weak self] in self?.refresh() }
    }

    /// Drop every trace of note content from memory before the volume goes away.
    private func close() {
        watcher = nil // before the volume detaches: a stream on a vanished path is useless
        flushPendingSave() // still mounted here, so the write lands
        selected = nil; notes = []; folders = []; uncacheAll()
        locked = true
    }

    func lockVault() {
        guard Vault.isEnabled, !locked else { return }
        close() // its flush → onSaved → backgroundSync is queued BEFORE the detach below
        onSyncQueue? { Vault.lock() }
    }

    func unlockVault(_ passphrase: String, done: ((Bool) -> Void)? = nil) {
        unlock({ passphrase }, done: done)
    }

    /// Unlock with the saved passphrase: silent from the Keychain, or the Touch ID sheet.
    func unlockVaultStored(done: ((Bool) -> Void)? = nil) {
        unlock({ Vault.storedPassphrase }, done: done)
    }

    /// `passphrase` runs ON the queue, after the mounted check — so wake + screen-unlock firing
    /// together cost one Touch ID prompt, not two, and a pending lock can't race the mount.
    private func unlock(_ passphrase: @escaping () -> String?, done: ((Bool) -> Void)?) {
        guard Vault.isEnabled else { return }
        onSyncQueue? { [weak self] in
            let ok = Vault.isMounted || (passphrase().map { Vault.unlock(passphrase: $0) } ?? false)
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    if self.locked { self.open() }
                    self.requestSync?()
                }
                done?(ok)
            }
        }
    }

    /// Give every daily note the same date heading, derived from the FILENAME (not today)
    /// so a historical note gets its real day.
    ///
    /// Two cases get rewritten: a note with no heading at all, and one still carrying a
    /// heading an OLDER BUILD generated (`Thursday, 23 July`, `23 July` — no year). Those
    /// stale forms are re-generated from the date and compared as strings, so we only ever
    /// touch text this app wrote itself; a title the user typed can't collide by
    /// construction and is left alone. Idempotent — changed files ride out on the next sync.
    // ponytail: re-reads every Daily file each launch — tiny files; gate behind a flag if launch measurably slows.
    private func backfillDailyTitles() {
        let fm = FileManager.default
        let daily = dir.appendingPathComponent("Daily")
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        parse.locale = Locale(identifier: "en_US_POSIX") // filenames are machine-written, never localised
        // display formatters keep the current locale — that's what the old builds wrote in
        let canonical = DateFormatter(); canonical.dateFormat = "EEEE, d MMMM yyyy"
        let staleFmts: [DateFormatter] = ["EEEE, d MMMM", "d MMMM"].map {
            let df = DateFormatter(); df.dateFormat = $0; return df
        }

        for url in (try? fm.contentsOfDirectory(at: daily, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "md" {
            guard let date = parse.date(from: url.deletingPathExtension().lastPathComponent),
                  let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let want = "# " + canonical.string(from: date)
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            let firstIdx = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let first = firstIdx.map { lines[$0].trimmingCharacters(in: .whitespaces) }

            let updated: String
            if first == want {
                continue                                   // already canonical
            } else if let first, first.hasPrefix("# ") {
                let stale = staleFmts.map { "# " + $0.string(from: date) }
                guard stale.contains(first), let i = firstIdx else { continue } // user's own title
                var out = lines
                out[i] = Substring(want)
                updated = out.joined(separator: "\n")
            } else {
                updated = want + "\n\n" + body             // no heading at all → prepend one
            }
            try? updated.write(to: url, atomically: true, encoding: .utf8)
            uncache(url)
        }
    }

    func refresh() {
        let fm = FileManager.default
        var found: [URL] = []
        var dirs: [String] = []
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            var isDir: ObjCBool = false // no resourceValues here either — see stat()
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                guard item.lastPathComponent != ".git" else { continue }
                dirs.append(item.lastPathComponent)
                found += ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "md" }
            } else if item.pathExtension == "md" {
                found.append(item)
            }
        }
        folders = dirs.sorted()
        // stat once per file, not once per sort comparison; a whole rebuild also picks up
        // sync pulls and external edits that the cache would otherwise hold stale
        var stamps: [URL: Date] = [:]
        for u in found { stamps[u] = Self.stat(u) }
        mtimeCache = stamps
        notes = found.sorted { (stamps[$0] ?? .distantPast) > (stamps[$1] ?? .distantPast) }
        if let sel = selected, !notes.contains(where: { $0.path == sel.path }) { selected = notes.first }
        // A sync merge may have rewritten the open note. With nothing in the debounce the
        // buffer is just a stale copy: reload it. (A dirty buffer is handled by saveNow.)
        if let sel = selected, saveWork == nil, Self.stat(sel) != loadedMtime {
            if let raw = try? String(contentsOf: sel, encoding: .utf8), Self.fromMarkdown(raw) != text {
                loadSelected()
            } else {
                loadedMtime = Self.stat(sel) // same content, only the stamp moved
            }
        }
        // first conflict ever: show the explainer once, and only from Capture so it
        // can't yank the screen out from under someone mid-task
        if !conflicts.isEmpty, screen == .capture,
           !UserDefaults.standard.bool(forKey: "sawConflictIntro") {
            UserDefaults.standard.set(true, forKey: "sawConflictIntro")
            screen = .conflicts
        }
    }

    // MARK: folders

    func folder(of url: URL) -> String? {
        let parent = url.deletingLastPathComponent()
        return parent.path == dir.path ? nil : parent.lastPathComponent
    }

    func createFolder(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(clean),
                                                 withIntermediateDirectories: true)
        refresh()
    }

    func renameFolder(_ name: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != name else { return }
        let fm = FileManager.default
        let dst = dir.appendingPathComponent(clean)
        guard !fm.fileExists(atPath: dst.path) else { return }
        let sel = selected
        try? fm.moveItem(at: dir.appendingPathComponent(name), to: dst)
        uncacheAll()
        refresh()
        if let s = sel, s.deletingLastPathComponent().lastPathComponent == name {
            selected = dst.appendingPathComponent(s.lastPathComponent)
        }
        onSaved?()
    }

    /// Non-destructive: move the folder's notes to the root Inbox, then remove it.
    func deleteFolder(_ name: String) {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent(name)
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where item.pathExtension == "md" {
            var dest = dir.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(name + "-" + item.lastPathComponent)
            }
            try? fm.moveItem(at: item, to: dest)
        }
        try? fm.removeItem(at: folder)
        uncacheAll()
        refresh()
        onSaved?()
    }

    func move(_ url: URL, to folder: String?) {
        let dest = (folder.map { dir.appendingPathComponent($0) } ?? dir)
            .appendingPathComponent(url.lastPathComponent)
        guard dest.path != url.path else { return }
        try? FileManager.default.moveItem(at: url, to: dest)
        uncache(url)
        if let i = pinned.firstIndex(of: rel(url)) { // keep the pin pointing at the new path
            pinned[i] = rel(dest)
            UserDefaults.standard.set(pinned, forKey: "pinned")
        }
        let wasSelected = selected?.path == url.path
        refresh()
        if wasSelected { selected = dest }
        onSaved?()
    }

    // MARK: notes

    /// One note per day, kept in Daily/; ⌥Space always lands here.
    func dailyNote() -> URL {
        let daily = dir.appendingPathComponent("Daily")
        try? FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd"
        let url = daily.appendingPathComponent(name.string(from: Date()) + ".md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = DateFormatter()
            header.dateFormat = "EEEE, d MMMM yyyy" // fixed, date-based title (full date for the day it's created)
            try? "# \(header.string(from: Date()))\n\n"
                .write(to: url, atomically: true, encoding: .utf8)
            refresh()
        }
        return url
    }

    /// Create a new note in `folder` (nil = Inbox / repo root). ⌘N passes nil; the
    /// Library's New Note button passes the folder you're browsing.
    @discardableResult
    func newNote(in folder: String? = nil) -> URL {
        // ⌘N reaches here from the main menu even while the lock screen is up. The write
        // would vanish into the mode-500 mountpoint and leave `selected` on a file that
        // doesn't exist; callers ignore the value while locked (the editor is hidden).
        if locked { return selected ?? dir }
        // debounce: reuse a still-empty scratch note *in the same folder*, or ignore rapid presses
        if let sel = selected, sel.lastPathComponent.hasPrefix("note-"),
           self.folder(of: sel) == folder,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            screen = .capture
            return sel
        }
        if Date().timeIntervalSince(lastNew) < 0.7, let sel = selected { return sel }
        lastNew = Date()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = folder.map { dir.appendingPathComponent($0) } ?? dir
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("note-\(stamp).md")
        try? "# ".write(to: url, atomically: true, encoding: .utf8) // start typing the title
        refresh()
        selected = url
        screen = .capture
        return url
    }

    func open(_ url: URL) {
        guard !locked else { return } // status-menu Recent: nothing to load from a detached volume
        selected = url
        screen = .capture
    }

    /// Select today's note, but never re-select it if it's already open: reassigning
    /// `selected` re-reads from disk, which throws away whatever is in the editor buffer
    /// (⌥Space lands here, and it fires far more often than the note actually changes).
    func selectDaily() {
        guard !locked else { return } // ⌥Space while locked: the lock screen is showing, don't create a phantom
        let daily = dailyNote()
        if selected?.path != daily.path { selected = daily }
    }

    /// Append text to today's note — used by the clipboard menu item and
    /// `gitpad://daily?append=`. If the daily note is open, append into the live
    /// editor buffer so in-flight edits aren't clobbered.
    func appendToDaily(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !locked else { return } // locked: the write would silently vanish
        let url = dailyNote()
        if selected?.path == url.path {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += trimmed + "\n"
            saveNow()
        } else {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try? (existing + sep + trimmed + "\n").write(to: url, atomically: true, encoding: .utf8)
            uncache(url)
            onSaved?()
            refresh()
        }
    }

    // MARK: pinning

    private func rel(_ url: URL) -> String {
        url.path.hasPrefix(dir.path + "/") ? String(url.path.dropFirst(dir.path.count + 1)) : url.lastPathComponent
    }

    func isPinned(_ url: URL) -> Bool { pinned.contains(rel(url)) }

    func togglePin(_ url: URL) {
        let r = rel(url)
        if let i = pinned.firstIndex(of: r) { pinned.remove(at: i) } else { pinned.append(r) }
        UserDefaults.standard.set(pinned, forKey: "pinned")
    }

    /// Currently-pinned notes that still exist, in pin order.
    func pinnedNotes() -> [URL] {
        pinned.compactMap { r in
            let u = dir.appendingPathComponent(r)
            return notes.contains { $0.path == u.path } ? u : nil
        }
    }

    /// Delete = move to the macOS Trash (already recoverable), and remember where it went
    /// so `undoDelete()` can put it straight back. That's why there's no confirmation
    /// dialog: the slip to protect against is an accidental ⌘⌫, and undo covers it
    /// without taxing every intentional delete.
    func delete(_ url: URL) {
        let wasPinned = isPinned(url)
        var trashed: NSURL?
        try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        if let t = trashed as URL? { lastDeleted = (original: url, trashed: t, pinned: wasPinned) }
        if wasPinned { togglePin(url) } // drop the stale pin; undo restores it
        uncache(url)
        refresh()
    }

    /// Put the last trashed note back where it came from.
    func undoDelete() {
        guard let d = lastDeleted, !locked else { return } // keep lastDeleted: undo still works after unlock
        lastDeleted = nil
        let parent = d.original.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard (try? FileManager.default.moveItem(at: d.trashed, to: d.original)) != nil else { return }
        if d.pinned, !isPinned(d.original) { togglePin(d.original) }
        refresh()
        selected = d.original
        screen = .capture
        onSaved?() // commit the restore
    }

    // MARK: conflict copies (created by GitSync when both machines edit the same note)

    var conflicts: [URL] {
        notes.filter { $0.lastPathComponent.contains(" (conflict ") }
    }

    /// "…(conflict from Studio 2026-07-23 1200).md" → "Studio". Copies written by
    /// older builds have no device in the name, hence the fallback.
    func conflictDevice(_ conflictCopy: URL) -> String {
        let name = conflictCopy.deletingPathExtension().lastPathComponent
        guard let tail = name.components(separatedBy: " (conflict from ").dropFirst().first
        else { return "another device" }
        let parts = tail.split(separator: " ") // <device…> yyyy-MM-dd HHmm)
        let device = parts.dropLast(2).joined(separator: " ")
        return device.isEmpty ? "another device" : device
    }

    /// Lines that exist on only one side of a conflict pair, by index. Classic LCS table.
    /// ponytail: O(n·m) memory and time — notes are hundreds of lines, not hundreds of
    /// thousands; switch to Myers if a diff ever takes visible time.
    static func uniqueLines(_ a: [String], _ b: [String]) -> (a: Set<Int>, b: Set<Int>) {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ua = Set<Int>(), ub = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { ua.insert(i); i += 1 }
            else { ub.insert(j); j += 1 }
        }
        while i < n { ua.insert(i); i += 1 }
        while j < m { ub.insert(j); j += 1 }
        return (ua, ub)
    }

    func original(for conflictCopy: URL) -> URL? {
        guard let base = conflictCopy.lastPathComponent.components(separatedBy: " (conflict ").first
        else { return nil }
        let url = conflictCopy.deletingLastPathComponent().appendingPathComponent(base + ".md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Replace the original note with the conflict copy's content, then remove the copy.
    func resolveKeep(_ conflictCopy: URL) {
        guard let orig = original(for: conflictCopy),
              let content = try? String(contentsOf: conflictCopy, encoding: .utf8) else {
            delete(conflictCopy)
            return
        }
        try? content.write(to: orig, atomically: true, encoding: .utf8)
        uncache(orig) // the original's body just changed — every cached read of it is stale
        if selected?.path == orig.path { selected = orig } // reload
        delete(conflictCopy)
        onSaved?()
    }

    /// Keep the original; trash the conflict copy.
    func resolveDiscard(_ conflictCopy: URL) {
        delete(conflictCopy)
        onSaved?()
    }

    /// Keep both versions: rename the copy so it stops reading as a conflict.
    func resolveKeepBoth(_ conflictCopy: URL) {
        let fm = FileManager.default
        let base = conflictCopy.deletingPathExtension().lastPathComponent
            .components(separatedBy: " (conflict").first ?? "note"
        let folder = conflictCopy.deletingLastPathComponent()
        var dest = folder.appendingPathComponent("\(base) (from \(conflictDevice(conflictCopy))).md")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) (from \(conflictDevice(conflictCopy)) \(n)).md")
            n += 1
        }
        try? fm.moveItem(at: conflictCopy, to: dest)
        uncache(conflictCopy)
        refresh()
        onSaved?()
    }

    func deleteCurrent() {
        if let sel = selected { delete(sel) }
        selected = dailyNote()
    }

    func title(for url: URL) -> String {
        let mt = modified(url)
        if let cached = titleCache[url], cached.mtime == mt { return cached.title }
        let title = Markdown.title(of: (try? String(contentsOf: url, encoding: .utf8)) ?? "",
                                   fallback: url.deletingPathExtension().lastPathComponent)
        titleCache[url] = (title, mt)
        return title
    }

    /// Library row data: first body line + checklist tally, mtime-validated like
    /// `titleCache` (one read on a miss, none while the file is unchanged).
    func meta(for url: URL) -> NoteMeta {
        let mt = modified(url)
        if let c = metaCache[url], c.mtime == mt { return c.meta }
        let m = Self.parseMeta((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        metaCache[url] = (m, mt)
        return m
    }

    static func parseMeta(_ body: String) -> NoteMeta { Markdown.parseMeta(body) }

    /// Drop every cached read of `url` — call wherever a file moves or is rewritten.
    private func uncache(_ url: URL) {
        titleCache[url] = nil; contentCache[url] = nil; metaCache[url] = nil; mtimeCache[url] = nil
    }

    private func uncacheAll() {
        titleCache.removeAll(); contentCache.removeAll(); metaCache.removeAll(); mtimeCache.removeAll()
    }

    static func fold(_ s: String) -> String { Markdown.fold(s) }

    /// Smart-lite search: split the query on whitespace and keep a note only if EVERY token
    /// hits its title or its body — so "groc milk" finds the note titled "Groceries" that
    /// mentions milk. Results rank title matches above body-only ones; within a tier the
    /// caller's mtime order survives.
    func matches(_ query: String) -> [URL] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return notes }
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return notes }

        var ranked: [(url: URL, tier: Int)] = []
        for url in notes {
            let t = Self.fold(title(for: url))
            if tokens.allSatisfy({ t.contains($0) }) {
                ranked.append((url, t.contains(q) ? 0 : 1)) // whole phrase in title beats scattered tokens
            } else {
                // a 1-char token is too noisy to run against whole bodies (the original guard)
                let body = content(of: url)
                guard tokens.allSatisfy({ t.contains($0) || ($0.count >= 2 && body.contains($0)) })
                else { continue }
                ranked.append((url, 2))
            }
        }
        // pair with the original index so equal tiers keep `notes` order (sorted isn't stable)
        return ranked.enumerated()
            .sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }
            .map(\.element.url)
    }

    /// Folded file body, mtime-validated (mirrors `titleCache`) so search
    /// doesn't re-read every file on each keystroke.
    /// `[[Title]]` target: the note whose H1 folds to `title`, opened; or a fresh note with
    /// that title (the wiki convention: a link to nothing is a note waiting to be written).
    func openNote(titled title: String) {
        let want = Self.fold(title.trimmingCharacters(in: .whitespaces))
        guard !want.isEmpty, !locked else { return }
        if let hit = notes.first(where: { Self.fold(self.title(for: $0)) == want }) {
            open(hit)
            return
        }
        newNote()
        text = "# \(title.trimmingCharacters(in: .whitespaces))\n\n"
    }

    /// Notes whose body links to `url` as `[[its title]]`. Folded on both sides, so case and
    /// accents don't matter. ponytail: linear scan over the folded content cache — the same
    /// cost as one search keystroke; index it if libraries reach thousands of notes.
    func backlinks(to url: URL) -> [URL] {
        let t = Self.fold(title(for: url))
        guard !t.isEmpty else { return [] }
        let needle = "[[" + t + "]]"
        return notes.filter { $0.path != url.path && content(of: $0).contains(needle) }
    }

    private func content(of url: URL) -> String {
        let mt = modified(url)
        if let c = contentCache[url], c.mtime == mt { return c.text }
        let text = Self.fold((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        contentCache[url] = (text, mt)
        return text
    }

    /// Stat once, then serve from memory. `refresh()`'s sort and every Library render call
    /// this dozens of times per pass, and it also gates the title/content/meta caches.
    // ponytail: an external edit stays stale until the next refresh(), which re-stats everything.
    func modified(_ url: URL) -> Date {
        if let d = mtimeCache[url] { return d }
        let d = Self.stat(url)
        mtimeCache[url] = d
        return d
    }

    /// attributesOfItem, not `url.resourceValues`: Foundation caches resource values per URL
    /// value, so back-to-back writes to one path read the same mtime for the rest of the
    /// run-loop pass — which hid a sync merge from the buffer-overwrite guard in saveNow.
    private static func stat(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: load/save — files keep standard markdown; the editor shows ☐/☑ glyphs

    static func fromMarkdown(_ s: String) -> String { Markdown.fromMarkdown(s) }
    static func toMarkdown(_ s: String) -> String { Markdown.toMarkdown(s) }

    private func loadSelected() {
        loading = true
        let raw = selected.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        text = Self.fromMarkdown(raw)
        loadedMtime = selected.map(Self.stat) ?? .distantPast
        loading = false
    }

    private func scheduleSave() {
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Write a still-debounced edit right now. `saveWork` is private, so a caller about to
    /// end the process (quit, or the updater's relaunch) has no other way to ask whether
    /// typing is sitting in the 1s window — and that window used to be dropped on the floor.
    func flushPendingSave() {
        if saveWork != nil { saveNow() }
    }

    func saveNow() {
        saveWork?.cancel() // any pending debounce is now redundant (no-op if this IS it)
        saveWork = nil
        dirty = false
        guard let url = selected else { return }
        let out = Self.toMarkdown(text)
        var wroteCopy = false
        // The file changed underneath the buffer (a sync merge landed while typing). Both
        // versions are real edits, so keep the other one as a conflict copy — the same
        // shape GitSync writes — instead of silently overwriting it. Before this check,
        // one keystroke after a clean merge erased the other Mac's edit for good.
        if Self.stat(url) != loadedMtime,
           let disk = try? String(contentsOf: url, encoding: .utf8), disk != out {
            let copy = url.deletingLastPathComponent().appendingPathComponent(
                Markdown.conflictCopyName(url.lastPathComponent, device: "another device", date: Date()))
            try? disk.write(to: copy, atomically: true, encoding: .utf8)
            wroteCopy = true
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
        loadedMtime = Self.stat(url)
        uncache(url) // body changed → search/snippet re-read next time
        if wroteCopy { refresh() } // the copy shows up in the library (and Conflicts) now, not next sync
        onSaved?()
    }
}

/// One FSEvents stream on the notes folder → one `refresh()` per batch of changes.
/// FSEvents, not a kqueue on the directory: kqueue only sees the folder's own entries,
/// and edits to a note's *contents* (or anything in a subfolder) never reach it.
///
/// Events under `.git/` are dropped: a sync writes there constantly and none of it
/// changes what the library shows — the sync's own completion already refreshes.
/// ponytail: no per-path bookkeeping, refresh re-stats everything; fine at hundreds of
/// notes, revisit if the library ever holds tens of thousands.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(_ dir: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // UseCFTypes below: `paths` is a CFArray of CFString, not a char**.
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) {
                me.onChange()
            }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [dir.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                                                   | kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }
        FSEventStreamSetDispatchQueue(s, .main) // refresh() is main-thread state
        FSEventStreamStart(s)
        stream = s
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
