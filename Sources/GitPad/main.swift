import AppKit
import GitPadCore
import SwiftUI

/// `precondition` in a release build traps without printing its message, so a CI failure
/// reads "Trace/BPT trap" and nothing else. This prints the message first.
func check(_ condition: Bool, _ message: @autoclosure () -> String = "check failed",
           file: StaticString = #file, line: UInt = #line) {
    if condition { return }
    FileHandle.standardError.write(Data("\(file):\(line): \(message())\n".utf8))
    exit(1)
}


// GitPad --uitest — drive the real editor stack headless through Tab/Enter/Backspace
// (precondition-based like --selftest, so it survives -c release)
if CommandLine.arguments.contains("--uitest") {
    _ = NSApplication.shared
    func makeEditor(_ text: String) -> (SmartTextView, MarkdownTextView.Coordinator) {
        let storage = NSTextStorage()
        let layout = DividerLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let tv = SmartTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 400), textContainer: container)
        tv.allowsUndo = true
        let coord = MarkdownTextView.Coordinator(MarkdownTextView(text: .constant(text)))
        coord.textView = tv
        tv.delegate = coord
        storage.delegate = coord
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return (tv, coord)
    }
    func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } // flush deferred renumber
    // NSTextView takes its undo manager from its window, so undo tests need one. Borderless
    // and never ordered in — nothing appears on screen.
    var undoWindows: [NSWindow] = [] // keep alive; a released window drops the undo manager
    func makeUndoableEditor(_ text: String) -> (SmartTextView, MarkdownTextView.Coordinator) {
        let (tv, coord) = makeEditor(text)
        let w = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView?.addSubview(tv)
        w.makeFirstResponder(tv)
        undoWindows.append(w)
        return (tv, coord)
    }

    // Tab on a caret at end of a list line: line indents, caret stays at its text position
    var (tv, coord) = makeEditor("- one\n- two\n")
    tv.setSelectedRange(NSRange(location: 5, length: 0)) // end of "- one"
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
    check(tv.string == "  - one\n- two\n", tv.string)
    check(tv.selectedRange() == NSRange(location: 7, length: 0), "\(tv.selectedRange())")

    // Tab on a multi-line selection ending at a line start: last line untouched, selection survives
    (tv, coord) = makeEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 0, length: 10)) // "1. a\n2. b\n" incl. trailing \n
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
    check(tv.string == "  1. a\n  2. b\n3. c\n", tv.string)
    let sel = tv.selectedRange()
    check(sel.location == 2 && sel.length == 12, "\(sel)") // still spans both lines
    // repeated Tab keeps working on the block
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
    check(tv.string == "    1. a\n    2. b\n3. c\n", tv.string)
    spin() // renumber pass: nested items restart at 1, top level restarts
    check(tv.string == "    1. a\n    2. b\n1. c\n", tv.string)

    // Enter mid-list splits and renumbers the following lines
    (tv, coord) = makeEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 9, length: 0)) // end of "2. b"
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    check(tv.string == "1. a\n2. b\n3. \n4. c\n", tv.string)

    // Enter on an empty nested item outdents one level, keeping the marker
    (tv, coord) = makeEditor("- a\n  - \n")
    tv.setSelectedRange(NSRange(location: 8, length: 0)) // end of "  - "
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    check(tv.string == "- a\n- \n", tv.string)
    check(tv.selectedRange() == NSRange(location: 6, length: 0), "\(tv.selectedRange())")

    // Enter on an empty top-level item exits the list
    (tv, coord) = makeEditor("- a\n- \n")
    tv.setSelectedRange(NSRange(location: 6, length: 0))
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    check(tv.string == "- a\n\n", tv.string)

    // Backspace at content start removes the whole marker in one go
    (tv, coord) = makeEditor("  ☐ task\n")
    tv.setSelectedRange(NSRange(location: 4, length: 0)) // right after "☐ "
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    check(tv.string == "  task\n", tv.string)
    check(tv.selectedRange() == NSRange(location: 2, length: 0), "\(tv.selectedRange())")

    // The line created by Enter is styled in the same deferred pass — its marker must be
    // cleared-for-display immediately, not on the next keystroke (was: raw "2."/"☐" flash)
    func markerCleared(_ tv: SmartTextView, at loc: Int) -> Bool {
        (tv.textStorage?.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor) == NSColor.clear
    }
    (tv, coord) = makeEditor("1. p\n  1. A\n")
    tv.setSelectedRange(NSRange(location: 11, length: 0)) // end of "  1. A"
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    check(tv.string == "1. p\n  1. A\n  2. \n", tv.string)
    check(markerCleared(tv, at: 14), "new nested ordinal not display-styled") // the "2"
    (tv, coord) = makeEditor("☐ a\n")
    tv.setSelectedRange(NSRange(location: 3, length: 0))
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    check(tv.string == "☐ a\n☐ \n", tv.string)
    check(markerCleared(tv, at: 4), "new checkbox glyph not display-styled")

    // Toggling ☐ ↔ ☑ must not move the text: both glyphs are pinned to the same fixed
    // advance (their fallback fonts — emoji for ☑! — have wildly different widths)
    (tv, coord) = makeEditor("☐ task\n")
    spin() // let the deferred styling pass run
    guard let lm = tv.layoutManager else { preconditionFailure("no layout manager") }
    let xUnchecked = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: 2)).x
    let hUnchecked = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    tv.insertText("☑", replacementRange: NSRange(location: 0, length: 1))
    spin()
    let xChecked = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: 2)).x
    let hChecked = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    check(abs(xChecked - xUnchecked) < 0.5, "text shifted on toggle: \(xUnchecked) → \(xChecked)")
    check(abs(hChecked - hUnchecked) < 0.5, "line height changed on toggle: \(hUnchecked) → \(hChecked)")

    // A fresh note's empty "# " line must be full H1 height — its glyphs are hidden at
    // 0.1pt, and without the minimumLineHeight floor the caret collapsed to invisibility
    (tv, coord) = makeEditor("# ")
    spin()
    let hEmptyTitle = tv.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    (tv, coord) = makeEditor("# Title")
    spin()
    let hFullTitle = tv.layoutManager!.lineFragmentRect(forGlyphAt: 2, effectiveRange: nil).height
    check(abs(hEmptyTitle - hFullTitle) < 1.5,
                 "empty title line collapsed: \(hEmptyTitle) vs \(hFullTitle)")

    // Backspace right after a heading marker drops the title to plain text
    (tv, coord) = makeEditor("# Title\n")
    tv.setSelectedRange(NSRange(location: 2, length: 0))
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    check(tv.string == "Title\n", tv.string)
    check(tv.selectedRange() == NSRange(location: 0, length: 0), "\(tv.selectedRange())")

    // Deleting a middle numbered line renumbers the rest, caret preserved
    (tv, coord) = makeEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 5, length: 5)) // "2. b\n"
    tv.insertText("", replacementRange: tv.selectedRange())
    spin()
    check(tv.string == "1. a\n2. c\n", tv.string)

    // Selection bar: wrap() is a toggle, through both detection paths
    (tv, coord) = makeEditor("hello world\n")
    tv.setSelectedRange(NSRange(location: 0, length: 5))
    coord.wrap("**")
    check(tv.string == "**hello** world\n", tv.string)
    check(tv.selectedRange() == NSRange(location: 2, length: 5), "\(tv.selectedRange())")
    coord.wrap("**") // marks around the selection → strip
    check(tv.string == "hello world\n", tv.string)
    check(tv.selectedRange() == NSRange(location: 0, length: 5), "\(tv.selectedRange())")
    tv.setSelectedRange(NSRange(location: 0, length: 5))
    coord.wrap("**")
    tv.setSelectedRange(NSRange(location: 0, length: 9)) // "**hello**" — marks inside
    coord.wrap("**")
    check(tv.string == "hello world\n", tv.string)

    // setHeading: set, clear, and re-level
    (tv, coord) = makeEditor("a line\n")
    tv.setSelectedRange(NSRange(location: 0, length: 0))
    coord.setHeading(2)
    check(tv.string == "## a line\n", tv.string)
    coord.setHeading(2)
    check(tv.string == "a line\n", tv.string)
    (tv, coord) = makeEditor("# Title\n")
    tv.setSelectedRange(NSRange(location: 0, length: 0))
    coord.setHeading(2)
    check(tv.string == "## Title\n", tv.string)

    // makeList converts across families, toggles off, and lets renumber fix ordinals
    (tv, coord) = makeEditor("☐ a\nplain\n☑ c\n")
    tv.setSelectedRange(NSRange(location: 0, length: 13))
    coord.makeList("- ")
    check(tv.string == "- a\n- plain\n- c\n", tv.string)
    coord.makeList("- ") // all one family now → strip
    check(tv.string == "a\nplain\nc\n", tv.string)
    coord.makeList("1. ")
    spin()
    check(tv.string == "1. a\n2. plain\n3. c\n", tv.string)
    // nesting survives the conversion (indent must not be duplicated)
    (tv, coord) = makeEditor("  - x\n")
    tv.setSelectedRange(NSRange(location: 0, length: 5))
    coord.makeList("☐ ")
    check(tv.string == "  ☐ x\n", tv.string)

    // converting to to-dos must not uncheck an existing ☑
    (tv, coord) = makeEditor("☑ done\nplain\n")
    tv.setSelectedRange(NSRange(location: 0, length: 12))
    coord.makeTodo()
    check(tv.string == "☑ done\n☐ plain\n", tv.string)

    // insertLink with nothing usable on the clipboard: the placeholder target is left
    // selected, so typing or ⌘V replaces it
    NSPasteboard.general.clearContents()
    (tv, coord) = makeEditor("docs\n")
    tv.setSelectedRange(NSRange(location: 0, length: 4))
    coord.insertLink()
    check(tv.string == "[docs](url)\n", tv.string)
    check(tv.selectedRange() == NSRange(location: 7, length: 3), "\(tv.selectedRange())")
    // a URL on the clipboard fills the target and the caret lands after the ")"
    NSPasteboard.general.setString("https://example.com/x", forType: .string)
    (tv, coord) = makeEditor("docs\n")
    tv.setSelectedRange(NSRange(location: 0, length: 4))
    coord.insertLink()
    check(tv.string == "[docs](https://example.com/x)\n", tv.string)
    check(tv.selectedRange() == NSRange(location: 29, length: 0), "\(tv.selectedRange())")
    NSPasteboard.general.clearContents()

    // Undo across a renumbering edit must converge on the original and keep redo alive.
    // The deferred renumber is its own top-level group (the event group has closed by the
    // time it runs), so an Enter mid-list is two presses — but each ⌘Z must make progress.
    // Before the fix it ping-ponged: undo ran the renumber again, which registered a *new*
    // group and wiped the redo stack, so the list never came back.
    (tv, coord) = makeUndoableEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 9, length: 0)) // end of "2. b"
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    check(tv.string == "1. a\n2. b\n3. \n4. c\n", tv.string)
    tv.undoManager?.undo() // the renumber
    spin()
    check(tv.string == "1. a\n2. b\n3. \n3. c\n", "undo #1 didn't revert the renumber: \(tv.string)")
    tv.undoManager?.undo() // the Enter
    spin()
    check(tv.string == "1. a\n2. b\n3. c\n", "undo #2 didn't restore the original: \(tv.string)")
    check(tv.undoManager?.canRedo == true, "redo stack cleared — the renumber re-registered")
    tv.undoManager?.redo(); spin()
    tv.undoManager?.redo(); spin()
    check(tv.string == "1. a\n2. b\n3. \n4. c\n", "redo didn't replay: \(tv.string)")

    // A no-op Shift-Tab must not eat the previous undo. indentList used to open its own undo
    // group around edits that all skipped, pushing an empty group that swallowed one ⌘Z.
    (tv, coord) = makeUndoableEditor("- one\n")
    tv.setSelectedRange(NSRange(location: 5, length: 0))
    tv.insertText(" two", replacementRange: tv.selectedRange())
    spin()
    check(coord.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:)))) // no indent to strip
    check(tv.string == "- one two\n", tv.string)
    tv.undoManager?.undo()
    spin()
    check(tv.string == "- one\n", "empty undo group swallowed the edit: \(tv.string)")

    // Inline code is a chip and [text](url) is a real link; the brackets recede.
    (tv, coord) = makeEditor("see `x` and [docs](https://example.com/a) here\n")
    spin()
    let st = tv.textStorage!
    check(st.attribute(codeKey, at: 5, effectiveRange: nil) != nil, "no code chip")
    check(st.attribute(codeKey, at: 2, effectiveRange: nil) == nil, "chip leaked onto prose")
    let linkAt = "see `x` and [".utf16.count
    check((st.attribute(.link, at: linkAt, effectiveRange: nil) as? URL)?.host == "example.com", "link text carries no .link")
    check(st.attribute(.link, at: linkAt - 1, effectiveRange: nil) == nil, "bracket became a link")
    (tv, coord) = makeEditor("[x](not a url)\n"); spin()
    check(tv.textStorage!.attribute(.link, at: 1, effectiveRange: nil) == nil, "junk target must not be clickable")

    // GITPAD_UITEST_SNAPSHOT=<dir>: render a few editor states to PNG for eyeballing what
    // the preconditions can't check (placeholders, chips). Never set on CI.
    if let dir = ProcessInfo.processInfo.environment["GITPAD_UITEST_SNAPSHOT"] {
        let cases: [(String, String, NSRange?)] = [
            ("fresh", "# ", nil), ("titled", "# Groceries\n\n", nil),
            ("body", "# Groceries\n- milk `2%` and [docs](https://x.y)\n", nil),
            ("select-empty-line", "# NYC\n\n☐ \n☐ Central Park\n", NSRange(location: 6, length: 1)),
            ("select-empty-todo", "# NYC\n\n☐ \n☐ Central Park\n", NSRange(location: 7, length: 3)),
            ("caret-before-box", "# NYC\n\n☐ \n☐ Central Park\n", NSRange(location: 7, length: 0)),
            ("caret-after-box", "# NYC\n\n☐ \n☐ Central Park\n", NSRange(location: 9, length: 0)),
            ("code-chip", "# Notes\nrun `swift build` then `./test.sh` — see [docs](https://x.y)\n", nil),
            ("code-wrap", "# Notes\nbehaviour `When do you start trusting AI blindly? When I first started using LLMs for tinkering` them and more\n", nil),
            ("multi-select", "# NYC\n☐ Central Park\n☐ Vessel\n", NSRange(location: 8, length: 22)),
        ]
        for (name, text, sel) in cases {
            let (tv, _) = makeUndoableEditor(text)
            tv.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
            tv.textContainerInset = EditorMetrics.inset
            if let sel { tv.setSelectedRange(sel); tv.window?.makeKeyAndOrderFront(nil); tv.window?.makeFirstResponder(tv) }
            spin()
            let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
            tv.cacheDisplay(in: tv.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("editor-\(name).png"))
        }
    }

    // [[Title]] renders as a link into the app's own scheme; "[[" opens the completion card.
    (tv, coord) = makeEditor("see [[Trip Plan]] soon\n"); spin()
    let wiki = tv.textStorage!.attribute(.link, at: 6, effectiveRange: nil) as? URL
    check(wiki?.scheme == "gitpad" && wiki?.host == "note" && wiki?.query == "title=Trip%20Plan", "wiki link: \(String(describing: wiki))")
    check(tv.textStorage!.attribute(.link, at: 4, effectiveRange: nil) == nil, "brackets must not be a link")
    do {
        let (tv2, coord2) = makeUndoableEditor("")
        coord2.parent = MarkdownTextView(text: .constant(""), noteTitles: { ["Trip Plan", "Groceries", "Tripwire"] })
        tv2.insertText("[[", replacementRange: NSRange(location: 0, length: 0)); spin() // trigger fires on this keystroke
        tv2.insertText("Tri", replacementRange: tv2.selectedRange()); spin()
        check(coord2.completionCount == 2, "\"[[Tri\" should offer Trip Plan and Tripwire, got \(coord2.completionCount)")
        tv2.insertText("p P", replacementRange: tv2.selectedRange()); spin() // spaces are fine in titles
        check(coord2.completionCount == 1, "\"[[Trip P\" should narrow to Trip Plan")
        tv2.insertText("]", replacementRange: tv2.selectedRange()); spin()
        check(coord2.completionCount == 0, "a typed ] closes the card")
    }

    // Pasting a copied list item mid-line starts a new line; a mid-line ☐ is not a box.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("☐ 1. two", forType: .string)
    (tv, coord) = makeUndoableEditor("☐ 1. one")
    tv.setSelectedRange(NSRange(location: 8, length: 0))
    tv.paste(nil); spin()
    check(tv.string == "☐ 1. one\n☐ 1. two", tv.string)
    NSPasteboard.general.clearContents()
    (tv, coord) = makeEditor("☐ a ☐ b\n"); spin()
    check(tv.textStorage!.attribute(checkboxKey, at: 0, effectiveRange: nil) != nil, "line-start box lost")
    check(tv.textStorage!.attribute(checkboxKey, at: 4, effectiveRange: nil) == nil, "mid-line ☐ drawn as a box")
    // backticks are hidden, the code between them is not
    (tv, coord) = makeEditor("a `b` c\n"); spin()
    check((tv.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize ?? 1 < 1, "opening tick visible")
    check((tv.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 > 1, "code text hidden")

    print("uitest OK")
    exit(0)
}

// CLI entry for tests: GitPad --sync <notesDir>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--sync" {
    exit(GitSync.sync(dir: URL(fileURLWithPath: CommandLine.arguments[2])) ? 0 : 1)
}

