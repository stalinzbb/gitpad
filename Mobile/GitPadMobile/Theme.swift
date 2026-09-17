import SwiftUI
import GitPadCore

/// The Mac's five themes on the phone. System follows the OS (light and dark); the presets
/// pin an appearance, an accent and an opaque surface — same table, `GitPadCore.Palette`.
struct Theme: Identifiable, Equatable {
    let id: String
    let scheme: ColorScheme?
    let accent: Color
    let code: Color
    let surface: Color
    /// Cards and fields: a wash of the text colour, so it reads on every surface.
    var card: Color { Color.primary.opacity(0.06) }

    init(_ p: Palette) {
        id = p.id
        scheme = p.dark.map { $0 ? .dark : .light }
        accent = p.accent.map(Color.init(hex:)) ?? .accentColor
        code = p.code.map(Color.init(hex:)) ?? .purple
        surface = p.tint.map(Color.init(hex:)) ?? Color(.systemBackground)
    }

    static let all = Palette.all.map(Theme.init)
    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.all[0] }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// A themed screen: opaque surface behind scrolling content and under the bars.
    func themedSurface(_ t: Theme) -> some View {
        scrollContentBackground(.hidden).background(t.surface.ignoresSafeArea())
            .toolbarBackground(t.surface, for: .navigationBar)
    }
}

/// Settings row: one swatch per theme, like the Mac's picker.
struct ThemePicker: View {
    @AppStorage("theme") private var themeID = "System"
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Theme.all) { t in
                    Button { themeID = t.id } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.surface)
                                VStack(alignment: .leading, spacing: 4) {
                                    Capsule().fill(t.id == "System" ? Color.blue : t.accent).frame(width: 22, height: 5)
                                    Capsule().fill(.gray.opacity(0.5)).frame(width: 34, height: 4)
                                    Capsule().fill(.gray.opacity(0.35)).frame(width: 28, height: 4)
                                }
                            }
                            .frame(width: 64, height: 46)
                            .environment(\.colorScheme, t.scheme ?? .light)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(themeID == t.id ? t.accent : Color.primary.opacity(0.15), lineWidth: themeID == t.id ? 2 : 1))
                            Text(t.id == "Solarized Light" ? "Solarized" : t.id).font(.caption2)
                                .foregroundStyle(themeID == t.id ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(t.id) theme").accessibilityAddTraits(themeID == t.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}
