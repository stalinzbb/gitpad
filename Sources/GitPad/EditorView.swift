import ServiceManagement
import SwiftUI
import AppKit
import Carbon.HIToolbox // kVK_Escape for the hotkey recorder

// MARK: - Root switcher

struct EditorView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("theme") private var themeID = "System"

    private var theme: Theme { Theme.named(themeID) }

    var body: some View {
        ZStack {
            GlassBackground()
            // the contrast floor: content always sits on the theme's own surface
            Rectangle().fill(theme.surface).opacity(PanelSurface.opacity).allowsHitTesting(false)
            Group {
                if store.pill {
                    PillView(store: store)
                } else {
                    screens
                }
            }
            if !store.pill, store.lastDeleted != nil {
                UndoDeleteBanner(store: store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !store.pill, store.paletteOpen, store.screen != .onboarding, !store.locked {
                CommandPalette(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(Motion.quick, value: store.lastDeleted?.original)
        .animation(Motion.quick, value: store.paletteOpen)
        // Every `.secondary` / `.tertiary` below resolves against these levels. The system greys
        // are tuned for white/black and fall to ~3:1 on Sepia and Solarized paper; 62% ink
        // clears AA (4.5:1) on every preset, 50% clears 3:1 for marks. System keeps the OS's.
        .foregroundStyle(.primary, theme.secondaryInk, theme.tertiaryInk)
        .tint(theme.accentSwift) // buttons/toggles/sliders/selection take the theme accent
        // The one reactive design value. `.tint` can't carry it: it never reaches
        // `Color.accentColor`, which is why themed panels used to select in system blue.
        .environment(\.theme, theme)
        .overlay( // hairline edge; material below dims itself when the window loses key
            RoundedRectangle(cornerRadius: store.pill ? Radius.pill : Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(Alpha.strokeFaint), lineWidth: 1)
                // match applyPill's curve, or the hairline snaps to its new radius while
                // the window is still growing
                .animation(Motion.pillFrame, value: store.pill)
        )
        .frame(minWidth: store.pill ? 0 : 280, minHeight: store.pill ? 0 : 180)
        .onAppear { store.applyAppearance?(theme.appearance) }
        .onChange(of: themeID) { _ in store.applyAppearance?(theme.appearance) }
    }

    @ViewBuilder private var screens: some View {
        Group {
            // One `if`, not a Screen case: a `.locked` case would need a guard at every
            // `screen = .capture` site. The vault has nothing to route.
            if store.locked {
                LockedView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
            switch store.screen {
            case .onboarding:
                OnboardingView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .capture:
                CaptureView(store: store)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            case .library:
                LibraryView(store: store)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            case .settings:
                SettingsView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .gitSetup:
                GitSetupView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .conflicts:
                ConflictView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            }
        }
        .animation(Motion.screen, value: store.screen)
        .animation(Motion.screen, value: store.locked)
    }
}

// MARK: - Shared navigation chrome

/// One header for every screen: [left] · [center title/context] · [right].
/// chevron.left always means "back one level"; xmark only appears on Capture.
struct NavBar<L: View, C: View, R: View>: View {
    @ViewBuilder var left: () -> L
    @ViewBuilder var center: () -> C
    @ViewBuilder var right: () -> R

    var body: some View {
        ZStack {
            center()
            HStack { left(); Spacer(); right() }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        // 8pt: the icon containers carry their own inset, so the glyphs still land
        // on the same optical margin as the body text.
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
    }
}

/// "Note deleted — Undo", bottom-anchored, self-dismissing. The delete already went to
/// the Trash; this just makes the slip one click to reverse instead of a Finder trip.
struct UndoDeleteBanner: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text("Note deleted").font(.callout)
                Spacer(minLength: 0)
                Button("Undo") { store.undoDelete() }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .floatingCard()
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .task(id: store.lastDeleted?.original) { // restarts the timer for each new delete
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            store.lastDeleted = nil
        }
    }
}

/// One palette entry. A static array, not menu-derived: half these commands
/// (Sync Now, Set Up Sync, Reveal in Finder) live in the status menu or no menu at all.
/// `group` is the section header the row sits under, in array order.
struct PaletteCommand {
    let group: String
    let title: String
    let symbol: String
    var keys: String = ""
    let run: () -> Void
}

/// ⌘K: one field over every command plus note search, floating above whatever screen
/// is showing. Enter runs the highlighted row; Esc (or the scrim) closes.
struct CommandPalette: View {
    @ObservedObject var store: NoteStore
    @State private var query = ""
    @State private var index = 0
    /// Hover highlights, but never moves the keyboard selection. Letting it drive `index`
    /// is the usual palette bug: the pointer sits still, ↓ scrolls a different row under
    /// it, that row fires onHover and steals the selection back.
    @State private var hovered: Int?
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    /// Commands index into `commands`; notes carry their URL.
    private enum Item {
        case cmd(Int)
        case note(URL)
    }

    private var commands: [PaletteCommand] {
        var c: [PaletteCommand] = [
            PaletteCommand(group: "Notes", title: "New Note",
                           symbol: ChromeGlyph.newNote, keys: "⌘N") { store.newNote() },
            PaletteCommand(group: "Notes", title: "Open Daily Note",
                           symbol: "calendar") { store.open(store.dailyNote()) },
            PaletteCommand(group: "Notes", title: "Append Clipboard to Daily",
                           symbol: "doc.on.clipboard") {
                guard let clip = NSPasteboard.general.string(forType: .string),
                      !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                store.open(store.dailyNote())
                store.appendToDaily(clip)
            },
            PaletteCommand(group: "Notes", title: "Delete Note",
                           symbol: "trash", keys: "⌘⌫") { store.deleteCurrent() },
        ]
        if store.lastDeleted != nil {
            c.append(PaletteCommand(group: "Notes", title: "Undo Delete",
                                    symbol: "arrow.uturn.backward") { store.undoDelete() })
        }
        c += [
            // ⌘L is a toggle, so name it for where it actually goes from here
            PaletteCommand(group: "Go", title: store.screen == .library ? "Back to Note" : "Library",
                           symbol: store.screen == .library ? ChromeGlyph.back : ChromeGlyph.library,
                           keys: "⌘L") { store.toggleLibrary() },
            PaletteCommand(group: "Go", title: "Search Library",
                           symbol: "magnifyingglass") { store.searchNotes() },
            PaletteCommand(group: "Go", title: "Settings",
                           symbol: ChromeGlyph.settings, keys: "⌘,") { store.openSettings() },
            PaletteCommand(group: "Go", title: "Reveal Notes in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.dir])
            },
            PaletteCommand(group: "Sync", title: "Save & Sync",
                           symbol: "square.and.arrow.down", keys: "⌘S") { store.saveNow() },
            PaletteCommand(group: "Sync", title: "Sync Now",
                           symbol: "arrow.clockwise") { store.requestSync?() },
            PaletteCommand(group: "Sync", title: "Set Up Sync",
                           symbol: "arrow.triangle.branch") { store.screen = .gitSetup },
            PaletteCommand(group: "Window", title: "Minimize to Pill",
                           symbol: ChromeGlyph.minimize, keys: "⌘M") { store.setPill?(true) },
        ]
        return c
    }

    /// Commands first, then notes. Notes reuse the Library's own ranking verbatim.
    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cmds: [Int]
        if q.isEmpty {
            cmds = Array(commands.indices)
        } else {
            let tokens = NoteStore.fold(q).split(whereSeparator: \.isWhitespace).map(String.init)
            let all = commands
            cmds = all.indices.filter { i in
                let t = NoteStore.fold(all[i].title)
                return tokens.allSatisfy { t.contains($0) }
            }
        }
        let notes = q.isEmpty ? Array(store.notes.prefix(5)) : Array(store.matches(q).prefix(8))
        return cmds.map(Item.cmd) + notes.map(Item.note)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(Alpha.scrim)
                .onTapGesture { store.paletteOpen = false }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    TextField("Run a command or find a note…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(runSelected)
                        .onExitCommand { store.paletteOpen = false } // beats PanelWindow.cancelOperation
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                SoftDivider()
                list
            }
            .floatingCard()
            .padding(.horizontal, 12).padding(.top, 44)
        }
        .onAppear {
            focused = true
            // The focused text field's field editor swallows ↑/↓, so `.onMoveCommand`
            // never fires. Same local-monitor trick as HotkeyRecorder, scoped to the
            // palette's lifetime — everything else passes straight through.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch Int(event.keyCode) {
                case kVK_UpArrow: move(-1); return nil
                case kVK_DownArrow: move(1); return nil
                default: return event
                }
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
        .onChange(of: query) { _ in index = 0 }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let rows = items
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows.indices, id: \.self) { i in
                        separator(before: i, in: rows)
                        row(rows[i], i)
                    }
                }
                .padding(6)
                .background(LeanScrollbar()) // inside the content → enclosingScrollView hits
            }
            .frame(maxHeight: 380)
            // nil anchor = scroll the minimum to reveal the row. `.center` re-centred on
            // every keypress, so the first ↓ yanked the whole list down to centre row 1.
            .onChange(of: index) { proxy.scrollTo($0) }
        }
    }

    /// What goes above a row when its group changes: a hairline between command groups
    /// (they're self-evident — labelling four of them just adds furniture), and a real
    /// header for the notes, which do need saying. Emitted inline so `index` keeps
    /// addressing selectable rows only.
    @ViewBuilder private func separator(before i: Int, in rows: [Item]) -> some View {
        let isNote: Bool = { if case .note = rows[i] { return true }; return false }()
        if i == 0 || group(rows[i]) != group(rows[i - 1]) {
            if isNote {
                SectionLabel(text: group(rows[i]))
                    .padding(.horizontal, 8)
                    .padding(.top, i == 0 ? 2 : 9).padding(.bottom, 3)
            } else if i > 0 {
                // an explicit hairline: Divider at 0.4 all but vanished on the material.
                // -6 cancels the list's own inset so it runs edge to edge of the card.
                Rectangle().fill(Color.primary.opacity(Alpha.cardDivider))
                    .frame(height: 1)
                    .padding(.horizontal, -6).padding(.vertical, 8)
            }
        }
    }

    private func row(_ item: Item, _ i: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(item))
                .font(Fonts.chromeGlyph) // same glyph weight as the chrome
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label(item)).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            if case .cmd(let c) = item, !commands[c].keys.isEmpty {
                Chip(text: commands[c].keys)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        // hover is its own, lighter state — it deliberately does NOT move `index`
        // (see the note on `hovered`), so the two can show at once
        .rowBackground(selected: i == index, hovering: hovered == i)
        .onHover { inside in
            if inside { hovered = i } else if hovered == i { hovered = nil }
        }
        .animation(Motion.quick, value: hovered)
        .onTapGesture { run(item) }
        .id(i)
    }

    private func label(_ item: Item) -> String {
        switch item {
        case .cmd(let i): return commands[i].title
        case .note(let url): return store.title(for: url)
        }
    }

    private func symbol(_ item: Item) -> String {
        switch item {
        case .cmd(let i): return commands[i].symbol
        case .note: return "doc.text"
        }
    }

    private func group(_ item: Item) -> String {
        switch item {
        case .cmd(let i): return commands[i].group
        case .note: return query.trimmingCharacters(in: .whitespaces).isEmpty ? "Recent" : "Matches"
        }
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        index = min(max(0, index + delta), count - 1)
    }

    private func runSelected() {
        let rows = items
        guard rows.indices.contains(index) else { return }
        run(rows[index])
    }

    private func run(_ item: Item) {
        store.paletteOpen = false
        switch item {
        case .cmd(let i): commands[i].run()
        case .note(let url): store.open(url)
        }
    }
}

/// Standard header: a screen-specific left slot + the persistent right cluster
/// (Settings · Minimize · Close) available on every screen.
struct ChromeBar<L: View>: View {
    @ObservedObject var store: NoteStore
    let title: String
    var subtitle: String? = nil
    var showSettings: Bool = true
    var showSyncDot: Bool = true
    @ViewBuilder var left: () -> L

    var body: some View {
        NavBar {
            left()
        } center: {
            NavCenter(store: store, title: title, subtitle: subtitle, showSyncDot: showSyncDot)
        } right: {
            HStack(spacing: 2) {
                if !store.conflicts.isEmpty && store.screen != .conflicts {
                    ChromeIcon(symbol: ChromeGlyph.conflict, help: "Two Macs edited the same note — review",
                               tint: .orange) { store.screen = .conflicts }
                }
                if showSettings {
                    ChromeIcon(symbol: ChromeGlyph.settings, help: "Settings (⌘,)") { store.openSettings() }
                }
                ChromeIcon(symbol: ChromeGlyph.minimize, help: "Minimize to pill (⌘M)") { store.setPill?(true) }
                ChromeIcon(symbol: ChromeGlyph.close, help: "Close (Esc)") { store.onHide?() }
            }
        }
        // double-click-to-minimize lives in PanelWindow.mouseDown (see the note there)
    }
}

/// Center slot: title with the ambient sync dot in the subtitle line.
struct NavCenter: View {
    @ObservedObject var store: NoteStore
    let title: String
    var subtitle: String? = nil
    var showSyncDot: Bool = true

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                if showSyncDot { SyncDot(status: store.syncStatus) }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if Updater.isDevBuild { DevTag() }
            }
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 200)
        .allowsHitTesting(false)
    }
}

/// The panel-side twin of the menu bar's "dev": a locally built copy looks exactly like
/// the release otherwise (same name, same bundle id, same icon).
struct DevTag: View {
    var body: some View {
        Text("DEV")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.statusWarn.opacity(Alpha.iconHover), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Development build")
    }
}

/// Collapsed UI: a lozenge. Double-click the body to expand (or ⌥Space, or one click on
/// the expand glyph); drag it to move — mirroring the header, where a double-click and the
/// minimize glyph both collapse. One DragGesture serves body-tap and drag: a near-zero move
/// on release is a tap, and two taps inside the system double-click interval expand. That
/// can't live in `PanelWindow.mouseDown` like the header's does — the pill's gesture covers
/// the whole window and swallows the event first. A single tap only arms, so there's no delay.
struct PillView: View {
    @ObservedObject var store: NoteStore
    @State private var lastTap = Date.distantPast
    @State private var expandHover = false

    var body: some View {
        HStack(spacing: 8) {
            SyncDot(status: store.syncStatus)
            Text(store.selected.map { store.title(for: $0) } ?? "GitPad")
                .font(.footnote.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            // A real control, not just a hint: ONE click expands, the way the header's
            // minimize glyph collapses in one. highPriorityGesture so it beats the
            // pill-wide drag below, which would otherwise demand a double-click here too.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(expandHover ? Color.iconHoverBg : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .contentShape(Rectangle())
                .onHover { expandHover = $0 }
                .animation(Motion.quick, value: expandHover)
                .highPriorityGesture(TapGesture().onEnded { store.setPill?(false) })
                .help("Expand")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in store.pillDrag?() }
                .onEnded { _ in
                    // moved? that was a reposition, and it never counts toward a double-click
                    guard store.pillDragEnded?() != true else { lastTap = .distantPast; return }
                    let now = Date()
                    if now.timeIntervalSince(lastTap) <= NSEvent.doubleClickInterval {
                        lastTap = .distantPast // consume, so a third click doesn't re-trigger
                        store.setPill?(false)
                    } else {
                        lastTap = now // first click just arms the second
                    }
                }
        )
        .help("Double-click to expand (\(Hotkey.display))")
    }
}

// MARK: - Capture (just the editor)

