import AppKit
import CoreText
import Foundation
import RioKit
import Testing
@testable import SuistoKit

@MainActor
@Suite("Embedded Nerd Font")
struct NerdFontTests {

    @Test("librio exposes an embedded symbols font that CoreText can load")
    func fontLoads() throws {
        var length = 0
        let bytes = try #require(rio_symbols_nerd_font(&length))
        #expect(length > 1000, "suspiciously small font blob: \(length) bytes")

        let data = Data(bytes: bytes, count: length)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgFont = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(cgFont, 13, nil, nil)
        let name = CTFontCopyFullName(font) as String
        print("NERD font=\(name) bytes=\(length)")
    }

    /// The glyphs that made a remote powerline prompt render as `?` boxes.
    @Test("The symbols font covers powerline separators the system font lacks")
    func coversPowerline() throws {
        var length = 0
        let bytes = try #require(rio_symbols_nerd_font(&length))
        let data = Data(bytes: bytes, count: length)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgFont = try #require(CGFont(provider))
        let nerd = CTFontCreateWithGraphicsFont(cgFont, 13, nil, nil)
        let system = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont

        func hasGlyph(_ font: CTFont, _ scalar: UnicodeScalar) -> Bool {
            var chars = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let ok = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
            return ok && glyphs[0] != 0
        }

        // U+E0B0/E0B2 powerline separators, U+F015 home, U+E725 git branch.
        for scalar in [UnicodeScalar(0xE0B0)!, UnicodeScalar(0xE0B2)!,
                       UnicodeScalar(0xF015)!, UnicodeScalar(0xE725)!] {
            let inNerd = hasGlyph(nerd, scalar)
            let inSystem = hasGlyph(system, scalar)
            print(String(format: "NERD U+%04X nerd=%@ system=%@",
                         scalar.value, inNerd ? "yes" : "no", inSystem ? "yes" : "no"))
            #expect(inNerd, "the embedded font should cover U+\(String(scalar.value, radix: 16))")
        }
    }

    @Test("The cache resolves powerline glyphs to the symbols font, not the base font")
    func cacheRoutesToSymbols() {
        let cache = GlyphCache(pointSize: 13, scale: 2)
        let plain = GlyphCache.Style(bold: false, italic: false)

        let ascii = cache.resolve("A", style: plain)
        #expect(ascii?.source == .base(plain), "ASCII must stay on the styled font")

        // U+E0B0 is the powerline right-facing separator.
        let separator = cache.resolve(UnicodeScalar(0xE0B0)!, style: plain)
        #expect(separator?.source == .symbols,
                "a powerline glyph should resolve to librio's embedded symbols font")
    }

    /// Before the symbols font was wired in, these cells drew nothing from
    /// CTFontDrawGlyphs and fell through to a missing-glyph box.
    @Test("A powerline separator renders real ink")
    func powerlineRendersInk() throws {
        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 40, rows: 6, pixelWidth: 400, pixelHeight: 120, scrollback: 50)
        let session = try #require(RioEngine.shared.makeSession(launch))
        defer { RioEngine.shared.closeSession(session.id) }

        let renderer = CoreTextRenderer(scale: 2)
        renderer.resize(to: CGSize(width: 400, height: 120), scale: 2)
        session.injectOutput("\u{E0B0}\u{E0B0}\u{E0B0}\r\n")

        var image: CGImage?
        for _ in 0..<80 {
            image = renderer.render(session, focused: false)
            if rio_render_state_cell(session.renderState, 0, 0).codepoint == 0xE0B0 {
                image = renderer.render(session, focused: false)
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        let frame = try #require(image)
        let ink = inkedPixels(in: frame, row: 0,
                              cellHeight: renderer.metrics.cellHeight, scale: 2)
        #expect(ink > 100, "powerline separators drew almost nothing (\(ink) px)")
    }

    /// Shared with RendererTests: counts pixels differing from the background.
    private func inkedPixels(in image: CGImage, row: Int,
                             cellHeight: CGFloat, scale: CGFloat) -> Int {
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
                if abs(Int(buffer[i]) - Int(background.r)) > 12
                    || abs(Int(buffer[i + 1]) - Int(background.g)) > 12
                    || abs(Int(buffer[i + 2]) - Int(background.b)) > 12 {
                    inked += 1
                }
            }
        }
        return inked
    }
}
