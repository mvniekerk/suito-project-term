import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    private var windowController: MainWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        windowController = controller
        // Built after the controller exists so the View items can target it.
        MenuBuilder.install(target: controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        DockAttention.shared.clear()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        windowController?.prepareForTermination()
    }
}
