import AppKit
import Foundation
import RioKit
import Testing
@testable import SuistoKit

@MainActor
@Suite("Appearance")
struct AppearanceTests {

    @Test("Every named theme resolves, and an unknown name falls back")
    func themesResolve() {
        for theme in TerminalTheme.all {
            #expect(TerminalTheme.named(theme.name).name == theme.name)
            #expect(theme.ansi.count == 16, "\(theme.name) must fill all 16 ANSI slots")
        }
        // A workspace naming a theme this build dropped must still open.
        #expect(TerminalTheme.named("No Such Theme").name == TerminalTheme.dark.name)
    }

    @Test("Appearance defaults survive a workspace written before it existed")
    func appearanceDefaultsOnOldFile() throws {
        let json = #"{"projects":[],"selectedProjectID":null}"#
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))

        #expect(workspace.appearance.fontName == nil)
        #expect(workspace.appearance.fontSize == 13)
        #expect(workspace.appearance.themeName == "Dark")
    }

    @Test("Appearance round-trips")
    func appearanceRoundTrips() throws {
        var appearance = Workspace.Appearance()
        appearance.fontName = "Menlo"
        appearance.fontSize = 15
        appearance.themeName = "Light"

        let decoded = try JSONDecoder().decode(
            Workspace.Appearance.self, from: JSONEncoder().encode(appearance))
        #expect(decoded == appearance)
        #expect(decoded.theme.name == "Light")
    }

    // MARK: - Terminal translucency

    /// The trap this guards: Swift's synthesised decoder treats a missing key
    /// as an error, so adding the opacity field would have thrown away the
    /// whole stored appearance of every existing workspace.
    @Test("An appearance written before the opacity field still decodes")
    func opacityDefaultsOnOlderAppearance() throws {
        let json = #"{"fontSize":15,"themeName":"Light","fontName":"Menlo"}"#
        let decoded = try JSONDecoder().decode(
            Workspace.Appearance.self, from: Data(json.utf8))

        #expect(decoded.terminalOpacity == Workspace.Appearance.defaultOpacity)
        // The rest must survive intact, not be reset alongside it.
        #expect(decoded.fontSize == 15)
        #expect(decoded.themeName == "Light")
        #expect(decoded.fontName == "Menlo")
    }

    @Test("Translucency persists through a workspace file")
    func opacityPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store(url: directory.appendingPathComponent("workspace.json"))

        var workspace = Workspace.bootstrap(directory: NSHomeDirectory())
        workspace.appearance.terminalOpacity = 0.55
        store.flush(workspace)

        let reloaded = try #require(store.load())
        #expect(reloaded.appearance.terminalOpacity == 0.55)
    }

    /// A slider that can reach zero leaves the terminal unreadable, which is
    /// a state you then cannot see well enough to undo.
    @Test("Opacity is clamped to a legible range")
    func opacityIsClamped() {
        let range = Workspace.Appearance.opacityRange
        #expect(Workspace.Appearance.clampOpacity(0) == range.lowerBound)
        #expect(Workspace.Appearance.clampOpacity(-5) == range.lowerBound)
        #expect(Workspace.Appearance.clampOpacity(2) == range.upperBound)
        #expect(Workspace.Appearance.clampOpacity(0.6) == 0.6)
        #expect(Workspace.Appearance.clampOpacity(.nan) == Workspace.Appearance.defaultOpacity)
    }

    @Test("A stored value outside the range is pulled back when decoded")
    func decodedOpacityIsClamped() throws {
        let json = #"{"terminalOpacity":0.01}"#
        let decoded = try JSONDecoder().decode(
            Workspace.Appearance.self, from: Data(json.utf8))
        #expect(decoded.terminalOpacity == Workspace.Appearance.opacityRange.lowerBound)
    }

    /// The renderer has to repaint everything, not just dirty rows: otherwise
    /// a new translucency would arrive one changed line at a time.
    @Test("Changing translucency repaints the whole grid")
    func translucencyForcesFullRepaint() {
        let renderer = CoreTextRenderer()
        renderer.resize(to: CGSize(width: 400, height: 200), scale: 2)
        renderer.invalidateAll()
        #expect(renderer.backgroundOpacity == CGFloat(Workspace.Appearance.defaultOpacity))

        renderer.setBackgroundOpacity(0.5)

        #expect(renderer.backgroundOpacity == 0.5)
        #expect(renderer.needsFullRepaint)
    }

    @Test("The renderer takes its translucency from the appearance")
    func rendererFollowsAppearance() {
        let renderer = CoreTextRenderer()
        var appearance = Workspace.Appearance()
        appearance.terminalOpacity = 0.44
        renderer.apply(appearance)
        #expect(renderer.backgroundOpacity == 0.44)
    }

    @Test("A font name the user no longer has falls back instead of failing")
    func missingFontFallsBack() {
        let cache = GlyphCache(pointSize: 13, scale: 2, fontName: "NoSuchFont-Regular")
        #expect(cache.metrics.cellWidth > 0)
        #expect(cache.metrics.cellHeight > 0)
        // Still usable: ASCII must resolve on the fallback face.
        #expect(cache.resolve("A", style: .init(bold: false, italic: false)) != nil)
    }

    @Test("A larger font yields larger cells, so the grid re-measures")
    func fontSizeChangesCellMetrics() {
        let small = GlyphCache(pointSize: 11, scale: 2)
        let large = GlyphCache(pointSize: 18, scale: 2)

        #expect(large.metrics.cellWidth > small.metrics.cellWidth)
        #expect(large.metrics.cellHeight > small.metrics.cellHeight)
    }

    @Test("Cell metrics land on whole device pixels so text cannot shimmer")
    func metricsArePixelAligned() {
        for scale in [1.0, 2.0] as [CGFloat] {
            let cache = GlyphCache(pointSize: 13, scale: scale)
            let widthPixels = cache.metrics.cellWidth * scale
            let heightPixels = cache.metrics.cellHeight * scale
            #expect(abs(widthPixels.rounded() - widthPixels) < 0.0001)
            #expect(abs(heightPixels.rounded() - heightPixels) < 0.0001)
        }
    }

    @Test("Switching theme changes what the renderer draws")
    func themeChangeRepaints() throws {
        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 20, rows: 4, pixelWidth: 200, pixelHeight: 80, scrollback: 50)
        let session = try #require(RioEngine.shared.makeSession(launch))
        defer {
            RioEngine.shared.closeSession(session.id)
            // Leave the process-wide palette as the rest of the suite expects.
            TerminalTheme.dark.apply()
        }

        let renderer = CoreTextRenderer(scale: 2)
        renderer.resize(to: CGSize(width: 200, height: 80), scale: 2)
        session.injectOutput("X\r\n")

        var dark: CGImage?
        for _ in 0..<60 {
            dark = renderer.render(session, focused: false)
            if rio_render_state_cell(session.renderState, 0, 0).codepoint == UInt32(88) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let before = try #require(dark)

        var appearance = Workspace.Appearance()
        appearance.themeName = "Light"
        renderer.apply(appearance)
        let after = try #require(renderer.render(session, focused: false))

        #expect(corner(of: before) != corner(of: after),
                "the background should differ between the dark and light themes")
    }

    /// Top-left pixel, which is background in both themes.
    private func corner(of image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return pixel }
        ctx.draw(image, in: CGRect(x: 0, y: 0,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return pixel
    }
}
