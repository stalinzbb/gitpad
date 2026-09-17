import SwiftUI
import AppKit

// MARK: - Themes (token set consumed by the editor + chrome)
//
// Curated presets, not a base×color matrix (see GROWTH-style decision: real palettes
// like Nord/Dracula are defined for ONE mode; the matrix would invent ugly combos and
// double the tokens). Adding a theme is one row below — appearance/swatch/SwiftUI color
// all derive from `base` + hex, so you only pick the 3 colors that actually differ.

enum ThemeBase {
    case system, light, dark
    var appearance: NSAppearance.Name? {
        switch self { case .system: return nil; case .light: return .aqua; case .dark: return .darkAqua }
    }
}

struct Theme: Identifiable {
    let id: String
    let appearance: NSAppearance.Name?  // nil = follow system; drives every native control
    let accent: NSColor                 // checkboxes, chips (and, wrapped, the SwiftUI tint)
    let code: NSColor                   // inline code
    private let tintHex: UInt?          // opaque panel surface. nil = System (follow the OS)

    var accentSwift: Color { Color(nsColor: accent) }
    /// The panel's own background. Text sits on THIS, never on the desktop — which is what
    /// keeps the window readable over a white backdrop. System follows the OS window color,
    /// so it adapts light/dark instead of having no surface at all.
    var surface: Color { tintHex.map { Color(hex: $0) } ?? Color(nsColor: .windowBackgroundColor) }
    var swatchBg: Color { surface }
    /// Selected row fill. Derived from the theme, NOT `Color.accentColor` — `.tint()` never
    /// changes accentColor, so a themed panel used to show system-blue selection.
    var selection: Color { accentSwift.opacity(Alpha.selection) }

    /// The common case: a preset from hex colors + a light/dark base.
    init(id: String, base: ThemeBase, accent: UInt, code: UInt, tint: UInt) {
        self.id = id; self.appearance = base.appearance
        self.accent = NSColor(hex: accent); self.code = NSColor(hex: code); self.tintHex = tint
    }
    /// System: dynamic accent that follows the OS, no tint wash.
    private init(system id: String) {
        self.id = id; self.appearance = nil
        self.accent = .controlAccentColor; self.code = .systemPurple; self.tintHex = nil
    }

    static let all: [Theme] = [
        Theme(system: "System"),
        Theme(id: "Sepia",            base: .light, accent: 0xA87538, code: 0x996B33, tint: 0xF5E8CF),
        Theme(id: "Nord",             base: .dark,  accent: 0x87BFD1, code: 0xA3BF8C, tint: 0x2E3340),
        Theme(id: "Dracula",          base: .dark,  accent: 0xBD94FA, code: 0x4FE67A, tint: 0x292936),
        Theme(id: "Solarized Light",  base: .light, accent: 0x268CD1, code: 0x859900, tint: 0xFCF5E3),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

/// The one reactive design value. Injected once, in `EditorView`; everything below reads it
/// instead of re-resolving `@AppStorage("theme")` per view. Scales (Radius/Space/Alpha/…)
/// are statics on purpose — AppKit consumers (PanelWindow, the layout manager, the
/// coordinator) can't see the SwiftUI environment.
private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.named("System")
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Scales

/// Corner radii, by the role of the thing being rounded — not by size.
enum Radius {
    static let chip: CGFloat = 5      // key caps, tags
    static let control: CGFloat = 6   // rows, icon squares, small buttons
    static let field: CGFloat = 8     // text fields
    static let card: CGFloat = 9      // floating cards (palette, undo banner)
    static let panel: CGFloat = 14    // the window itself
    static let pill: CGFloat = 20     // collapsed window = height/2
}

/// The spacing steps actually used. Anything not here is deliberate one-off geometry.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 14
    static let gutter: CGFloat = 20
}

/// Every translucency in the UI, named by what it means. Roles that happen to share a
/// number keep separate names — they drift apart for good reasons, not by accident.
enum Alpha {
    static let hover = 0.06        // row / chip hover fill
    static let iconHover = 0.08    // icon squares: smaller target, needs more contrast
    static let strokeFaint = 0.08  // the window's own hairline
    static let stroke = 0.10       // card borders
    static let strokeStrong = 0.12 // pressed / armed borders
    static let cardDivider = 0.14  // hairline drawn ON material (a Divider vanishes there)
    static let selection = 0.18    // selected row fill
    static let shadow = 0.18       // floating-card drop shadow
    static let scrim = 0.25        // modal backdrop
    static let inset = 0.04        // recessed content wells
    static let divider = 0.4       // SwiftUI Divider softening
}

extension Color {
    static let hoverBg = Color.primary.opacity(Alpha.hover)
    static let iconHoverBg = Color.primary.opacity(Alpha.iconHover)
    static let quietFill = Color.primary.opacity(Alpha.hover)   // search fields, steppers
    static let cardStroke = Color.primary.opacity(Alpha.stroke)
    // Status colors, so the sync dot / setup checks can't disagree across screens.
    static let statusOK = Color.green
    static let statusErr = Color.red
    static let statusWarn = Color.orange
}

enum Fonts {
    /// One glyph size/weight for every chrome icon, so clusters balance optically.
    static let chromeGlyph = Font.system(size: 13, weight: .medium)
}

/// Editor metrics shared by the SwiftUI wrapper and the NSTextView/layout-manager side.
/// One source, because these are the values that silently drift apart.
enum EditorMetrics {
    static let lineHeightMultiple: CGFloat = 1.25
    static let paragraphSpacing: CGFloat = 6
    static let listParagraphSpacing: CGFloat = 2
    static let headingOffsets: (CGFloat, CGFloat, CGFloat) = (8, 4, 2)      // H1/H2/H3 over body
    static let headingSpaceBefore: (CGFloat, CGFloat, CGFloat) = (14, 10, 8)
    static let inset = NSSize(width: 20, height: 14)
    static let indentUnitFactor: CGFloat = 1.5  // × font size, per nest level
    static let codeSizeDelta: CGFloat = -1
}

/// Window geometry. `PanelWindow` derives every frame it builds from these.
enum PanelMetrics {
    static let size = NSSize(width: 400, height: 560)
    static let pillSize = NSSize(width: 240, height: 40)
    static let headerHeight: CGFloat = 42
}

/// Central motion tokens. `reduce` is read at interaction time (no observer), and a
/// nil animation means "instant" — so Reduce Motion falls out for free everywhere.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    // screen: critically-damped reposition; quick: snappy hover; pop: momentum bounce.
    static var screen: Animation? { reduce ? nil : .spring(response: 0.32, dampingFraction: 0.85) }
    static var quick:  Animation? { reduce ? nil : .spring(response: 0.18, dampingFraction: 0.9) }
    static var pop:    Animation? { reduce ? nil : .spring(response: 0.30, dampingFraction: 0.7) }

