import RioKit

/// Typed views over librio's bit flags and enums.
///
/// The C header spells these as `#define`s, which import into Swift as
/// `UInt32` even where the struct field holding them is `UInt16` or `UInt8`.
/// Wrapping them once here keeps casts out of the renderer and turns bit
/// fiddling into readable set operations.
struct CellStyle: OptionSet {
    let rawValue: UInt16

    static let inverse = CellStyle(rawValue: 1 << 0)
    static let bold = CellStyle(rawValue: 1 << 1)
    static let italic = CellStyle(rawValue: 1 << 2)
    static let dim = CellStyle(rawValue: 1 << 3)
    static let hidden = CellStyle(rawValue: 1 << 4)
    static let strikeout = CellStyle(rawValue: 1 << 5)
    static let underline = CellStyle(rawValue: 1 << 6)
    static let doubleUnderline = CellStyle(rawValue: 1 << 7)
    static let undercurl = CellStyle(rawValue: 1 << 8)
    static let dottedUnderline = CellStyle(rawValue: 1 << 9)
    static let dashedUnderline = CellStyle(rawValue: 1 << 10)
    static let slowBlink = CellStyle(rawValue: 1 << 11)
    static let rapidBlink = CellStyle(rawValue: 1 << 12)

    /// Bits 14-15 are markers rather than styles: they say that extra data is
    /// available for the cell through a separate call.
    static let hasUnderlineColor = CellStyle(rawValue: 1 << 14)
    static let hasCluster = CellStyle(rawValue: 1 << 15)

    /// At most one of these is ever set on a cell.
    static let anyUnderline: CellStyle = [
        .underline, .doubleUnderline, .undercurl, .dottedUnderline, .dashedUnderline,
    ]
    /// Anything that draws a line through or under the cell.
    static let anyDecoration: CellStyle = anyUnderline.union(.strikeout)
}

extension rio_cell_s {
    var style: CellStyle { CellStyle(rawValue: style_flags) }
}

/// DECSCUSR cursor shape, or `.hidden` when the program hid the cursor
/// (DECTCEM) or the view is scrolled into history.
enum CursorShape: UInt8 {
    case block = 0
    case underline = 1
    case beam = 2
    case hidden = 3

    init(rawShape: UInt8) { self = CursorShape(rawValue: rawShape) ?? .block }
}

enum SelectionKind: UInt8 {
    case simple = 0
    case word = 1
    case line = 2
    case block = 3
}
