import AppKit

/// Shared scaffolding for the small edit sheets.
@MainActor
private enum Form {
    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }

    static func field(_ value: String, placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        return field
    }

    /// Builds a two-column grid and wraps it in a sheet with Cancel/Save.
    static func sheet(
        title: String,
        rows: [(String, NSView)],
        in parent: NSWindow,
        onCancel: (() -> Void)? = nil,
        onSave: @escaping () -> Void
    ) {
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).width = 110
        grid.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).height = 24
        }

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 0),
            styleMask: [.titled], backing: .buffered, defer: false)

        let save = NSButton(title: "Save", target: nil, action: nil)
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"

        let actions = NSStackView(views: [cancel, save])
        actions.orientation = .horizontal
        actions.spacing = 10

        let root = NSStackView(views: [heading, grid, actions])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView = root
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalToConstant: 420),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        ])

        let handler = SheetHandler(sheet: sheet, parent: parent,
                                   onCancel: onCancel, onSave: onSave)
        save.target = handler
        save.action = #selector(SheetHandler.save)
        cancel.target = handler
        cancel.action = #selector(SheetHandler.cancel)
        // The buttons' targets are unowned, so the handler has to outlive the
        // call; the sheet keeps it alive until it is dismissed.
        objc_setAssociatedObject(sheet, Unmanaged.passUnretained(handler).toOpaque(),
                                 handler, .OBJC_ASSOCIATION_RETAIN)

        parent.beginSheet(sheet)
    }

    @MainActor
    final class SheetHandler: NSObject {
        private let sheet: NSWindow
        private let parent: NSWindow
        private let onSave: () -> Void
        private let onCancel: (() -> Void)?

        init(sheet: NSWindow, parent: NSWindow,
             onCancel: (() -> Void)? = nil, onSave: @escaping () -> Void) {
            self.sheet = sheet
            self.parent = parent
            self.onCancel = onCancel
            self.onSave = onSave
        }

        @objc func save() {
            onSave()
            parent.endSheet(sheet)
        }

        @objc func cancel() {
            onCancel?()
            parent.endSheet(sheet)
        }
    }
}

/// Add or edit one minor tab.
@MainActor
enum TabEditor {
    static func present(
        in parent: NSWindow,
        tab: TabSpec,
        projectName: String,
        onSave: @escaping (TabSpec) -> Void
    ) {
        let name = Form.field(tab.name, placeholder: "claude")
        let command = Form.field(tab.command ?? "", placeholder: "login shell")
        let term = Form.field(tab.term)

        let target = NSPopUpButton()
        target.addItems(withTitles: ["Local", "SSH"])
        target.selectItem(at: tab.target.isRemote ? 1 : 0)

        let host: NSTextField
        let directory: NSTextField
        if case .ssh(let existingHost, let existingDirectory) = tab.target {
            host = Form.field(existingHost)
            directory = Form.field(existingDirectory ?? "", placeholder: "remote directory")
        } else {
            host = Form.field(Workspace.defaultSSHHost)
            directory = Form.field("", placeholder: "remote directory")
        }

        let keepOpen = NSButton(checkboxWithTitle: "Keep a shell open after the command exits",
                                target: nil, action: nil)
        keepOpen.state = tab.keepOpenAfterExit ? .on : .off

        let persistence = NSPopUpButton()
        for mode in TabSpec.SessionPersistence.allCases {
            persistence.addItem(withTitle: mode.label)
        }
        persistence.selectItem(at: TabSpec.SessionPersistence.allCases
            .firstIndex(of: tab.persistence) ?? 0)

        Form.sheet(
            title: "Tab in “\(projectName)”",
            rows: [
                ("Name", name),
                ("Runs on", target),
                ("SSH host", host),
                ("Remote dir", directory),
                ("Command", command),
                ("TERM", term),
                ("Persistence", persistence),
                ("", keepOpen),
            ],
            in: parent
        ) {
            var edited = tab
            edited.name = name.stringValue.isEmpty ? "tab" : name.stringValue
            edited.command = command.stringValue.isEmpty ? nil : command.stringValue
            edited.term = term.stringValue.isEmpty ? "xterm-256color" : term.stringValue
            edited.keepOpenAfterExit = keepOpen.state == .on
            edited.persistence = TabSpec.SessionPersistence
                .allCases[persistence.indexOfSelectedItem]
            edited.target = target.indexOfSelectedItem == 1
                ? .ssh(host: host.stringValue,
                       directory: directory.stringValue.isEmpty ? nil : directory.stringValue)
                : .local
            onSave(edited)
        }
    }
}

