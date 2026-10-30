import AppKit
import Testing
@testable import SuistoKit

/// Where a drop actually lands, measured on a real view hierarchy.
///
/// `ReorderTests` pins the index arithmetic, and all of it was right while the
/// sidebar still moved every clicked project to the top. The arithmetic was
/// being fed midpoints measured in the stack view's coordinate space against a
/// drag location measured in the sidebar's, so no amount of testing the pure
/// function could catch it. These tests lay out real views and assert the two
/// agree.
@MainActor
@Suite("Drop geometry")
struct DropGeometryTests {

    private func projects(_ count: Int) -> [Project] {
        (0..<count).map {
            Project(name: "project-\($0)", directory: "/tmp", colorIndex: $0,
                    tabs: [TabSpec(name: "shell", target: .local)])
        }
    }

    private func laidOutSidebar(rows: Int, height: CGFloat = 900) -> ProjectSidebarView {
        let list = projects(rows)
        // A tall sidebar holding a short stack is the shape that exposed the
        // bug: the taller the window, the further off the midpoints were.
        let sidebar = ProjectSidebarView(
            frame: NSRect(x: 0, y: 0, width: 220, height: height))
        sidebar.update(projects: list, selected: list.first?.id) { _ in .init() }
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test("Sidebar midpoints run top-down, in display order")
    func sidebarMidpointsAreTopDown() throws {
        let midpoints = laidOutSidebar(rows: 4).rowMidpointsTopDown()
        try #require(midpoints.count == 4)
        for (earlier, later) in zip(midpoints, midpoints.dropFirst()) {
            #expect(earlier < later,
                    "row \(earlier) should sit above row \(later): \(midpoints)")
        }
        // The first row clears the traffic lights, so it starts some way down,
        // but it must still be near the top rather than near the bottom.
        let first = try #require(midpoints.first)
        #expect(first < 120, "first row should be near the top, was \(first)")
    }

    /// The row actually under a point, found by hit-testing rather than by the
    /// same arithmetic the drop logic uses — otherwise the test would agree
    /// with the bug.
    private func row(under point: NSPoint, in container: NSView) -> ProjectRowView? {
        var view = container.hitTest(point)
        while let current = view, !(current is ProjectRowView) {
            view = current.superview
        }
        return view as? ProjectRowView
    }

    @Test("Dropping a project where it already sits leaves it alone")
    func droppingOnItsOwnRowIsANoOp() throws {
        let list = projects(4)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 900))
        let sidebar = ProjectSidebarView(frame: container.bounds)
        container.addSubview(sidebar)
        sidebar.update(projects: list, selected: list.first?.id) { _ in .init() }
        container.layoutSubtreeIfNeeded()

        // Sweep the whole sidebar. Wherever a row is genuinely under the
        // pointer, letting go there must leave that row where it is — that is
        // precisely what a click is.
        var checked = 0
        for y in stride(from: CGFloat(1), to: container.bounds.height, by: 2) {
            let point = NSPoint(x: 110, y: y)
            guard let row = row(under: point, in: container),
                  let index = list.firstIndex(where: { $0.id == row.project.id })
            else { continue }

            let insertion = sidebar.insertionIndex(at: point)
            let destination = DropIndex.destination(movingFrom: index,
                                                    toInsertionIndex: insertion)
            #expect(destination == index,
                    "a drop on row \(index) at y=\(y) moved it to \(destination)")
            checked += 1
        }
        try #require(checked > 40, "the sweep has to land on rows to prove anything")
    }

    @Test("A drop below every row lands last, not first")
    func dropBelowEverythingLandsLast() throws {
        let sidebar = laidOutSidebar(rows: 3)
        let midpoints = sidebar.rowMidpointsTopDown()
        let below = try #require(midpoints.last) + 200
        #expect(DropIndex.insertion(at: below, midpoints: midpoints) == 3)
    }

    @Test("Tab midpoints run left to right, in display order")
    func tabMidpointsAreLeftToRight() throws {
        let tabs = [TabSpec(name: "one", target: .local),
                    TabSpec(name: "two", target: .local),
                    TabSpec(name: "three", target: .local)]
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 60))
        bar.update(tabs: tabs, selected: tabs.first?.id, accent: .controlAccentColor) {
            _ in .init()
        }
        bar.layoutSubtreeIfNeeded()

        let midpoints = bar.buttonMidpoints()
        try #require(midpoints.count == 3)
        for (earlier, later) in zip(midpoints, midpoints.dropFirst()) {
            #expect(earlier < later, "\(midpoints)")
        }
        // Each tab's own midpoint must resolve back to its own slot.
        for (index, midpoint) in midpoints.enumerated() {
            let insertion = DropIndex.insertion(at: midpoint - 1, midpoints: midpoints)
            #expect(DropIndex.destination(movingFrom: index,
                                          toInsertionIndex: insertion) == index)
        }
    }

    @Test("A press only becomes a drag once it has travelled")
    func dragNeedsRealMovement() {
        let origin = NSPoint(x: 100, y: 100)
        #expect(!DragThreshold.exceeded(from: origin, to: origin))
        #expect(!DragThreshold.exceeded(from: origin, to: NSPoint(x: 101, y: 102)),
                "a tremor during a click is not a drag")
        #expect(DragThreshold.exceeded(from: origin, to: NSPoint(x: 100, y: 112)))
        #expect(DragThreshold.exceeded(from: origin, to: NSPoint(x: 80, y: 100)))
    }
}
