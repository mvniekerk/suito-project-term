import Foundation
import Testing
@testable import SuistoKit

/// Cmd-N selects the nth tab of the current project; Cmd-Shift-N selects the
/// nth project. Both count from 1 on the keyboard and from 0 in the tag.
@MainActor
@Suite("Index shortcuts")
struct ShortcutTests {

    private func makeController() -> (WorkspaceController, () -> Void) {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-sc-\(UUID().uuidString).json")
        let historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-sc-h-\(UUID().uuidString)", isDirectory: true)
        let controller = WorkspaceController(
            store: Store(url: store), history: HistoryStore(directory: historyDir))
        return (controller, {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: historyDir)
        })
    }

    @Test("Cmd-N picks the nth tab of the current project")
    func selectsNthTab() throws {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        let projectID = try #require(controller.workspace.selectedProjectID)
        controller.addTab(TabSpec(name: "penultimate"), to: projectID)
        controller.addTab(TabSpec(name: "last"), to: projectID)
        // The bootstrap project already has tabs, so index off the real list
        // rather than assuming how many.
        let names = try #require(controller.selectedProject?.tabs.map(\.name))
        try #require(names.count >= 3)

        for index in [names.count - 1, 0, 1] {
            #expect(controller.selectTab(atIndex: index))
            #expect(controller.selectedTab?.name == names[index],
                    "index \(index) should select \(names[index])")
        }
    }

    @Test("An index past the last tab does nothing at all")
    func tabIndexOutOfRangeIsNoOp() throws {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        let before = controller.selectedTab?.id
        // Not a clamp to the last tab, and not a wrap to the first.
        #expect(controller.selectTab(atIndex: 8) == false)
        #expect(controller.selectTab(atIndex: -1) == false)
        #expect(controller.selectedTab?.id == before)
    }

    @Test("Cmd-Shift-N picks the nth project")
    func selectsNthProject() throws {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        controller.addProject(name: "second", directory: "/tmp")
        controller.addProject(name: "third", directory: "/tmp")
        let names = controller.workspace.projects.map(\.name)
        try #require(names.count == 3)

        #expect(controller.selectProject(atIndex: 1))
        #expect(controller.selectedProject?.name == names[1])

        #expect(controller.selectProject(atIndex: 0))
        #expect(controller.selectedProject?.name == names[0])
    }

    @Test("An index past the last project does nothing")
    func projectIndexOutOfRangeIsNoOp() throws {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        let before = controller.workspace.selectedProjectID
        #expect(controller.selectProject(atIndex: 7) == false)
        #expect(controller.selectProject(atIndex: -1) == false)
        #expect(controller.workspace.selectedProjectID == before)
    }

    /// Tab selection is scoped to the current project, so the same Cmd-N means
    /// a different tab depending on where you are.
    @Test("Tab indices are per project, and each project remembers its own tab")
    func tabIndexIsScopedToProject() throws {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        let first = try #require(controller.workspace.selectedProjectID)
        controller.addTab(TabSpec(name: "first-two"), to: first)

        controller.addProject(name: "second", directory: "/tmp")
        let second = try #require(controller.workspace.selectedProjectID)
        #expect(second != first)
        controller.addTab(TabSpec(name: "second-two"), to: second)

        #expect(controller.selectTab(atIndex: 1))
        #expect(controller.selectedTab?.name == "second-two")

        // Back to the first project: its own remembered tab, not the other's.
        #expect(controller.selectProject(atIndex: 0))
        #expect(controller.selectedProject?.name != "second")
        #expect(controller.selectedTab?.name == "first-two",
                "each project should keep its own selection")
    }

    @Test("Selecting the nth tab survives a reload from disk")
    func selectionPersists() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-sc-\(UUID().uuidString).json")
        let historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-sc-h-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: historyDir)
        }

        let projectID: UUID
        let wantedTab: UUID
        do {
            let controller = WorkspaceController(
                store: Store(url: storeURL), history: HistoryStore(directory: historyDir))
            projectID = try #require(controller.workspace.selectedProjectID)
            controller.addTab(TabSpec(name: "two"), to: projectID)
            #expect(controller.selectTab(atIndex: 1))
            wantedTab = try #require(controller.selectedTab?.id)
            controller.flush()
        }

        let reloaded = WorkspaceController(
            store: Store(url: storeURL), history: HistoryStore(directory: historyDir))
        #expect(reloaded.workspace.selectedProjectID == projectID)
        #expect(reloaded.selectedTab?.id == wantedTab)
    }
}