/// Edit a project's name, directory and colour.
@MainActor
enum ProjectEditor {
    static func present(
        in parent: NSWindow,
        project: Project,
        onSave: @escaping (Project) -> Void
    ) {
        let name = Form.field(project.name)
        let directory = Form.field(project.directory)

        let color = NSPopUpButton()
        for (index, _) in ProjectPalette.colors.enumerated() {
            let item = NSMenuItem()
            item.title = "   Colour \(index + 1)"
            item.image = swatch(ProjectPalette.color(at: index))
            color.menu?.addItem(item)
        }
        color.selectItem(at: project.colorIndex % ProjectPalette.colors.count)

        Form.sheet(
            title: "Project",
            rows: [("Name", name), ("Directory", directory), ("Colour", color)],
            in: parent
        ) {
            var edited = project
            edited.name = name.stringValue.isEmpty ? project.name : name.stringValue
            edited.directory = directory.stringValue
            edited.colorIndex = color.indexOfSelectedItem
            onSave(edited)
        }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()
        return image
    }
}

/// Font and colour scheme, applied to every terminal at once.
@MainActor
enum AppearanceEditor {
    static func present(
        in parent: NSWindow,
        appearance: Workspace.Appearance,
        onPreview: @escaping (Double) -> Void,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Workspace.Appearance) -> Void
    ) {
        let fonts = NSPopUpButton()
        fonts.addItem(withTitle: "System Monospace")
        // Only fixed-pitch faces: a proportional font would break the grid.
        let monospaced = NSFontManager.shared
            .availableFontNames(with: .fixedPitchFontMask)?
            .filter { !$0.hasPrefix(".") }
            .sorted() ?? []
        for name in monospaced { fonts.addItem(withTitle: name) }
        if let current = appearance.fontName, monospaced.contains(current) {
            fonts.selectItem(withTitle: current)
        } else {
            fonts.selectItem(at: 0)
        }

        let size = NSTextField(string: String(format: "%g", appearance.fontSize))
        let stepper = NSStepper()
        stepper.minValue = 8
        stepper.maxValue = 32
        stepper.increment = 1
        stepper.doubleValue = appearance.fontSize
        let sizeRow = NSStackView(views: [size, stepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 6
        size.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let linker = StepperLink(field: size, stepper: stepper)
        stepper.target = linker
        stepper.action = #selector(StepperLink.stepped)
        objc_setAssociatedObject(stepper, Unmanaged.passUnretained(linker).toOpaque(),
                                 linker, .OBJC_ASSOCIATION_RETAIN)

        let themes = NSPopUpButton()
        for theme in TerminalTheme.all { themes.addItem(withTitle: theme.name) }
        themes.selectItem(withTitle: appearance.themeName)

        // The slider reads as translucency to match its label, while the
        // model stores opacity, so the two are mirror images of each other.
        let range = Workspace.Appearance.opacityRange
        let readout = NSTextField(labelWithString: "")
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let slider = NSSlider()
        slider.minValue = 1 - range.upperBound
        slider.maxValue = 1 - range.lowerBound
        slider.doubleValue = 1 - appearance.terminalOpacity
        // Live: the terminal has to follow the thumb, not the mouse-up.
        slider.isContinuous = true

        let translucencyRow = NSStackView(views: [slider, readout])
        translucencyRow.orientation = .horizontal
        translucencyRow.spacing = 8

        let link = TranslucencyLink(slider: slider, readout: readout, onPreview: onPreview)
        slider.target = link
        slider.action = #selector(TranslucencyLink.moved)
        link.refresh()
        objc_setAssociatedObject(slider, Unmanaged.passUnretained(link).toOpaque(),
                                 link, .OBJC_ASSOCIATION_RETAIN)

        Form.sheet(
            title: "Appearance",
            rows: [("Font", fonts), ("Size", sizeRow), ("Theme", themes),
                   ("Translucency", translucencyRow)],
            in: parent,
            onCancel: onCancel
        ) {
            var edited = appearance
            edited.fontName = fonts.indexOfSelectedItem == 0 ? nil : fonts.titleOfSelectedItem
            // Ignore nonsense rather than shrinking the terminal to nothing.
            if let parsed = Double(size.stringValue), (8...32).contains(parsed) {
                edited.fontSize = parsed
            }
            edited.themeName = themes.titleOfSelectedItem ?? appearance.themeName
            edited.terminalOpacity = link.opacity
            onSave(edited)
        }
    }

    /// Keeps the readout in step with the slider and previews each move.
    @MainActor
    private final class TranslucencyLink: NSObject {
        private let slider: NSSlider
        private let readout: NSTextField
        private let onPreview: (Double) -> Void

        /// What the model stores: the slider shows the complement.
        var opacity: Double { Workspace.Appearance.clampOpacity(1 - slider.doubleValue) }

        init(slider: NSSlider, readout: NSTextField,
             onPreview: @escaping (Double) -> Void) {
            self.slider = slider
            self.readout = readout
            self.onPreview = onPreview
        }

        func refresh() {
            readout.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
        }

        @objc func moved() {
            refresh()
            onPreview(opacity)
        }
    }

    /// Keeps the stepper and the text field showing the same number.
    @MainActor
    private final class StepperLink: NSObject {
        private let field: NSTextField
        private let stepper: NSStepper

        init(field: NSTextField, stepper: NSStepper) {
            self.field = field
            self.stepper = stepper
        }

        @objc func stepped() {
            field.stringValue = String(format: "%g", stepper.doubleValue)
        }
    }
}
