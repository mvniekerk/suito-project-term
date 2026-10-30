import AppKit
import CoreText
import Foundation
import RioKit

/// Paints the cell grid with CoreText into an offscreen bitmap.
///
/// Only rows librio marks dirty are repainted; the bitmap persists between
/// frames, so steady output costs a few rows rather than a full screen. The
/// view presents the bitmap as its layer contents.
@MainActor
final class CoreTextRenderer: TerminalRenderer {
    private var theme: TerminalTheme
    private var cache: GlyphCache
    /// How solid the terminal's *default* background is over the frosted
    /// panel behind it. Cells with a colour of their own — coloured output,
    /// selections, inverse video — stay fully opaque regardless, so only the
    /// empty parts of the grid let the frost through.
    ///
    /// Lower reads as more glass and less text. Driven by the appearance, so
    /// the Settings slider moves it live.
    private(set) var backgroundOpacity = CGFloat(Workspace.Appearance.defaultOpacity)

    private var context: CGContext?
    private var scale: CGFloat = 2
    private var sizeInPoints: CGSize = .zero
    private var repaintEverything = true

    /// State that changes a row's appearance without librio marking it dirty,
    /// so we have to notice it ourselves.
    private var lastCursor: rio_cursor_s?
    private var lastSelection: rio_selection_s?
    private var lastFocused = true

    var metrics: GlyphCache.Metrics { cache.metrics }

    /// Bottom edge of a terminal row in point space. Row 0 sits at the top, so
    /// any height that is not a whole number of cells is slack at the bottom.
    private func rowY(_ row: UInt16) -> CGFloat {
        sizeInPoints.height - CGFloat(row + 1) * cache.metrics.cellHeight
    }

    init(theme: TerminalTheme = .dark, pointSize: CGFloat = 13, scale: CGFloat = 2) {
        self.theme = theme
        self.scale = scale
        self.cache = GlyphCache(pointSize: pointSize, scale: scale)
    }

    // MARK: - Backing store

    func resize(to size: CGSize, scale: CGFloat) {
        let changed = size != sizeInPoints || scale != self.scale
        guard changed else { return }

        if scale != self.scale {
            self.scale = scale
            cache = GlyphCache(pointSize: cache.pointSize, scale: scale,
                               fontName: cache.fontName)
        }
        sizeInPoints = size

        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else {
            context = nil
            return
        }

        let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        // Left unflipped, on CoreGraphics' native bottom-left origin: terminal
        // row 0 maps to the top via `rowY(_:)`. Flipping instead would need a
        // compensating text matrix and invert every glyph.
        ctx?.scaleBy(x: scale, y: scale)
        ctx?.setAllowsAntialiasing(true)
        ctx?.setShouldAntialias(true)
        ctx?.setShouldSmoothFonts(false)   // grid text: subpixel smoothing smears
        context = ctx
        repaintEverything = true
    }

    func invalidateAll() { repaintEverything = true }

    /// Whether the next frame redraws the whole grid rather than dirty rows.
    var needsFullRepaint: Bool { repaintEverything }

    /// Switches font and colours at runtime.
    ///
    /// The palette is pushed to librio as well, because it resolves named and
    /// indexed cell colours itself and would otherwise keep handing back the
    /// old RGB. `rio_set_colors` is process-wide, so one call covers every
    /// surface; each view still has to repaint.
    func apply(_ appearance: Workspace.Appearance) {
        theme = appearance.theme
        theme.apply()
        cache = GlyphCache(pointSize: appearance.fontSize, scale: scale,
                           fontName: appearance.fontName)
        backgroundOpacity = CGFloat(appearance.terminalOpacity)
        repaintEverything = true
    }

    /// Just the translucency, for the Settings slider. A whole repaint is
    /// required: only dirty rows are redrawn, so without it the new alpha
    /// would creep in one changed line at a time.
    func setBackgroundOpacity(_ value: Double) {
        backgroundOpacity = CGFloat(Workspace.Appearance.clampOpacity(value))
        repaintEverything = true
    }

