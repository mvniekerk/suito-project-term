import AppKit

/// The tab-of-tabs window: projects down the left, that project's tabs across
/// the top, and the live terminal filling the rest.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate,
                                  NSMenuItemValidation {
    private let workspace = WorkspaceController()
    private let sampler = ProcessSampler()

    private let sidebar = ProjectSidebarView()
    private let tabBar = TabBarView()
    private let terminalContainer = NSView()
    /// Frost behind the terminal, and a tint over it carrying the theme's
    /// background colour at the same strength the renderer uses. The tint is
    /// what keeps the padding around the grid matching the grid itself.
    private let terminalBackdrop = Glass.backdrop(.underWindowBackground,
                                                  blending: .behindWindow)
    private let terminalTint = NSView()
    /// One view and one renderer, re-attached on every switch. Sessions keep
    /// running regardless — the PTY is independent of whether we draw it — and
    /// this keeps memory flat instead of holding a bitmap per tab.
    private let terminalView = TerminalView()
    private let emptyLabel = NSTextField(labelWithString: "No tabs. Press + to add one.")

    private var lastGrid = (cols: UInt16(0), rows: UInt16(0))
    /// Snapshots scrollback periodically. `applicationWillTerminate` covers a
    /// normal quit or a restart, but not a crash or a force-quit.
    private var historyTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Suisto"
        window.titlebarAppearsTransparent = true
        // Required for the frosted chrome: a `.behindWindow` material samples
        // what is behind the window, which an opaque window does not let it
        // reach. The terminal keeps its own opaque backing, so only the chrome
        // becomes translucent.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 640, height: 400)
        AppSupport.migrateDefault(from: "NSWindow Frame ProjectsTermMain",
                                  to: "NSWindow Frame SuistoMain")
        window.setFrameAutosaveName("SuistoMain")
        super.init(window: window)
        window.delegate = self

        buildLayout()
        wireActions()

        workspace.onChange = { [weak self] in self?.refresh() }
        startSampling()
        startHistorySnapshots()
        applyAppearance()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        for view in [sidebar, tabBar, terminalContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        // Order matters: frost, then tint, then the grid on top of both.
        terminalTint.wantsLayer = true
        terminalTint.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminalBackdrop)
        terminalContainer.addSubview(terminalTint)
        Glass.pin(terminalBackdrop, to: terminalContainer)
        Glass.pin(terminalTint, to: terminalContainer)

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminalView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true
        terminalContainer.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),

            // Runs to the very top so the frost is one continuous sheet from
            // the titlebar down; the bar leaves its own 28pt of headroom for
            // the traffic lights, since the content runs under the titlebar.
            tabBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 60),

            terminalContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 6),
            terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 4),
            terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor),
        ])
    }

    private func wireActions() {
        sidebar.onSelect = { [weak self] id in
            self?.workspace.selectProject(id)
            self?.refresh()
        }
        sidebar.onAdd = { [weak self] in self?.addProject() }
        sidebar.onEdit = { [weak self] id in self?.editProject(id) }
        sidebar.onRemove = { [weak self] id in self?.removeProject(id) }
        sidebar.onReorder = { [weak self] from, to in
            self?.workspace.moveProject(from: from, to: to)
            self?.refresh()
        }

        tabBar.onSelect = { [weak self] id in
            self?.workspace.selectTab(id)
            self?.refresh()
        }
        tabBar.onAdd = { [weak self] in self?.addTab() }
        tabBar.onEdit = { [weak self] id in self?.editTab(id) }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        tabBar.onRestart = { [weak self] id in self?.restartTab(id) }
        tabBar.onReorder = { [weak self] from, to in
            guard let project = self?.workspace.selectedProject else { return }
            self?.workspace.moveTab(from: from, to: to, in: project.id)
            self?.refresh()
        }
    }

    // MARK: - Refresh

    /// Rebuilds the chrome from the model and makes sure the right session is
    /// on screen. Cheap enough to run on every badge tick.
    private func refresh() {
        let projects = workspace.workspace.projects
        sidebar.update(projects: projects,
                       selected: workspace.workspace.selectedProjectID) { [weak self] project in
            self?.workspace.badges(for: project) ?? .init()
        }

        guard let project = workspace.selectedProject else {
            tabBar.update(tabs: [], selected: nil, accent: .controlAccentColor) { _ in .init() }
            showEmpty(true, message: "No projects. Press + Project to add one.")
            return
        }

        let selectedTab = workspace.selectedTab
        tabBar.update(tabs: project.tabs, selected: selectedTab?.id, accent: project.color) {
            [weak self] tab in
            guard let self else { return .init() }
            let session = workspace.existingSession(for: tab.id)
            return .init(
                bells: session?.bellCount ?? 0,
                hasUnread: session?.hasUnread ?? false,
                isBusy: session?.isBusy ?? false,
                hasExited: workspace.exitedTabs.contains(tab.id),
                agent: session?.agentStatus,
                liveTitle: session?.title
            )
        }

        guard let tab = selectedTab else {
            showEmpty(true, message: "No tabs. Press + to add one.")
            return
        }
        showEmpty(false, message: "")
        attachSession(for: tab, in: project)
        updateWindowTitle(project: project, tab: tab)
    }

    private func showEmpty(_ empty: Bool, message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = !empty
        terminalView.isHidden = empty
        if empty { terminalView.detach() }
    }

    /// Spawns on first visit, then keeps the session attached to the one view.
    private func attachSession(for tab: TabSpec, in project: Project) {
        syncGrid()
        guard let session = workspace.session(for: tab, in: project) else {
            showEmpty(true, message: "Could not start “\(tab.name)”.")
            return
        }
        guard terminalView.session !== session else { return }

        // Only one session is visible at a time; the rest accrue unread marks.
        for other in RioEngine.shared.liveSessions where other !== session {
            other.isVisible = false
        }
        terminalView.attach(session)
        session.isVisible = true
        window?.makeFirstResponder(terminalView)
    }

    private func updateWindowTitle(project: Project, tab: TabSpec) {
        let detail = workspace.existingSession(for: tab.id)?.title ?? tab.name
        window?.title = "\(project.name) — \(detail)"
    }

    /// Keeps every session's PTY at the visible grid size, not just the one on
    /// screen, so a build running in a background tab sees the right COLUMNS.
    private func syncGrid() {
        let size = terminalView.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let grid = terminalView.gridFitting(size: size)
        guard grid.cols != lastGrid.cols || grid.rows != lastGrid.rows else { return }
        lastGrid = (grid.cols, grid.rows)
        workspace.resizeAllSessions(
            cols: grid.cols, rows: grid.rows,
            pixelWidth: UInt16(min(Int(size.width * scale), Int(UInt16.max))),
            pixelHeight: UInt16(min(Int(size.height * scale), Int(UInt16.max)))
        )
    }

    // MARK: - Sampling

    private func startSampling() {
        sampler.start { [weak self] in
            guard let self else { return [] }
            // Refresh the foreground process name here too: it is a librio
            // call and so has to happen on the main actor.
            var pids: [pid_t] = []
            for session in RioEngine.shared.liveSessions {
                session.foregroundProcess = session.readForegroundProcess()
                if !session.launch.isRemote, session.childPID > 0 {
                    pids.append(session.childPID)
                }
            }
            return pids
        } apply: { [weak self] reading in
            guard let self else { return }
            for session in RioEngine.shared.liveSessions {
                session.cpuPercent = reading[session.childPID]
            }
            self.refresh()
        }
    }

    // MARK: - Editing

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose the project's directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.addProject(name: url.lastPathComponent, directory: url.path)
        refresh()
    }

    private func editProject(_ id: UUID) {
        guard var project = workspace.workspace.project(id: id), let window else { return }
        ProjectEditor.present(in: window, project: project) { [weak self] edited in
            project = edited
            self?.workspace.update(project: project)
            self?.refresh()
        }
    }

    private func removeProject(_ id: UUID) {
        guard let project = workspace.workspace.project(id: id), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(project.name)”?"
        alert.informativeText = "Its \(project.tabs.count) tab(s) will be closed and any running programs stopped."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.workspace.removeProject(id)
                self?.refresh()
            }
        }
    }

    private func addTab() {
        guard let project = workspace.selectedProject, let window else { return }
        TabEditor.present(in: window, tab: TabSpec(name: "shell"), projectName: project.name) {
            [weak self] tab in
            self?.workspace.addTab(tab, to: project.id)
            self?.refresh()
        }
    }

    private func editTab(_ id: UUID) {
        guard let project = workspace.selectedProject,
              let tab = project.tabs.first(where: { $0.id == id }),
              let window else { return }
        TabEditor.present(in: window, tab: tab, projectName: project.name) { [weak self] edited in
            self?.workspace.update(tab: edited, in: project.id)
            self?.refresh()
        }
    }

    private func closeTab(_ id: UUID) {
        guard let project = workspace.selectedProject else { return }
        if terminalView.session === workspace.existingSession(for: id) {
            terminalView.detach()
        }
        workspace.removeTab(id, from: project.id)
        refresh()
    }

    private func restartTab(_ id: UUID) {
        guard let project = workspace.selectedProject,
              let tab = project.tabs.first(where: { $0.id == id }) else { return }
        terminalView.detach()
        workspace.restart(tab: tab, in: project)
        refresh()
    }

    @objc func showAppearance(_ sender: Any?) {
        guard let window else { return }
        let original = workspace.appearance.terminalOpacity
        AppearanceEditor.present(
            in: window,
            appearance: workspace.appearance,
            onPreview: { [weak self] opacity in
                self?.previewTranslucency(opacity)
            },
            onCancel: { [weak self] in
                // Put back what the live preview changed under them.
                self?.previewTranslucency(original)
            },
            onSave: { [weak self] edited in
                guard let self else { return }
                workspace.update(appearance: edited)   // writes workspace.json
                applyAppearance()
            })
    }

    /// Re-applies font and colours, then re-measures: a font change moves the
    /// cell size, so every session needs the new grid.
    private func applyAppearance() {
        terminalView.apply(workspace.appearance)
        applyTint(opacity: workspace.appearance.terminalOpacity)
        lastGrid = (0, 0)   // force syncGrid to push the new size through
        syncGrid()
        refresh()
    }

    private func applyTint(opacity: Double) {
        terminalTint.layer?.backgroundColor = workspace.appearance.theme
            .background.cgColor(alpha: CGFloat(opacity))
    }

    /// Live preview while the Settings slider moves. Deliberately narrower
    /// than `applyAppearance()`: it repaints at the new translucency and
    /// leaves the grid alone, so dragging the slider cannot shower every
    /// running program with resize signals.
    private func previewTranslucency(_ opacity: Double) {
        terminalView.applyTranslucency(opacity)
        applyTint(opacity: opacity)
    }

    // MARK: - Menu actions

    @objc func selectNextTab(_ sender: Any?) {
        workspace.selectTab(offset: 1)
        refresh()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        workspace.selectTab(offset: -1)
        refresh()
    }

    /// Cmd-1 ... Cmd-9: the item's tag is the tab index within the current
    /// project. Out of range is a no-op, not a wrap: pressing Cmd-5 with four
    /// tabs open should do nothing rather than land somewhere surprising.
    @objc func selectTabByIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              workspace.selectTab(atIndex: item.tag) else { return }
        refresh()
    }

    /// Cmd-Shift-1 ... Cmd-Shift-9: the item's tag is the project index.
    @objc func selectProjectByIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              workspace.selectProject(atIndex: item.tag) else { return }
        refresh()
    }

    @objc func selectNextProject(_ sender: Any?) {
        workspace.selectProject(offset: 1)
        refresh()
    }

    @objc func selectPreviousProject(_ sender: Any?) {
        workspace.selectProject(offset: -1)
        refresh()
    }

    /// Greys out the index shortcuts that have nothing to select, so the menu
    /// shows how many projects and tabs there actually are.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectTabByIndex(_:)):
            return workspace.selectedProject?.tabs.indices.contains(menuItem.tag) ?? false
        case #selector(selectProjectByIndex(_:)):
            return workspace.workspace.projects.indices.contains(menuItem.tag)
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return (workspace.selectedProject?.tabs.count ?? 0) > 1
        case #selector(selectNextProject(_:)), #selector(selectPreviousProject(_:)):
            return workspace.workspace.projects.count > 1
        default:
            return true
        }
    }

    // MARK: - Window

    func windowDidResize(_ notification: Notification) {
        syncGrid()
    }

    private func startHistorySnapshots() {
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.workspace.captureHistory() }
        }
        RunLoop.main.add(timer, forMode: .common)
        historyTimer = timer
    }

    func prepareForTermination() {
        sampler.stop()
        historyTimer?.invalidate()
        historyTimer = nil
        // Saves the layout and every live session's scrollback.
        workspace.flush()
    }
}
