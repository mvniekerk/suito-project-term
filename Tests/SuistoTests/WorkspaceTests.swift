import Foundation
import Testing
@testable import SuistoKit

@Suite("Workspace persistence")
struct WorkspaceTests {

    @Test("A workspace survives a JSON round trip, remote targets included")
    func roundTrip() throws {
        var workspace = Workspace.bootstrap(directory: "/tmp/work")
        workspace.projects[0].colorIndex = 4
        workspace.projects[0].tabs.append(
            TabSpec(name: "deploy",
                    target: .ssh(host: "mike@example.test", directory: "/srv/app"),
                    command: "make deploy",
                    keepOpenAfterExit: true,
                    term: "xterm-256color"))

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        #expect(decoded.projects.count == workspace.projects.count)
        #expect(decoded.selectedProjectID == workspace.selectedProjectID)

        let original = workspace.projects[0]
        let restored = decoded.projects[0]
        #expect(restored.id == original.id)
        #expect(restored.colorIndex == 4)
        #expect(restored.tabs.map(\.id) == original.tabs.map(\.id))

        let deploy = try #require(restored.tabs.last)
        #expect(deploy.keepOpenAfterExit)
        #expect(deploy.command == "make deploy")
        guard case .ssh(let host, let directory) = deploy.target else {
            Issue.record("expected the ssh target to survive decoding")
            return
        }
        #expect(host == "mike@example.test")
        #expect(directory == "/srv/app")
    }

    @Test("Saving and loading through the store preserves the workspace")
    @MainActor
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = Store(url: url)
        let workspace = Workspace.bootstrap(directory: "/tmp/work")
        store.flush(workspace)

        let loaded = try #require(store.load())
        #expect(loaded.projects.map(\.id) == workspace.projects.map(\.id))
    }

    @Test("An unreadable workspace is moved aside rather than silently replaced")
    @MainActor
    func corruptFileIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-test-\(UUID().uuidString).json")
        let backup = url.appendingPathExtension("corrupt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backup)
        }

        try Data("{ not json".utf8).write(to: url)
        let store = Store(url: url)

        #expect(store.load() == nil)
        // The user's layout may be recoverable by hand, so it must not vanish.
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("New projects take an unused colour so they stay distinguishable")
    func colorsStayDistinct() {
        var workspace = Workspace(projects: [])
        var used: Set<Int> = []
        for index in 0..<ProjectPalette.colors.count {
            let next = workspace.nextColorIndex
            #expect(!used.contains(next), "colour \(next) reused at project \(index)")
            used.insert(next)
            workspace.projects.append(
                Project(name: "p\(index)", directory: "/tmp", colorIndex: next))
        }
    }

    /// Upgrade safety. Swift's synthesised `Decodable` ignores property
    /// defaults: a key that is simply absent is a hard error. A workspace
    /// written before `persistence` existed therefore failed to decode, and
    /// the app started the user over with an empty layout.
    ///
    /// This is the real file that broke, minus the key added later.
    @Test("A workspace from an older build still loads, with defaults filled in")
    func decodesWorkspaceMissingNewerKeys() throws {
        let json = """
        {
          "projects": [
            {
              "colorIndex": 0,
              "directory": "/Users/someone",
              "id": "F375A32D-4471-4A3B-AB88-B9F64EA90340",
              "name": "mike",
              "tabs": [
                {
                  "id": "ABD72FE1-AA0A-4A87-A01E-26594E71307E",
                  "keepOpenAfterExit": false,
                  "name": "shell",
                  "target": { "local": {} },
                  "term": "xterm-256color"
                }
              ]
            }
          ],
          "selectedProjectID": "F375A32D-4471-4A3B-AB88-B9F64EA90340"
        }
        """

        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        let project = try #require(workspace.projects.first)
        let tab = try #require(project.tabs.first)

        #expect(project.name == "mike")
        #expect(tab.name == "shell")
        // Keys that did not exist yet fall back rather than failing the decode.
        #expect(tab.persistence == .none)
        #expect(project.selectedTabID == nil)
    }

    @Test("A tab object with only the keys that have ever been required decodes")
    func decodesMinimalTab() throws {
        let json = #"{"id":"ABD72FE1-AA0A-4A87-A01E-26594E71307E","name":"bare"}"#
        let tab = try JSONDecoder().decode(TabSpec.self, from: Data(json.utf8))

        #expect(tab.name == "bare")
        #expect(tab.target == .local)
        #expect(tab.term == "xterm-256color")
        #expect(tab.persistence == .none)
        #expect(tab.keepOpenAfterExit == false)
        #expect(tab.command == nil)
    }

    @Test("Persistence survives the round trip once it is set")
    func persistenceRoundTrips() throws {
        var tab = TabSpec(name: "agent", target: .ssh(host: "h", directory: nil))
        tab.persistence = .screen

        let decoded = try JSONDecoder().decode(
            TabSpec.self, from: JSONEncoder().encode(tab))
        #expect(decoded.persistence == .screen)
        #expect(decoded.sessionName == tab.sessionName)
    }
}