    // MARK: - Render

    func render(_ session: TerminalSession, focused: Bool) -> CGImage? {
        guard let ctx = context else { return nil }

        rio_render_state_update(session.renderState)
        let state = session.renderState
        let rows = rio_render_state_lines(state)
        let cols = rio_render_state_columns(state)
        guard rows > 0, cols > 0 else { return nil }

        let cursor = rio_render_state_cursor(state)
        let cursorShape = CursorShape(rawShape: rio_render_state_cursor_shape(state))
        let selection = rio_render_state_selection(state)

        // The program can override the default colours at runtime (OSC 10/11).
        var dynamicBG = rio_rgb_s()
        let background: TerminalTheme.RGB =
            rio_render_state_dynamic_color(state, 1, &dynamicBG)
            ? .init(r: dynamicBG.r, g: dynamicBG.g, b: dynamicBG.b)
            : theme.background

        // Rows that need repainting for reasons librio does not track: the
        // cursor moving off a row, a changed selection, a focus change.
        var extraDirty = Set<UInt16>()
        if let last = lastCursor, last.line != cursor.line || last.column != cursor.column {
            extraDirty.insert(last.line)
            extraDirty.insert(cursor.line)
        } else if lastCursor == nil {
            extraDirty.insert(cursor.line)
        }
        if !selectionsEqual(lastSelection, selection) {
            // A selection can span any range, and the old one has to be
            // cleared, so the cheap and correct move is a full repaint.
            repaintEverything = true
        }
        if focused != lastFocused {
            extraDirty.insert(cursor.line)
        }

        if repaintEverything {
            // Cleared first: the bitmap persists between frames, so painting a
            // translucent colour over it would compound towards opaque.
            let whole = CGRect(origin: .zero, size: sizeInPoints)
            ctx.clear(whole)
            ctx.setFillColor(background.cgColor(alpha: backgroundOpacity))
            ctx.fill(whole)
        }

        for row in 0..<rows {
            let isDirty = repaintEverything
                || rio_render_state_row_dirty(state, row)
                || extraDirty.contains(row)
            guard isDirty else { continue }
            drawRow(row, in: ctx, state: state, cols: cols,
                    background: background, selection: selection)
        }

        drawCursor(cursor, shape: cursorShape, in: ctx, state: state,
                   cols: cols, rows: rows, focused: focused, background: background)

        if ProcessInfo.processInfo.environment["SUISTO_DEBUG_RENDER"] != nil {
            var nonBlank = 0
            var dirtyRows = 0
            for r in 0..<rows {
                if rio_render_state_row_dirty(state, r) { dirtyRows += 1 }
                for c in 0..<cols where rio_render_state_cell(state, r, c).codepoint > 32 {
                    nonBlank += 1
                }
            }
            let dump = (rio_surface_dump(session.surface).map { p -> String in
                defer { rio_text_free(p) }
                return String(cString: p)
            } ?? "")
            let dumpChars = dump.filter { !$0.isWhitespace }.count
            NSLog("PTRENDER grid=\(cols)x\(rows) repaintAll=\(repaintEverything) dirtyRows=\(dirtyRows) nonBlankCells=\(nonBlank) dumpNonWS=\(dumpChars) cursor=\(cursor.line),\(cursor.column) ctx=\(context != nil) size=\(sizeInPoints)")
        }

        // librio never clears dirty flags itself; the host must, once it has
        // consumed the snapshot.
        rio_render_state_reset_dirty(state)
        repaintEverything = false
        lastCursor = cursor
        lastSelection = selection
        lastFocused = focused

        return ctx.makeImage()
    }

    // MARK: - Rows