struct CaptureView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            MarkdownTextView(text: $store.text,
                             fontSize: CGFloat(editorFontSize),
                             design: fontDesign,
                             theme: theme,
                             noteTitles: { store.notes.map { store.title(for: $0) }.filter { !$0.isEmpty } })
            statusLine
        }
        // ⌘N/⌘L/⌘S/⌘⌫/⌘M/⌘, are handled by the main-menu "Note" submenu in AppDelegate,
        // so they work from every screen — not just here.
    }

    /// Not `ChromeBar`: the editor's header says *where you are*, not what the note is
    /// called — the H1 in the text below is already the title, and repeating it at 11pt
    /// spent the centre slot on a duplicate. Every other screen keeps ChromeBar, whose
    /// centred label names a destination the content can't.
    private var header: some View {
        NavBar {
            Button { store.screen = .library } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "doc.text").iconSlot()
                    Text(breadcrumb).font(.caption).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Library (⌘L)")
        } center: {
            EmptyView()
        } right: {
            HStack(spacing: Space.xxs) {
                if !store.conflicts.isEmpty {
                    ChromeIcon(symbol: ChromeGlyph.conflict, help: "Two Macs edited the same note — review",
                               tint: .orange) { store.screen = .conflicts }
                }
                ChromeIcon(symbol: ChromeGlyph.newNote, help: "New note (⌘N)") { store.newNote() }
                ChromeIcon(symbol: "magnifyingglass", help: "Search notes (⌘K)") { store.searchNotes() }
                overflowMenu
            }
        }
    }

    /// Settings · Minimize · Close were three permanent glyphs for actions the keyboard
    /// already owns (⌘, · ⌘M · Esc). One menu, and the header gets its width back.
    private var overflowMenu: some View {
        Menu {
            if let sel = store.selected {
                Button(store.isPinned(sel) ? "Unpin Note" : "Pin Note") { store.togglePin(sel) }
            }
            Text("\(wordCount) words")
            Divider()
            Button("Settings") { store.openSettings() }
            Button("Minimize to Pill") { store.setPill?(true) }
            Button("Close") { store.onHide?() }
        } label: {
            Image(systemName: "ellipsis").iconSlot()
        }
        .chromeMenu()
        .frame(width: ChromeIcon.side)
        .help("More")
    }

    /// Location, in the same 11pt secondary the old title used: folder, then the note.
    /// A daily note is named by its day ("Today", "Yesterday", "Sep 9" — from the file's
    /// date, not the modification date, which made every note edited today say "Today");
    /// any other note shows its title.
    private var breadcrumb: String {
        guard let sel = store.selected else { return "GitPad" }
        let folder = store.folder(of: sel) ?? "Notes"
        return "\(folder) › \(context(for: sel))"
    }

    private func context(for sel: URL) -> String {
        if store.folder(of: sel) == "Daily" {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            if let date = f.date(from: sel.deletingPathExtension().lastPathComponent) {
                if Calendar.current.isDateInToday(date) { return "Today" }
                if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
                return date.formatted(.dateTime.month(.abbreviated).day())
            }
        }
        let title = store.title(for: sel)
        return title.isEmpty ? "Untitled" : title
    }

    /// Replaces the word count. This bar sits where the eye lands after typing, so it
    /// answers the questions typing actually raises — did that save, is it synced, is
    /// anything stuck — instead of a vanity metric. Word count moved to the ··· menu.
    ///
    /// It also absorbs the old stale-sync banner: a broken sync turns this line orange and
    /// clickable rather than pushing a second strip in above the text.
    private var statusLine: some View {
        VStack(spacing: 0) {
            SoftDivider()
            Button {
                if needsAttention { store.openSettings() }
            } label: {
                HStack(spacing: Space.s) {
                    SyncDot(status: store.syncStatus)
                    Text(store.dirty ? "Saving…" : "Saved")
                    dot
                    Text(syncLabel)
                    if pendingLabel != nil {
                        dot
                        Text(pendingLabel!)
                    }
                    Spacer(minLength: Space.m)
                    backlinksMenu
                    if Updater.isDevBuild { DevTag() }
                    Chip(text: "⌘K", font: .caption2.weight(.medium))
                }
                .font(.caption)
                .foregroundStyle(needsAttention ? Color.statusWarn : .secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!needsAttention)
            .help(needsAttention ? "Sync isn't working — open Settings" : store.syncStatus.label)
            .padding(.horizontal, Space.xxl).padding(.vertical, Space.s)
        }
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }

    /// Notes that link here as `[[this title]]`: a small menu in the status line, present
    /// only when there are any — the bar stays quiet for the common case.
    @ViewBuilder private var backlinksMenu: some View {
        if let sel = store.selected {
            let links = store.backlinks(to: sel)
            if !links.isEmpty {
                Menu {
                    ForEach(links, id: \.self) { url in
                        Button(store.title(for: url)) { store.open(url) }
                    }
                } label: {
                    Label("\(links.count) linked", systemImage: "arrow.turn.up.left")
                        .font(.caption2).labelStyle(.titleAndIcon)
                }
                .chromeMenu().fixedSize()
                .help("Notes that link to this one")
            }
        }
    }

    private var needsAttention: Bool { store.syncStatus == .offline }

    /// Short forms of `SyncStatus.label` — the long ones are for Settings, where there's room.
    private var syncLabel: String {
        switch store.syncStatus {
        case .unknown: return store.syncing ? "Syncing…" : "Not synced yet"
        case .noRemote: return "Local only"
        case .synced(let d): return "Synced \(d.formatted(.relative(presentation: .numeric)))"
        case .offline: return "Can't reach remote"
        }
    }

    private var pendingLabel: String? {
        var parts: [String] = []
        if store.pending.ahead > 0 { parts.append("\(store.pending.ahead) to push") }
        if store.pending.behind > 0 { parts.append("\(store.pending.behind) to pull") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var wordCount: Int {
        store.text.split(whereSeparator: \.isWhitespace).count
    }
}

// MARK: - Vault

/// Replaces every screen while the encrypted vault is unmounted (Keychain miss, or the
/// user chose not to remember the passphrase). See `Vault`.
struct LockedView: View {
    @ObservedObject var store: NoteStore
    @State private var pass = ""
    @State private var working = false
    @State private var result: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Vault locked", showSettings: false, showSyncDot: false) { EmptyView() }
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Your notes are encrypted on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                if Vault.touchID {
                    Button(working ? "Unlocking…" : "Unlock with Touch ID") {
                        working = true; result = nil
                        store.unlockVaultStored { ok in
                            working = false
                            if !ok { result = "✗ Touch ID didn't complete — try again, or type the passphrase" }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                    Text("or type your passphrase").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: Space.s) {
                    SecureField("Passphrase", text: $pass)
                        .focused($focused)
                        .fieldStyle(focused: focused)
                        .frame(width: 200)
                        .onSubmit(unlock)
                    Button(working ? "Unlocking…" : "Unlock", action: unlock)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(pass.isEmpty || working)
                }
                if let result {
                    Text(result).font(.caption).foregroundStyle(Color.statusErr)
                }
                Spacer()
                Text("Locks when the screen locks or the Mac sleeps.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding()
        }
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !pass.isEmpty, !working else { return }
        working = true; result = nil
        let p = pass
        store.unlockVault(p) { ok in
            working = false
            if ok { // next launch/unlock is silent again; Keychain writes block, keep them off main
                store.onSyncQueue? { Vault.savePassphrase(p) }
                pass = ""
            } else { result = "✗ Wrong passphrase, or the vault is busy" }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("vaultEnabled") private var vaultEnabled = false
    @AppStorage("vaultTouchID") private var vaultTouchID = false
    @State private var vaultExpanded = false // the two passphrase fields hide behind one row
    @State private var vaultPass = ""
    @State private var vaultPass2 = ""
    @State private var vaultWorking = false
    @State private var vaultResult: String?
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?
    @State private var confirmErase = false
    @State private var eraseHasRemote = true
    @FocusState private var vaultPassFocused: Bool
    @FocusState private var vaultPass2Focused: Bool
    private var devBuild: Bool { ProcessInfo.processInfo.environment["GITPAD_DIR"] != nil }
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0
    @AppStorage("theme") private var themeID = "System"
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("autoUpdate") private var autoUpdate = false
    @AppStorage("vaultIdleMinutes") private var vaultIdleMinutes = 0
    @State private var remote = ""
    @State private var log: [SyncLog.Entry] = []
    @State private var checkingUpdate = false
    @State private var checkNote: String? // manual-check result only; the timer stays silent

    @ViewBuilder private var vaultSection: some View {
        Section {
            if vaultEnabled {
                LabeledContent("Notes are encrypted at rest") {
                    Button("Lock now") { store.lockVault() }
                }
                Picker("Lock when idle", selection: $vaultIdleMinutes) {
                    Text("Never").tag(0)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                }
                if Vault.touchIDAvailable {
                    // Bound to the store switch, not the default directly: the move reads the
                    // current copy (a Touch ID prompt when turning off) and can refuse.
                    Toggle("Require Touch ID to unlock", isOn: Binding(
                        get: { vaultTouchID },
                        set: { on in runVault({ Vault.setTouchID(on) }) {} }))
                        .disabled(vaultWorking)
                }
                Button("Decrypt notes…", role: .destructive) { runVault(Vault.remove) }
                    .disabled(vaultWorking)
            } else if vaultExpanded {
                SecureField("Passphrase", text: $vaultPass)
                    .focused($vaultPassFocused).fieldStyle(focused: vaultPassFocused)
                SecureField("Confirm passphrase", text: $vaultPass2)
                    .focused($vaultPass2Focused).fieldStyle(focused: vaultPass2Focused)
                Button(vaultWorking ? "Working…" : "Encrypt notes…") {
                    let p = vaultPass
                    runVault { Vault.create(passphrase: p) }
                }
                .disabled(vaultPass.count < 8 || vaultPass != vaultPass2 || vaultWorking)
            } else {
                Button {
                    withAnimation(Motion.quick) { vaultExpanded = true }
                    vaultPassFocused = true
                } label: {
                    Label("Encrypt notes on this Mac…", systemImage: "lock.shield")
                }
            }
            if let vaultResult {
                Text(vaultResult).font(.caption)
                    .foregroundStyle(vaultResult.hasPrefix("✓") ? Color.statusOK : Color.statusErr)
            }
        } header: {
            Text("Encrypted vault")
        } footer: {
            if vaultEnabled || vaultExpanded {
                Text(vaultEnabled
                     ? (vaultTouchID
                        ? "Your notes live in an AES-256 disk image mounted at the same folder. It locks when the screen locks, the Mac sleeps, or nobody has touched the keyboard for the idle time above. The passphrase is sealed by the Secure Enclave and released only after Touch ID (or your password on a Mac without it) — expect a prompt at launch and after every screen unlock. Decrypt puts the plain files back."
                        : "Your notes live in an AES-256 disk image mounted at the same folder. It locks when the screen locks, the Mac sleeps, or nobody has touched the keyboard for the idle time above; the passphrase is in your login Keychain, so unlocking is silent. Decrypt puts the plain files back.")
                     : "Moves your notes into an AES-256 disk image mounted at the same folder — git sync is unchanged. Locks when the screen locks or the Mac sleeps; the passphrase is kept in your login Keychain. No recovery: a lost passphrase means lost notes unless a remote has them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(devBuild)
    }

    /// SMAppService, not a LaunchAgent plist: the system owns the entry, it shows up in
    /// System Settings › Login Items, and unregistering removes it cleanly.
    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = nil
        } catch {
            loginNote = "Couldn't change it: \(error.localizedDescription)"
        }
        // Read back rather than trust the toggle: macOS can hold a registration for approval.
        loginItem = SMAppService.mainApp.status == .enabled
        if on, SMAppService.mainApp.status == .requiresApproval {
            loginNote = "Needs your approval in System Settings › General › Login Items."
        }
    }

    /// Vault ops go through the sync queue so a timer sync can't write mid-copy.
    private func runVault(_ op: @escaping () -> String?, then: (() -> Void)? = nil) {
        vaultWorking = true; vaultResult = nil
        store.flushPendingSave()
        let queue = store.onSyncQueue ?? { DispatchQueue.global().async(execute: $0) }
        queue {
            let err = op()
            DispatchQueue.main.async {
                vaultWorking = false
                vaultResult = err.map { "✗ " + $0 } ?? "✓ Done"
                vaultPass = ""; vaultPass2 = ""
                guard err == nil else { return }
                if let then { then() } else { store.refresh() }
            }
        }
    }

    /// Local state, deliberately NOT new `Screen` cases: those would multiply the
    /// `goBack()` / settingsReturn branches for nothing. Esc and ⌘, keep working as-is;
    /// the tab just resets to Writing after a Setup-guide round trip.
    /// Grouped by decision, not implementation: "how does my writing look?" is one tab.
    enum Tab: String, CaseIterable {
        case writing = "Writing", sync = "Sync", shortcuts = "Shortcuts", advanced = "Advanced"
    }
    @State private var tab: Tab = .writing

    // (tag, label) — system designs plus Apple-bundled note-friendly fonts.
    // Nothing here ships with the app, so open-sourcing stays clean.
    static let fonts: [(String, String)] = [
        ("system", "SF Pro (System)"),
        ("serif", "New York (Serif)"),
        ("rounded", "SF Rounded"),
        ("mono", "SF Mono"),
        ("Avenir Next", "Avenir Next"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Charter", "Charter"),
        ("Georgia", "Georgia"),
        ("Palatino", "Palatino"),
        ("Iowan Old Style", "Iowan Old Style"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Settings", showSettings: false, showSyncDot: false) {
                ChromeIcon(symbol: ChromeGlyph.back, help: "Back (Esc)") { store.goBack() }
            }

            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.bottom, 4)

            Form {
                switch tab {
                case .writing:
                Section("Editor") {
                    Picker("Font", selection: $fontDesign) {
                        ForEach(Self.fonts, id: \.0) { tag, label in
                            Text(label).tag(tag)
                        }
                    }
                    LabeledContent("Size") {
                        HStack(spacing: 10) {
                            Text("\(Int(editorFontSize)) pt")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            HStack(spacing: 0) {
                                stepper("minus") { editorFontSize = max(11, editorFontSize - 1) }
                                Divider().frame(height: 14)
                                stepper("plus") { editorFontSize = min(20, editorFontSize + 1) }
                            }
                            .background(Color.quietFill, in: Capsule())
                        }
                    }
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(Font(MarkdownTextView.Coordinator.baseFont(CGFloat(editorFontSize), fontDesign) as CTFont))
                        .foregroundStyle(.secondary)
                }
                // Full-width row, not a LabeledContent trailing slot: that slot compresses
                // on a narrow panel and clipped the swatches into different shapes.
                Section {
                    VStack(alignment: .leading, spacing: Space.m) {
                        HStack(spacing: Space.xl) {
                            ForEach(Theme.all) { t in
                                ThemeSwatch(theme: t, selected: themeID == t.id) { themeID = t.id }
                            }
                        }
                        Text(themeID) // say which one is on; the swatches alone are a guess
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Space.xxs)
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Changes apply immediately — there's no Save button.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                case .sync:
                syncTab

                case .shortcuts:
                Section("Global Hotkey") {
                    HotkeyRecorder()
                }
                ShortcutsList()

                case .advanced:
                Section {
                    Toggle("Open at login", isOn: Binding(get: { loginItem }, set: setLoginItem))
                        .disabled(Updater.isDevBuild) // a dev build registered at login would outlive its checkout
                    if let loginNote {
                        Text(loginNote).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Startup")
                } footer: {
                    Text(Updater.isDevBuild ? "Not for dev builds — install the release to use this."
                         : "GitPad starts with your Mac, in the menu bar, without opening its window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Version") {
                        Text((Updater.currentVersion ?? "—") + (Updater.isDevBuild ? " · dev build" : ""))
                    }
                    // The opt-out is what keeps SECURITY.md's "no network calls except your
                    // git remote" honest — off means the app never contacts github.com.
                    Toggle("Check automatically", isOn: $autoCheckUpdates)
                    if autoCheckUpdates {
                        Toggle("Install updates automatically", isOn: $autoUpdate)
                    }
                    updateRow
                } header: {
                    Text("Updates")
                } footer: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Checks github.com/stalinzbb/GitPad about once a day. Nothing is sent except the request.")
                        if autoCheckUpdates && autoUpdate {
                            Text("Downloads and verifies in the background, then installs when you quit — or right away with Restart to Update. Never while you're writing.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Help") {
                    Link("Report a problem or suggest something ↗", destination: URL(string: "https://github.com/stalinzbb/GitPad/issues/new")!)
                    Link("How syncing works ↗", destination: URL(string: "https://github.com/stalinzbb/GitPad/blob/main/SYNCING.md")!)
                }
                vaultSection
                Section {
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit GitPad", systemImage: "power")
                    }
                } footer: {
                    Text("Also ⌘Q from any screen, or the menu-bar icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Last section, last tab, destructive tint: the one landmine gets a wide berth.
                Section {
                    // Dragging the app to the Trash can't run code, so this is the only
                    // path that actually removes the notes from the machine.
                    Button(role: .destructive) {
                        eraseHasRemote = GitSync.run(["remote", "get-url", "origin"], in: store.dir).status == 0
                        confirmErase = true
                    } label: {
                        Label("Erase GitPad from this Mac…", systemImage: "trash")
                    }
                    .foregroundStyle(Color.statusErr)
                    .disabled(vaultWorking || devBuild || store.locked)
                    .alert("Erase GitPad and all notes from this Mac?", isPresented: $confirmErase) {
                        Button("Erase", role: .destructive) { runVault(Vault.erase) { NSApp.terminate(nil) } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Syncs first, then deletes the notes folder, the encrypted vault, its Keychain entry and settings, and moves GitPad to the Trash. Notes already pushed to your remote are unaffected."
                             + (eraseHasRemote ? "" : "\n\nNo remote is set: this is the only copy."))
                    }
                } footer: {
                    Text("Deleting the app by hand leaves your notes on disk.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(LeanScrollbar())
        }
        .onAppear { refreshGitInfo() }
        // backgroundSync publishes a fresh .synced(Date) on each cycle → refresh ahead/behind
        // exactly when sync finishes, instead of guessing with a 2s delay.
        .onChange(of: store.syncStatus) { _ in refreshGitInfo() }
    }

    /// Problem first, then facts, then the record. The repo is a value with a Change link,
    /// not a form: editing goes through the setup guide, which already validates and syncs.
    @ViewBuilder private var syncTab: some View {
        if store.syncStatus == .offline {
            Section {
                FixSyncPanel(store: store, ahead: store.pending.ahead)
                    .listRowBackground(Color.statusWarn.opacity(Alpha.iconHover))
            }
        } else if case .synced(let d) = store.syncStatus {
            Section {
                HStack(spacing: Space.l) {
                    SyncDot(status: store.syncStatus)
                    Text("Everything's synced · \(d.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                }
            }
        }
        Section("Repository") {
            if remote.isEmpty {
                Button("Set up sync…") { store.screen = .gitSetup }
            } else {
                LabeledContent {
                    Button("Change…") { store.screen = .gitSetup }
                        .buttonStyle(.plain).foregroundStyle(.tint).font(.caption)
                } label: {
                    Text(remote).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                DeviceNameField()
            }
        }
        if !store.conflicts.isEmpty {
            Section("Conflicts") {
                Button {
                    store.screen = .conflicts
                } label: {
                    Label("Review \(store.conflicts.count) conflict\(store.conflicts.count == 1 ? "" : "s")…",
                          systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
        if !remote.isEmpty {
            Section {
                if log.isEmpty {
                    Text("Nothing yet — syncs on every save, every 5 minutes, and on wake.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(log.enumerated()), id: \.offset) { _, e in
                    HStack(spacing: Space.l) {
                        SyncDot(status: e.ok ? .synced(e.date) : .offline)
                        Text(e.text).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(e.date.formatted(activityStamp(e.date)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    Button(store.syncing ? "Syncing…" : "Sync now") { store.requestSync?() }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                        .disabled(store.syncing)
                }
            }
        }
    }

    /// "10:31" today, "Tue 18:02" this week, else "Sep 2".
    private func activityStamp(_ d: Date) -> Date.FormatStyle {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return .dateTime.hour().minute() }
        if d > cal.date(byAdding: .day, value: -6, to: Date())! { return .dateTime.weekday(.abbreviated).hour().minute() }
        return .dateTime.month(.abbreviated).day()
    }

    private func stepper(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The one row that changes with `store.update`. Everything here is a plain Form row —
    /// an update never takes over the screen, and never appears over the editor at all.
    @ViewBuilder private var updateRow: some View {
        switch store.update {
        case .available(let r):
            LabeledContent("Version \(r.version) is available") {
                HStack(spacing: 10) {
                    Button("Update") { Updater.install(r) { store.update = $0 } }
                    Button("View Release") { NSWorkspace.shared.open(r.pageURL) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                }
            }
        case .busy(let stage):
            LabeledContent(stage) { ProgressView().controlSize(.small) }
        case .failed(let why):
            LabeledContent {
                Button("View Releases") { NSWorkspace.shared.open(Updater.releasesPage) }
            } label: {
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let v):
            LabeledContent("Version \(v) is ready") {
                Button("Restart to Update") { Updater.installStagedNow { store.update = $0 } }
            }
        case .none:
            LabeledContent {
                Button(checkingUpdate ? "Checking…" : "Check for Updates") { checkForUpdates() }
                    .disabled(checkingUpdate)
            } label: {
                if let checkNote {
                    Text(checkNote).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Same shape as refreshGitInfo: kick off-main, land back on main. Unlike the timer's
    /// check this one asked for an answer, so "couldn't reach GitHub" is said out loud.
    private func checkForUpdates() {
        checkingUpdate = true
        checkNote = nil
        Updater.check { release, ok in
            checkingUpdate = false
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            if let release {
                store.update = .available(release)
            } else {
                checkNote = ok ? "Up to date" : "Couldn't check"
            }
        }
    }

    private func refreshGitInfo() {
        DispatchQueue.global().async {
            // ponytail: ahead/behind comes from store.pending — every sync already fills it
            let url = GitSync.remoteURL(in: store.dir)
            DispatchQueue.main.async {
                remote = url
                log = SyncLog.entries
            }
        }
    }
}

/// "This Mac": the commit author on the remote. Empty = the Mac's own name.
/// Takes effect on the next sync (`GitSync.sync` re-applies `user.name` every run).
private struct DeviceNameField: View {
    @AppStorage("deviceName") private var name = ""
    var body: some View {
        LabeledContent("This Mac") {
            TextField(Host.current().localizedName ?? "GitPad", text: $name)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                .multilineTextAlignment(.trailing)
        }
        Text("How this Mac signs its commits and labels conflict copies. Visible to anyone who can read the repo.")
            .font(.caption2).foregroundStyle(.tertiary)
    }
}

/// Sync is failing — one card: the cause in plain words, when it last worked and what's
/// waiting, then a ranked primary/secondary action. The diagnosis is deliberately async:
/// `ls-remote` can hang for a long time.
struct FixSyncPanel: View {
    @ObservedObject var store: NoteStore
    var ahead = 0
    @State private var problem: GitSync.SyncProblem?
    @State private var ghReady = false
    @State private var note: String?

    @State private var canSignIn = false

    private var headline: String {
        switch problem {
        case nil: return "Checking what went wrong…"
        case .sshAuth: return "The repo host rejected this Mac's SSH key"
        case .repoMissing: return "That repository isn't there"
        case .hostKeyChanged: return "The server's SSH key changed"
        case .httpsNeedsLogin: return "This HTTPS URL needs a login"
        default: return "Can't reach the remote"
        }
    }

    private var detail: String? {
        switch problem {
        case .sshAuth(let key): return "\(URL(fileURLWithPath: key).lastPathComponent) isn't on the account that owns this repo."
            + (ghReady ? " Switching to HTTPS pushes with your gh login's token, which can reach every repo on your account." : "")
        case .repoMissing: return "Check the URL."
        case .hostKeyChanged: return "That can be a man-in-the-middle attack — verify the new key with your host before trusting it."
        case .httpsNeedsLogin: return canSignIn ? "Sign in with GitHub and GitPad pushes over HTTPS — or use the SSH URL instead."
            : "Sign in to the gh CLI (`gh auth login`) or use the SSH URL instead."
        case .offline: return "Network unreachable — GitPad retries every 5 minutes."
        default: return nil
        }
    }

    private var record: String {
        var parts: [String] = []
        if let last = UserDefaults.standard.object(forKey: "lastSyncOK") as? Date {
            parts.append("Last successful sync: \(last.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
        }
        if ahead > 0 { parts.append("\(ahead) waiting to push") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                SyncDot(status: .offline)
                Text(headline).font(.callout.weight(.semibold))
            }
            Text([detail, record.isEmpty ? nil : record].compactMap { $0 }.joined(separator: " "))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                switch problem {
                case .sshAuth(let key):
                    if ghReady {
                        Button("Switch to HTTPS") { switchToHTTPS() }.buttonStyle(.borderedProminent)
                    }
                    Button("Copy public key") {
                        let pub = (try? String(contentsOfFile: key + ".pub", encoding: .utf8)) ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pub, forType: .string)
                        note = pub.isEmpty ? "Couldn't read \(key).pub" : "Copied — paste it at your host"
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    if GitSync.remoteURL(in: store.dir).contains("github.com") {
                        Link("Add key ↗", destination: URL(string: "https://github.com/settings/ssh/new")!)
                            .font(.caption)
                    }
                case .httpsNeedsLogin where canSignIn:
                    GitHubSignInButton { _ in store.requestSync?(); diagnose() }
                    Button("Change repository…") { store.screen = .gitSetup }.buttonStyle(.bordered)
                case .repoMissing, .httpsNeedsLogin:
                    Button("Change repository…") { store.screen = .gitSetup }.buttonStyle(.borderedProminent)
                default:
                    Button(store.syncing ? "Syncing…" : "Try again") { store.requestSync?() }
                        .buttonStyle(.borderedProminent).disabled(store.syncing)
                }
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Space.xxs)
        .onAppear(perform: diagnose)
    }

    private func diagnose() {
        DispatchQueue.global().async {
            let p = GitSync.diagnose(dir: store.dir)
            let gh = GitSync.ghReady()
            let hub = GitHubAuth.enabled && GitSync.remoteURL(in: store.dir).contains("github.com")
            DispatchQueue.main.async { problem = p; ghReady = gh; canSignIn = hub }
        }
    }

    /// Exactly the manual fix: point origin at HTTPS and let gh's token drive it.
    private func switchToHTTPS() {
        guard let https = GitSync.httpsURL(from: GitSync.remoteURL(in: store.dir)) else { return }
        note = "Switching…"
        DispatchQueue.global().async {
            GitSync.setRemote(https, in: store.dir)
            GitSync.enableHTTPSAuth()
            DispatchQueue.main.async {
                note = "Now using \(https)"
                store.requestSync?()
                diagnose()
            }
        }
    }
}

// MARK: - Conflicts

/// One screen for every conflict copy: what happened, both versions, three ways out.
struct ConflictView: View {
    @ObservedObject var store: NoteStore
    @State private var selection: URL?

    private var copy: URL? { selection ?? store.conflicts.first }

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Conflicts", showSettings: false, showSyncDot: false) {
                ChromeIcon(symbol: ChromeGlyph.back, help: "Back (Esc)") { store.goBack() }
            }

            Text("Two Macs edited the same note between syncs. GitPad kept this Mac's version and saved the other alongside it — nothing was lost. Highlighted lines exist only on that side.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 8)

            if let copy {
                if store.conflicts.count > 1 {
                    Picker("", selection: Binding(get: { copy }, set: { selection = $0 })) {
                        ForEach(store.conflicts, id: \.self) { c in
                            Text(store.title(for: c)).tag(c)
                        }
                    }
                    .labelsHidden().padding(.horizontal, 14).padding(.bottom, 6)
                }
                if let orig = store.original(for: copy) {
                    let mine = Self.lines(orig), theirs = Self.lines(copy)
                    let only = NoteStore.uniqueLines(mine, theirs)
                    HStack(spacing: 8) {
                        pane("On this Mac", mine, only.a)
                        pane("From \(store.conflictDevice(copy))", theirs, only.b)
                    }
                    .padding(.horizontal, 14)
                    HStack(spacing: 10) {
                        Button("Keep Mine") { resolve { store.resolveDiscard(copy) } }
                        Button("Use Theirs") { resolve { store.resolveKeep(copy) } }
                        Button("Keep Both") { resolve { store.resolveKeepBoth(copy) } }
                    }
                    .font(.callout).padding(.vertical, 12)
                } else {
                    // the original is gone — this Mac deleted it while the other edited it
                    VStack(spacing: 8) {
                        Text("The note this came from no longer exists on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        pane("From \(store.conflictDevice(copy))", Self.lines(copy), [])
                        HStack(spacing: 10) {
                            Button("Keep as Note") { resolve { store.resolveKeepBoth(copy) } }
                            Button("Discard") { resolve { store.resolveDiscard(copy) } }
                        }
                        .font(.callout)
                    }
                    .padding(14)
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: store.conflicts) { list in if list.isEmpty { store.goBack() } }
    }

    private func resolve(_ action: () -> Void) {
        action()
        selection = nil
    }

    private static func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
    }

    /// One Text with per-line background attributes, not a VStack of rows: selection and
    /// copy still work across the whole pane, and there's nothing to lay out per line.
    private static func highlighted(_ lines: [String], _ only: Set<Int>) -> AttributedString {
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            var s = AttributedString(line + (i < lines.count - 1 ? "\n" : ""))
            if only.contains(i) { s.backgroundColor = Color.statusWarn.opacity(Alpha.iconHover) }
            out += s
        }
        return out
    }

    private func pane(_ label: String, _ lines: [String], _ only: Set<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(Self.highlighted(lines, only))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(minHeight: 120)
            .background(LeanScrollbar())
            .background(Color.primary.opacity(Alpha.inset),
                        in: RoundedRectangle(cornerRadius: Radius.control))
        }
    }
}

/// Every binding, read-only (the global hotkey above it is the one rebindable thing).
/// A static table on purpose: half of these — Tab indent, Enter list-continue, the slash
/// menu, click-to-toggle — exist in no menu at all, so nothing to derive from.
/// Keep in sync with the Note menu, GitPadApp.swift:135-152.
struct ShortcutsList: View {
    private static let panel = [
        ("New note", "⌘N"), ("Library", "⌘L"), ("Command palette", "⌘K"),
        ("Save & sync", "⌘S"), ("Delete note", "⌘⌫"), ("Minimize to pill", "⌘M"),
        ("Settings", "⌘,"), ("Quit GitPad", "⌘Q"), ("Back one level / close", "Esc"),
    ]
    private static let editing = [
        ("Undo", "⌘Z"), ("Redo", "⇧⌘Z"), ("Cut", "⌘X"),
        ("Copy", "⌘C"), ("Paste", "⌘V"), ("Select all", "⌘A"),
    ]
    private static let behaviors = [
        ("Indent / outdent list item", "⇥ / ⇧⇥"), ("Continue the list", "↩"),
        ("Snippet menu", "/"), ("Toggle a checkbox", "Click ☐"),
        ("Minimize to pill", "Double-click header"),
    ]

    var body: some View {
        Group {
            Section("Panel") { rows(Self.panel) }
            Section("Editing") { rows(Self.editing) }
            Section("Editor") { rows(Self.behaviors) }
        }
    }

    private func rows(_ items: [(String, String)]) -> some View {
        ForEach(items, id: \.0) { label, keys in
            LabeledContent(label) { Chip(text: keys) }
        }
    }
}

/// Records a new global hotkey: click to arm, then press a modified key combo.
/// A local key-down monitor captures (and consumes) the first press; Esc cancels.
struct HotkeyRecorder: View {
    @State private var recording = false
    @State private var display = Hotkey.display
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Summon GitPad")
                Spacer()
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Press keys…" : display)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.primary.opacity(recording ? Alpha.strokeStrong : Alpha.hover),
                                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.primary.opacity(Alpha.strokeStrong)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(warning ?? (recording
                             ? "Esc cancels."
                             : "Press this from any app, even when GitPad is hidden — click to change."))
                .font(.caption)
                .foregroundStyle(warning == nil ? .secondary : Color.statusWarn)
        }
        .onDisappear(perform: stop) // never leave a live monitor behind
    }

    private func start() {
        recording = true
        warning = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // consume every key-down while recording
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { stop(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { warning = "Add a modifier — ⌘, ⌥, ⌃, or ⇧"; return }
        let mods = Hotkey.carbonModifiers(flags)
        let combo = Hotkey.displayString(flags, keyCode: event.keyCode,
                                         chars: event.charactersIgnoringModifiers ?? "")
        if Hotkey.apply(keyCode: UInt32(event.keyCode), modifiers: mods) {
            let d = UserDefaults.standard
            d.set(Int(event.keyCode), forKey: "hotkeyKeyCode")
            d.set(Int(mods), forKey: "hotkeyModifiers")
            d.set(combo, forKey: "hotkeyDisplay")
            display = combo
            stop()
        } else {
            warning = "\(combo) is already in use — try another" // keep recording
        }
    }
}

// MARK: - Library (two-column: sources on the left, notes on the right)

enum LibrarySource: Hashable {
    case recent, daily, inbox, folder(String)

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .daily: return "Daily"
        case .inbox: return "Inbox"
        case .folder(let f): return f
        }
    }
    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .daily: return "calendar"
        case .inbox: return "tray"
        case .folder: return "folder"
        }
    }
}

struct LibraryView: View {
    @ObservedObject var store: NoteStore
    @State private var query = ""
    @State private var source: LibrarySource = .recent
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var newFolderHover = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var folderFieldFocused: Bool

    // user folders shown in the rail (Daily is its own top-level item)
    private var folders: [String] { store.folders.filter { $0 != "Daily" } }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var newNoteHelp: String {
        switch source {
        case .folder(let f): return "New note in \(f)"
        case .daily: return "Open today's daily note"
        default: return "New note in Inbox (⌘N)"
        }
    }

    /// New note lands where you're browsing: a folder → that folder; Daily → today's
    /// note (the only note Daily can hold); Recent/Inbox → the Inbox (repo root).
    private func newNoteHere() {
        switch source {
        case .daily: store.open(store.dailyNote())
        case .folder(let f): store.newNote(in: f)
        default: store.newNote()
        }
    }

    private var notes: [URL] {
        let m = store.matches(query)
        guard !searching else { return m } // a search spans every folder
        return m.filter { url in
            switch source {
            case .recent: return true
            case .daily: return store.folder(of: url) == "Daily"
            case .inbox: return store.folder(of: url) == nil
            case .folder(let f): return store.folder(of: url) == f
            }
        }
    }

    private var groups: [(String, [URL])] {
        let cal = Calendar.current
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let pinnedSet = Set(store.pinnedNotes().map(\.path))
        let pinned = notes.filter { pinnedSet.contains($0.path) }
        let rest = notes.filter { !pinnedSet.contains($0.path) }
        return ([("Pinned", pinned)] + [
            ("Today", rest.filter { cal.isDateInToday(store.modified($0)) }),
            ("This Week", rest.filter { !cal.isDateInToday(store.modified($0)) && store.modified($0) > weekAgo }),
            ("Earlier", rest.filter { store.modified($0) <= weekAgo }),
        ]).filter { !$1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Library") {
                HStack(spacing: 2) {
                    ChromeIcon(symbol: ChromeGlyph.back, help: "Back to note (⌘L / Esc)") { store.screen = .capture }
                    ChromeIcon(symbol: ChromeGlyph.newNote, help: newNoteHelp) { newNoteHere() }
                }
            }

            // full-width search — spans every folder, above the two columns
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all notes…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = notes.first { store.open(first) } }
                    // Esc clears an active search first; only then leaves the Library.
                    .onExitCommand { if searching { query = "" } else { store.goBack() } }
                if searching {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.quietFill,
                        in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8) // breathe below the chrome bar
            SoftDivider()

            HStack(spacing: 0) {
                sourceRail.disabled(searching) // browsing is paused while searching everything
                Divider()
                noteColumn
            }
        }
    }

    // MARK: left rail

    private var sourceRail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sourceRow(.recent)
                    sourceRow(.daily)
                    sourceRow(.inbox)
                    if !folders.isEmpty {
                        SectionLabel(text: "Folders") // matches the note-list section headers
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                        ForEach(folders, id: \.self) { f in
                            FolderRailRow(name: f, count: count(.folder(f)),
                                          selected: source == .folder(f),
                                          select: { source = .folder(f) },
                                          rename: { renameText = f; renaming = f },
                                          delete: { deleting = f })
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.top, 8)
            }
            .background(LeanScrollbar())

            SoftDivider()
            if creatingFolder {
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($folderFieldFocused)
                    // 16 = the rail's 6pt gutter + a row's 10pt inset, so the caret
                    // lines up with the folder names above it
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .onSubmit {
                        store.createFolder(newFolderName)
                        if !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                            source = .folder(newFolderName.trimmingCharacters(in: .whitespaces))
                        }
                        newFolderName = ""; creatingFolder = false
                    }
                    .onExitCommand { newFolderName = ""; creatingFolder = false }
            } else {
                Button {
                    creatingFolder = true; folderFieldFocused = true
                } label: {
                    // same geometry and hover pill as a folder row, so it reads as one list
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.callout).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: railSlot, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .rowBackground(hovering: newFolderHover)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 6)
                .onHover { newFolderHover = $0 }
                .animation(Motion.quick, value: newFolderHover)
            }
        }
        .frame(width: 150)
        .alert("Rename folder", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let f = renaming {
                    let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.renameFolder(f, to: new)
                    if source == .folder(f), !new.isEmpty { source = .folder(new) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete “\(deleting ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let f = deleting {
                    store.deleteFolder(f)
                    if source == .folder(f) { source = .recent }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Notes inside move to Inbox; the folder is removed.")
        }
    }

    /// How many notes a rail entry would show. Cheap: `notes` is already in memory.
    private func count(_ s: LibrarySource) -> Int {
        switch s {
        case .recent: return store.notes.count
        case .daily: return store.notes.filter { store.folder(of: $0) == "Daily" }.count
        case .inbox: return store.notes.filter { store.folder(of: $0) == nil }.count
        case .folder(let f): return store.notes.filter { store.folder(of: $0) == f }.count
        }
    }

    private func sourceRow(_ s: LibrarySource) -> some View {
        Button { source = s } label: {
            HStack(spacing: 6) {
                Label(s.label, systemImage: s.symbol).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count(s))").foregroundStyle(.secondary)
            }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: railSlot, alignment: .leading) // match folder-row height
                .padding(.horizontal, 10).padding(.vertical, 3)
                .rowBackground(selected: source == s)
        }
        .buttonStyle(.plain)
    }

    // MARK: right column

    private var noteColumn: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                Spacer()
                Image(systemName: searching ? "magnifyingglass" : "note.text")
                    .font(.title2).foregroundStyle(.tertiary).padding(.bottom, Space.s)
                Text(searching ? "No matches" : "No notes here yet")
                    .font(.callout).foregroundStyle(.secondary)
                if !searching {
                    Text("Press ⌘N to write one.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(groups, id: \.0) { name, urls in
                        Section {
                            ForEach(urls, id: \.self) { url in
                                NoteRow(store: store, url: url)
                            }
                        } header: {
                            SectionLabel(text: name)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(LeanScrollbar())
            }
        }
        .frame(maxWidth: .infinity)
        // animate the empty↔populated / group swap on search only — NOT on refresh(),
        // which fires every 5-min sync and would churn rows.
        .animation(Motion.quick, value: query)
        .onAppear { searchFocused = true }
        .onChange(of: store.searchRequest) { _ in searchFocused = true }
    }
}

/// One height for every sidebar row: 22pt of content + 3pt above and below ≈ 28pt.
/// Shared so the rail's sources, folders and New Folder can't drift apart.
private let railSlot: CGFloat = 22

/// Folder row in the rail: tap to select; hover reveals an ⋯ menu; right-click too.
struct FolderRailRow: View {
    let name: String
    let count: Int
    let selected: Bool
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label(name, systemImage: "folder").font(.callout).lineLimit(1)
            Spacer(minLength: 0)
            // count and ⋯ share ONE fixed slot, so nothing resizes on hover.
            // (No .fixedSize(): that re-measured on the menu's own hover highlight and
            // fed the twitch back into row layout.)
            Group {
                if hovering {
                    Menu {
                        Button("Rename…", action: rename)
                        Button("Delete Folder", role: .destructive, action: delete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90)) // vertical ⋮ (no single SF symbol for it)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: railSlot, height: railSlot)
                            .contentShape(Rectangle())
                    }
                    .chromeMenu()
                } else {
                    Text("\(count)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: railSlot, height: railSlot)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .rowBackground(selected: selected, hovering: hovering)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu {
            Button("Rename…", action: rename)
            Button("Delete Folder", role: .destructive, action: delete)
        }
    }
}

struct NoteRow: View {
    @ObservedObject var store: NoteStore
    let url: URL
    @State private var hovering = false

    /// "3 of 7 done · yesterday" for checklists, else "first line · yesterday".
    private var detail: String {
        let m = store.meta(for: url)
        let when = store.modified(url).formatted(.relative(presentation: .named))
        if m.total > 0 { return "\(m.done) of \(m.total) done · \(when)" }
        return (m.snippet.isEmpty ? "Empty" : m.snippet) + " · \(when)"
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if store.meta(for: url).total > 0 {
                        Image(systemName: "checkmark.square.fill")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                    Text(store.title(for: url)).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.folder(of: url) == "Daily" {
                Chip(text: "Daily", font: .caption2)
            }
            Menu {
                Button("Open") { store.open(url) }
                Button(store.isPinned(url) ? "Unpin" : "Pin") { store.togglePin(url) }
                Menu("Move to") {
                    Button("Notes") { store.move(url, to: nil) }
                    ForEach(store.folders, id: \.self) { f in
                        Button(f) { store.move(url, to: f) }
                    }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("Delete", role: .destructive) { store.delete(url) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .iconSlot() // constant slot; no .fixedSize() remeasure
                    .contentShape(Rectangle())
            }
            .chromeMenu()
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering) // hidden ⋯ must not eat taps meant for the row
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .rowBackground(hovering: hovering)
        .onTapGesture { store.open(url) }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Smart markdown editor

private let dividerKey = NSAttributedString.Key("gitpadDivider")
let checkboxKey = NSAttributedString.Key("gitpadCheckbox") // value: Bool (checked)
let codeKey = NSAttributedString.Key("gitpadCode")            // inline code span → rounded chip
private let markerKey = NSAttributedString.Key("gitpadListMarker") // value: String (display marker)

/// Drawn checkbox size and the fixed layout advance the ☐/☑ character occupies, derived
/// from the body font. ☐/☑ aren't in SF Pro — fallback fonts (☑ often gets the emoji
/// font!) have wildly different advances and line metrics, which shifted the text and line
/// height between the unchecked, typed, and checked states. The glyph is laid out at 0.1pt
/// with a kern of exactly `checkboxAdvance`, so both states occupy identical space and the
/// drawn box is the single source of truth. The advance exceeds the box side by a gap so
/// the label doesn't crowd the box (the space character alone was too tight).
private func checkboxSide(_ f: NSFont) -> CGFloat { (f.capHeight * 1.45).rounded() }
private func checkboxAdvance(_ f: NSFont) -> CGFloat { checkboxSide(f) + (f.pointSize * 0.3).rounded() }

/// Pure list logic: parsing, renumbering, and display markers. Disk stays CommonMark
/// (`- ` bullets, `1. 2. 3.` ordinals at every depth); letters/romans and •/◦/▪ are
/// display-layer only, drawn by DividerLayoutManager over cleared text.
enum ListLogic {
    /// 1=indent  2=bullet/checkbox  3=number  4=content
    static let listRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(?:([-*+☐☑]) |(\d+)\. )(.*)$"#)

    static func match(_ line: String) -> NSTextCheckingResult? {
        listRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    static func letterLabel(_ n: Int) -> String { // 1 → a, 27 → aa
        var n = n, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(97 + n % 26))) + s; n /= 26 }
        return s
    }

    static func romanLabel(_ n: Int) -> String {
        guard n > 0 else { return "\(n)" }
        let pairs: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                                      (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                                      (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = n, s = ""
        for (v, r) in pairs { while n >= v { s += r; n -= v } }
        return s
    }

    /// Ordered: 1. → a. → i. by depth; bullets: • → ◦ → ▪ (cycling every 3 levels).
    static func displayMarker(number: Int?, depth: Int) -> String {
        if let n = number {
            switch depth % 3 {
            case 1: return letterLabel(n) + "."
            case 2: return romanLabel(n) + "."
            default: return "\(n)."
            }
        }
        switch depth % 3 {
        case 1: return "◦"
        case 2: return "▪"
        default: return "•"
        }
    }

    /// Rewrites ordinals so every ordered run counts 1, 2, 3… per depth. A non-list
    /// line breaks all runs; a bullet/checkbox breaks the run at its own depth;
    /// dedenting past a depth resets the deeper counters.
    static func renumber(_ lines: [String]) -> [String] {
        var counters: [Int: Int] = [:] // depth → last ordinal
        return lines.map { line in
            guard let m = match(line) else { counters.removeAll(); return line }
            let ns = line as NSString
            let depth = ns.substring(with: m.range(at: 1)).count / 2
            counters = counters.filter { $0.key <= depth }
            guard m.range(at: 3).location != NSNotFound else {
                counters[depth] = 0
                return line
            }
            let n = (counters[depth] ?? 0) + 1
            counters[depth] = n
            let numR = m.range(at: 3)
            return ns.substring(with: numR) == "\(n)" ? line : ns.replacingCharacters(in: numR, with: "\(n)")
        }
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14
    var design: String = "system"
    var theme: Theme = Theme.named("System")
    /// Titles for the `[[` completion card. A closure, read only when "[[" is typed.
    var noteTitles: () -> [String] = { [] }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 stack so our layout manager can draw full-width dividers
        let storage = NSTextStorage()
        let layout = DividerLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let tv = SmartTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Coordinator.baseFont(fontSize, design)
        tv.textContainerInset = EditorMetrics.inset // room to breathe, like a real notes app
        tv.defaultParagraphStyle = Coordinator.paragraphStyle
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticDashSubstitutionEnabled = false // keep "---" as typed → divider
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        // Highlight only — no .foregroundColor. AppKit's default recolors selected glyphs,
        // which un-hides the `.clear` backing markers ("2." showing under the drawn "b.").
        // Keeping stored colors is also what Notes/Xcode do.
        // Themed, not `selectedTextBackgroundColor`: that's the OS accent, so Nord and
        // Dracula selected their own text in system blue over a themed surface.
        tv.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.32)]
        tv.delegate = context.coordinator
        storage.delegate = context.coordinator
        context.coordinator.textView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = LeanScroller()
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SmartTextView, let storage = tv.textStorage else { return }
        context.coordinator.parent = self
        if context.coordinator.fontSize != fontSize || context.coordinator.design != design
            || context.coordinator.themeID != theme.id {
            context.coordinator.fontSize = fontSize
            context.coordinator.design = design
            // string compare, not the whole Theme: this guard is what keeps a stray
            // updateNSView from re-highlighting the entire document
            context.coordinator.themeID = theme.id
            tv.font = Coordinator.baseFont(fontSize, design)
            tv.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.32)]
            context.coordinator.highlight(storage, range: NSRange(location: 0, length: storage.length))
        }
        if tv.string != text {
            tv.string = text
            // Wholesale replacement — every queued undo action points at ranges in the
            // document that just went away. Only fires on external changes (typing keeps the
            // binding equal via textDidChange), so nothing undoable is lost.
            tv.undoManager?.removeAllActions()
            if text == "# " { // fresh note: caret after the title marker, keyboard ready to type
                tv.setSelectedRange(NSRange(location: 2, length: 0))
                DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
            }
            context.coordinator.highlight(storage, range: NSRange(location: 0, length: storage.length))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextView
        weak var textView: SmartTextView?
        var fontSize: CGFloat = 14
        var design: String = "system"
        var themeID: String = "System"
        private var slashLocation: Int?
        /// "/" or "[[" — what opened the card, and so what its rows are.
        private var slashTrigger = "/"
        private let actionCard = FloatingCard()
        private let slashCard = FloatingCard()
        private var slashItems: [SlashCommand] = []
        private var slashIndex = 0
        private var slashMonitor: Any?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            self.fontSize = parent.fontSize
            self.design = parent.design
        }

        /// Shared leading. MUST also ride in the `base` attribute dict below — `highlight()`
        /// calls `setAttributes`, which replaces every attribute on the range, so a style set
        /// only via `defaultParagraphStyle` would be wiped on the first keystroke.
        static let paragraphStyle: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = EditorMetrics.lineHeightMultiple
            p.paragraphSpacing = EditorMetrics.paragraphSpacing
            return p
        }()

        // MARK: fonts
        static func baseFont(_ size: CGFloat, _ design: String) -> NSFont {
            switch design {
            case "system", "serif", "rounded", "mono":
                let d: NSFontDescriptor.SystemDesign = design == "serif" ? .serif
                    : design == "rounded" ? .rounded
                    : design == "mono" ? .monospaced : .default
                let desc = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(d)
                return desc.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
            default: // a named system-installed font (Avenir Next, Charter, …)
                return NSFont(name: design, size: size) ?? .systemFont(ofSize: size)
            }
        }

        static func bold(_ f: NSFont) -> NSFont {
            NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.bold), size: f.pointSize) ?? f
        }

        // MARK: text change → binding + slash menu
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            tv.needsDisplay = true // placeholders live outside the edited range (see SmartTextView.draw)
            parent.text = tv.string
            updateSlashMenu(tv)
        }

        // MARK: paragraph-scoped highlighting
        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            // Deferred on purpose: layout-affecting attribute edits (kern, fonts) made
            // synchronously inside didProcessEditing leave stale glyph advances on the
            // initial full-document pass, and renumbering mutates text — illegal here.
            // Typed characters don't flash meanwhile because typingAttributes are set
            // explicitly (refreshTypingAttributes).
            guard editedMask.contains(.editedCharacters) else { return }
            let loc = min(editedRange.location, storage.length)
            let safe = NSRange(location: loc, length: min(editedRange.length, storage.length - loc))
            let para = (storage.string as NSString).paragraphRange(for: safe)
            // Must be read HERE: isUndoing is only true while undo executes, and by the time
            // the async block runs it's false again — so the deferred renumber would register
            // a *new* top-level undo group (redo stack cleared, next ⌘Z undoes the renumber).
            // highlight() below still runs: attribute-only, registers nothing, and undone text
            // needs restyling.
            let um = self.textView?.undoManager
            let isUndoRedo = (um?.isUndoing ?? false) || (um?.isRedoing ?? false)
            DispatchQueue.main.async { [weak self, weak storage] in
                guard let self, let storage else { return }
                var range = para
                if let tv = self.textView, !isUndoRedo, !self.isRenumbering, !tv.hasMarkedText() {
                    self.isRenumbering = true
                    self.renumberListBlock(tv, around: para.location)
                    self.isRenumbering = false
                    // renumbering may have shifted lengths; re-clamp, keeping the full span —
                    // an Enter edit covers TWO paragraphs (split line + new line), and collapsing
                    // to one left the new line unstyled (raw "2."/"☐") until the next keystroke
                    let ns = storage.string as NSString
                    let loc = min(para.location, ns.length)
                    let len = min(para.length, ns.length - loc)
                    range = ns.paragraphRange(for: NSRange(location: loc, length: len))
                }
                self.highlight(storage, range: range)
            }
        }

        private var isRenumbering = false

        /// One pass over the contiguous list block around the edit — covers Enter, Tab,
        /// Backspace, paste, and undo without per-command bookkeeping. Only ordinals that
        /// actually differ are rewritten; the changed lines re-highlight via their own
        /// didProcessEditing round (a fixpoint: the second pass changes nothing).
        private func renumberListBlock(_ tv: NSTextView, around loc: Int) {
            guard let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            guard ns.length > 0 else { return }
            let anchor = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
            func isList(_ r: NSRange) -> Bool {
                ListLogic.match(ns.substring(with: r)) != nil
            }
            var start = anchor.location
            while start > 0 {
                let prev = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
                guard isList(prev) else { break }
                start = prev.location
            }
            var end = anchor.location + anchor.length
            while end < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
                guard isList(next) else { break }
                end = next.location + next.length
            }
            let block = NSRange(location: start, length: end - start)
            guard block.length > 0 else { return }

            var lineRanges: [NSRange] = []
            var lines: [String] = []
            ns.enumerateSubstrings(in: block, options: [.byParagraphs]) { sub, subR, _, _ in
                lineRanges.append(subR)
                lines.append(sub ?? "")
            }
            let fixed = ListLogic.renumber(lines)
            var edits: [(NSRange, String)] = [] // number subrange in storage coords → new digits
            for (i, new) in fixed.enumerated() where new != lines[i] {
                guard let m = ListLogic.match(lines[i]), m.range(at: 3).location != NSNotFound,
                      let f = ListLogic.match(new), f.range(at: 3).location != NSNotFound else { continue }
                let numR = NSRange(location: lineRanges[i].location + m.range(at: 3).location,
                                   length: m.range(at: 3).length)
                edits.append((numR, (new as NSString).substring(with: f.range(at: 3))))
            }
            guard !edits.isEmpty else { return }

            let sel = tv.selectedRange()
            var delta = 0
            for (r, s) in edits.reversed() { // back-to-front keeps earlier offsets valid
                guard tv.shouldChangeText(in: r, replacementString: s) else { continue }
                storage.replaceCharacters(in: r, with: s)
                tv.didChangeText()
                if r.location < sel.location { delta += (s as NSString).length - r.length }
            }
            tv.setSelectedRange(NSRange(location: max(0, sel.location + delta), length: sel.length))
        }

        private var cachedRules: (size: CGFloat, design: String, theme: String,
                                  base: [NSAttributedString.Key: Any],
                                  rules: [(NSRegularExpression, [NSAttributedString.Key: Any])])?

        private func rules() -> (base: [NSAttributedString.Key: Any],
                                 rules: [(NSRegularExpression, [NSAttributedString.Key: Any])]) {
            if let c = cachedRules, c.size == fontSize, c.design == design, c.theme == themeID {
                return (c.base, c.rules)
            }
            let theme = Theme.named(themeID)
            func re(_ p: String) -> NSRegularExpression {
                try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
            }
            let f = Self.baseFont(fontSize, design)
            let base: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.labelColor,
                                                       .paragraphStyle: Self.paragraphStyle]
            let tinyFont = NSFont.systemFont(ofSize: 0.1)
            func checkKern(_ glyph: String) -> CGFloat {
                checkboxAdvance(f) - (glyph as NSString).size(withAttributes: [.font: tinyFont]).width
            }
            // headings get air above them; body spacing stays at the shared style's 6pt.
            // minimumLineHeight floors the line at the heading font's height — the hidden
            // "#{1,3} " marker is 0.1pt, so an empty "# " line (every fresh note) would
            // otherwise collapse to a ~2pt fragment with an invisible caret.
            func headingStyle(_ before: CGFloat, _ hFont: NSFont) -> NSParagraphStyle {
                let p = Self.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacingBefore = before
                p.minimumLineHeight = (NSLayoutManager().defaultLineHeight(for: hFont)
                    * EditorMetrics.lineHeightMultiple).rounded()
                return p
            }
            // typographic scale: H1 ≈ 1.6×, H2 ≈ 1.3×, H3 ≈ 1.15× body
            let (o1, o2, o3) = EditorMetrics.headingOffsets
            let (b1, b2, b3) = EditorMetrics.headingSpaceBefore
            let h1 = Self.bold(Self.baseFont(fontSize + o1, design))
            let h2 = Self.bold(Self.baseFont(fontSize + o2, design))
            let h3 = Self.bold(Self.baseFont(fontSize + o3, design))
            let list: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
                (re(#"^# .*$"#), [.font: h1, .paragraphStyle: headingStyle(b1, h1)]),
                (re(#"^## .*$"#), [.font: h2, .paragraphStyle: headingStyle(b2, h2)]),
                (re(#"^### .*$"#), [.font: h3, .paragraphStyle: headingStyle(b3, h3)]),
                // hide the hash marks entirely so headers read as rendered titles
                // (no lookahead: a bare "# " collapses immediately, so the line never
                // jumps left when the first title character lands)
                (re(#"^#{1,3} "#), [.foregroundColor: NSColor.clear,
                                    .font: NSFont.systemFont(ofSize: 0.1)]),
                (re(#"\*\*[^*\n]+\*\*"#), [.font: Self.bold(f)]),
                (re(#"(?<!\*)\*[^*\n]+\*(?!\*)"#), [.obliqueness: 0.15]),
                (re(#"~~[^~\n]+~~"#), [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                // a chip, not just a colour: monospace on a tinted background reads as code
                // at a glance; the backticks stay (editable) but recede to tertiary
                (re(#"`[^`\n]+`"#), [.font: NSFont.monospacedSystemFont(
                                        ofSize: fontSize + EditorMetrics.codeSizeDelta, weight: .regular),
                                     .foregroundColor: theme.code, codeKey: true]),
                // the ticks read as stray quotes at 11pt; hide them the way "# " is hidden
                (re(#"`(?=[^`\n]+`)|(?<=`[^`\n]{1,200})`"#), [.foregroundColor: NSColor.clear, .font: tinyFont]),
                // strike/dim only the text after a checked box (fixed 2-char lookbehind)
                // 0.45, a step below secondary (~0.5): a done item should recede further
                // than the 1.5pt tertiary outline of an item still waiting to be ticked.
                (re(#"(?<=^\s{0,40}☑ ).*$"#), [.foregroundColor: NSColor.labelColor.withAlphaComponent(0.45),
                                      .strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                // hide the raw glyph AND neutralize its fallback-font layout: 0.1pt font +
                // a kern that pins the advance to the drawn box width, so ☐ and ☑ occupy
                // identical space (no text shift or line-height jump on toggle/typing)
                // line-start only (bounded lookbehind = the indent): a ☐ that lands mid-line
                // stays a visible glyph instead of a fake box nothing can toggle
                (re(#"(?<=^\s{0,40})☐"#), [.foregroundColor: NSColor.clear, .font: tinyFont,
                             .kern: checkKern("☐"), checkboxKey: false]),
                (re(#"(?<=^\s{0,40})☑"#), [.foregroundColor: NSColor.clear, .font: tinyFont,
                             .kern: checkKern("☑"), checkboxKey: true]),
                // dashes hidden; DividerLayoutManager draws a full-width rule instead
                (re(#"^\s*[-—]{3,}\s*$"#), [.foregroundColor: NSColor.clear, dividerKey: true]),
            ]
            cachedRules = (fontSize, design, themeID, base, list)
            listStyleCache.removeAll()
            prefixWidthCache.removeAll()
            return (base, list)
        }

        func highlight(_ storage: NSTextStorage, range: NSRange) {
            guard range.location + range.length <= storage.length else { return }
            let lmTheme = Theme.named(themeID)
            (storage.layoutManagers.first as? DividerLayoutManager)?.accent = lmTheme.accent
            (storage.layoutManagers.first as? DividerLayoutManager)?.code = lmTheme.code
            let (base, list) = rules()
            storage.beginEditing()
            storage.setAttributes(base, range: range)
            for (regex, attrs) in list {
                regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                    if let r = match?.range { storage.addAttributes(attrs, range: r) }
                }
            }
            // [text](url): the text becomes a real link (accent, underline, click opens),
            // the brackets and the target recede. Per-group attributes, hence not in `list`.
            let accent = Theme.named(themeID).accent
            Self.linkRegex.enumerateMatches(in: storage.string, range: range) { m, _, _ in
                guard let m else { return }
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: m.range)
                let text = m.range(at: 1), target = m.range(at: 2)
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
                let raw = (storage.string as NSString).substring(with: target)
                if let url = URL(string: raw), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
                    attrs[.link] = url
                }
                storage.addAttributes(attrs, range: text)
            }
            // [[Title]]: same look, and the target is the app's own URL scheme, so the click
            // path (SmartTextView.mouseDown → NSWorkspace → AppDelegate.handleURL) needs
            // nothing new — and Raycast can open notes by title with the same URL.
            Self.wikiRegex.enumerateMatches(in: storage.string, range: range) { m, _, _ in
                guard let m else { return }
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: m.range)
                let title = (storage.string as NSString).substring(with: m.range(at: 1))
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
                if let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "gitpad://note?title=" + q) { attrs[.link] = url }
                storage.addAttributes(attrs, range: m.range(at: 1))
            }
            applyListLayout(storage, in: range)
            storage.endEditing()
            if let tv = textView {
                // .link ranges draw with these, not the storage colour — keep them in the theme
                tv.linkTextAttributes = [.foregroundColor: accent, .cursor: NSCursor.pointingHand,
                                         .underlineStyle: NSUnderlineStyle.single.rawValue]
                refreshTypingAttributes(tv)
            }
        }

        /// `[text](target)` — text can't contain `]`, target can't contain `)`.
        static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\n]*)\)"#)
        /// `[[Title]]` — a note by its title.
        static let wikiRegex = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)

        // MARK: list layout — hanging indents + display markers
        private var listStyleCache: [String: NSParagraphStyle] = [:]
        private var prefixWidthCache: [String: CGFloat] = [:]

        /// Per list paragraph: a hanging indent so wrapped lines align under the content
        /// (not the margin), a real per-depth visual indent (2 literal spaces alone are
        /// ~7pt — invisible), and a display marker (• ◦ ▪ / 1. a. i.) drawn by the layout
        /// manager over the cleared source marker. Disk text is untouched.
        private func applyListLayout(_ storage: NSTextStorage, in range: NSRange) {
            let ns = storage.string as NSString
            let font = Self.baseFont(fontSize, design)
            let unit = (fontSize * EditorMetrics.indentUnitFactor).rounded() // extra indent per nest level
            ns.enumerateSubstrings(in: range, options: [.byParagraphs]) { sub, subR, _, _ in
                guard let line = sub, let m = ListLogic.match(line) else { return }
                let lineNS = line as NSString
                let depth = lineNS.substring(with: m.range(at: 1)).count / 2
                let prefix = lineNS.substring(to: m.range(at: 4).location) // indent + marker + " "

                let width: CGFloat
                if let w = self.prefixWidthCache[prefix] { width = w } else {
                    let marker = m.range(at: 2).location != NSNotFound
                        ? lineNS.substring(with: m.range(at: 2)) : ""
                    if marker == "☐" || marker == "☑" {
                        // the glyph's layout advance is pinned to checkboxAdvance, not its
                        // fallback-font width — measure the rest and add the pinned advance
                        let rest = lineNS.substring(with: m.range(at: 1)) + " "
                        width = (rest as NSString).size(withAttributes: [.font: font]).width
                            + checkboxAdvance(font)
                    } else {
                        width = (prefix as NSString).size(withAttributes: [.font: font]).width
                    }
                    self.prefixWidthCache[prefix] = width
                }
                let key = "\(depth)|\(width)"
                let style: NSParagraphStyle
                if let s = self.listStyleCache[key] { style = s } else {
                    let p = NSMutableParagraphStyle()
                    p.lineHeightMultiple = EditorMetrics.lineHeightMultiple
                    // tighter inside lists; same for bullets and numbers
                    p.paragraphSpacing = EditorMetrics.listParagraphSpacing
                    p.firstLineHeadIndent = CGFloat(depth) * unit
                    p.headIndent = p.firstLineHeadIndent + width // wrap under the content
                    self.listStyleCache[key] = p
                    style = p
                }
                storage.addAttribute(.paragraphStyle, value: style, range: subR)

                // bullets and numbers get a drawn display marker; checkboxes are drawn already
                let bulletR = m.range(at: 2)
                let numberR = m.range(at: 3)
                if numberR.location != NSNotFound {
                    let n = Int(lineNS.substring(with: numberR)) ?? 0
                    let markerR = NSRange(location: subR.location + numberR.location,
                                          length: numberR.length + 1) // digits + "."
                    storage.addAttributes([.foregroundColor: NSColor.clear,
                                           markerKey: ListLogic.displayMarker(number: n, depth: depth)],
                                          range: markerR)
                } else if bulletR.location != NSNotFound {
                    let marker = lineNS.substring(with: bulletR)
                    if marker != "☐" && marker != "☑" {
                        let markerR = NSRange(location: subR.location + bulletR.location, length: bulletR.length)
                        storage.addAttributes([.foregroundColor: NSColor.clear,
                                               markerKey: ListLogic.displayMarker(number: nil, depth: depth)],
                                              range: markerR)
                    }
                }
            }
        }

        /// NSTextView derives typingAttributes from the character before the caret — right
        /// after a hidden marker that's clear + 0.1pt, so the first character typed was
        /// invisible for a frame. Set them explicitly from the paragraph context instead.
        func refreshTypingAttributes(_ tv: NSTextView) {
            let (base, _) = rules()
            var attrs = base
            let ns = tv.string as NSString
            let caret = min(tv.selectedRange().location, ns.length)
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: caret, length: 0)))
            let (o1, o2, o3) = EditorMetrics.headingOffsets
            if line.hasPrefix("# ") { attrs[.font] = Self.bold(Self.baseFont(fontSize + o1, design)) }
            else if line.hasPrefix("## ") { attrs[.font] = Self.bold(Self.baseFont(fontSize + o2, design)) }
            else if line.hasPrefix("### ") { attrs[.font] = Self.bold(Self.baseFont(fontSize + o3, design)) }
            tv.typingAttributes = attrs
        }

        // MARK: auto list continuation
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { return continueList(tv) }
            if selector == #selector(NSResponder.insertTab(_:)) { return indentList(tv, out: false) }
            if selector == #selector(NSResponder.insertBacktab(_:)) { return indentList(tv, out: true) }
            if selector == #selector(NSResponder.deleteBackward(_:)) { return smartDeleteBackward(tv) }
            // Esc with text selected drops the selection (and so the selection bar); the
            // next Esc steps back as usual via `PanelWindow.cancelOperation`.
            if selector == #selector(NSResponder.cancelOperation(_:)), tv.selectedRange().length > 0 {
                tv.setSelectedRange(NSRange(location: NSMaxRange(tv.selectedRange()), length: 0))
                return true
            }
            return false
        }

        /// Replace `r` with `s` through the undo-aware channel, WITHOUT the caret-moves-to-
        /// end-of-insertion behavior of insertText(_:replacementRange:).
        private func replaceText(_ tv: NSTextView, _ r: NSRange, _ s: String) -> Bool {
            guard tv.shouldChangeText(in: r, replacementString: s), let storage = tv.textStorage else { return false }
            storage.replaceCharacters(in: r, with: s)
            tv.didChangeText()
            return true
        }

        /// Tab / Shift-Tab nest list items by two spaces per level. Caret and selection are
        /// preserved (mapped through the edits), so repeated Tab on a block works. Markdown
        /// nests via leading whitespace and `to/fromMarkdown` preserves it. Tab never emits
        /// a literal \t — that's an indented code block in Markdown on disk.
        private func indentList(_ tv: NSTextView, out: Bool) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            var scan = sel
            if scan.length > 0, ns.lineRange(for: NSRange(location: scan.location + scan.length, length: 0))
                .location == scan.location + scan.length {
                scan.length -= 1 // selection ends exactly at a line start → don't drag that line in
            }
            let span = ns.lineRange(for: scan)
            var starts: [Int] = [] // line starts that are list items (span may be one empty line)
            var i = span.location
            repeat {
                let lr = ns.lineRange(for: NSRange(location: i, length: 0))
                if ListLogic.match(ns.substring(with: lr)) != nil { starts.append(lr.location) }
                i = lr.location + lr.length
            } while i < span.location + span.length
            if starts.isEmpty {
                guard !out else { return true } // shift-tab outside a list: no-op
                tv.insertText("  ", replacementRange: sel) // plain tab → two spaces
                return true
            }

            // No explicit undo group: groupsByEvent already opened one for this Tab press, so
            // nesting here pushed an empty group whenever every replaceText skipped — and an
            // empty group silently swallows one ⌘Z.
            var edits: [(Int, Int)] = [] // (line start, char delta)
            for start in starts.sorted(by: >) { // back-to-front keeps earlier offsets valid
                if !out {
                    if replaceText(tv, NSRange(location: start, length: 0), "  ") { edits.append((start, 2)) }
                } else if start < ns.length, ns.substring(with: NSRange(location: start, length: 1)) == "\t" {
                    if replaceText(tv, NSRange(location: start, length: 1), "") { edits.append((start, -1)) }
                } else {
                    var n = 0 // strip up to two leading spaces
                    while n < 2, start + n < ns.length,
                          ns.substring(with: NSRange(location: start + n, length: 1)) == " " { n += 1 }
                    if n > 0, replaceText(tv, NSRange(location: start, length: n), "") { edits.append((start, -n)) }
                }
            }

            var mapped = sel // map the original selection through the edits
            for (loc, d) in edits {
                if loc <= mapped.location { mapped.location = max(mapped.location + d, loc) }
                else if loc < mapped.location + mapped.length { mapped.length = max(mapped.length + d, 0) }
            }
            tv.setSelectedRange(mapped)
            return true
        }

        private func continueList(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let caret = tv.selectedRange().location
            let lineR = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
            let upToCaret = ns.substring(with: NSRange(location: lineR.location, length: caret - lineR.location))
            let lineNS = upToCaret as NSString
            guard let m = ListLogic.match(upToCaret) else { return false }
            let content = lineNS.substring(with: m.range(at: 4))
            if content.isEmpty {
                let indent = lineNS.substring(with: m.range(at: 1))
                if indent.count >= 2 { // nested empty item: outdent one level, keep the marker
                    if replaceText(tv, NSRange(location: lineR.location, length: 2), "") {
                        tv.setSelectedRange(NSRange(location: caret - 2, length: 0))
                    }
                } else { // top level: exit the list
                    tv.insertText("", replacementRange: NSRange(location: lineR.location, length: caret - lineR.location))
                }
                return true
            }
            var prefix = lineNS.substring(with: m.range(at: 1))
            if m.range(at: 3).location != NSNotFound, let n = Int(lineNS.substring(with: m.range(at: 3))) {
                prefix += "\(n + 1). "
            } else {
                let marker = lineNS.substring(with: m.range(at: 2))
                prefix += (marker == "☐" || marker == "☑") ? "☐ " : marker + " "
            }
            tv.insertText("\n" + prefix, replacementRange: tv.selectedRange())
            return true
        }

        static let headingPrefix = try! NSRegularExpression(pattern: #"^#{1,3} "#)

        /// Backspace with the caret right after a list or heading marker removes the whole
        /// marker in one go (Notes-style) — a title drops back to plain text instead of
        /// leaving a stray "#", and a stripped ☐ never lingers invisibly.
        private func smartDeleteBackward(_ tv: NSTextView) -> Bool {
            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location > 0 else { return false }
            let ns = tv.string as NSString
            let lineR = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            let line = ns.substring(with: lineR)
            if let h = Self.headingPrefix.firstMatch(in: line,
                    range: NSRange(location: 0, length: (line as NSString).length)),
               sel.location == lineR.location + h.range.length {
                let r = NSRange(location: lineR.location, length: h.range.length)
                if replaceText(tv, r, "") { tv.setSelectedRange(NSRange(location: lineR.location, length: 0)) }
                return true
            }
            guard let m = ListLogic.match(line) else { return false }
            let contentStart = lineR.location + m.range(at: 4).location
            guard sel.location == contentStart else { return false }
            let markerLoc = m.range(at: 2).location != NSNotFound ? m.range(at: 2).location
                                                                  : m.range(at: 3).location
            let r = NSRange(location: lineR.location + markerLoc,
                            length: m.range(at: 4).location - markerLoc)
            if replaceText(tv, r, "") { tv.setSelectedRange(NSRange(location: r.location, length: 0)) }
            return true
        }

        // MARK: slash commands

        /// The "/" menu. Rebuilt fresh each keystroke so Date/Time preview the value they'd
        /// actually insert.
        private static func slashCommands() -> [SlashCommand] {
            let now = Date()
            return [
                SlashCommand("Title", "textformat.size", "# ", aliases: ["h1", "heading", "header"]),
                SlashCommand("Subtitle", "textformat", "## ", aliases: ["h2", "heading 2", "subheading"]),
                SlashCommand("Bullet List", "list.bullet", "- ", aliases: ["bullets", "list", "ul", "unordered"]),
                SlashCommand("To-do", "checklist", "☐ ", aliases: ["todo", "checkbox", "checklist", "task", "check"]),
                SlashCommand("Numbered List", "list.number", "1. ", aliases: ["numbered", "ordered", "ol", "numbers"]),
                SlashCommand("Date", "calendar", now.formatted(date: .abbreviated, time: .omitted) + " ", aliases: ["today"]),
                SlashCommand("Date & Time", "clock",
                             now.formatted(date: .abbreviated, time: .shortened) + " "),
                SlashCommand("Divider", "minus", "---\n", aliases: ["hr", "line", "rule", "separator"]),
            ]
        }

        /// Non-modal, unlike the `NSMenu` this replaces: `popUp` runs its own event loop, so
        /// the caret vanished and the first typed character dismissed it — "/da↩" for Date,
        /// the thing a slash menu exists for, could never work. Here the "/" and the query
        /// stay in the document as ordinary text, the card just filters alongside, and any
        /// character that matches nothing puts the editor straight back to being an editor.
        private func updateSlashMenu(_ tv: NSTextView) {
            let ns = tv.string as NSString
            let caret = tv.selectedRange().location

            if slashLocation == nil {
                guard caret > 0, caret <= ns.length else { return }
                let c = ns.character(at: caret - 1)
                let prev: UInt16? = caret >= 2 ? ns.character(at: caret - 2) : nil
                if c == UInt16(UnicodeScalar("/").value), prev == nil || prev == 32 || prev == 10 || prev == 9 {
                    slashTrigger = "/"; slashLocation = caret - 1
                } else if c == UInt16(UnicodeScalar("[").value), prev == UInt16(UnicodeScalar("[").value) {
                    slashTrigger = "[["; slashLocation = caret - 2 // the first "["
                } else { return }
                slashIndex = 0
            }

            guard let loc = slashLocation, caret > loc, caret <= ns.length else { return dismissSlash() }
            let query = ns.substring(with: NSRange(location: loc + slashTrigger.count,
                                                   length: caret - loc - slashTrigger.count))
            let all: [SlashCommand]
            if slashTrigger == "/" {
                // a space or punctuation means you were writing, not choosing
                guard query.allSatisfy({ $0.isLetter || $0.isNumber }) else { return dismissSlash() }
                all = Self.slashCommands()
            } else {
                // titles have spaces; "]" or a newline means the link was finished by hand
                guard !query.contains("]"), !query.contains("\n") else { return dismissSlash() }
                all = parent.noteTitles().map { SlashCommand($0, "doc.text", "[[\($0)]] ") }
            }
            let hits = query.isEmpty ? all : all.filter { $0.matches(query) }
            guard !hits.isEmpty else { return dismissSlash() }
            slashTotal = hits.count
            slashItems = Array(hits.prefix(8)) // the card is eight rows tall
            slashIndex = min(slashIndex, slashItems.count - 1)
            showSlash(tv, at: loc, query: query)
        }

        private var slashTotal = 0
        /// Test seam: rows the card currently offers (0 = no card).
        var completionCount: Int { slashItems.count }

        private func showSlash(_ tv: NSTextView, at loc: Int, query: String) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let gr = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1),
                                   actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: gr, in: tc)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y
            slashCard.show(SlashMenuCard(items: slashItems, index: slashIndex, query: query, total: slashTotal,
                                         onPick: { [weak self] in self?.insertSnippet($0) })
                            .environment(\.theme, Theme.named(themeID)),
                           above: rect, of: tv)
            if slashMonitor == nil {
                // The text view keeps key focus (that's the point), so ↑↓↩esc have to be
                // intercepted before it sees them. Same local-monitor pattern as the palette
                // and HotkeyRecorder, scoped to the card's lifetime.
                slashMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.slashCard.isVisible else { return event }
                    switch Int(event.keyCode) {
                    case kVK_UpArrow: self.moveSlash(-1); return nil
                    case kVK_DownArrow: self.moveSlash(1); return nil
                    case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab:
                        if self.slashItems.indices.contains(self.slashIndex) {
                            self.insertSnippet(self.slashItems[self.slashIndex])
                        }
                        return nil
                    case kVK_Escape: self.dismissSlash(); return nil
                    default: return event
                    }
                }
            }
        }

        private func moveSlash(_ delta: Int) {
            guard !slashItems.isEmpty, let tv = textView, let loc = slashLocation else { return }
            slashIndex = min(max(0, slashIndex + delta), slashItems.count - 1)
            let caret = tv.selectedRange().location
            let query = (tv.string as NSString).substring(with: NSRange(location: loc + 1,
                                                                        length: max(0, caret - loc - 1)))
            showSlash(tv, at: loc, query: query)
        }

        func closeFloatingCards() {
            actionCard.close()
            dismissSlash()
        }

        func dismissSlash() {
            slashLocation = nil
            slashItems = []
            slashIndex = 0
            slashCard.close()
            if let m = slashMonitor { NSEvent.removeMonitor(m); slashMonitor = nil }
        }

        /// Replaces "/" and everything typed after it — so the snippet lands where the
        /// query was, leaving no crumbs. A block command typed right after an existing
        /// marker ("☐ /title", "- /numbered") replaces that marker instead of nesting.
        private func insertSnippet(_ cmd: SlashCommand) {
            guard let tv = textView, let loc = slashLocation else { return }
            let caret = tv.selectedRange().location
            let ns = tv.string as NSString
            guard loc < ns.length, caret >= loc, caret <= ns.length else { return dismissSlash() }
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let local = Self.blockReplaceRange(line: ns.substring(with: para), slash: loc - para.location,
                                               caret: caret - para.location, snippet: cmd.snippet)
            tv.insertText(cmd.snippet, replacementRange: NSRange(location: para.location + local.location,
                                                                 length: local.length))
            dismissSlash()
        }

        /// The paragraph-local range a snippet replaces. Plain case: the "/" and the query.
        /// Block commands also swallow a marker the slash sits *after* (`blockStart`) or
        /// *in front of* — "/todo" typed at the start of "☐ Central Park" used to yield two
        /// boxes; now the old one goes.
        static func blockReplaceRange(line: String, slash: Int, caret: Int, snippet: String) -> NSRange {
            let plain = NSRange(location: slash, length: caret - slash)
            guard blockSnippets.contains(snippet) else { return plain }
            let ns = line as NSString
            let before = ns.substring(to: slash)
            if let start = blockStart(before: before, snippet: snippet) {
                return NSRange(location: start, length: caret - start)
            }
            guard before.trimmingCharacters(in: .whitespaces).isEmpty, caret <= ns.length else { return plain }
            let rest = ns.substring(from: caret)
            let restNS = rest as NSString
            let markerLen: Int
            if let h = headingPrefix.firstMatch(in: rest, range: NSRange(location: 0, length: restNS.length)) {
                markerLen = h.range.length
            } else if let m = ListLogic.match(rest), m.range(at: 1).length == 0 {
                markerLen = m.range(at: 4).location
            } else { return plain }
            let start = snippet.hasPrefix("#") ? 0 : slash // headings never indent
            return NSRange(location: start, length: caret + markerLen - start)
        }

        static let blockSnippets: Set<String> = ["# ", "## ", "- ", "☐ ", "1. "]

        /// Where a block snippet should start replacing, as an offset into the paragraph —
        /// nil means "just replace the slash query". `before` is the paragraph text up to
        /// the "/". Only fires when that text is *exactly* a marker (plus indent) or a
        /// heading prefix: "☐ some words /title" is an ordinary insert.
        static func blockStart(before: String, snippet: String) -> Int? {
            guard blockSnippets.contains(snippet) else { return nil }
            let ns = before as NSString
            if headingPrefix.firstMatch(in: before, range: NSRange(location: 0, length: ns.length))?.range.length == ns.length {
                return 0 // "# " → any block replaces the heading outright
            }
            let (indent, body) = split(before)
            guard body.isEmpty, ns.length > (indent as NSString).length else { return nil } // a marker, nothing after
            // headings never indent; lists keep their nesting
            return snippet.hasPrefix("#") ? 0 : (indent as NSString).length
        }

        // MARK: highlight-to-actions mini toolbar

        /// Selection changes fire continuously *during* a drag, so this only closes the bar
        /// (an empty selection) and refreshes one that's already up. Opening waits for
        /// `selectionSettled` — mouse-up, or a keyboard selection — which is what makes the
        /// bar feel like it appears with your hand rather than a quarter-second behind it.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if let snapped = Self.caretOutsideMarker(tv.string, caret: tv.selectedRange(), previous: lastCaret) {
                tv.setSelectedRange(NSRange(location: snapped, length: 0)) // re-enters here with a clean caret
                return
            }
            lastCaret = tv.selectedRange().location
            refreshTypingAttributes(tv)
            if tv.selectedRange().length == 0 {
                actionCard.close()
            } else if actionCard.isVisible || NSEvent.pressedMouseButtons == 0 {
                showActions()
            }
        }

        private var lastCaret = 0

        /// The heading hashes and list markers are drawn as something else (nothing, a
        /// checkbox, a bullet) and are ~0pt wide, so a caret inside them sits on top of the
        /// drawn glyph. Where it should go instead, or nil if it's fine where it is:
        /// one step Left from the content start hops to the previous line's end (what
        /// Left means there); anything else lands on the content start.
        static func caretOutsideMarker(_ text: String, caret: NSRange, previous: Int) -> Int? {
            guard caret.length == 0 else { return nil }
            let ns = text as NSString
            guard caret.location <= ns.length else { return nil }
            let lineR = ns.lineRange(for: NSRange(location: caret.location, length: 0))
            let line = ns.substring(with: lineR)
            let markerStart: Int, contentStart: Int
            if let h = headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                markerStart = 0; contentStart = h.range.length
            } else if let m = ListLogic.match(line) {
                markerStart = m.range(at: 1).length; contentStart = m.range(at: 4).location
            } else { return nil }
            let local = caret.location - lineR.location
            guard local >= markerStart, local < contentStart else { return nil }
            let content = lineR.location + contentStart
            if previous == content, lineR.location > 0 { return lineR.location - 1 }
            return content
        }

        /// Called from `SmartTextView.mouseUp`: the drag is over, the selection is final.
        func selectionSettled() {
            showActions()
        }

        @objc func showActions() {
            guard let tv = textView, tv.window != nil, tv.selectedRange().length > 0,
                  tv.window?.firstResponder === tv, // no bar while the ⌘K palette holds focus
                  let lm = tv.layoutManager, let tc = tv.textContainer else {
                actionCard.close()
                return
            }
            // pure view-space geometry — screen-space conversion put the bar far from the text
            let gr = lm.glyphRange(forCharacterRange: tv.selectedRange(), actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: gr, in: tc)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y
            guard rect.width > 0, rect.height > 0 else { return }
            // Above by default (it's where the eye already is); below when the selection is
            // in the top ~1.5 lines of the visible editor, where "above" would sit on the
            // title or the header instead of over empty margin.
            let visible = tv.enclosingScrollView?.documentVisibleRect ?? tv.bounds
            let below = rect.minY - visible.minY < 48
            actionCard.show(ActionBar(coordinator: self, active: activeMarks(), block: blockLabel())
                                .environment(\.theme, Theme.named(themeID)),
                            above: rect, of: tv, below: below)
        }

        /// Which inline marks the selection already carries — the same two shapes `wrap`
        /// toggles (marks inside the selection, or wrapped around it), so a lit button and
        /// what the next tap does can't disagree.
        func activeMarks() -> Set<String> {
            guard let tv = textView else { return [] }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            guard sel.length > 0 else { return [] }
            let s = ns.substring(with: sel)
            var out: Set<String> = []
            if s.contains("\n") { // multi-line: lit when every line is wrapped (what `wrap` would strip)
                for mark in ["**", "*", "~~", "`"]
                where (Self.wrapLines(s, mark) as NSString).length < (s as NSString).length { out.insert(mark) }
                if out.contains("**") { out.remove("*") }
                return out
            }
            for mark in ["**", "*", "~~", "`"] {
                let n = (mark as NSString).length
                let inside = sel.length >= 2 * n && s.hasPrefix(mark) && s.hasSuffix(mark)
                let around = sel.location >= n && sel.location + sel.length + n <= ns.length
                    && ns.substring(with: NSRange(location: sel.location - n, length: n)) == mark
                    && ns.substring(with: NSRange(location: sel.location + sel.length, length: n)) == mark
                if inside || around { out.insert(mark) }
            }
            // "*" matches inside "**" as well; bold wins, exactly as `wrap` resolves it
            if out.contains("**") { out.remove("*") }
            return out
        }

        /// The selection's paragraph type, named — so the block menu says what you're in
        /// before you open it.
        func blockLabel() -> String {
            guard let tv = textView else { return "Body" }
            let ns = tv.string as NSString
            let line = ns.substring(with: ns.paragraphRange(for: tv.selectedRange()))
                .components(separatedBy: "\n").first ?? ""
            if line.hasPrefix("# ") { return "Title" }
            if line.hasPrefix("## ") { return "Subtitle" }
            guard let m = ListLogic.match(line) else { return "Body" }
            guard m.range(at: 2).location != NSNotFound else { return "Numbered" }
            let marker = (line as NSString).substring(with: m.range(at: 2))
            return (marker == "☐" || marker == "☑") ? "Checklist" : "Bullets"
        }

        /// Toggle, not just wrap: the mark comes off text that already carries it, so a
        /// second tap on Bold un-bolds instead of producing `****text****`. The selection
        /// survives either way (kept on the plain text) so taps keep toggling.
        /// ponytail: `*` on a `**x**` selection strips one pair — bold becomes italic
        /// rather than nesting. Nesting the same family is the rarer intent.
        func wrap(_ mark: String) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let s = ns.substring(with: sel)
            let n = (mark as NSString).length

            // Markdown inline marks stop at a paragraph, so a selection spanning lines is
            // wrapped line by line, after any list marker or heading prefix. Toggle as a
            // whole: every non-empty line already marked → unmark every line.
            if s.contains("\n") {
                let out = Self.wrapLines(s, mark)
                if replaceText(tv, sel, out) {
                    tv.setSelectedRange(NSRange(location: sel.location, length: (out as NSString).length))
                }
                showActions()
                return
            }

            if sel.length >= 2 * n, s.hasPrefix(mark), s.hasSuffix(mark) { // marks inside the selection
                let inner = (s as NSString).substring(with: NSRange(location: n, length: sel.length - 2 * n))
                if replaceText(tv, sel, inner) {
                    tv.setSelectedRange(NSRange(location: sel.location, length: sel.length - 2 * n))
                }
            } else if sel.location >= n, sel.location + sel.length + n <= ns.length, // marks around it
                      ns.substring(with: NSRange(location: sel.location - n, length: n)) == mark,
                      ns.substring(with: NSRange(location: sel.location + sel.length, length: n)) == mark {
                let wide = NSRange(location: sel.location - n, length: sel.length + 2 * n)
                if replaceText(tv, wide, s) {
                    tv.setSelectedRange(NSRange(location: wide.location, length: sel.length))
                }
            } else if replaceText(tv, sel, mark + s + mark) {
                tv.setSelectedRange(NSRange(location: sel.location + n, length: sel.length))
            }
            showActions()
        }

        /// Per-line wrap/unwrap for `wrap`. Pure, so the selftest can pin it down.
        static func wrapLines(_ text: String, _ mark: String) -> String {
            let lines = text.components(separatedBy: "\n")
            func parts(_ line: String) -> (prefix: String, body: String) {
                let ns = line as NSString
                if let h = headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    return (ns.substring(to: h.range.length), ns.substring(from: h.range.length))
                }
                if let m = ListLogic.match(line) {
                    return (ns.substring(to: m.range(at: 4).location), ns.substring(with: m.range(at: 4)))
                }
                return ("", line)
            }
            let filled = lines.filter { !parts($0).body.trimmingCharacters(in: .whitespaces).isEmpty }
            let strip = !filled.isEmpty && filled.allSatisfy {
                let b = parts($0).body
                return b.count >= 2 * mark.count && b.hasPrefix(mark) && b.hasSuffix(mark)
            }
            return lines.map { line -> String in
                let (prefix, body) = parts(line)
                guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if strip { return prefix + String(body.dropFirst(mark.count).dropLast(mark.count)) }
                return prefix + mark + body + mark
            }.joined(separator: "\n")
        }

        func makeTodo() { makeList("☐ ") }

        /// Back to plain text: whichever block marker the paragraph wears, toggling that
        /// same family off is what `makeList`/`setHeading` already do.
        func makeBody() {
            switch blockLabel() {
            case "Title": setHeading(1)
            case "Subtitle": setHeading(2)
            case "Bullets": makeList("- ")
            case "Numbered": makeList("1. ")
            case "Checklist": makeTodo()
            default: break
            }
        }

        /// Convert the selected paragraphs to a `prefix` list. Every line already in that
        /// marker family → strip back to plain text, so the button toggles. `"1. "` inserts
        /// the literal prefix and lets the deferred renumber pass fix the ordinals.
        func makeList(_ prefix: String) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let para = ns.paragraphRange(for: tv.selectedRange())
            let lines = ns.substring(with: para).components(separatedBy: "\n")
            let filled = lines.filter { !$0.isEmpty }
            let strip = !filled.isEmpty && filled.allSatisfy { Self.inFamily($0, prefix) }

            let out = lines.map { line -> String in
                guard !line.isEmpty else { return line }
                let (indent, body) = Self.split(line)
                guard !Self.inFamily(line, prefix) else {
                    // already ours: strip it, or leave it alone so ☑ keeps its check
                    return strip ? indent + body : line
                }
                // an existing marker of another family converts in place (was: "☐ - foo")
                return indent + prefix + body
            }.joined(separator: "\n")

            if replaceText(tv, para, out) {
                tv.setSelectedRange(NSRange(location: para.location, length: (out as NSString).length))
            }
            showActions()
        }

        /// Set a heading on every selected line; the same level again clears it.
        /// One `replaceText` over the whole paragraph range → one undo step, no grouping.
        func setHeading(_ level: Int) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let para = ns.paragraphRange(for: tv.selectedRange())
            let want = String(repeating: "#", count: level) + " "
            let lines = ns.substring(with: para).components(separatedBy: "\n")
            let filled = lines.filter { !$0.isEmpty }
            let strip = !filled.isEmpty && filled.allSatisfy { $0.hasPrefix(want) }

            let out = lines.map { line -> String in
                guard !line.isEmpty else { return line }
                let lns = line as NSString
                var plain = line
                if let h = Self.headingPrefix.firstMatch(in: line,
                        range: NSRange(location: 0, length: lns.length)) {
                    plain = lns.substring(from: h.range.length)
                }
                return strip ? plain : want + plain
            }.joined(separator: "\n")

            if replaceText(tv, para, out) {
                tv.setSelectedRange(NSRange(location: para.location, length: (out as NSString).length))
            }
            showActions()
        }

        /// `[selection](url)`. A URL on the clipboard fills the target and the caret lands
        /// after it. Otherwise the target is the placeholder word `url`, left *selected*:
        /// typing or ⌘V replaces it, which is the whole interaction — no dialog. Once a
        /// real target is in place the text renders as a link and a click opens it.
        func insertLink() {
            guard let tv = textView else { return }
            let sel = tv.selectedRange()
            let s = (tv.string as NSString).substring(with: sel)
            let clip = (NSPasteboard.general.string(forType: .string) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fromClip = clip.hasPrefix("http://") || clip.hasPrefix("https://")
            let url = fromClip ? clip : "url"
            if replaceText(tv, sel, "[\(s)](\(url))") {
                let start = sel.location + (s as NSString).length + 3
                tv.setSelectedRange(fromClip
                    ? NSRange(location: start + (url as NSString).length + 1, length: 0) // after ")"
                    : NSRange(location: start, length: (url as NSString).length))         // "url" selected
            }
            actionCard.close()
        }

        /// (leading whitespace, text after any list marker) — so a line converts in place
        /// between families instead of stacking markers.
        static func split(_ line: String) -> (indent: String, body: String) {
            guard let m = ListLogic.match(line) else { return ("", line) }
            let ns = line as NSString
            return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 4)))
        }

        /// Is the line already this prefix's marker family? ☐ and ☑ are one family (so
        /// converting to to-dos never unchecks anything), and any ordinal counts as "1. ".
        static func inFamily(_ line: String, _ prefix: String) -> Bool {
            guard let m = ListLogic.match(line) else { return false }
            if prefix == "1. " { return m.range(at: 3).location != NSNotFound }
            guard m.range(at: 2).location != NSNotFound else { return false }
            let bullet = (line as NSString).substring(with: m.range(at: 2))
            if prefix == "☐ " { return bullet == "☐" || bullet == "☑" }
            return bullet == String(prefix.dropLast())
        }
    }
}

/// The selection bar: inline marks | headings | list conversions | link.
/// Lives in its own NSHostingController (the popover's), so it inherits nothing from
/// EditorView's view tree — including the `.tint` that themes every other control.
struct SlashCommand: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    /// What lands in the document. Date/Time bake the value in at build time, which is also
    /// what the row previews — the old menu inserted a format you couldn't see first.
    let snippet: String
    /// Other names people type for the same thing ("checkbox" for To-do, "h1" for Title).
    /// Prefix-matched like the title; the row still shows the title.
    let aliases: [String]

    init(_ title: String, _ symbol: String, _ snippet: String, aliases: [String] = []) {
        self.title = title; self.symbol = symbol; self.snippet = snippet; self.aliases = aliases
    }

    /// Title prefix or substring, or any alias prefix — folded, so case and accents don't matter.
    func matches(_ query: String) -> Bool {
        let q = NoteStore.fold(query)
        let t = NoteStore.fold(title)
        return t.hasPrefix(q) || t.contains(q) || aliases.contains { NoteStore.fold($0).hasPrefix(q) }
    }

    /// Only the snippets that insert a literal value are worth previewing; a "- " prefix
    /// previews itself.
    var preview: String? { snippet.first.map { $0.isLetter || $0.isNumber } == true ? snippet.trimmingCharacters(in: .whitespaces) : nil }
}

