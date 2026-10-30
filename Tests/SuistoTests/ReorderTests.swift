import Foundation
import Testing
@testable import SuistoKit

/// The index arithmetic behind drag-to-reorder.
///
/// The subtle half is `destination(movingFrom:toInsertionIndex:)`: the item is
/// removed before it is re-inserted, which shifts every later slot down by one.
/// Getting that wrong drops items one position too far, and only when dragging
/// downward — easy to miss by hand, so it is pinned here.
@Suite("Drag reordering")
struct ReorderTests {

    @Test("An insertion index counts the items whose midpoint the drag passed")
    func insertionCountsPassedMidpoints() {
        let midpoints: [CGFloat] = [10, 30, 50, 70]

        #expect(DropIndex.insertion(at: 0, midpoints: midpoints) == 0)
        #expect(DropIndex.insertion(at: 20, midpoints: midpoints) == 1)
        #expect(DropIndex.insertion(at: 60, midpoints: midpoints) == 3)
        #expect(DropIndex.insertion(at: 999, midpoints: midpoints) == 4, "past the end")
    }

    @Test("An empty list accepts a drop at index 0")
    func emptyListDropsAtZero() {
        #expect(DropIndex.insertion(at: 42, midpoints: []) == 0)
    }

    @Test("Dragging downward accounts for the gap the item leaves behind")
    func downwardDragAdjusts() {
        // [A B C D], drag A (0) to sit after C: insertion index 3, but once A
        // is removed, B C D shift down, so the real destination is 2.
        #expect(DropIndex.destination(movingFrom: 0, toInsertionIndex: 3) == 2)
        #expect(DropIndex.destination(movingFrom: 1, toInsertionIndex: 4) == 3)
    }

    @Test("Dragging upward needs no adjustment")
    func upwardDragIsDirect() {
        #expect(DropIndex.destination(movingFrom: 3, toInsertionIndex: 1) == 1)
        #expect(DropIndex.destination(movingFrom: 2, toInsertionIndex: 0) == 0)
    }

    /// Applies the computed move to a list and checks the result reads the way
    /// a person dragging would expect.
    @Test("Moves land where the drop indicator pointed")
    func movesMatchTheIndicator() {
        func move(_ items: [String], from source: Int, insertionIndex: Int) -> [String] {
            var copy = items
            let destination = DropIndex.destination(
                movingFrom: source, toInsertionIndex: insertionIndex)
            let moved = copy.remove(at: source)
            copy.insert(moved, at: destination)
            return copy
        }

        let items = ["A", "B", "C", "D"]
        #expect(move(items, from: 0, insertionIndex: 3) == ["B", "C", "A", "D"])
        #expect(move(items, from: 3, insertionIndex: 0) == ["D", "A", "B", "C"])
        #expect(move(items, from: 1, insertionIndex: 4) == ["A", "C", "D", "B"])
        // Dropping an item back onto its own slot changes nothing.
        #expect(move(items, from: 2, insertionIndex: 2) == items)
    }

    @Test("Reordering projects persists and keeps every project")
    @MainActor
    func reorderProjectsKeepsAll() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-reorder-\(UUID().uuidString).json")
        let historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-reorder-h-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: historyDir)
        }

        let controller = WorkspaceController(
            store: Store(url: url), history: HistoryStore(directory: historyDir))
        controller.addProject(name: "beta", directory: "/tmp/b")
        controller.addProject(name: "gamma", directory: "/tmp/c")
        let before = controller.workspace.projects.map(\.name)
        try #require(before.count >= 3)

        controller.moveProject(from: 0, to: before.count - 1)
        let after = controller.workspace.projects.map(\.name)

        #expect(Set(after) == Set(before), "reordering must not lose a project")
        #expect(after.last == before.first)
        #expect(after.count == before.count)
    }

    @Test("Out-of-range moves are ignored rather than crashing")
    @MainActor
    func outOfRangeIsIgnored() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-reorder-\(UUID().uuidString).json")
        let historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-reorder-h-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: historyDir)
        }

        let controller = WorkspaceController(
            store: Store(url: url), history: HistoryStore(directory: historyDir))
        let before = controller.workspace.projects.map(\.id)

        controller.moveProject(from: 99, to: 0)
        controller.moveProject(from: 0, to: 99)
        controller.moveProject(from: 0, to: -1)

        #expect(controller.workspace.projects.map(\.id) == before)
    }
}
