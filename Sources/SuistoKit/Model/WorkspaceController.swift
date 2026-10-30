import AppKit

/// The app's single source of truth: the persisted workspace, which tab is
/// selected in each project, and the live sessions.
///
/// Sessions are spawned lazily — the first time a tab is actually looked at —
/// and then kept running when the user switches away, which is the entire
/// point of the app.
@MainActor
final class WorkspaceController {
    private(set) var workspace: Workspace
    private let store: Store
    private let history: HistoryStore
    private let engine = RioEngine.shared

    /// Keyed by `TabSpec.id`.
    private var sessions: [UUID: TerminalSession] = [:]
    /// Tabs whose program exited; kept so the UI can offer a restart.
    private(set) var exitedTabs: Set<UUID> = []
    /// The grid the terminal area can currently show, used when spawning so a
/// program never starts at a wrong size.
    var currentGrid = (cols: UInt16(80), rows: UInt16(24),
                       pixelWidth: UInt16(720), pixelHeight: UInt16(432))

    /// Model or badge state changed and the chrome should redraw.
    var onChange: (() -> Void)?

    init(store: Store = Store(), history: HistoryStore = HistoryStore()) {
        self.store = store
        self.history = history
        if let loaded = store.load() {
            self.workspace = loaded
        } else {
            // A bundled app launches with cwd "/", which would make a
            // meaningless first project; fall back to the home directory.
            let cwd = FileManager.default.currentDirectoryPath
            self.workspace = .bootstrap(directory: cwd == "/" ? NSHomeDirectory() : cwd)
        }
        if workspace.selectedProjectID == nil {
            workspace.selectedProjectID = workspace.projects.first?.id
        }
        engine.onSessionClosed = { [weak self] session in
            self?.handleClosed(session)
        }
    }

    // MARK: - Selection

    var selectedProject: Project? { workspace.project(id: workspace.selectedProjectID) }

    var selectedTab: TabSpec? {
        guard let project = selectedProject else { return nil }
        if let id = project.selectedTabID,
           let tab = project.tabs.first(where: { $0.id == id }) {
            return tab
        }
        return project.tabs.first
    }

    func selectProject(_ id: UUID) {
        guard workspace.selectedProjectID != id else { return }
        workspace.selectedProjectID = id
        persist()
        onChange?()
    }

    func selectTab(_ id: UUID) {
        guard let index = workspace.selectedProjectID.flatMap({ workspace.index(of: $0) }),
              workspace.projects[index].selectedTabID != id else { return }
        workspace.projects[index].selectedTabID = id
        persist()
        onChange?()
    }

    /// Selects the nth tab of the current project, counting from zero.
    ///
    /// Out of range is a deliberate no-op rather than a clamp or a wrap:
    /// pressing Cmd-5 with four tabs open should do nothing, not jump to the
    /// last tab or the first.
    @discardableResult
    func selectTab(atIndex index: Int) -> Bool {
        guard let project = selectedProject,
              project.tabs.indices.contains(index) else { return false }
        selectTab(project.tabs[index].id)
        return true
    }

    /// Selects the nth project, counting from zero. Out of range is a no-op.
    @discardableResult
    func selectProject(atIndex index: Int) -> Bool {
        guard workspace.projects.indices.contains(index) else { return false }
        selectProject(workspace.projects[index].id)
        return true
    }

    func selectProject(offset: Int) {
        guard !workspace.projects.isEmpty,
              let current = workspace.selectedProjectID,
              let index = workspace.index(of: current) else { return }
        let next = (index + offset + workspace.projects.count) % workspace.projects.count
        selectProject(workspace.projects[next].id)
    }

    func selectTab(offset: Int) {
        guard let project = selectedProject, !project.tabs.isEmpty,
              let current = selectedTab,
              let index = project.tabs.firstIndex(of: current) else { return }
        let next = (index + offset + project.tabs.count) % project.tabs.count
        selectTab(project.tabs[next].id)
    }

    // MARK: - Sessions