    /// The pill curve, in both dialects. `PanelWindow.applyPill` animates the window with
    /// `pillCA`; SwiftUI chrome tracks the same frame with `pillFrame`. One tuple, so they
    /// can't drift — a mismatch shows up as the hairline snapping ahead of the window.
    static let pillDuration: TimeInterval = 0.22
    static let pillCurve: (Float, Float, Float, Float) = (0.23, 1, 0.32, 1)
    static var pillCA: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: pillCurve.0, pillCurve.1, pillCurve.2, pillCurve.3)
    }
    static var pillFrame: Animation? {
        reduce ? nil : .timingCurve(Double(pillCurve.0), Double(pillCurve.1),
                                    Double(pillCurve.2), Double(pillCurve.3),
                                    duration: pillDuration)
    }
}

/// Contrast floor for the floating panel. The window blends `.behindWindow`, so without
/// a real surface the text renders against whatever is on screen — unreadable over white,
/// because `labelColor` follows the window's *appearance*, not the actual backdrop.
/// One tunable: how much of the material shows through.
enum PanelSurface {
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    static var opacity: Double { reduceTransparency ? 1.0 : 0.92 }
}

/// Ambient sync-state color, shared by every NavBar dot + the pill.
func syncColor(_ status: SyncStatus) -> Color {
    switch status {
    case .synced: return .statusOK
    case .offline: return .statusWarn
    default: return .secondary.opacity(Alpha.divider)
    }
}

// MARK: - Shared components

/// Every chrome control is this: one identical square container, one glyph size/weight,
/// one hover background. Alignment then comes from the container geometry rather than
/// from each SF Symbol's own optical center — which is why mixing a heavy glyph
/// (square.and.pencil) with a thin one (xmark) used to read as misaligned.
/// Pair it with symmetric glyphs; see `ChromeGlyph`.
struct ChromeIcon: View {
    let symbol: String
    let help: String
    var tint: Color? = nil // only the conflict badge deviates from the secondary chrome
    let action: () -> Void
    @State private var hovering = false

    static let side: CGFloat = 28 // container; 2pt gaps → ~30pt pitch

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .iconSlot()
                .background(hovering ? Color.iconHoverBg : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Color.secondary)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
    }
}

