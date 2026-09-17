/// The theme presets as plain numbers, so the Mac and the phone draw the same five themes
/// from one table. Each platform wraps these in its own colour type. `dark == nil` and
/// nil hexes mean "System": follow the OS appearance and accent.
public struct Palette {
    public let id: String
    public let dark: Bool?
    public let accent: UInt?, code: UInt?, tint: UInt?

    public static let all: [Palette] = [
        Palette(id: "System",          dark: nil,   accent: nil,      code: nil,      tint: nil),
        Palette(id: "Sepia",           dark: false, accent: 0xA87538, code: 0x996B33, tint: 0xF5E8CF),
        Palette(id: "Nord",            dark: true,  accent: 0x87BFD1, code: 0xA3BF8C, tint: 0x2E3340),
        Palette(id: "Dracula",         dark: true,  accent: 0xBD94FA, code: 0x4FE67A, tint: 0x292936),
        Palette(id: "Solarized Light", dark: false, accent: 0x268CD1, code: 0x859900, tint: 0xFCF5E3),
    ]
}