    func existingSession(for tabID: UUID) -> TerminalSession? { sessions[tabID] }

    /// The session for a tab, spawning it if this is the first visit.
    @discardableResult
    func session(for tab: TabSpec, in project: Project) -> TerminalSession? {
        if let existing = sessions[tab.id] { return existing }

        let launch = tab.launch(
            projectDirectory: project.directory,
            cols: currentGrid.cols,
            rows: currentGrid.rows,
            pixelWidth: currentGrid.pixelWidth,
            pixelHeight: currentGrid.pixelHeight
        )
        guard let session = engine.makeSession(launch) else {
            NSLog("Suisto: could not spawn a terminal for tab '\(tab.name)'")
            return nil
        }
        session.onBadgeChange = { [weak self] in self?.onChange?() }
        sessions[tab.id] = session
        exitedTabs.remove(tab.id)

        // Replay what this tab said before the app was last quit. The program
        // itself is gone — only its output can come back — so this goes to the
        // display, never to the PTY.
        //
        // A multiplexed tab is skipped: its real session is still alive on the
        // other side and repaints itself on reattach, so a transcript on top
        // would just duplicate it.
        if tab.persistence == .none, let saved = history.load(for: tab.id) {
            session.injectOutput(HistoryStore.replayBytes(saved))
        }
        return session
    }

    /// Kills a tab's program but keeps the tab, so it can be started again.
    func restart(tab: TabSpec, in project: Project) {
        if let session = sessions.removeValue(forKey: tab.id) {
            engine.closeSession(session.id)
        }
        exitedTabs.remove(tab.id)
        session(for: tab, in: project)
        onChange?()
    }

