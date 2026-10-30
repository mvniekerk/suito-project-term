import AppKit

/// The app menu.
///
/// Without one, an app built this way has no Edit menu at all, so Cmd-C/V
/// never reach the terminal view.
///
/// The View items carry an explicit target rather than relying on the
/// responder chain: an `NSWindowController` created with `init(window:)` is
/// not reliably inserted into it, and a menu item whose action no responder
/// implements is silently disabled.
@MainActor
enum MenuBuilder {
    static func install(target: MainWindowController) {
        let main = NSMenu()

        for submenu in [appMenu(target: target), editMenu(), viewMenu(target: target)] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private static func appMenu(target: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: "Suisto")
        menu.addItem(withTitle: "About Suisto",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…",
                                    action: #selector(MainWindowController.showAppearance(_:)),
                                    keyEquivalent: ",")
        settings.target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Suisto",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit Suisto",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Left on the responder chain on purpose: these belong to whatever view
    /// has focus, which is the terminal.
    static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        // Cmd-K, and the same name Terminal.app gives it.
        menu.addItem(withTitle: "Clear Scrollback",
                     action: #selector(TerminalView.clearScrollback(_:)), keyEquivalent: "k")
        return menu
    }

    private static func viewMenu(target: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: "View")

        func add(to menu: NSMenu, _ title: String, _ action: Selector,
                 _ key: String, _ mods: NSEvent.ModifierFlags, tag: Int = 0) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            item.tag = tag
        }

        add(to: menu, "Next Tab",
            #selector(MainWindowController.selectNextTab(_:)), "\t", [.control])
        add(to: menu, "Previous Tab",
            #selector(MainWindowController.selectPreviousTab(_:)), "\t", [.control, .shift])
        menu.addItem(.separator())
        add(to: menu, "Next Project",
            #selector(MainWindowController.selectNextProject(_:)), "]", [.command, .shift])
        add(to: menu, "Previous Project",
            #selector(MainWindowController.selectPreviousProject(_:)), "[", [.command, .shift])
        menu.addItem(.separator())

        // Nine of each would be eighteen items in one flat menu, so they go in
        // submenus. The key equivalents work the same either way.
        //
        // Cmd-N for a tab within the current project, Cmd-Shift-N for a
        // project: the narrower scope gets the easier chord, because switching
        // tabs is the more frequent move.
        let tabs = NSMenu(title: "Go to Tab")
        for index in 0..<9 {
            add(to: tabs, "Tab \(index + 1)",
                #selector(MainWindowController.selectTabByIndex(_:)),
                "\(index + 1)", [.command], tag: index)
        }
        let tabsItem = menu.addItem(withTitle: "Go to Tab", action: nil, keyEquivalent: "")
        tabsItem.submenu = tabs

        let projects = NSMenu(title: "Go to Project")
        for index in 0..<9 {
            add(to: projects, "Project \(index + 1)",
                #selector(MainWindowController.selectProjectByIndex(_:)),
                "\(index + 1)", [.command, .shift], tag: index)
        }
        let projectsItem = menu.addItem(
            withTitle: "Go to Project", action: nil, keyEquivalent: "")
        projectsItem.submenu = projects

        return menu
    }
}
