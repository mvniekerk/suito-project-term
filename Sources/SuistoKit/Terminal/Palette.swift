import AppKit
import RioKit

/// Colours for the terminal grid.
///
/// librio resolves named and indexed cell colours itself and hands the renderer
/// concrete RGB (see `rio_color_s`), so this palette exists to *tell* librio
/// which RGB to resolve to. Selection and cursor colours stay host-side:
/// librio never draws, so it only needs the slots cells can reference.
struct TerminalTheme: Sendable, Identifiable {
    var id: String { name }
    /// Shown in preferences and stored in the workspace.
    var name: String = "Dark"
    /// ANSI 0-7 normal, 8-15 bright.
    var ansi: [RGB]
    var foreground: RGB
    var background: RGB
    var cursor: RGB
    /// Host-side only; librio has no concept of a selection colour.
    var selection: RGB

    struct RGB: Sendable, Hashable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        var cgColor: CGColor { cgColor(alpha: 1) }

        func cgColor(alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                    blue: CGFloat(b) / 255, alpha: alpha)
        }
    }

    /// A muted, slightly warm dark scheme. Deliberately close to Rio's own
    /// defaults so output designed for a terminal still looks right.
    static let dark = TerminalTheme(
        name: "Dark",
        ansi: [
            RGB(r: 0x15, g: 0x16, b: 0x1c),  // black
            RGB(r: 0xe5, g: 0x5f, b: 0x6a),  // red
            RGB(r: 0x6f, g: 0xc2, b: 0x76),  // green
            RGB(r: 0xd9, g: 0xa6, b: 0x4e),  // yellow
            RGB(r: 0x58, g: 0x9b, b: 0xe6),  // blue
            RGB(r: 0xb2, g: 0x7c, b: 0xd9),  // magenta
            RGB(r: 0x4f, g: 0xb3, b: 0xb8),  // cyan
            RGB(r: 0xc5, g: 0xc8, b: 0xd1),  // white
            RGB(r: 0x3b, g: 0x3f, b: 0x4c),  // bright black
            RGB(r: 0xff, g: 0x7b, b: 0x85),  // bright red
            RGB(r: 0x8b, g: 0xdc, b: 0x92),  // bright green
            RGB(r: 0xf2, g: 0xc0, b: 0x6b),  // bright yellow
            RGB(r: 0x79, g: 0xb5, b: 0xff),  // bright blue
            RGB(r: 0xcd, g: 0x98, b: 0xf2),  // bright magenta
            RGB(r: 0x6d, g: 0xcf, b: 0xd4),  // bright cyan
            RGB(r: 0xe9, g: 0xeb, b: 0xf0),  // bright white
        ],
        foreground: RGB(r: 0xd4, g: 0xd7, b: 0xde),
        background: RGB(r: 0x14, g: 0x15, b: 0x1a),
        cursor: RGB(r: 0xd4, g: 0xd7, b: 0xde),
        selection: RGB(r: 0x33, g: 0x46, b: 0x6b)
    )

    /// A light scheme, for bright rooms and for screen sharing.
    static let light = TerminalTheme(
        name: "Light",
        ansi: [
            RGB(r: 0x32, g: 0x34, b: 0x3b), RGB(r: 0xc0, g: 0x3b, b: 0x46),
            RGB(r: 0x3f, g: 0x8c, b: 0x4a), RGB(r: 0xa6, g: 0x72, b: 0x12),
            RGB(r: 0x2f, g: 0x6d, b: 0xc4), RGB(r: 0x8a, g: 0x4b, b: 0xb5),
            RGB(r: 0x24, g: 0x87, b: 0x8e), RGB(r: 0x5c, g: 0x60, b: 0x6a),
            RGB(r: 0x6b, g: 0x6f, b: 0x7a), RGB(r: 0xd9, g: 0x52, b: 0x5d),
            RGB(r: 0x4f, g: 0xa0, b: 0x5c), RGB(r: 0xc2, g: 0x8c, b: 0x1f),
            RGB(r: 0x3f, g: 0x82, b: 0xdb), RGB(r: 0xa0, g: 0x5f, b: 0xcc),
            RGB(r: 0x2f, g: 0x9d, b: 0xa5), RGB(r: 0x1c, g: 0x1e, b: 0x24),
        ],
        foreground: RGB(r: 0x24, g: 0x26, b: 0x2c),
        background: RGB(r: 0xfa, g: 0xfa, b: 0xf7),
        cursor: RGB(r: 0x24, g: 0x26, b: 0x2c),
        selection: RGB(r: 0xbe, g: 0xd6, b: 0xf5)
    )

    /// Lower contrast than `dark`, for long sessions.
    static let muted = TerminalTheme(
        name: "Muted",
        ansi: [
            RGB(r: 0x20, g: 0x24, b: 0x28), RGB(r: 0xcf, g: 0x73, b: 0x78),
            RGB(r: 0x8a, g: 0xb5, b: 0x8e), RGB(r: 0xc9, g: 0xab, b: 0x74),
            RGB(r: 0x76, g: 0x9c, b: 0xc4), RGB(r: 0xa8, g: 0x8c, b: 0xc0),
            RGB(r: 0x6f, g: 0xa8, b: 0xaa), RGB(r: 0xb4, g: 0xb8, b: 0xbf),
            RGB(r: 0x44, g: 0x4a, b: 0x52), RGB(r: 0xe0, g: 0x8b, b: 0x90),
            RGB(r: 0xa3, g: 0xcb, b: 0xa6), RGB(r: 0xdc, g: 0xc0, b: 0x8c),
            RGB(r: 0x8f, g: 0xb4, b: 0xd8), RGB(r: 0xbf, g: 0xa5, b: 0xd6),
            RGB(r: 0x88, g: 0xc0, b: 0xc2), RGB(r: 0xd6, g: 0xd9, b: 0xde),
        ],
        foreground: RGB(r: 0xc3, g: 0xc7, b: 0xcf),
        background: RGB(r: 0x1e, g: 0x22, b: 0x27),
        cursor: RGB(r: 0xc9, g: 0xab, b: 0x74),
        selection: RGB(r: 0x36, g: 0x44, b: 0x55)
    )

    static let all: [TerminalTheme] = [.dark, .muted, .light]

    static func named(_ name: String) -> TerminalTheme {
        all.first { $0.name == name } ?? .dark
    }

    /// Pushes this palette into librio. Process-wide: librio has one palette
    /// for every surface, so this is called once at startup.
    func apply() {
        var colors = rio_colors_s()
        withUnsafeMutablePointer(to: &colors.ansi) { tuple in
            let slots = UnsafeMutableRawPointer(tuple)
                .assumingMemoryBound(to: rio_rgb_s.self)
            for i in 0..<16 {
                slots[i] = rio_rgb_s(r: ansi[i].r, g: ansi[i].g, b: ansi[i].b)
            }
        }
        colors.foreground = rio_rgb_s(r: foreground.r, g: foreground.g, b: foreground.b)
        colors.background = rio_rgb_s(r: background.r, g: background.g, b: background.b)
        colors.cursor = rio_rgb_s(r: cursor.r, g: cursor.g, b: cursor.b)
        rio_set_colors(&colors)
    }
}

extension rio_color_s {
    /// A cell colour, or nil when librio reported `RIO_COLOR_NONE` (a missing
    /// cell, or no explicit underline colour) — never mistake that for black.
    var rgb: TerminalTheme.RGB? {
        kind == RIO_COLOR_NONE ? nil : TerminalTheme.RGB(r: r, g: g, b: b)
    }
}
