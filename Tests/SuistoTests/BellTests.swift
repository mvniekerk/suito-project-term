import AppKit
import Foundation
import Testing
@testable import SuistoKit

/// When a bell should move the Dock icon, and — more importantly — when it
/// should leave it alone.
@MainActor
@Suite("Dock attention")
struct BellTests {

    /// A fresh instance with the AppKit calls stubbed, so none of this needs
    /// an app that is really in the Dock.
    private func makeAttention(active: Bool) -> (DockAttention, () -> Int, () -> [Int]) {
        let attention = DockAttention()
        var requests = 0
        var cancelled: [Int] = []
        attention.isApplicationActive = { active }
        attention.beginRequest = { requests += 1; return requests }
        attention.endRequest = { cancelled.append($0) }
        return (attention, { requests }, { cancelled })
    }

    @Test("A bell in the background asks for attention")
    func bouncesWhenBackgrounded() {
        let (attention, requests, _) = makeAttention(active: false)

        #expect(attention.bell())
        #expect(requests() == 1)
        #expect(attention.pendingRequest == 1)
    }

    /// Bouncing while the user is already looking at the app is pure noise —
    /// the tab badge has already said which session rang.
    @Test("A bell in the foreground does not")
    func staysQuietWhenActive() {
        let (attention, requests, _) = makeAttention(active: true)

        #expect(attention.bell() == false)
        #expect(requests() == 0)
        #expect(attention.pendingRequest == nil)
    }

    /// A build that fails noisily can ring several bells in a row, and each
    /// request queues another bounce.
    @Test("A burst of bells bounces once, not once each")
    func coalescesABurst() {
        let (attention, requests, _) = makeAttention(active: false)
        let start = Date()

        #expect(attention.bell(at: start))
        for offset in [0.1, 0.4, 1.0, 1.9] {
            #expect(attention.bell(at: start.addingTimeInterval(offset)) == false)
        }

        #expect(requests() == 1)
    }

    @Test("A later bell bounces again")
    func bouncesAgainAfterTheInterval() {
        let (attention, requests, _) = makeAttention(active: false)
        let start = Date()

        #expect(attention.bell(at: start))
        let next = start.addingTimeInterval(DockAttention.coalescingInterval + 0.1)
        #expect(attention.bell(at: next))

        #expect(requests() == 2)
    }

    @Test("Coming back to the app cancels the request")
    func clearingCancels() {
        let (attention, _, cancelled) = makeAttention(active: false)
        attention.bell()

        attention.clear()

        #expect(cancelled() == [1])
        #expect(attention.pendingRequest == nil)
    }

    // MARK: - Wiring

    /// The unit tests above decide *when* to bounce; this one proves a bell
    /// coming off a real surface actually arrives there, which is the part a
    /// stub cannot tell you.
    @Test("A bell event on a live session reaches the Dock")
    func bellEventReachesTheDock() throws {
        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 20, rows: 4, pixelWidth: 200, pixelHeight: 80, scrollback: 50)
        let session = try #require(RioEngine.shared.makeSession(launch))

        let attention = DockAttention.shared
        let savedActive = attention.isApplicationActive
        let savedBegin = attention.beginRequest
        let savedEnd = attention.endRequest
        defer {
            attention.isApplicationActive = savedActive
            attention.beginRequest = savedBegin
            attention.endRequest = savedEnd
        }

        var requests = 0
        attention.isApplicationActive = { false }
        attention.beginRequest = { requests += 1; return requests }
        attention.endRequest = { _ in }

        var events = SurfaceEvents()
        events.bells = 1
        session.apply(events)

        #expect(requests == 1, "a bell must ask the Dock for attention")
        #expect(session.bellCount == 1, "and still raise the tab's own badge")
    }

    @Test("Clearing with nothing pending cancels nothing")
    func clearingWithoutARequestIsHarmless() {
        let (attention, _, cancelled) = makeAttention(active: false)

        attention.clear()

        #expect(cancelled().isEmpty)
    }
}