/// The chrome glyph set — symmetric, matched optical weight, so the clusters balance.
enum ChromeGlyph {
    static let back     = "chevron.left"
    static let library  = "square.grid.2x2"
    static let newNote  = "plus"          // was square.and.pencil (heavy, juts top-right)
    static let settings = "gearshape"
    static let minimize = "minus"         // was a busy 4-arrow glyph
    static let close    = "xmark"
    static let conflict = "exclamationmark.triangle.fill"
}

extension View {
    /// The chrome glyph slot: fixed square + the house glyph size/weight. `ChromeIcon` uses
    /// it internally; apply it directly to Menu labels, which can't be Buttons.
    /// Every chrome `Menu` goes through here. `.borderlessButton` paints its label in the
    /// accent colour and ignores `foregroundStyle` alone, so a ⋯ menu came out purple next to
    /// grey + and search buttons. Tinting to the same colour is what makes it match.
    func chromeMenu(_ color: Color = .secondary, indicator: Visibility = .hidden) -> some View {
        menuStyle(.borderlessButton).menuIndicator(indicator).tint(color).foregroundStyle(color)
    }

    func iconSlot(side: CGFloat = ChromeIcon.side) -> some View {
        font(Fonts.chromeGlyph).frame(width: side, height: side)
    }

    /// The floating-card recipe: material, radius, hairline, shadow. Palette and the undo
    /// banner are the same object at different sizes.
    func floatingCard() -> some View {
        background(.thickMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(Alpha.shadow), radius: 8, y: 2)
    }
}

/// Selected / hovered row fill. Selection is theme-derived (see `Theme.selection`); hover
/// is a lighter, independent state, so a row can show both at once. Row *padding* stays
/// with each list — the rail and the note list have deliberately different geometry.
struct RowBackground: ViewModifier {
    var selected: Bool = false
    var hovering: Bool = false
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(selected ? theme.selection : (hovering ? Color.hoverBg : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
    }
}

extension View {
    func rowBackground(selected: Bool = false, hovering: Bool = false) -> some View {
        modifier(RowBackground(selected: selected, hovering: hovering))
    }
}

/// The ambient sync dot, one size everywhere.
struct SyncDot: View {
    let status: SyncStatus
    var body: some View { Circle().fill(syncColor(status)).frame(width: 7, height: 7) }
}

/// A Divider at full strength reads as a hard rule inside the panel; this is the house one.
struct SoftDivider: View {
    var body: some View { Divider().opacity(Alpha.divider) }
}

/// A small monospaced-ish key cap / tag. Same object in the palette, the shortcuts table
/// and the Library's Daily tag.
struct Chip: View {
    let text: String
    var font: Font = .footnote.weight(.medium)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
            .background(Color.hoverBg,
                        in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}

/// Section label, matching the Library's group headers.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

// ponytail: no shared icon+field component. The palette and the Library search each need
// their own .focused/.onSubmit/.onExitCommand, so wrapping them saves one HStack and costs
// a generic. Two sites is not a pattern.

/// The house text field.
///
/// `.textFieldStyle(.roundedBorder)` draws a system control that answers to the window's
/// forced appearance, not to the theme: a bright white well on Sepia, a near-black one on
/// Nord, always fighting the surface it sits on. This is a plain field on the panel's own
/// quiet fill, so it belongs to whichever theme is showing. The focus ring is the theme
/// accent, and `strokeBorder` draws inward — a focused field never changes size.
struct FieldStyle: ViewModifier {
    var focused: Bool = false
    @Environment(\.theme) private var theme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(Color.quietFill, in: shape)
            .overlay(shape.strokeBorder(focused ? theme.accentSwift.opacity(0.8) : Color.cardStroke,
                                        lineWidth: focused ? 2 : 1))
            .animation(Motion.quick, value: focused)
    }
}

extension View {
    func fieldStyle(focused: Bool = false) -> some View { modifier(FieldStyle(focused: focused)) }
}

/// One theme swatch: surface disc, accent pip, check when picked.
///
/// The ring is drawn with `strokeBorder` (inward) over a hard 26pt frame, so picking a
/// theme changes colors only — never the swatch's size or shape. The earlier version let
/// a `LabeledContent` trailing slot squeeze the row, which clipped the discs into
/// different shapes at narrow panel widths.
struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    static let side: CGFloat = 26

