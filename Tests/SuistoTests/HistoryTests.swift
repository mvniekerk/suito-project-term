import Foundation
import RioKit
import Testing
@testable import SuistoKit

@MainActor
@Suite("Scrollback restore")
struct HistoryTests {

    private func scratchStore() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-history-\(UUID().uuidString)", isDirectory: true)
        return (HistoryStore(directory: dir), dir)
    }

    @Test("History round-trips through the store")
    func roundTrip() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = UUID()

        store.save("line one\nline two", for: tab)
        #expect(store.load(for: tab) == "line one\nline two")
    }

    @Test("A dump's trailing blank grid rows are not saved")
    func trailingBlanksTrimmed() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = UUID()

        // rio_surface_dump returns the whole grid, so most of it is empty.
        store.save("real output\n   \n\n\n     \n", for: tab)
        let loaded = try #require(store.load(for: tab))
        #expect(loaded == "real output")
    }

    @Test("An empty dump removes the file instead of leaving a stub")
    func emptyDumpClears() {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = UUID()

        store.save("something", for: tab)
        store.save("\n\n   \n", for: tab)
        #expect(store.load(for: tab) == nil)
    }

    @Test("Oversized history keeps the tail and stays valid UTF-8")
    func capKeepsTail() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = UUID()

        // Multi-byte throughout, so a naive byte cut would split a scalar.
        let unit = "héllo-wörld\n"
        let huge = String(repeating: unit, count: (HistoryStore.byteLimit / unit.utf8.count) + 500)
        huge.withCString { _ in }
        store.save(huge + "THE-VERY-END", for: tab)

        let loaded = try #require(store.load(for: tab))
        #expect(loaded.utf8.count <= HistoryStore.byteLimit)
        #expect(loaded.hasSuffix("THE-VERY-END"), "the tail is the part worth keeping")
        // Decoding garbage yields replacement characters; there should be none.
        #expect(!loaded.contains("\u{FFFD}"), "the cut split a multi-byte scalar")
    }

    @Test("Pruning drops history for tabs that no longer exist")
    func pruneRemovesOrphans() {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = UUID()
        let dropped = UUID()

        store.save("keep me", for: kept)
        store.save("delete me", for: dropped)
        store.prune(keeping: [kept])

        #expect(store.load(for: kept) == "keep me")
        #expect(store.load(for: dropped) == nil)
    }

    /// A dump carries bare `\n`. Replaying that without a carriage return
    /// stair-steps every line further right across the screen.
    @Test("Replay converts bare newlines so lines start at column 0")
    func replayNormalisesLineEndings() {
        let replay = HistoryStore.replayBytes("alpha\nbeta")
        #expect(replay.contains("alpha\r\nbeta"))
        #expect(!replay.contains("alpha\nbeta"))
        #expect(replay.contains("── restored"), "the boundary should be marked")
    }

    @Test("Already-CRLF history is not doubled up")
    func replayDoesNotDoubleCarriageReturns() {
        let replay = HistoryStore.replayBytes("alpha\r\nbeta")
        #expect(!replay.contains("\r\r"))
        #expect(replay.contains("alpha\r\nbeta"))
    }

    /// The end-to-end path: dump a live surface, save it, and replay it into a
    /// fresh one, which is exactly what a restart does.
    @Test("A session's output survives a dump, save and replay into a new session")
    func dumpSaveReplayRoundTrip() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = UUID()
        let marker = "HISTORY-MARKER-42"

        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 40, rows: 8, pixelWidth: 400, pixelHeight: 160, scrollback: 200)

        let original = try #require(RioEngine.shared.makeSession(launch))
        original.injectOutput("\(marker)\r\n")

        var dump: String?
        for _ in 0..<80 {
            dump = original.dumpBuffer()
            if dump?.contains(marker) == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RioEngine.shared.closeSession(original.id)

        let captured = try #require(dump)
        #expect(captured.contains(marker))
        store.save(captured, for: tab)

        // A new app launch: new surface, saved history replayed into it.
        let restored = try #require(RioEngine.shared.makeSession(launch))
        defer { RioEngine.shared.closeSession(restored.id) }
        let saved = try #require(store.load(for: tab))
        restored.injectOutput(HistoryStore.replayBytes(saved))

        var replayed = false
        for _ in 0..<80 {
            if restored.dumpBuffer()?.contains(marker) == true { replayed = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(replayed, "the restored session never showed the earlier output")
    }
}
