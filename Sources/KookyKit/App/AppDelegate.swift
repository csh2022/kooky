import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    let store = WorkspaceStore()
    private lazy var hookServer = HookServer { [weak store] event, sessionId in
        store?.applyHookEvent(event, sessionId: sessionId)
    }

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        KookyFonts.registerOnce()
        KookyShellIntegration.installAgentHooks()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "kooky"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Force dark chrome regardless of system appearance — the terminal
        // surface and our sidebar are always dark, and SwiftUI's .primary /
        // .secondary need a dark context to resolve to readable colors.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMainMenu()
        hookServer.start()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        store.flushPersistence()
        hookServer.stop()
        KookyShellIntegration.cleanup()
    }

    // MARK: - Menu

    /// Builds the menu bar at app launch. Keyboard shortcuts route through
    /// NSMenu first, so they fire even though `GhosttySurfaceView.keyDown`
    /// captures every other key — the menu system gets first dibs on `⌘x`
    /// before keyDown sees the event.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About kooky", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide kooky", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit kooky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem(title: "New Tab", action: #selector(handleNewTab), keyEquivalent: "t"))
        fileMenu.addItem(menuItem(title: "New Workspace", action: #selector(handleNewWorkspace), keyEquivalent: "n"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem(title: "Close Tab", action: #selector(handleCloseTab), keyEquivalent: "w"))
        fileMenu.addItem(menuItem(title: "Close Workspace", action: #selector(handleCloseWorkspace), keyEquivalent: "w", modifiers: [.command, .shift]))
        #if DEBUG
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem(title: "Cycle Activity (debug)", action: #selector(handleCycleActivity), keyEquivalent: "a", modifiers: [.command, .shift]))
        #endif
        mainMenu.addItem(submenu(fileMenu))

        // Edit menu uses first-responder selectors so libghostty's NSResponder
        // implementation handles copy/paste inside the surface.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu(editMenu))

        let windowMenu = NSMenu(title: "Window")
        for n in 1...9 {
            let item = menuItem(title: "Tab \(n)", action: #selector(handleSwitchTab(_:)), keyEquivalent: "\(n)")
            item.tag = n
            windowMenu.addItem(item)
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mainMenu.addItem(submenu(windowMenu))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        // AppKit's menu bar renders the menu item's own title — submenu.title
        // isn't used as a fallback. An empty title degrades to "NSMenuItem"
        // in the bar, so copy the submenu's title across.
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    // MARK: - Menu actions

    @objc private func handleNewTab() {
        guard let workspace = store.active else { return }
        store.addTab(in: workspace)
    }

    @objc private func handleNewWorkspace() {
        store.addWorkspace()
    }

    @objc private func handleCloseTab() {
        guard let workspace = store.active, let tab = workspace.activeTab else { return }
        store.closeTab(tab, in: workspace)
    }

    @objc private func handleCloseWorkspace() {
        guard let workspace = store.active else { return }
        store.closeWorkspace(workspace)
    }

    @objc private func handleSwitchTab(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        guard let workspace = store.active, index >= 0, index < workspace.tabs.count else { return }
        store.activateTab(workspace.tabs[index], in: workspace)
    }

    #if DEBUG
    @objc private func handleCycleActivity() {
        guard let tab = store.active?.activeTab else { return }
        switch tab.activityState {
        case .idle: tab.activityState = .running
        case .running: tab.activityState = .attention
        case .attention: tab.activityState = .idle
        }
    }
    #endif
}