    var body: some View {
        Button(action: action) {
            Circle().fill(theme.swatchBg)
                .frame(width: Self.side, height: Self.side)
                .overlay(Circle().fill(theme.accentSwift).frame(width: 11, height: 11))
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(selected ? 1 : 0))
                .overlay(Circle().strokeBorder(
                    Color.primary.opacity(selected ? 0.45 : Alpha.strokeStrong),
                    lineWidth: selected ? 2 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(Motion.quick, value: selected)
        .help(theme.id)
    }
}

/// A 5pt capsule knob and no track line. Drawing is the ONLY thing overridden — an
/// earlier version also narrowed the scroller to 9pt, which pushed the knob into the
/// panel's rounded mask (it read as cut off at the ends) and fought the overlay
/// scroller's expand animation. Standard geometry costs nothing: overlay scrollers
/// float above the content, so the gutter takes no layout width either way.
final class LeanScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {} // no track line

    override func drawKnob() {
        guard bounds.height >= bounds.width else { return super.drawKnob() } // vertical only
        let knob = rect(for: .knob)
        let width: CGFloat = 5
        // centred in the scroller, so it clears the window's corner radius at both ends
        let r = NSRect(x: bounds.midX - width / 2, y: knob.minY + 2,
                       width: width, height: knob.height - 4)
        guard r.height > 0 else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: r, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

/// Give a SwiftUI ScrollView/List/Form the same lean scroller: `.background(LeanScrollbar())`
/// on the scrolling container.
///
/// The work happens in `viewDidMoveToWindow`, NOT `updateNSView` — SwiftUI never calls
/// update on a `.background()` representable, so an update-based version is dead code.
/// SwiftUI also wraps the helper in its own host view, so the scroll view is never a
/// sibling: climb ancestors until one of them contains it. Nothing private; a miss just
/// leaves the stock scroller in place.
struct LeanScrollbar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Swapper(frame: .zero) }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Swapper: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // async: the sibling scroll view isn't built yet on the first pass
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // placed inside the scrolling content → exact hit, no searching
                if let sv = self.enclosingScrollView {
                    Swapper.install(in: sv)
                    return
                }
                guard let start = self.superview else { return }
                var node: NSView? = start
                for _ in 0..<6 { // bounded, so we can't wander into an unrelated screen
                    guard let n = node else { return }
                    if let sv = Swapper.firstScrollView(in: n) {
                        Swapper.install(in: sv)
                        return
                    }
                    node = n.superview
                }
            }
        }

        static func install(in sv: NSScrollView) {
            guard !(sv.verticalScroller is LeanScroller) else { return }
            sv.verticalScroller = LeanScroller()
            sv.tile() // else the swapped-in scroller lays out 0pt wide
        }

        static func firstScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let hit = firstScrollView(in: sub) { return hit }
            }
            return nil
        }
    }
}

/// Refined translucent material; automatically softens when the window is inactive.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// A borderless child window that hosts a SwiftUI card next to a rect inside a text view.
///
/// Replaces NSPopover for the two in-text surfaces (selection bar, slash menu): a popover
/// draws an arrow ("this explains that") and steals key focus, which is exactly wrong for a
/// toolbar you keep tapping and a menu you keep typing into. This is `floatingCard()` in a
/// window — the same recipe as the ⌘K palette — so the editor has one card language.
///
/// ponytail: no arrow, no auto-flip animation. It clamps into the host window and flips
/// above/below when there's no room; that's all either caller needs.
final class FloatingCard {
    private var panel: NSPanel?
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var resignObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// `rect` is in `view`'s own coordinates. The card sits above it by `gap`, or below when
    /// the top would leave the host window.
    func show<C: View>(_ content: C, above rect: NSRect, of view: NSView, gap: CGFloat = 8, below: Bool = false) {
        guard let win = view.window else { return }
        host.rootView = AnyView(content)
        let panel = panel ?? makePanel()
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)

        // view space → screen space, via the host window
        let inWin = view.convert(rect, to: nil)
        let anchor = win.convertToScreen(inWin)
        let frame = win.frame
        var x = anchor.minX - size.width / 2 + min(anchor.width, 120) / 2
        x = min(max(x, frame.minX + Space.xl), frame.maxX - size.width - Space.xl)
        var y = below ? anchor.minY - gap - size.height : anchor.maxY + gap
        if y + size.height > frame.maxY { y = anchor.minY - gap - size.height } // no room above → below
        if y < frame.minY { y = anchor.maxY + gap }                              // no room below → above

        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        if panel.parent == nil { win.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        // A child window is hidden and re-shown *with* its parent, so a card left up when
        // the panel was hidden, minimized or clicked away from came back on reopen.
        // Losing key is the one signal all of those share.
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in self?.close() }
        }
    }

    func close() {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.contentViewController = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false          // floatingCard() draws its own
        p.hidesOnDeactivate = true
        p.level = .popUpMenu
        p.animationBehavior = .none  // the parent panel is borderless; a system fade flickers
        panel = p
        return p
    }
}