    private func drawRow(
        _ row: UInt16,
        in ctx: CGContext,
        state: OpaquePointer,
        cols: UInt16,
        background: TerminalTheme.RGB,
        selection: rio_selection_s
    ) {
        let m = cache.metrics
        let rowRect = CGRect(
            x: 0,
            y: rowY(row),
            width: CGFloat(cols) * m.cellWidth,
            height: m.cellHeight
        )

        // 1. Backgrounds, merging runs of one colour into a single fill.
        //    Cleared first for the same reason as the whole-bitmap repaint.
        ctx.clear(rowRect)
        ctx.setFillColor(background.cgColor(alpha: backgroundOpacity))
        ctx.fill(rowRect)

        var runStart: UInt16 = 0
        var runColor: TerminalTheme.RGB? = nil

        func flushBackground(end: UInt16) {
            guard let color = runColor, color != background, end > runStart else { return }
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(
                x: CGFloat(runStart) * m.cellWidth,
                y: rowRect.minY,
                width: CGFloat(end - runStart) * m.cellWidth,
                height: m.cellHeight
            ))
        }

        for col in 0..<cols {
            let cell = rio_render_state_cell(state, row, col)
            let color = effectiveBackground(cell, selected: isSelected(row: row, col: col, selection))
            if color != runColor {
                flushBackground(end: col)
                runStart = col
                runColor = color
            }
        }
        flushBackground(end: cols)

        // 2. Glyphs. Grouped by (style, colour) so each group is one CoreText
        // call rather than one per cell.
        var groups: [GlyphGroup: [(CGGlyph, CGPoint)]] = [:]
        var fallbacks: [(text: String, style: GlyphCache.Style, color: CGColor, x: CGFloat)] = []

        let baselineY = rowRect.minY + m.baseline

        for col in 0..<cols {
            let cell = rio_render_state_cell(state, row, col)
            guard !cell.style.contains(.hidden) else { continue }

            // A wide character's trailing cell is a spacer carrying no
            // codepoint of its own; the wide glyph already covered it.
            guard cell.codepoint != 0 else { continue }

            var fg = effectiveForeground(cell)
            if cell.style.contains(.dim) {
                fg = TerminalTheme.RGB(
                    r: UInt8(Double(fg.r) * 0.6), g: UInt8(Double(fg.g) * 0.6),
                    b: UInt8(Double(fg.b) * 0.6))
            }

            let style = GlyphCache.Style(
                bold: cell.style.contains(.bold),
                italic: cell.style.contains(.italic)
            )
            let x = CGFloat(col) * m.cellWidth

            // Clusters (combining marks, DEC-2027 graphemes) carry more than
            // one codepoint and must be shaped as a unit.
            if cell.style.contains(.hasCluster) {
                if let text = clusterText(state: state, row: row, col: col) {
                    fallbacks.append((text, style, fg.cgColor, x))
                }
                continue
            }

            guard let scalar = UnicodeScalar(cell.codepoint) else { continue }
            if scalar == " " { continue }

            if let resolved = cache.resolve(scalar, style: style) {
                let key = GlyphGroup(source: resolved.source, color: fg)
                groups[key, default: []].append((resolved.glyph, CGPoint(x: x, y: baselineY)))
            } else {
                fallbacks.append((String(scalar), style, fg.cgColor, x))
            }
        }

        // CTLineDraw leaves its own text matrix behind, and CTFontDrawGlyphs
        // honours whatever is there. Without this reset, one fallback glyph
        // (a powerline or emoji cell) silently breaks every plain glyph drawn
        // afterwards, in this row and every later frame.
        // CTLineDraw leaves a translation in the context's text matrix, and
        // CTFontDrawGlyphs adds it to every position it is given. Without this
        // reset, one fallback glyph (an emoji or a powerline prompt icon)
        // pushes every plain glyph drawn after it off the canvas.
        ctx.textMatrix = .identity

        for (key, entries) in groups {
            ctx.setFillColor(key.color.cgColor)
            let font = cache.font(for: key.source)
            var glyphs = entries.map { $0.0 }
            var positions = entries.map { $0.1 }
            CTFontDrawGlyphs(font, &glyphs, &positions, glyphs.count, ctx)
        }