/// The "/" card. Same row recipe as the ⌘K palette — 18pt glyph slot, callout label,
/// trailing chip — so the editor has one list language instead of three menus in three
/// styles.
struct SlashMenuCard: View {
    let items: [SlashCommand]
    let index: Int
    let query: String
    var total: Int = 8
    let onPick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, cmd in
                HStack(spacing: Space.l) {
                    Image(systemName: cmd.symbol)
                        .font(Fonts.chromeGlyph).frame(width: 18).foregroundStyle(.secondary)
                    label(cmd).font(.callout).lineLimit(1)
                    Spacer(minLength: Space.m)
                    if let p = cmd.preview {
                        Text(p).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
                .rowBackground(selected: i == index)
                .onTapGesture { onPick(cmd) }
            }
            HStack {
                Text("↑↓ choose · ↩ insert · esc")
                Spacer(minLength: Space.xl)
                Text("\(items.count) of \(max(total, items.count))")
            }
            .font(.caption2).foregroundStyle(.tertiary)
            .padding(.horizontal, Space.m).padding(.top, Space.xs)
        }
        .padding(Space.s)
        .frame(width: 236)
        .floatingCard()
    }

    /// Underline the matched prefix, so it's visible that the card is answering what you typed.
    private func label(_ cmd: SlashCommand) -> Text {
        guard !query.isEmpty,
              NoteStore.fold(cmd.title).hasPrefix(NoteStore.fold(query)),
              query.count <= cmd.title.count else { return Text(cmd.title) }
        let cut = cmd.title.index(cmd.title.startIndex, offsetBy: query.count)
        return Text(String(cmd.title[..<cut])).underline() + Text(String(cmd.title[cut...]))
    }
}

