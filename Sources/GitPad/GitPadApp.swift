import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Global hotkey via Carbon. NSEvent global monitors can't *consume* the event, so
/// Carbon stays. The event handler is installed exactly once; the binding is swapped
/// in place (unregister-then-register) so re-applying never double-fires and never
/// collides with our own previous registration.
enum Hotkey {
    static let defaultKeyCode = UInt32(kVK_Space)
    static let defaultModifiers = UInt32(optionKey)
    static let defaultDisplay = "⌥Space"

    private static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var installed = false
    private static var currentCode = defaultKeyCode
    private static var currentMods = defaultModifiers
    private static let hotkeyID = EventHotKeyID(signature: OSType(0x47504144), id: 1) // "GPAD"

    /// User-facing combo, e.g. "⌥Space" — read at render time; no observer needed.
    static var display: String {
        UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? defaultDisplay
    }

    /// Install the shared handler once, then apply the stored (or default) binding.
    static func start(_ onFire: @escaping () -> Void) {
        handler = onFire
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Hotkey.handler?(); return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let d = UserDefaults.standard
        let code = (d.object(forKey: "hotkeyKeyCode") as? Int).map(UInt32.init) ?? defaultKeyCode
        let mods = (d.object(forKey: "hotkeyModifiers") as? Int).map(UInt32.init) ?? defaultModifiers
        _ = apply(keyCode: code, modifiers: mods)
    }

    /// Swap the binding. Returns false — and restores the previous binding — if the
    /// combo is already taken (eventHotKeyExistsErr) or registration otherwise fails.
    @discardableResult
    static func apply(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if let old = ref { UnregisterEventHotKey(old); ref = nil } // free our own combo first
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        if status == noErr, let newRef {
            ref = newRef; currentCode = keyCode; currentMods = modifiers
            return true
        }
        NSLog("GitPad: hotkey register failed status=%d", status)
        var restore: EventHotKeyRef?
        if RegisterEventHotKey(currentCode, currentMods, hotkeyID,
                               GetApplicationEventTarget(), 0, &restore) == noErr { ref = restore }
        return false
    }

    /// Release our combo. Only the updater calls this: the replacement instance launches
    /// while this one is still alive, and two processes can't hold ⌥Space at once —
    /// without this the new GitPad comes up with a dead hotkey.
    static func stop() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    // MARK: NSEvent → Carbon + display

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    static func displayString(_ flags: NSEvent.ModifierFlags, keyCode: UInt16, chars: String) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName(keyCode, chars)
    }

    private static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
    ]

    private static func keyName(_ keyCode: UInt16, _ chars: String) -> String {
        if let s = specialKeys[keyCode] { return s }
        let up = chars.uppercased()
        return up.isEmpty ? "Key\(keyCode)" : up
    }
}