    /// Applies the terminal area's size to every live session, not just the
    /// visible one: a build running in a background tab should still see the
    /// right COLUMNS.
    func resizeAllSessions(cols: UInt16, rows: UInt16, pixelWidth: UInt16, pixelHeight: UInt16) {
        currentGrid = (cols, rows, pixelWidth, pixelHeight)
        for session in sessions.values {
            session.resize(cols: cols, rows: rows,
                           pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
    }

    private func handleClosed(_ session: TerminalSession) {
        guard let (tabID, _) = sessions.first(where: { $0.value === session }) else { return }
        exitedTabs.insert(tabID)
        onChange?()
    }

    // MARK: - Badge aggregation

    /// What a project's row in the sidebar shows.
    struct ProjectBadges {
        var busy = 0
        var total = 0
        var bells = 0
        var unread = 0
        /// Tabs running an agent that is thinking.
        var agentsWorking = 0
        /// Tabs running an agent that has stopped and is waiting on you.
        var agentsWaiting = 0
        /// nil when nothing local can be measured — every tab is remote.
        var cpuPercent: Double?
    }

    func badges(for project: Project) -> ProjectBadges {
        var badges = ProjectBadges()
        var cpuTotal = 0.0
        var sawLocal = false

        for tab in project.tabs {
            guard let session = sessions[tab.id] else { continue }
            badges.total += 1
            if session.isBusy { badges.busy += 1 }
            badges.bells += session.bellCount
            if session.hasUnread { badges.unread += 1 }
            // Unlike busy and CPU, this one holds over SSH: the title is
            // set by the program itself and arrives down the same connection
            // as its output, so a remote agent is counted like a local one.
            switch session.agentStatus {
            case .working: badges.agentsWorking += 1
            case .waiting: badges.agentsWaiting += 1
            case nil: break
            }

            // A remote session's local process tree is just the ssh client, so
            // its CPU says nothing about the work happening on the far side.
            if !tab.target.isRemote {
                sawLocal = true
                cpuTotal += session.cpuPercent ?? 0
            }
        }
        badges.cpuPercent = sawLocal ? cpuTotal : nil
        return badges
    }

    // MARK: - Editing

    func addProject(name: String, directory: String) {
        let project = Project(name: name, directory: directory,
                              colorIndex: workspace.nextColorIndex,
                              tabs: [TabSpec(name: "shell", target: .local)])
        workspace.projects.append(project)
        workspace.selectedProjectID = project.id
        persist()
        onChange?()
    }

    func removeProject(_ id: UUID) {
        guard let index = workspace.index(of: id) else { return }
        for tab in workspace.projects[index].tabs { closeTabSession(tab.id) }
        workspace.projects.remove(at: index)
        if workspace.selectedProjectID == id {
            workspace.selectedProjectID = workspace.projects.first?.id
        }
        persist()
        onChange?()
    }

    func addTab(_ tab: TabSpec, to projectID: UUID) {
        guard let index = workspace.index(of: projectID) else { return }
        workspace.projects[index].tabs.append(tab)
        workspace.projects[index].selectedTabID = tab.id
        persist()
        onChange?()
    }

    func update(tab: TabSpec, in projectID: UUID) {
        guard let projectIndex = workspace.index(of: projectID),
              let tabIndex = workspace.projects[projectIndex].tabs
                .firstIndex(where: { $0.id == tab.id }) else { return }
        workspace.projects[projectIndex].tabs[tabIndex] = tab
        persist()
        onChange?()
    }

    func removeTab(_ tabID: UUID, from projectID: UUID) {
        guard let index = workspace.index(of: projectID) else { return }
        closeTabSession(tabID)
        workspace.projects[index].tabs.removeAll { $0.id == tabID }
        if workspace.projects[index].selectedTabID == tabID {
            workspace.projects[index].selectedTabID = workspace.projects[index].tabs.first?.id
        }
        persist()
        onChange?()
    }

    var appearance: Workspace.Appearance { workspace.appearance }

    func update(appearance: Workspace.Appearance) {
        guard workspace.appearance != appearance else { return }
        workspace.appearance = appearance
        persist()
        onChange?()
    }

    func moveProject(from source: Int, to destination: Int) {
        guard workspace.projects.indices.contains(source),
              destination >= 0, destination < workspace.projects.count,
              source != destination else { return }
        let moved = workspace.projects.remove(at: source)
        workspace.projects.insert(moved, at: destination)
        persist()
        onChange?()
    }

    func moveTab(from source: Int, to destination: Int, in projectID: UUID) {
        guard let index = workspace.index(of: projectID),
              workspace.projects[index].tabs.indices.contains(source),
              destination >= 0, destination < workspace.projects[index].tabs.count,
              source != destination else { return }
        let moved = workspace.projects[index].tabs.remove(at: source)
        workspace.projects[index].tabs.insert(moved, at: destination)
        persist()
        onChange?()
    }

    func update(project: Project) {
        guard let index = workspace.index(of: project.id) else { return }
        workspace.projects[index] = project
        persist()
        onChange?()
    }

    private func closeTabSession(_ tabID: UUID) {
        if let session = sessions.removeValue(forKey: tabID) {
            engine.closeSession(session.id)
        }
        exitedTabs.remove(tabID)
        // The tab is gone, so keeping its output on disk would be a leak.
        history.remove(tabID)
    }

    /// Captures every live session's scrollback. Called on the way out, and
    /// periodically so a crash or a force-quit does not lose everything.
    func captureHistory() {
        let multiplexed = Set(
            workspace.projects.flatMap { $0.tabs }
                .filter { $0.persistence != .none }.map(\.id))

        for (tabID, session) in sessions {
            // A multiplexer keeps the real session; a stale transcript would
            // only get in the way if persistence is later turned off.
            if multiplexed.contains(tabID) {
                history.remove(tabID)
                continue
            }
            guard let dump = session.dumpBuffer() else { continue }
            history.save(dump, for: tabID)
        }
        // Tabs that still exist but were never opened keep whatever they had.
        let known = Set(workspace.projects.flatMap { $0.tabs.map(\.id) })
        history.prune(keeping: known)
    }

    // MARK: - Persistence

    private func persist() { store.save(workspace) }

    /// Saves everything that must survive a quit: the layout, and each live
    /// session's scrollback.
    func flush() {
        captureHistory()
        store.flush(workspace)
    }
}