struct ActionBar: View {
    let coordinator: MarkdownTextView.Coordinator
    /// The marks the selection already carries — a lit Bold means the next tap un-bolds.
    /// Eleven equal glyphs with no state was the bar's real problem: bold-on-bold and
    /// bold-on-plain looked identical.
    var active: Set<String> = []
    /// The selection's paragraph type, named. Five inline marks stay as buttons; the
    /// block conversions (which act on whole paragraphs, not the selection) collapse into
    /// this one menu — same actions, a third of the width, and it fits anywhere in a 400pt
    /// panel instead of clipping past the midpoint.
    var block: String = "Body"

    var body: some View {
        HStack(spacing: Space.xxs) {
            mark("bold", "Bold", "**")
            mark("italic", "Italic", "*")
            mark("strikethrough", "Strikethrough", "~~")
            mark("chevron.left.forwardslash.chevron.right", "Inline code", "`")
            ChromeIcon(symbol: "link", help: "Link", tint: .primary) { coordinator.insertLink() }
            Divider().frame(height: 14)
            Menu {
                Button("Body") { coordinator.makeBody() }
                Button("Title") { coordinator.setHeading(1) }
                Button("Subtitle") { coordinator.setHeading(2) }
                Divider()
                Button("Bullets") { coordinator.makeList("- ") }
                Button("Numbered") { coordinator.makeList("1. ") }
                Button("Checklist") { coordinator.makeTodo() }
            } label: {
                Text(block).font(.caption)
            }
            .chromeMenu(.primary, indicator: .automatic) // matches the bar's primary glyphs
            .fixedSize()
            .padding(.trailing, Space.xs)
            .help("Paragraph type")
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .floatingCard()
    }

    /// ChromeIcon carries the house hover background, glyph size/weight and tooltip; the
    /// active fill is the theme's own selection colour, the same one a picked row wears.
    /// Primary, not the chrome's secondary: six grey glyphs in a row read as disabled.
    @ViewBuilder private func mark(_ symbol: String, _ help: String, _ mark: String) -> some View {
        ChromeIcon(symbol: symbol, help: help, tint: .primary) { coordinator.wrap(mark) }
            .rowBackground(selected: active.contains(mark))
    }
}

/// Draws a full-width rule for `---` lines and a real checkbox for ☐/☑
/// (their text is set to clear; the character stays in the model for editing).
final class DividerLayoutManager: NSLayoutManager {
    var accent: NSColor = .controlAccentColor

