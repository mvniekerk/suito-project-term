import AppKit
import Foundation
import RioKit
import Testing
@testable import SuistoKit

/// Rendering tests that drive a real librio surface.
///
/// `rio_surface_inject_output` writes straight to the terminal display without
/// going through the PTY, which makes it possible to put exact content on the
/// grid and then assert on the pixels that come out.
@MainActor
@Suite("CoreText renderer", .serialized)
struct RendererTests {

    private static let size = CGSize(width: 600, height: 200)

    /// Spawns a surface on `cat`, so nothing writes to the grid except us.
    private func makeSession() throws -> TerminalSession {
        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 60, rows: 10, pixelWidth: 600, pixelHeight: 200, scrollback: 100)
        return try #require(RioEngine.shared.makeSession(launch))
    }

    /// Renders until the grid actually holds `expected` glyphs, then returns
    /// the frame. The IO thread parses injected output asynchronously.
    private func renderUntilReady(
        _ renderer: CoreTextRenderer, _ session: TerminalSession, expecting expected: Int
    ) -> CGImage? {
        var image: CGImage?
        for _ in 0..<80 {
            image = renderer.render(session, focused: false)
            if countGlyphCells(session) >= expected { return renderer.render(session, focused: false) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return image
    }

    private func countGlyphCells(_ session: TerminalSession) -> Int {
        let state = session.renderState
        var count = 0
        for row in 0..<rio_render_state_lines(state) {
            for col in 0..<rio_render_state_columns(state)
            where rio_render_state_cell(state, row, col).codepoint > 32 {
                count += 1
            }
        }
        return count
    }

    /// Counts pixels that differ from the theme background inside one row.
    private func inkedPixels(in image: CGImage, row: Int, cellHeight: CGFloat, scale: CGFloat) -> Int {
        let width = image.width
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        guard let ctx = CGContext(
            data: &buffer, width: width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))

        let background = TerminalTheme.dark.background
        let top = Int(CGFloat(row) * cellHeight * scale)
        let bottom = min(image.height, Int(CGFloat(row + 1) * cellHeight * scale))
        guard top < bottom else { return 0 }

        var inked = 0
        for y in top..<bottom {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                // Tolerate antialiasing against the background.
                if abs(Int(buffer[i]) - Int(background.r)) > 12
                    || abs(Int(buffer[i + 1]) - Int(background.g)) > 12
                    || abs(Int(buffer[i + 2]) - Int(background.b)) > 12 {
                    inked += 1
                }
            }
        }
        return inked
    }

    @Test("Plain text renders visible pixels")
    func plainTextRenders() throws {
        let session = try makeSession()
        defer { RioEngine.shared.closeSession(session.id) }

        let renderer = CoreTextRenderer(scale: 2)
        renderer.resize(to: Self.size, scale: 2)
        session.injectOutput("HELLO\r\n")

        let image = try #require(renderUntilReady(renderer, session, expecting: 5))
        #expect(inkedPixels(in: image, row: 0,
                            cellHeight: renderer.metrics.cellHeight, scale: 2) > 0)
    }

    /// Regression: CTLineDraw leaves a translation in the context's text
    /// matrix (measured: tx/ty equal to where the line was drawn), and
    /// CTFontDrawGlyphs adds that to every glyph position it is given. One
    /// fallback glyph — an emoji or a powerline prompt icon — used to push
    /// every plain glyph drawn afterwards off the canvas, so the terminal
    /// went blank as soon as such a prompt appeared.
    ///
    /// Asserted against a control render of the same ASCII with no fallback
    /// glyph present, because the failure is "much less ink", not "no ink":
    /// an empty row still measures a little antialiasing noise.
    @Test("Plain glyphs still render after a fallback glyph")
    func asciiSurvivesFallbackGlyph() throws {
        let ascii = "PLAINTEXT"

        func inkOfSecondRow(firstRow: String) throws -> (first: Int, second: Int) {
            let session = try makeSession()
            defer { RioEngine.shared.closeSession(session.id) }
            let renderer = CoreTextRenderer(scale: 2)
            renderer.resize(to: Self.size, scale: 2)
            session.injectOutput("\(firstRow)\r\n\(ascii)\r\n")

            let expected = firstRow.count + ascii.count - 2
            let image = try #require(renderUntilReady(renderer, session, expecting: expected))
            let cellHeight = renderer.metrics.cellHeight
            return (inkedPixels(in: image, row: 0, cellHeight: cellHeight, scale: 2),
                    inkedPixels(in: image, row: 1, cellHeight: cellHeight, scale: 2))
        }

        // Control: both rows plain ASCII, so nothing takes the CTLine path.
        let control = try inkOfSecondRow(firstRow: "AA rocket")
        // Same layout, but the first cell needs CoreText fallback.
        let withFallback = try inkOfSecondRow(firstRow: "\u{1F680} rocket")

        #expect(control.second > 100, "control row rendered almost nothing: \(control.second)")

        // The row after the fallback must still carry its glyphs.
        #expect(Double(withFallback.second) > Double(control.second) * 0.5,
                """
                ASCII after a fallback glyph lost its ink \
                (\(withFallback.second) vs control \(control.second)): \
                the text matrix was not reset before CTFontDrawGlyphs
                """)

        // And the ASCII sharing the fallback's own row must survive too.
        #expect(Double(withFallback.first) > Double(control.first) * 0.5,
                """
                ASCII on the same row as a fallback glyph lost its ink \
                (\(withFallback.first) vs control \(control.first))
                """)
    }

    @Test("A repaint after re-attaching another session still draws text")
    func repaintAfterSwitchDrawsText() throws {
        let first = try makeSession()
        let second = try makeSession()
        defer {
            RioEngine.shared.closeSession(first.id)
            RioEngine.shared.closeSession(second.id)
        }

        let renderer = CoreTextRenderer(scale: 2)
        renderer.resize(to: Self.size, scale: 2)

        first.injectOutput("FIRSTSESSION\r\n")
        second.injectOutput("\u{1F680} second\r\n")

        _ = renderUntilReady(renderer, first, expecting: 12)
        // Switching sessions is what the window controller does on a tab change.
        renderer.invalidateAll()
        _ = renderUntilReady(renderer, second, expecting: 7)
        renderer.invalidateAll()
        let back = try #require(renderUntilReady(renderer, first, expecting: 12))

        #expect(inkedPixels(in: back, row: 0,
                            cellHeight: renderer.metrics.cellHeight, scale: 2) > 0,
                "the first session rendered blank after switching back")
    }
}
