import AppKit
import CoreText
import RioKit

/// Font variants and glyph lookup for the cell grid.
///
/// Two paths, because terminals are overwhelmingly ASCII:
///
/// - **Fast path** — a direct `CTFontGetGlyphsForCharacters` lookup in the base
///   font, memoised per (character, style). Covers printable ASCII.
/// - **Symbols** — librio ships an embedded "Symbols Nerd Font Mono"
///   (`rio_symbols_nerd_font`) covering the powerline separators and icon
///   ranges the system monospace font has no glyphs for. Without it a remote
///   shell's powerline prompt renders as a row of missing-glyph boxes.
/// - **Fallback** — a cached `CTLine` built from an attributed string, which
///   gets CoreText's font fallback, so CJK, emoji and combining clusters draw
///   correctly instead of as missing-glyph boxes.
@MainActor
final class GlyphCache {
    struct Metrics {
        /// Advance of one cell, in points, rounded to a whole pixel so the
        /// grid never drifts.
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        /// Baseline offset from the bottom of the cell.
        var baseline: CGFloat { descent }
        let underlinePosition: CGFloat
        let underlineThickness: CGFloat
    }

    struct Style: Hashable {
        var bold: Bool
        var italic: Bool
    }

    /// Which font a glyph id belongs to. Glyph ids are per-font, so this has
    /// to travel with the glyph all the way to the draw call.
    enum Source: Hashable {
        case base(Style)
        case symbols
    }

    struct Resolved {
        var glyph: CGGlyph
        var source: Source
    }

    private struct GlyphKey: Hashable {
        var scalar: UInt32
        var style: Style
    }

    private struct LineKey: Hashable {
        var text: String
        var style: Style
    }

    let pointSize: CGFloat
    let scale: CGFloat
    /// nil falls back to the system monospace font.
    let fontName: String?
    private(set) var metrics: Metrics

    private var fonts: [Style: CTFont] = [:]
    private var glyphs: [GlyphKey: Resolved?] = [:]
    private var lines: [LineKey: CTLine] = [:]

    /// Parsed once per process: the blob is ~1.9MB and parsing it per font
    /// size or backing-scale change would be wasteful.
    private static let symbolsCGFont: CGFont? = {
        var length = 0
        guard let bytes = rio_symbols_nerd_font(&length), length > 0 else { return nil }
        // librio owns the buffer, so copy before handing it to CoreGraphics.
        let data = Data(bytes: bytes, count: length)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGFont(provider)
    }()

    private lazy var symbolsFont: CTFont? = Self.symbolsCGFont.map {
        CTFontCreateWithGraphicsFont($0, pointSize, nil, nil)
    }

    init(pointSize: CGFloat, scale: CGFloat, fontName: String? = nil) {
        self.pointSize = pointSize
        self.scale = scale
        self.fontName = fontName

        let regular = GlyphCache.font(
            bold: false, italic: false, size: pointSize, named: fontName)
        fonts[Style(bold: false, italic: false)] = regular

        // Monospace, so every advance matches: measure one.
        var ch: UniChar = 0x4D  // "M"
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)

        // Snap to device pixels: a fractional cell size makes text shimmer as
        // rounding drifts across the grid.
        func snap(_ value: CGFloat) -> CGFloat {
            max(1, (value * scale).rounded(.up) / scale)
        }

        self.metrics = Metrics(
            cellWidth: snap(advance.width),
            cellHeight: snap(ascent + descent + leading),
            ascent: ascent,
            descent: descent,
            underlinePosition: CTFontGetUnderlinePosition(regular),
            underlineThickness: max(1 / scale, CTFontGetUnderlineThickness(regular))
        )
    }

    private static func font(bold: Bool, italic: Bool, size: CGFloat,
                             named name: String?) -> CTFont {
        // A named font the user no longer has installed must not break the
        // terminal, so fall back rather than failing.
        var base = name.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if bold, let bolder = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            as NSFont? {
            base = bolder
        }
        if italic {
            let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
            if let slanted = NSFont(descriptor: descriptor, size: size) {
                base = slanted
            }
        }
        return base as CTFont
    }

    func font(for style: Style) -> CTFont {
        if let cached = fonts[style] { return cached }
        let made = GlyphCache.font(bold: style.bold, italic: style.italic,
                                   size: pointSize, named: fontName)
        fonts[style] = made
        return made
    }

    func font(for source: Source) -> CTFont {
        switch source {
        case .base(let style): return font(for: style)
        case .symbols: return symbolsFont ?? font(for: Style(bold: false, italic: false))
        }
    }

    /// A single glyph for `scalar`, from the styled font or the symbols font,
    /// or nil when neither covers it and the caller should use `line(for:)`.
    func resolve(_ scalar: UnicodeScalar, style: Style) -> Resolved? {
        let key = GlyphKey(scalar: scalar.value, style: style)
        if let cached = glyphs[key] { return cached }

        let resolved = lookUp(scalar, style: style)
        glyphs[key] = resolved
        return resolved
    }

    private func lookUp(_ scalar: UnicodeScalar, style: Style) -> Resolved? {
        // Outside the BMP a single UniChar cannot hold it; shape it instead.
        guard scalar.value <= 0xFFFF else { return nil }
        var ch = UniChar(scalar.value)

        var glyph = CGGlyph()
        if CTFontGetGlyphsForCharacters(font(for: style), &ch, &glyph, 1), glyph != 0 {
            return Resolved(glyph: glyph, source: .base(style))
        }
        // The system monospace font stops at the private-use icon ranges.
        if let symbols = symbolsFont {
            var symbolGlyph = CGGlyph()
            if CTFontGetGlyphsForCharacters(symbols, &ch, &symbolGlyph, 1), symbolGlyph != 0 {
                return Resolved(glyph: symbolGlyph, source: .symbols)
            }
        }
        return nil
    }

    /// A shaped line for text the base font cannot draw directly: emoji, CJK,
    /// and grapheme clusters with combining marks.
    func line(for text: String, style: Style) -> CTLine {
        let key = LineKey(text: text, style: style)
        if let cached = lines[key] { return cached }

        // No foreground colour attribute: CTLine then draws in the context's
        // fill colour, so one cached line serves every colour. Colour-font
        // glyphs (emoji) still carry their own colours.
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font(for: style) as NSFont,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        // Bound the cache: terminals can scroll a lot of unique text past.
        if lines.count > 4096 { lines.removeAll(keepingCapacity: true) }
        lines[key] = line
        return line
    }
}