    /// Selection (and any background attribute) comes through here. A selected newline is
    /// handed to us as a bar out to the container's right edge — a blank line selected
    /// looked like a giant highlighted block. Cap every rect at the line's used width
    /// plus a small stub, which is what Notes shows for a selected line end.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let container = textContainers.first, let tv = container.textView else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        let origin = tv.textContainerOrigin
        var rects = Array(UnsafeBufferPointer(start: rectArray, count: rectCount))
        for i in rects.indices {
            let r = rects[i]
            let gi = glyphIndex(for: NSPoint(x: r.minX - origin.x + 1, y: r.midY - origin.y), in: container)
            let frag = lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
            // Select All hands over the middle lines as ONE tall rect; capping it to the
            // single line under its midY shrank the whole block to a sliver at the edge.
            guard r.height <= frag.height + 1 else { continue }
            let used = lineFragmentUsedRect(forGlyphAt: gi, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            if r.maxX > used.maxX + 1 { rects[i].size.width = max(0, used.maxX + 6 - r.minX) }
        }
        rects.withUnsafeBufferPointer {
            super.fillBackgroundRectArray($0.baseAddress!, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }

    var code: NSColor = .systemPurple

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Code chips go under the selection highlight (super), so a selected span still
        // reads as selected. A rounded rect with a hairline, not a square background
        // attribute: that's the difference between "highlighted" and "a token".
        if let storage = textStorage, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(codeKey, in: charRange) { value, range, _ in
                guard value != nil else { return }
                let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                // one chip per line the span touches — the union rect of a wrapped span
                // would cover both lines edge to edge
                self.enumerateLineFragments(forGlyphRange: gr) { _, _, _, fragGlyphs, _ in
                    let sub = NSIntersectionRange(gr, fragGlyphs)
                    guard sub.length > 0 else { return }
                    var rect = self.boundingRect(forGlyphRange: sub, in: container).offsetBy(dx: origin.x, dy: origin.y)
                    rect = rect.insetBy(dx: -3, dy: 1)
                    let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                    self.code.withAlphaComponent(0.10).setFill(); path.fill()
                    self.code.withAlphaComponent(0.28).setStroke(); path.lineWidth = 0.5; path.stroke()
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(dividerKey, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: gr, in: container)
            let y = rect.midY + origin.y
            let path = NSBezierPath()
            path.move(to: NSPoint(x: origin.x + 2, y: y))
            path.line(to: NSPoint(x: origin.x + container.size.width - 4, y: y))
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
        }

        storage.enumerateAttribute(checkboxKey, in: charRange) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // Size from the text's cap height and sit the box ON the baseline, not on the
            // line-fragment's midY — the fragment is inflated by lineHeightMultiple, so the
            // old boundingRect box floated and drifted with font/size.
            // the glyph itself is 0.1pt; size the box from the body text right after it,
            // matching the kerned advance the glyph was pinned to (see checkboxAdvance)
            var font = (storage.attribute(.font, at: min(range.location + 1, storage.length - 1),
                                          effectiveRange: nil) as? NSFont)
                ?? .systemFont(ofSize: NSFont.systemFontSize)
            if font.pointSize < 1 { font = .systemFont(ofSize: NSFont.systemFontSize) }
            let frag = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let loc = location(forGlyphAt: gr.location) // glyph offset within its fragment
            let baselineY = frag.minY + loc.y + origin.y
            let side = checkboxSide(font)
            // flipped space: smaller y is higher. The box is taller than the cap height, so
            // center it on the cap band — it dips slightly below the baseline like a native
            // checkbox instead of towering above the text.
            // frag.minX + loc.x is the glyph's left edge → indented checkboxes stay aligned.
            let box = NSRect(x: frag.minX + loc.x + origin.x,
                             y: baselineY - side + ((side - font.capHeight) / 2).rounded(),
                             width: side, height: side)
            drawCheckbox(in: box, checked: checked)
        }

        storage.enumerateAttribute(markerKey, in: charRange) { value, range, _ in
            guard let display = value as? String else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                ?? .systemFont(ofSize: NSFont.systemFontSize)
            let frag = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let loc = location(forGlyphAt: gr.location)
            // right-align to the source marker's trailing edge so the content start (and
            // caret positions) never move: "iii." may be wider than "3." — it grows left.
            var trailingX = loc.x
            let next = gr.location + gr.length // the space after the marker, same line
            if next < numberOfGlyphs {
                trailingX = location(forGlyphAt: next).x
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let str = display as NSString
            let w = str.size(withAttributes: attrs).width
            // draw(at:) takes the glyph-box top-left in this flipped view
            str.draw(at: NSPoint(x: frag.minX + trailingX - w + origin.x,
                                 y: frag.minY + loc.y - font.ascender + origin.y),
                     withAttributes: attrs)
        }
    }

    private func drawCheckbox(in box: NSRect, checked: Bool) {
        let side = box.width
        let path = NSBezierPath(roundedRect: box, xRadius: side * 0.28, yRadius: side * 0.28)
        if checked {
            accent.setFill(); path.fill()
            // y grows downward here (NSTextView is flipped): mid-left → bottom dip → top-right
            let c = NSBezierPath()
            c.move(to: NSPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.48))
            c.line(to: NSPoint(x: box.minX + side * 0.42, y: box.minY + side * 0.68))
            c.line(to: NSPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.30))
            c.lineWidth = max(1.4, side * 0.12)
            c.lineCapStyle = .round; c.lineJoinStyle = .round
            NSColor.white.setStroke(); c.stroke()
        } else {
            // Quaternary is 10% white: on a dark themed surface the empty box all but
            // disappeared, and in a to-do note the empty box is the primary affordance.
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1.5; path.stroke()
        }
    }
}

/// NSTextView that toggles ☐/☑ on click.
final class SmartTextView: NSTextView {
    private static let checkboxRegex = try! NSRegularExpression(pattern: #"^(\s*)([☐☑]) "#)

    override func mouseDown(with event: NSEvent) {
        let ns = string as NSString
        if ns.length > 0 {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            // A plain click on link text opens it. Handled here, not left to NSTextView:
            // in plain-text mode its own link handling never fired for us. The caret can
            // still be placed inside a link with the arrow keys.
            if event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
               idx < ns.length, let url = attributedString().attribute(.link, at: idx, effectiveRange: nil) as? URL {
                NSWorkspace.shared.open(url)
                return
            }
            let lineR = ns.lineRange(for: NSRange(location: min(idx, ns.length - 1), length: 0))
            let line = ns.substring(with: lineR)
            // hit zone is the glyph itself, not the whole indented prefix — clicks on the
            // indentation or at the content start place the caret / start a drag as normal
            if let m = Self.checkboxRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
               case let boxStart = lineR.location + m.range(at: 2).location,
               idx >= boxStart, idx <= boxStart + 1 {
                let boxR = NSRange(location: boxStart, length: 1)
                let checked = ns.substring(with: boxR) == "☑"
                insertText(checked ? "☐" : "☑", replacementRange: boxR)
                // tactile confirmation on the same event that flips the box (causality)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                return
            }
            // a click landing inside a hidden heading marker (it's ~0pt wide at the line's
            // left edge) snaps the caret to the title text instead of before the "#"
            if let h = MarkdownTextView.Coordinator.headingPrefix.firstMatch(in: line,
                    range: NSRange(location: 0, length: (line as NSString).length)),
               idx >= lineR.location, idx < lineR.location + h.range.length {
                setSelectedRange(NSRange(location: lineR.location + h.range.length, length: 0))
                window?.makeFirstResponder(self)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// "Untitled" where the title will land and "Start typing…" where the body will, each
    /// only while that part is empty. Drawn, not inserted: the document stays exactly what
    /// the user typed (a fresh note is "# " and nothing else). Positions come from the real
    /// caret rects, so the hints sit precisely where the typed text appears.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholders()
    }

    private func drawPlaceholders() {
        guard let coord = delegate as? MarkdownTextView.Coordinator, let window else { return }
        let ns = string as NSString
        let titleRange = ns.length == 0 ? NSRange(location: 0, length: 0)
            : ns.lineRange(for: NSRange(location: 0, length: 0))
        let titleLine = ns.substring(with: titleRange).trimmingCharacters(in: .newlines)
        let hasNewline = titleRange.length > (titleLine as NSString).length
        let bodyEmpty = ns.substring(from: titleRange.location + titleRange.length)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        func viewRect(at index: Int) -> NSRect {
            let screen = firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
            return convert(window.convertFromScreen(screen), from: nil)
        }
        let color = NSColor.placeholderTextColor
        var bodyTop: CGFloat?
        // Only a real "# " line gets the title hint. With the marker deleted (backspace at
        // the title start, or ⌘A + delete) the line types as body text, and a title-size
        // "Untitled" beside a body-size caret was the mismatch.
        if titleLine == "# " {
            let (o1, _, _) = EditorMetrics.headingOffsets
            let font = MarkdownTextView.Coordinator.bold(
                MarkdownTextView.Coordinator.baseFont(coord.fontSize + o1, coord.design))
            var r = viewRect(at: (titleLine as NSString).length)
            // the caret rect can be shorter than a heading line — size the hint for its own font
            r.size.height = max(r.height, Self.placeholderStyle(font).minimumLineHeight)
            ("Untitled" as NSString).draw(in: NSRect(x: r.minX, y: r.minY, width: bounds.width - r.minX, height: r.height),
                                          withAttributes: [.font: font, .foregroundColor: color,
                                                           .paragraphStyle: Self.placeholderStyle(font)])
            if !hasNewline { bodyTop = r.maxY + EditorMetrics.paragraphSpacing } // no body line yet: hint below the title
        }
        if bodyEmpty {
            let font = MarkdownTextView.Coordinator.baseFont(coord.fontSize, coord.design)
            let r: NSRect
            if hasNewline || titleLine.isEmpty { // an empty first line is body: the hint sits on it
                let caret = viewRect(at: titleLine.isEmpty ? 0 : titleRange.location + titleRange.length)
                r = NSRect(x: caret.minX, y: caret.minY, width: caret.width,
                           height: max(caret.height, Self.placeholderStyle(font).minimumLineHeight))
            }
            else if let top = bodyTop {
                r = NSRect(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: top,
                           width: bounds.width, height: font.pointSize * 2)
            } else { return } // title present, body line not yet started: nothing to hint at
            ("Start typing. / for commands." as NSString).draw(
                in: NSRect(x: r.minX, y: r.minY, width: bounds.width - r.minX, height: r.height),
                withAttributes: [.font: font, .foregroundColor: color,
                                 .paragraphStyle: Self.placeholderStyle(font)])
        }
    }

    /// Same vertical metrics as the real text, so the hint and the caret share a baseline.
    private static func placeholderStyle(_ font: NSFont) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = EditorMetrics.lineHeightMultiple
        p.minimumLineHeight = (NSLayoutManager().defaultLineHeight(for: font) * EditorMetrics.lineHeightMultiple).rounded()
        p.lineBreakMode = .byClipping
        return p
    }

    /// Pasting a copied list item or heading at the end of a line used to splice it in
    /// ("☐ a☐ b" with a box drawn mid-line). A block belongs on its own line: if the
    /// clipboard starts with a marker and the caret isn't at a line start, break first.
    override func paste(_ sender: Any?) {
        if let clip = NSPasteboard.general.string(forType: .string),
           let first = clip.components(separatedBy: "\n").first,
           ListLogic.match(first) != nil || MarkdownTextView.Coordinator.headingPrefix
               .firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length)) != nil {
            let loc = selectedRange().location
            if loc > 0, (string as NSString).character(at: loc - 1) != 0x0A {
                insertText("\n", replacementRange: selectedRange())
            }
        }
        super.paste(sender)
    }

    /// The selection bar and slash card are child panels positioned for one geometry.
    /// Collapsing to the pill *replaces* the editor in the view tree — this view leaves
    /// the window entirely, so a frame hook never fires and the cards stayed up next to
    /// the pill. Hook the window itself: leaving it, or it resizing, closes them.
    private var resizeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o); resizeObserver = nil }
        let coordinator = delegate as? MarkdownTextView.Coordinator
        guard let window else { coordinator?.closeFloatingCards(); return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            (self?.delegate as? MarkdownTextView.Coordinator)?.closeFloatingCards()
        }
    }

    /// The drag is over, so the selection is final — see `Coordinator.selectionSettled`.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if selectedRange().length > 0 {
            (delegate as? MarkdownTextView.Coordinator)?.selectionSettled()
        }
    }
}