        for fallback in fallbacks {
            ctx.setFillColor(fallback.color)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: fallback.x, y: baselineY)
            CTLineDraw(cache.line(for: fallback.text, style: fallback.style), ctx)
        }

        // 3. Decorations, which need per-cell colours and so run last.
        drawDecorations(row: row, in: ctx, state: state, cols: cols,
                        selection: selection, baselineY: baselineY)
    }

    private struct GlyphGroup: Hashable {
        var source: GlyphCache.Source
        var color: TerminalTheme.RGB
    }

    private func drawDecorations(
        row: UInt16,
        in ctx: CGContext,
        state: OpaquePointer,
        cols: UInt16,
        selection: rio_selection_s,
        baselineY: CGFloat
    ) {
        let m = cache.metrics

        for col in 0..<cols {
            let cell = rio_render_state_cell(state, row, col)
            let flags = cell.style
            guard !flags.isDisjoint(with: .anyDecoration) else { continue }

            // SGR 58 gives an explicit underline colour; without it, rio's own
            // renderer uses the glyph colour, so we do too.
            let color: TerminalTheme.RGB
            if flags.contains(.hasUnderlineColor),
               let explicit = rio_render_state_cell_underline_color(state, row, col).rgb {
                color = explicit
            } else {
                color = effectiveForeground(cell)
            }

            let x = CGFloat(col) * m.cellWidth
            ctx.setFillColor(color.cgColor)
            let thickness = m.underlineThickness
            let underlineY = baselineY + m.underlinePosition - thickness

            if flags.contains(.strikeout) {
                ctx.fill(CGRect(x: x, y: baselineY + m.ascent * 0.3,
                                width: m.cellWidth, height: thickness))
            }
            if flags.contains(.underline) {
                ctx.fill(CGRect(x: x, y: underlineY, width: m.cellWidth, height: thickness))
            }
            if flags.contains(.doubleUnderline) {
                ctx.fill(CGRect(x: x, y: underlineY, width: m.cellWidth, height: thickness))
                ctx.fill(CGRect(x: x, y: underlineY - thickness * 2,
                                width: m.cellWidth, height: thickness))
            }
            if flags.contains(.dottedUnderline) {
                let step = max(2 / scale, thickness * 2)
                var dotX = x
                while dotX < x + m.cellWidth {
                    ctx.fill(CGRect(x: dotX, y: underlineY, width: thickness, height: thickness))
                    dotX += step
                }
            }
            if flags.contains(.dashedUnderline) {
                ctx.fill(CGRect(x: x, y: underlineY,
                                width: m.cellWidth * 0.6, height: thickness))
            }
            if flags.contains(.undercurl) {
                drawUndercurl(at: x, y: underlineY, in: ctx, color: color, thickness: thickness)
            }
        }
    }

    private func drawUndercurl(
        at x: CGFloat, y: CGFloat, in ctx: CGContext,
        color: TerminalTheme.RGB, thickness: CGFloat
    ) {
        let m = cache.metrics
        let amplitude = max(1, thickness)
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(thickness)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x, y: y))
        let steps = 4
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let waveY = y + (i % 2 == 0 ? 0 : amplitude)
            ctx.addLine(to: CGPoint(x: x + m.cellWidth * t, y: waveY))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Cursor

    private func drawCursor(
        _ cursor: rio_cursor_s,
        shape: CursorShape,
        in ctx: CGContext,
        state: OpaquePointer,
        cols: UInt16,
        rows: UInt16,
        focused: Bool,
        background: TerminalTheme.RGB
    ) {
        guard shape != .hidden,
              cursor.line < rows, cursor.column < cols else { return }

        let m = cache.metrics
        let x = CGFloat(cursor.column) * m.cellWidth
        let y = rowY(cursor.line)
        let color = theme.cursor

        ctx.setFillColor(color.cgColor)

        switch shape {
        case .beam:
            ctx.fill(CGRect(x: x, y: y, width: max(1, 2 / scale * 2), height: m.cellHeight))
        case .underline:
            ctx.fill(CGRect(x: x, y: y, width: m.cellWidth, height: max(1, m.underlineThickness * 2)))
        default:
            let rect = CGRect(x: x, y: y, width: m.cellWidth, height: m.cellHeight)
            if focused {
                ctx.fill(rect)
                // Redraw the covered glyph in the background colour so the
                // character under a block cursor stays readable.
                let cell = rio_render_state_cell(state, cursor.line, cursor.column)
                if let scalar = UnicodeScalar(cell.codepoint), scalar != " ",
                   cell.codepoint != 0 {
                    let style = GlyphCache.Style(
                        bold: cell.style.contains(.bold),
                        italic: cell.style.contains(.italic))
                    ctx.setFillColor(background.cgColor)
                    ctx.textMatrix = .identity
                    let point = CGPoint(x: x, y: y + m.baseline)
                    if let resolved = cache.resolve(scalar, style: style) {
                        var glyphs = [resolved.glyph]
                        var positions = [point]
                        CTFontDrawGlyphs(cache.font(for: resolved.source),
                                         &glyphs, &positions, 1, ctx)
                    } else {
                        ctx.textPosition = point
                        CTLineDraw(cache.line(for: String(scalar), style: style), ctx)
                    }
                }
            } else {
                // Unfocused: outline only, the convention every terminal uses.
                ctx.stroke(rect.insetBy(dx: 0.5 / scale, dy: 0.5 / scale),
                           width: max(1 / scale, 1))
            }
        }
    }

    // MARK: - Colour and selection helpers

    /// Selection only recolours the background, so the glyph colour is just
    /// the cell's own, with INVERSE applied: librio exports fg/bg pre-swap and
    /// leaves the swap to the host, as rio's own renderer does.
    private func effectiveForeground(_ cell: rio_cell_s) -> TerminalTheme.RGB {
        cell.style.contains(.inverse)
            ? (cell.bg.rgb ?? theme.background)
            : (cell.fg.rgb ?? theme.foreground)
    }

    private func effectiveBackground(_ cell: rio_cell_s, selected: Bool) -> TerminalTheme.RGB {
        if selected { return theme.selection }
        return cell.style.contains(.inverse)
            ? (cell.fg.rgb ?? theme.foreground)
            : (cell.bg.rgb ?? theme.background)
    }

    private func isSelected(row: UInt16, col: UInt16, _ selection: rio_selection_s) -> Bool {
        guard selection.active else { return false }
        if selection.is_block {
            let loCol = min(selection.start_col, selection.end_col)
            let hiCol = max(selection.start_col, selection.end_col)
            return row >= min(selection.start_line, selection.end_line)
                && row <= max(selection.start_line, selection.end_line)
                && col >= loCol && col <= hiCol
        }
        if row < selection.start_line || row > selection.end_line { return false }
        if selection.start_line == selection.end_line {
            return col >= selection.start_col && col <= selection.end_col
        }
        if row == selection.start_line { return col >= selection.start_col }
        if row == selection.end_line { return col <= selection.end_col }
        return true
    }

    private func selectionsEqual(_ a: rio_selection_s?, _ b: rio_selection_s) -> Bool {
        guard let a else { return !b.active }
        return a.active == b.active
            && a.start_line == b.start_line && a.start_col == b.start_col
            && a.end_line == b.end_line && a.end_col == b.end_col
            && a.is_block == b.is_block
    }

    private func clusterText(state: OpaquePointer, row: UInt16, col: UInt16) -> String? {
        var buffer = [UInt32](repeating: 0, count: 16)
        var count = buffer.withUnsafeMutableBufferPointer {
            rio_render_state_cell_cluster(state, row, col, $0.baseAddress, $0.count)
        }
        if count > buffer.count {
            buffer = [UInt32](repeating: 0, count: count)
            count = buffer.withUnsafeMutableBufferPointer {
                rio_render_state_cell_cluster(state, row, col, $0.baseAddress, $0.count)
            }
        }
        guard count > 0 else { return nil }
        var text = ""
        for scalar in buffer.prefix(count).compactMap(UnicodeScalar.init) {
            text.unicodeScalars.append(scalar)
        }
        return text.isEmpty ? nil : text
    }
}