/// Logs text copied anywhere on the Mac into Clipboard/ while GitPad runs (Settings →
/// Advanced, off by default). macOS posts no pasteboard-change notification, so this polls
/// `changeCount` — reading the count and the type list never touches the content.
enum ClipboardWatcher {
    static let enabledKey = "captureClipboard"
    private static var timer: Timer?
    private static var lastCount = NSPasteboard.general.changeCount
    private static var lastText = ""
    // nspasteboard.org: how password managers mark what must never be recorded
    private static let secret = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                 "org.nspasteboard.AutoGeneratedType"].map { NSPasteboard.PasteboardType($0) }
    // ponytail: a marker only helps when the source app sets it — a password copied out of a
    // web page or Terminal is logged like any text. That's why Clipboard/ never syncs.

    /// The text worth logging from `pb`, or nil: secrets, non-text, repeats and pastes big
    /// enough to be a whole file are skipped.
    static func capturable(_ pb: NSPasteboard, last: String) -> String? {
        let types = pb.types ?? []
        guard !types.contains(where: secret.contains),
              let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != last, text.utf8.count <= 10_000 else { return nil }
        return text
    }

    static func start(_ onCopy: @escaping (String) -> Void) {
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            let pb = NSPasteboard.general
            guard pb.changeCount != lastCount else { return }
            lastCount = pb.changeCount
            // off, or a copy made inside GitPad (it's already a note): remember the count only,
            // so switching the setting on never logs what was copied before
            guard UserDefaults.standard.bool(forKey: enabledKey), !NSApp.isActive,
                  let text = capturable(pb, last: lastText) else { return }
            lastText = text
            onCopy(text)
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = NoteStore()
    var panel: PanelWindow!
    var statusItem: NSStatusItem!
    var openItem: NSMenuItem!
    var revealItem: NSMenuItem!         // anchor for inserting the dynamic recent-notes section
    var recentItems: [NSMenuItem] = []  // dynamically rebuilt on each menu open
    var updateItem: NSMenuItem!         // hidden until a check finds a newer release
    var updateSeparator: NSMenuItem!
    var syncTimer: Timer?
    var idleTimer: Timer?
    var updateTimer: Timer?
    private var lastSyncKick = Date.distantPast
    private var pillDragOrigin: NSRect?
    private var pillDragMouse: NSPoint?
    private let syncQueue = DispatchQueue(label: "gitpad.sync")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // accessory apps have no menu bar, but a main menu is still required
        // for standard edit key equivalents (⌘A/⌘C/⌘V/⌘Z) to route
        let main = NSMenu()
        let editHolder = NSMenuItem()
        main.addItem(editHolder)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editHolder.submenu = edit

        // Note commands. The hidden main menu routes key equivalents even though
        // an accessory app shows no menu bar — so these work from every screen,
        // which the old zero-opacity SwiftUI buttons never did (capture only).
        let noteHolder = NSMenuItem()
        main.addItem(noteHolder)
        let note = NSMenu(title: "Note")
        note.autoenablesItems = false // no responder validates our @objc actions → force-enable
        note.addItem(withTitle: "New Note", action: #selector(newNoteCmd), keyEquivalent: "n")
        note.addItem(withTitle: "Library", action: #selector(toggleLibraryCmd), keyEquivalent: "l")
        note.addItem(withTitle: "Command Palette", action: #selector(paletteCmd), keyEquivalent: "k")
        note.addItem(.separator())
        // saveCmd → saveNow → onSaved → backgroundSync: ⌘S has always synced too
        note.addItem(withTitle: "Save & Sync", action: #selector(saveCmd), keyEquivalent: "s")
        let del = note.addItem(withTitle: "Delete Note", action: #selector(deleteNoteCmd), keyEquivalent: "\u{8}")
        del.keyEquivalentModifierMask = .command
        // no ⌘Z — that belongs to the editor's own text undo
        note.addItem(withTitle: "Undo Delete", action: #selector(undoDeleteCmd), keyEquivalent: "")
        note.addItem(.separator())
        note.addItem(withTitle: "Minimize to Pill", action: #selector(minimizeCmd), keyEquivalent: "m")
        note.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        note.items.forEach { $0.target = self }
        note.addItem(.separator())
        // ⌘Q from the panel; the status-bar menu's Quit only fires while that menu is open
        let quitCmd = note.addItem(withTitle: "Quit GitPad",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitCmd.target = NSApp // AppDelegate has no terminate:; NSApp does
        noteHolder.submenu = note

        NSApp.mainMenu = main

        panel = PanelWindow(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = statusImage(alert: false)
        if Updater.isDevBuild, let b = statusItem.button { // "dev" beside the glyph, release shows none
            statusItem.length = NSStatusItem.variableLength
            b.title = "dev"
            b.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
            b.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        // Added first so they sit at index 0/1, above everything. Both stay hidden until
        // menuNeedsUpdate sees a release — an empty slot beats shuffling indices later.
        updateItem = menu.addItem(withTitle: "Update Available…", action: #selector(updateAction), keyEquivalent: "")
        updateItem.isHidden = true
        updateSeparator = .separator()
        updateSeparator.isHidden = true
        menu.addItem(updateSeparator)
        openItem = menu.addItem(withTitle: "Open  (\(Hotkey.display))", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Append Clipboard to Daily", action: #selector(appendClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Sync Now", action: #selector(syncNow), keyEquivalent: "")
        menu.addItem(withTitle: "Set Up Sync…", action: #selector(showGitSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        // recent notes are inserted just above this item on each open (menuNeedsUpdate)
        revealItem = menu.addItem(withTitle: "Reveal Notes in Finder", action: #selector(revealNotes), keyEquivalent: "")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit GitPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        // …except Quit: this menu auto-enables its items, and AppDelegate doesn't implement
        // terminate: — pointing it at self made AppKit grey the item out. NSApp does.
        quit.target = NSApp
        menu.delegate = self // refresh the hotkey title + recent notes each time it opens
        statusItem.menu = menu

        Hotkey.start { [weak self] in self?.togglePanel() }
        ClipboardWatcher.start { [weak self] in self?.store.appendToClipboard($0) }

        store.onSaved = { [weak self] in self?.backgroundSync() }
        store.onHide = { [weak self] in self?.panel.orderOut(nil) }
        store.requestSync = { [weak self] in self?.backgroundSync() }
        store.onSyncQueue = { [syncQueue] block in syncQueue.async(execute: block) }
        store.setPill = { [weak self] on in
            self?.store.pill = on
            self?.panel.applyPill(on)
        }
        store.pillDrag = { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if self.pillDragOrigin == nil { self.pillDragOrigin = self.panel.frame; self.pillDragMouse = mouse }
            let o = self.pillDragOrigin!, m = self.pillDragMouse!
            self.panel.setFrameOrigin(NSPoint(x: o.origin.x + (mouse.x - m.x),
                                              y: o.origin.y + (mouse.y - m.y)))
        }
        store.pillDragEnded = { [weak self] in
            guard let self, let start = self.pillDragMouse else { return false }
            let end = NSEvent.mouseLocation
            self.pillDragOrigin = nil; self.pillDragMouse = nil
            return abs(end.x - start.x) + abs(end.y - start.y) >= 4 // same slop, screen space
        }
        store.applyAppearance = { [weak self] name in
            self?.panel.appearance = name.flatMap { NSAppearance(named: $0) }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.backgroundSync() }
        // 6h tick, but checkForUpdates throttles to ~once a day — the timer only exists so
        // a Mac that stays awake for a week still notices a release.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 21_600, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
        // Idle lock: sleep and screen lock already detach the vault; this covers the Mac
        // that stays awake and unlocked at an empty desk. Minute granularity is plenty.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.lockIfIdle()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(syncNow), name: NSWorkspace.didWakeNotification, object: nil)
        // Encrypted vault: gone whenever nobody is at the keyboard. Handlers no-op unless enabled.
        ws.addObserver(self, selector: #selector(lockVault), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(unlockVault), name: NSWorkspace.didWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(lockVault), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(unlockVault), name: .init("com.apple.screenIsUnlocked"), object: nil)
        unlockVault()    // from the Keychain; a miss leaves LockedView up for the passphrase
        backgroundSync() // no-op while locked — unlock's completion syncs instead
        checkForUpdates()

        // show the panel on first launch so opening the app isn't a no-op
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Every quit path — the status menu, ⌘Q, the Settings button, and the updater's
    /// relaunch — goes through NSApp.terminate, so this is the single place that has to
    /// catch a note still sitting in the 1s autosave debounce. (Quitting mid-debounce
    /// used to drop it.) saveNow's onSaved kicks a background sync that may not survive
    /// the exit; harmless, the next launch syncs immediately.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.flushPendingSave()
        // Gated on the toggle, not merely on a stage existing: switching "Install updates
        // automatically" off has to stop the automatic install too, or the switch lies.
        // The staged bundle stays put, and "Restart to Update" still offers it explicitly.
        if UserDefaults.standard.bool(forKey: "autoUpdate") { Updater.installStagedQuietly() }
        // Vault: wait for the sync the flush just queued, then detach — never leave notes
        // mounted after quit. The sync's completion is main.async, so blocking main is safe.
        // ponytail: an offline push can hold quit for its timeout; fine for a menu-bar app.
        if Vault.isEnabled { syncQueue.sync { Vault.lock() } }
        return .terminateNow
    }

    @objc func lockVault() { store.lockVault() }

    /// Settings → Encrypted vault → "Lock when idle". 0 = never (the default, so nothing
    /// changes for existing vaults). System-wide idle, not just GitPad's: someone typing in
    /// another app is at the keyboard, and the vault should stay open for them.
    func lockIfIdle() {
        let minutes = UserDefaults.standard.integer(forKey: "vaultIdleMinutes")
        guard minutes > 0, Vault.isEnabled, !store.locked else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        if idle >= Double(minutes * 60) { store.lockVault() }
    }

    /// An idle lock gets no screen-unlock notification to re-mount on, so the next
    /// deliberate open retries the stored passphrase (silent Keychain, or a Touch ID prompt).
    private func unlockIfLocked() {
        if store.locked { store.unlockVaultStored() }
    }
    /// Keychain read (blocks for seconds) or Touch ID sheet, off main; a miss leaves LockedView up.
    @objc func unlockVault() {
        // Test hook, GITPAD_VAULT only: seed the saved passphrase as the app itself, so the
        // Keychain ACL trusts this binary — items made by `security` prompt regardless of -A.
        let env = ProcessInfo.processInfo.environment
        if env["GITPAD_VAULT"] != nil, let p = env["GITPAD_VAULT_PASS"], !p.isEmpty {
            syncQueue.async { Vault.savePassphrase(p) } // serial: lands before the read below
        }
        store.unlockVaultStored()
    }

    // double-clicking the app (or `open`) while running shows the panel
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    @objc func togglePanel() {
        if store.pill {                  // pill visible → spring back to the full panel
            store.setPill?(false)
            return
        }
        if panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            unlockIfLocked()
            if store.screen != .onboarding {
                store.screen = .capture
                store.selectDaily() // ⌥Space always lands on today
            }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            syncIfStale() // freshest notes when you actually look at them
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        openItem.title = "Open  (\(Hotkey.display))" // reflect a rebound hotkey
        // Deliberately not the orange statusImage(alert:) badge — that's the sync-failure
        // cue, and an available update is good news, not a problem to fix.
        // This menu auto-enables its items, so .busy stays clickable rather than fighting
        // that; install() single-flights, so a second click is a no-op anyway.
        let updateTitle: String? = {
            switch store.update {
            case .none: return nil
            case .available(let r): return "Update to \(r.version)…"
            case .busy(let stage): return stage
            case .ready(let v): return "Restart to Update to \(v)"
            case .failed: return "Update Failed — Open Releases…"
            }
        }()
        if let updateTitle { // nil = no news; leave the item hidden and fall through to Recent
            updateItem.title = updateTitle
            updateItem.isHidden = false
            updateSeparator.isHidden = false
        }
        // rebuild the "Recent" section directly above "Reveal Notes in Finder"
        recentItems.forEach(menu.removeItem)
        recentItems.removeAll()
        let anchor = menu.index(of: revealItem)
        guard anchor >= 0 else { return }
        let recents = Array(store.notes.prefix(5))
        guard !recents.isEmpty else { return }
        var at = anchor
        let header = NSMenuItem(); header.title = "Recent"; header.isEnabled = false
        menu.insertItem(header, at: at); recentItems.append(header); at += 1
        for url in recents {
            let it = NSMenuItem(title: store.title(for: url), action: #selector(openRecent(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = url
            it.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            menu.insertItem(it, at: at); recentItems.append(it); at += 1
        }
        let sep = NSMenuItem.separator()
        menu.insertItem(sep, at: at); recentItems.append(sep)
    }

    /// Bring the panel to the front (expanding the pill first if collapsed).
    private func showPanel() {
        unlockIfLocked()
        if store.pill { store.setPill?(false) }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncIfStale()
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        store.open(url)
        showPanel()
    }

    @objc func revealNotes() { NSWorkspace.shared.activateFileViewerSelecting([store.dir]) }

    @objc func appendClipboard() {
        guard !store.locked, let clip = NSPasteboard.general.string(forType: .string),
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.selectDaily()
        store.screen = .capture
        store.appendToDaily(clip)
        showPanel()
    }

    // MARK: gitpad:// URL scheme (Raycast/Alfred/Shortcuts/scripts)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard store.screen != .onboarding, !store.locked else { return } // don't hijack first-run or a locked vault
        for url in urls where url.scheme == "gitpad" { handleURL(url) }
    }

    private func handleURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host {
        case "new":
            store.newNote()
            if let t = value("text"), !t.trimmingCharacters(in: .whitespaces).isEmpty { store.text = t }
            store.screen = .capture
            showPanel()
        case "note": // [[wiki links]] render as this URL, so a click lands here; scripts can use it too
            if let t = value("title") { store.openNote(titled: t) }
            store.screen = .capture
            showPanel()
        case "daily":
            store.selectDaily()
            store.screen = .capture
            if let append = value("append") { store.appendToDaily(append) }
            showPanel()
        default: break
        }
    }

    @objc func syncNow() { backgroundSync() }

    @objc func newNoteCmd() { store.newNote() }
    @objc func toggleLibraryCmd() { store.toggleLibrary() }
    /// ⌘K toggles the palette. It never renders in the pill, so expand first; onboarding
    /// is off-limits (same guard as the URL scheme).
    @objc func paletteCmd() {
        guard store.screen != .onboarding else { return }
        if store.pill { store.setPill?(false) }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.paletteOpen.toggle()
    }
    @objc func saveCmd() { store.saveNow() }
    @objc func deleteNoteCmd() { store.deleteCurrent() }
    @objc func undoDeleteCmd() { store.undoDelete() }
    @objc func minimizeCmd() { if !store.pill { store.setPill?(true) } }

    @objc func showSettings() {
        store.screen = .settings
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Menu-bar glyph: Resources/MenuBarIcon.svg (NSImage reads SVG natively since 11.0)
    /// as a *template* image, so macOS inverts it for light/dark menu bars and Increase
    /// Contrast for free. The alert variant punches a notch in the bottom-right corner and
    /// sets a dot in it — the same badge shape SF Symbols use — so the failure cue survives
    /// colour-blindness; the orange tint is only a secondary hint. SF Symbols remain the
    /// fallback for a bundle-less `swift run`.
    private func statusImage(alert: Bool) -> NSImage? {
        let label = alert ? "GitPad — sync problem" : "GitPad"
        let side: CGFloat = 18
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.svg"),
              let glyph = NSImage(contentsOf: url) else {
            let names = alert ? ["note.text.badge.exclamationmark", "exclamationmark.triangle"]
                              : ["note.text", "square.and.pencil"]
            let img = names.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }.first
            img?.isTemplate = true
            if img == nil { statusItem.button?.title = "G" } // last resort: never an invisible item
            return img
        }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            guard let ctx = NSGraphicsContext.current else { return true }
            if Updater.isDevBuild { // top-right: a hollow ring, so the glyph itself says "dev"
                let notch = NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 8, height: 8)
                ctx.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: notch).fill()
                ctx.compositingOperation = .sourceOver
                let ring = NSBezierPath(ovalIn: notch.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            guard alert else { return true }
            let notch = NSRect(x: rect.maxX - 8, y: rect.minY, width: 8, height: 8) // bottom-right corner
            ctx.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: notch).fill()                       // clear a hole in the glyph
            ctx.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: notch.insetBy(dx: 2, dy: 2)).fill() // the dot inside it
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = label
        return img
    }

    /// Panel-show trigger: sync unless one just ran. Cheap enough to call on every show.
    func syncIfStale() {
        guard !store.syncing, Date().timeIntervalSince(lastSyncKick) > 30 else { return }
        backgroundSync()
    }

    func backgroundSync() {
        guard !Vault.isLocked else { return } // covers the timer, wake, syncIfStale and onSaved alike
        let dir = store.dir
        store.syncing = true
        lastSyncKick = Date()
        syncQueue.async { [weak self] in
            let hasRemote = GitSync.run(["remote", "get-url", "origin"], in: dir).status == 0
            let before = GitSync.run(["rev-parse", "HEAD"], in: dir)
            let ok = GitSync.sync(dir: dir)
            if hasRemote { SyncLog.record(ok: ok, dir: dir, before: before.status == 0 ? before.out : "") }
            let ab = hasRemote ? GitSync.aheadBehind(in: dir) : nil
            DispatchQueue.main.async {
                self?.statusItem.button?.image = self?.statusImage(alert: hasRemote && !ok)
                self?.statusItem.button?.contentTintColor = (ok || !hasRemote) ? nil : .systemOrange
                if ok && hasRemote { UserDefaults.standard.set(Date(), forKey: "lastSyncOK") }
                self?.store.syncStatus = !hasRemote ? .noRemote : ok ? .synced(Date()) : .offline
                self?.store.pending = ab ?? (0, 0)
                self?.store.syncing = false
                self?.store.refresh() // pick up files pulled from remote
            }
        }
    }

    @objc func showGitSetup() {
        store.screen = .gitSetup
        showPanel()
    }

    // MARK: updates

    /// Release check. Silent by design: a failure leaves `store.update` untouched, so a
    /// flaky network never nags and never clears a release we already found.
    /// `force` (the Settings button) skips the throttle; nothing skips the opt-out.
    func checkForUpdates(force: Bool = false) {
        guard Updater.currentVersion != nil else { return } // `swift run`: no bundle, no version
        let d = UserDefaults.standard
        if !force {
            guard d.object(forKey: "autoCheckUpdates") as? Bool ?? true else { return }
            let last = d.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 72_000 else { return } // ~20h: once a day
        }
        Updater.check { [weak self] release, _ in
            d.set(Date(), forKey: "lastUpdateCheck")
            guard let self, let release else { return }
            // Already fetched this exact release in an earlier session — don't pay for it
            // twice, just re-offer the restart.
            if Updater.stagedVersionOnDisk == release.version {
                store.update = .ready(release.version)
                return
            }
            store.update = .available(release)
            guard d.bool(forKey: "autoUpdate") else { return }
            Updater.stage(release) { [weak self] s in
                // Staging failure stays silent: .available is still on screen and the
                // manual Update button still works. Nothing is worth a nag here.
                if case .failed = s { return }
                self?.store.update = s
            }
        }
    }

    @objc func updateAction() {
        switch store.update {
        case .available(let r):
            Updater.install(r) { [weak self] in self?.store.update = $0 }
        case .ready:
            Updater.installStagedNow { [weak self] in self?.store.update = $0 }
        case .failed:
            NSWorkspace.shared.open(Updater.releasesPage)
        default:
            break // .busy is already running (install single-flights); .none can't be clicked
        }
    }
}