// Library row parser check: GitPad --selftest (precondition, so it survives -c release)
if CommandLine.arguments.contains("--selftest") {
    let m = NoteStore.parseMeta("# Title\n\nsome body\n- [x] a\n- [ ] b\n")
    check(m.done == 1 && m.total == 2 && m.snippet == "some body", "\(m)")
    check(NoteStore.parseMeta("# Only a title\n").snippet.isEmpty)
    check(NoteStore.parseMeta("# T\n- [ ] first\n").snippet == "first")
    // nested (indented) checkboxes must survive the markdown round-trip — the persistence
    // guarantee behind Tab/Shift-Tab list nesting (Fix B).
    let nested = "# T\n  - [ ] a\n    - [x] b\n"
    let editor = NoteStore.fromMarkdown(nested)
    check(editor.contains("  ☐ a") && editor.contains("    ☑ b"), editor)
    check(NoteStore.toMarkdown(editor) == nested, NoteStore.toMarkdown(editor))
    // search folding: "cafe" must find "Café" (diacritics + case)
    check(NoteStore.fold("Café Notes").contains(NoteStore.fold("cafe")))
    check(NoteStore.fold("RÉSUMÉ") == NoteStore.fold("resume"))
    // tolerant read: other editors' `* [X]` variants map to glyphs (write stays canonical `- [x]`)
    check(NoteStore.fromMarkdown("* [X] a\n+ [ ] b\n").contains("☑ a"))
    check(NoteStore.fromMarkdown("* [X] a\n+ [ ] b\n").contains("☐ b"))
    // ordered lists renumber per depth; bullets and non-list lines break the runs
    check(ListLogic.renumber(["1. a", "5. b", "  3. x", "  9. y", "2. c"])
        == ["1. a", "2. b", "  1. x", "  2. y", "3. c"])
    check(ListLogic.renumber(["1. a", "text", "5. b"]) == ["1. a", "text", "1. b"])
    check(ListLogic.renumber(["1. a", "- b", "5. c"]) == ["1. a", "- b", "1. c"])
    // display markers cycle 1. → a. → i. by depth
    check(ListLogic.displayMarker(number: 3, depth: 0) == "3.")
    check(ListLogic.displayMarker(number: 3, depth: 1) == "c.")
    check(ListLogic.displayMarker(number: 3, depth: 2) == "iii.")
    check(ListLogic.letterLabel(27) == "aa")
    check(ListLogic.romanLabel(4) == "iv" && ListLogic.romanLabel(9) == "ix")
    check(ListLogic.displayMarker(number: nil, depth: 1) == "◦")
    // GitPadCore: shared with the iOS companion, so the on-disk shapes must not drift
    check(Markdown.parseRemote("git@github.com:o/r.git").map { "\($0.owner)/\($0.repo)" } == "o/r")
    check(Markdown.parseRemote("https://github.com/o/r").map { "\($0.owner)/\($0.repo)" } == "o/r")
    check(Markdown.parseRemote("https://github.com/o/r.git/").map { "\($0.owner)/\($0.repo)" } == "o/r")
    check(Markdown.parseRemote("ssh://git@github.com/o/r").map { "\($0.owner)/\($0.repo)" } == "o/r")
    check(Markdown.parseRemote("git@gitlab.com:o/r.git") == nil)
    check(Markdown.parseRemote("https://github.com/o") == nil)
    let cdate = DateFormatter(); cdate.dateFormat = "yyyy-MM-dd HHmm"
    check(Markdown.conflictCopyName("Inbox/a.md", device: "iPhone", date: cdate.date(from: "2026-07-23 1200")!)
        == "Inbox/a (conflict from iPhone 2026-07-23 1200).md")
    check(Markdown.title(of: "## Hello  \nbody", fallback: "f") == "Hello" && Markdown.title(of: "\n", fallback: "f") == "f")

    // lean scrollbar: our scroller survives being installed, and stays eligible for
    // overlay drawing (false here means AppKit silently draws its own knob instead)
    check(LeanScroller.isCompatibleWithOverlayScrollers)
    let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    sv.hasVerticalScroller = true
    LeanScrollbar.Swapper.install(in: sv)
    sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    sv.tile()
    check(sv.verticalScroller is LeanScroller)
    check(sv.verticalScroller!.frame.width > 0, "\(sv.verticalScroller!.frame)")

    // Updater: version compare is numeric per component — a string compare gets 10 vs 9 wrong
    check(Updater.isNewer("0.9.10", than: "0.9.9"))
    check(Updater.isNewer("1.0", than: "0.9.3"))     // short version, missing parts = 0
    check(!Updater.isNewer("0.9.3", than: "0.9.3"))  // same → nothing to offer
    check(!Updater.isNewer("0.9.2", than: "0.9.3"))  // older → never downgrade
    // feed parsing: skip drafts, strip the tag's "v", match the un-prefixed asset name,
    // strip the digest's "sha256:" — every one of those mismatches is a silent failure
    let feed = Data("""
    [{"tag_name":"v1.5.0","draft":true,"html_url":"https://e/d","assets":[]},
     {"tag_name":"v0.9.9","draft":false,"html_url":"https://e/0.9.9",
      "assets":[{"name":"GitPad-0.9.9.dmg","browser_download_url":"https://e/d.dmg","digest":"sha256:dd"},
                {"name":"GitPad-0.9.9.zip","browser_download_url":"https://e/GitPad-0.9.9.zip","digest":"sha256:ab"}]}]
    """.utf8)
    let rel = Updater.parse(feed, "0.9.3")
    check(rel?.version == "0.9.9", "draft skipped, v stripped: \(String(describing: rel))")
    check(rel?.sha256 == "ab", "picked the zip's digest, not the dmg's")
    check(rel?.zipURL?.lastPathComponent == "GitPad-0.9.9.zip")
    check(rel?.pageURL.absoluteString == "https://e/0.9.9")
    check(Updater.parse(feed, "0.9.9") == nil) // already running it
    check(Updater.parse(feed, "1.2.0") == nil) // running something newer
    // a release whose asset hasn't uploaded yet still surfaces — the page link is the fallback
    let noAsset = Data(#"[{"tag_name":"v0.9.9","draft":false,"html_url":"https://e/n","assets":[]}]"#.utf8)
    check(Updater.parse(noAsset, "0.9.3")?.zipURL == nil)
    check(Updater.parse(noAsset, "0.9.3")?.version == "0.9.9")
    // garbage and no-network must both be silent, never a nag
    check(Updater.parse(Data("not json".utf8), "0.9.3") == nil)
    check(Updater.parse(nil, "0.9.3") == nil)

    // Updater.swap: the move-aside that replaces a *running* bundle. A half-finished swap
    // is the one failure here that loses the user's app, so both directions are checked.
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("gitpad-swaptest-\(getpid())")
    try? fm.removeItem(at: sandbox)
    try! fm.createDirectory(at: sandbox.appendingPathComponent("staged"), withIntermediateDirectories: true)
    let live = sandbox.appendingPathComponent("GitPad.app")
    let fresh = sandbox.appendingPathComponent("staged/GitPad.app")
    try! "old".write(to: live, atomically: true, encoding: .utf8)
    try! "new".write(to: fresh, atomically: true, encoding: .utf8)
    check(Updater.swap(live, with: fresh) == nil)
    check((try? String(contentsOf: live, encoding: .utf8)) == "new", "swap didn't install")
    check(try! fm.contentsOfDirectory(atPath: sandbox.path)
        .allSatisfy { !$0.hasPrefix(".GitPad.app.old-") }, "move-aside copy left behind")
    // source gone → must fail *and* roll the original back, not leave an empty slot
    check(Updater.swap(live, with: sandbox.appendingPathComponent("absent.app")) != nil)
    check((try? String(contentsOf: live, encoding: .utf8)) == "new", "rollback lost the app")
    try? fm.removeItem(at: sandbox)

    // NoteStore vs sync: a merge that rewrites the *open* note on disk must never be
    // overwritten by the stale editor buffer. Clean buffer → reload; dirty buffer → the
    // on-disk version survives as a conflict copy. This was a silent two-Mac data-loss path.
    let notesDir = fm.temporaryDirectory.appendingPathComponent("gitpad-storetest-\(getpid())")
    try? fm.removeItem(at: notesDir)
    setenv("GITPAD_DIR", notesDir.path, 1) // before NoteStore.defaultDir is first touched
    let store = NoteStore()
    let note = store.newNote()
    store.text = "# Mine\nlocal line\n"
    store.saveNow()
    try! "# Mine\nlocal line\nremote line\n".write(to: note, atomically: true, encoding: .utf8)
    store.refresh()
    check(store.text == "# Mine\nlocal line\nremote line\n", "clean buffer not reloaded: \(store.text)")
    store.text = "# Mine\nlocal line\nremote line\ntyped\n" // dirty: sits in the debounce
    try! "# Mine\nother mac\n".write(to: note, atomically: true, encoding: .utf8)
    store.saveNow()
    check((try? String(contentsOf: note, encoding: .utf8)) == "# Mine\nlocal line\nremote line\ntyped\n",
                 "buffer didn't win the original")
    check(store.conflicts.count == 1
                 && (try? String(contentsOf: store.conflicts[0], encoding: .utf8)) == "# Mine\nother mac\n",
                 "on-disk version wasn't kept as a conflict copy")
    store.text += "more\n"
    store.saveNow() // disk untouched since our own write → plain save, no second copy
    check(store.conflicts.count == 1, "spurious conflict copy on an ordinary save")

    // Backlinks + open-by-title. Titles fold (case/accents), the note itself is excluded.
    // written straight to disk: newNote() debounces two calls inside 0.7 s into one note
    let a = store.dir.appendingPathComponent("alpha.md"), b = store.dir.appendingPathComponent("beta.md")
    try! "# Alpha\nsee [[beta]] and [[Gamma]]\n".write(to: a, atomically: true, encoding: .utf8)
    try! "# Beta\nplain\n".write(to: b, atomically: true, encoding: .utf8)
    store.refresh()
    check(store.backlinks(to: b).map(\.path) == [a.path], "backlink to Beta not found: \(store.backlinks(to: b))")
    check(store.backlinks(to: a).isEmpty, "Alpha has no backlinks")
    store.openNote(titled: "beta")
    check(store.selected?.path == b.path, "open by title (folded) should land on Beta")
    Thread.sleep(forTimeInterval: 0.75) // past newNote's double-press debounce
    store.openNote(titled: "Gamma")
    check(store.selected?.path != b.path && store.text.hasPrefix("# Gamma"), "a missing target becomes a new note titled Gamma")

    // FolderWatcher: a file written by something else appears without a manual refresh.
    // store.dir, not notesDir: the store realpaths GITPAD_DIR (/var → /private/var).
    let external = store.dir.appendingPathComponent("from-elsewhere.md")
    try! "# Elsewhere\n".write(to: external, atomically: true, encoding: .utf8)
    let deadline = Date().addingTimeInterval(6) // FSEvents latency is 1 s; leave slack for CI
    while Date() < deadline, !store.notes.contains(where: { $0.path == external.path }) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    check(store.notes.contains(where: { $0.path == external.path }), "watcher never saw the external file")
    try? fm.removeItem(at: notesDir)

    // Slash aliases: "checkbox" finds To-do; the title still wins on its own prefix.
    let todo = SlashCommand("To-do", "checklist", "☐ ", aliases: ["todo", "checkbox", "checklist"])
    check(todo.matches("check") && todo.matches("Todo") && todo.matches("to-d") && !todo.matches("bul"))

    // Caret never rests inside a hidden marker (heading hashes, ☐, "- ").
    typealias CO = MarkdownTextView.Coordinator
    let doc = "# T\n☐ a\n  - b\n"
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 0, length: 0), previous: 5) == 2)   // before "#" → after "# "
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 1, length: 0), previous: 5) == 2)   // inside "# "
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 4, length: 0), previous: 3) == 6)   // Right from line 1 end → after "☐ "
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 5, length: 0), previous: 6) == 3)   // Left from content start → previous line end
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 8, length: 0), previous: 0) == nil) // in the indent: fine
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 10, length: 0), previous: 0) == 12) // on "- " → content
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 6, length: 0), previous: 0) == nil) // content start: fine
    check(CO.caretOutsideMarker(doc, caret: NSRange(location: 4, length: 3), previous: 0) == nil) // a selection is left alone

    // Slash block commands replace an existing marker instead of nesting inside it.
    typealias C = MarkdownTextView.Coordinator
    check(C.blockStart(before: "☐ ", snippet: "# ") == 0)        // to-do → title
    check(C.blockStart(before: "☐ ", snippet: "1. ") == 0)       // to-do → numbered
    check(C.blockStart(before: "  - ", snippet: "☐ ") == 2)      // nested bullet keeps its indent
    check(C.blockStart(before: "  - ", snippet: "# ") == 0)      // headings never indent
    check(C.blockStart(before: "# ", snippet: "☐ ") == 0)        // heading → to-do
    check(C.blockStart(before: "☐ words ", snippet: "# ") == nil) // marker + text: ordinary insert
    check(C.blockStart(before: "", snippet: "# ") == nil)         // plain line: ordinary insert
    check(C.blockStart(before: "☐ ", snippet: "---\n") == nil)    // not a block command

    // A block command typed in front of an existing marker replaces it (no "☐ ☐ x").
    let br = C.blockReplaceRange
    check(br("/todo☐ Central Park", 0, 5, "☐ ") == NSRange(location: 0, length: 7))   // eats "☐ "
    check(br("  /todo- x", 2, 7, "☐ ") == NSRange(location: 2, length: 7))            // keeps indent
    check(br("  /title- x", 2, 8, "# ") == NSRange(location: 0, length: 10))          // heading drops indent
    check(br("/title# Old", 0, 6, "# ") == NSRange(location: 0, length: 8))           // heading → heading
    check(br("/date☐ x", 0, 5, "Sep 11 ") == NSRange(location: 0, length: 5))         // not a block command
    check(br("word /todo☐ x", 5, 10, "☐ ") == NSRange(location: 5, length: 5))        // text before: plain

    // Inline marks across lines: per line, after the marker; all-wrapped → all unwrapped.
    check(C.wrapLines("- a\n- b\n", "**") == "- **a**\n- **b**\n")
    check(C.wrapLines("- **a**\n- **b**\n", "**") == "- a\n- b\n")
    check(C.wrapLines("# T\n\nbody", "*") == "# *T*\n\n*body*")          // blank line untouched
    check(C.wrapLines("- **a**\n- b", "**") == "- ****a****\n- **b**")   // mixed: wraps (toggle is all-or-nothing)

    // Conflict diff: lines unique to each side, by index.
    let d1 = NoteStore.uniqueLines(["# T", "a", "b", "c"], ["# T", "a", "x", "c"])
    check(d1.a == [2] && d1.b == [2], "\(d1)")
    let d2 = NoteStore.uniqueLines(["a", "b"], ["a", "b", "c", "d"])
    check(d2.a.isEmpty && d2.b == [2, 3], "\(d2)")
    let d3 = NoteStore.uniqueLines(["a", "b", "c"], ["c"])
    check(d3.a == [0, 1] && d3.b.isEmpty, "\(d3)")
    let d4 = NoteStore.uniqueLines([], ["only"])
    check(d4.a.isEmpty && d4.b == [0], "\(d4)")
    check(NoteStore.uniqueLines(["same"], ["same"]) == ([], []), "identical must mark nothing")

    // Commit author: Settings override beats the Mac's name, blank means the Mac's name.
    let hostName = Host.current().localizedName ?? "GitPad"
    UserDefaults.standard.set("  Studio/2:b  ", forKey: "deviceName")
    check(GitSync.deviceName == "Studio-2-b", GitSync.deviceName)
    UserDefaults.standard.set("   ", forKey: "deviceName")
    check(GitSync.deviceName == hostName, "blank override should fall back to the Mac's name")
    UserDefaults.standard.removeObject(forKey: "deviceName")

    print("selftest OK")
    exit(0)
}

// Warm the signed-build check before a single view exists. It is a lazy static that shells
// out to codesign, and Process.waitUntilExit spins the run loop — so the first SwiftUI body
// to ask (NavCenter's DEV tag) re-entered another body, which asked again while the
// one-time init was still running, and dispatch_once trapped. Deterministic on a
// locked-vault launch (test_vault_app.sh), racy otherwise. Here nothing can re-enter.
_ = Updater.isDevBuild

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
