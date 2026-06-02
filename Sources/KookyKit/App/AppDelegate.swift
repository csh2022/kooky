import AppKit
import SwiftUI

/// Namespace for the View menu's Tab/Workspace switch items. Tags share a
/// single integer field on `NSMenuItem`, so we partition them: 1...9 for tabs
/// (matching ⌘N), 101...109 for workspaces (⌥⌘N). The 100 offset keeps both
/// sets identifiable from `menuNeedsUpdate`.
private enum MenuTag {
    static let tabRange = 1...9
    static let workspaceRange = 101...109
    static func tab(_ n: Int) -> Int { n }
    static func workspace(_ n: Int) -> Int { 100 + n }
    static func tabIndex(from tag: Int) -> Int { tag - 1 }
    static func workspaceIndex(from tag: Int) -> Int { tag - 101 }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowControllers: [KookyWindowController] = []
    private let appPersistence = AppPersistence()
    /// Set in `applicationShouldTerminate` so `windowWillClose` (fired for
    /// every window during ⌘Q) can tell "app quitting" from "user closed
    /// one window" — the former keeps each window's persisted slot.
    private var isTerminating = false
    /// Walks the macOS window cascade so a `⌘⇧N` window doesn't land
    /// exactly on top of the previous one.
    private var cascadePoint = NSPoint.zero
    /// The kooky window that was key most recently. `activeStore` routes
    /// here (not an arbitrary array slot) when a Settings / Update panel is
    /// the key window. Weak so a closed window doesn't pin its store.
    private weak var lastKeyController: KookyWindowController?
    /// Agent hook events carry a global surface-UUID. Broadcast to every
    /// window's store — `applyHookEvent` & friends no-op when the session
    /// isn't theirs, so exactly the owning window reacts.
    private lazy var hookServer = HookServer { [weak self] message in
        guard let self else { return }
        for controller in self.windowControllers {
            let store = controller.store
            switch message {
            case .agent(let agent, let event, let sessionId):
                store.applyHookEvent(agent: agent, event: event, sessionId: sessionId)
            case .shellEnvironment(let env, let sessionId):
                store.applyShellEnvironment(env, sessionId: sessionId)
            case .conversationId(let conversationId, let sessionId):
                store.applyConversationId(conversationId: conversationId, sessionId: sessionId)
            case .toolCall(let agent, let toolName, let identifier, let event, let success, let toolUseId, let sessionId):
                store.applyToolCallEvent(
                    agent: agent,
                    toolName: toolName,
                    identifier: identifier,
                    event: event,
                    success: success,
                    toolUseId: toolUseId,
                    sessionId: sessionId
                )
            }
        }
    }


    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        KookyFonts.registerOnce()
        // First-launch onboarding (blocking NSAlert if a ghostty config exists)
        // — must run before any window is created and before any libghostty
        // surface is spawned, since `LibghosttyApp` reads `~/.kooky/settings.json`
        // at process init when the first surface is created.
        KookyOnboarding.runIfNeeded()
        let settings = KookySettingsModel.shared
        KookyShellIntegration.installAgentHooks(sshRemoteAgentDetection: settings.sshRemoteAgentDetection)
        KookyShellIntegration.refreshClaudeCustomSettings(customAgents: settings.customAgents)

        restoreWindows()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMainMenu()
        hookServer.start()

        // Sweep paste-image cache off the launch hot path. macOS's
        // own Caches eviction is unreliable; without this a heavy
        // Cmd+V-screenshots workflow accumulates GBs over months.
        Task.detached(priority: .utility) {
            KookyShellIntegration.prunePastesCache()
        }
    }

    /// Rebuilds every window persisted in `state.json`, or opens one default
    /// window on a fresh install.
    private func restoreWindows() {
        let ids = appPersistence.windowIds
        if ids.isEmpty {
            addWindow()
        } else {
            for id in ids { addWindow(windowId: id) }
        }
        // `addWindow` keys each as it's created, so the last restored window
        // ends up frontmost — kooky doesn't persist which window was key.
        //
        // Worktree two-way reconcile runs off the main actor so launch
        // isn't blocked by N × `git worktree list` subprocesses. Sidebar
        // paints first; adoptions / zombie removals trickle in once each
        // store's reconcile returns.
        for controller in windowControllers {
            Task { [store = controller.store] in
                await store.reconcileWorktrees()
            }
        }
    }

    /// Creates a window + its own `WorkspaceStore`. A fresh `windowId` (the
    /// `⌘⇧N` default) gets an empty store, which opens one default
    /// workspace; a restored id loads that window's persisted slice.
    @discardableResult
    private func addWindow(windowId: UUID = UUID()) -> KookyWindowController {
        let store = WorkspaceStore(
            persistence: WindowPersistence(windowId: windowId, app: appPersistence),
            peerStores: { [weak self] in self?.windowControllers.map(\.store) ?? [] },
            moveToNewWindow: { [weak self] id in self?.moveTabToNewWindow(sessionId: id) }
        )
        let controller = KookyWindowController(windowId: windowId, store: store)
        controller.onWillClose = { [weak self] in self?.handleWindowWillClose($0) }
        controller.onDidBecomeKey = { [weak self] in self?.lastKeyController = $0 }
        windowControllers.append(controller)
        if let window = controller.window {
            if windowControllers.count == 1 {
                window.center()
                cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            } else {
                cascadePoint = window.cascadeTopLeft(from: cascadePoint)
            }
            window.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    /// Right-click → "Move to New Window": creates a fresh window and pulls
    /// the session into it via the same cross-window machinery as a drag
    /// between existing windows. The new window's throwaway default tab is
    /// discarded once the adoption lands — `discardTab` (vs `closeTab`)
    /// keeps it off the `⌘⇧T` reopen stack since the user never asked for it.
    private func moveTabToNewWindow(sessionId: UUID) {
        let controller = addWindow()
        guard let workspace = controller.store.active,
              let pane = workspace.activePane else { return }
        let defaultTab = pane.tabs.first
        controller.store.handleTabDrop(droppedId: sessionId, to: pane, at: pane.tabs.count, in: workspace)
        // `count > 1` is a soft-fail guard for the rare case where
        // cross-window adoption returned false (e.g. the source store
        // vanished between right-click and here) — without it we'd discard
        // the placeholder, leaving the new window with zero tabs.
        if let defaultTab, pane.tabs.count > 1 {
            controller.store.discardTab(defaultTab, in: workspace)
        }
    }

    private func handleWindowWillClose(_ controller: KookyWindowController) {
        // Keep the persisted slot (restore next launch) when this is the
        // last window — closing it is effectively a quit, matching kooky's
        // long-standing single-window behaviour — or when ⌘Q is closing
        // every window. Closing one of several open windows discards just
        // that one. `contains` is evaluated synchronously against the live
        // array, so it's correct regardless of the deferred removal below
        // and doesn't depend on `isTerminating` having been set yet.
        let isLastWindow = !windowControllers.contains { $0 !== controller }
        if isTerminating || isLastWindow {
            controller.store.flushPersistence()
        } else {
            appPersistence.removeWindow(controller.windowId)
        }
        controller.store.terminate()
        // Drop the controller next tick — releasing it (and its NSWindow)
        // synchronously inside windowWillClose can crash AppKit mid-close.
        DispatchQueue.main.async { [weak self] in
            self?.windowControllers.removeAll { $0 === controller }
        }
    }

    /// The kooky window that should host a menu action — the key window
    /// when it's one of ours, otherwise the most-recently-key kooky window.
    /// Nil only when no kooky window exists.
    private var activeController: KookyWindowController? {
        if let key = NSApp.keyWindow,
           let controller = windowControllers.first(where: { $0.window === key }) {
            return controller
        }
        return lastKeyController ?? windowControllers.first
    }

    /// The `WorkspaceStore` of the key window — the target for menu actions.
    /// When a non-kooky window (Settings / Update) is key, routes to the
    /// most-recently-key kooky window; nil only when no kooky window exists.
    private var activeStore: WorkspaceStore? { activeController?.store }

    /// Re-applies `Theme.windowAppearance` to every kooky-owned window so a
    /// theme switch flips title bar / traffic lights / sheets in lockstep
    /// with the SwiftUI chrome. Enumerated rather than walking `NSApp.windows`
    /// because the latter touches system-spawned panels (alerts, color
    /// pickers) that aren't ours.
    func refreshThemeAppearances() {
        let appearance = Theme.windowAppearance
        for controller in windowControllers {
            controller.window?.appearance = appearance
        }
        KookySettingsWindowController.shared.window?.appearance = appearance
        UpdatePromptWindowController.shared.window?.appearance = appearance
        CommandPaletteWindowController.shared.window?.appearance = appearance
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Runs before AppKit closes the windows, so every `windowWillClose`
        // that follows sees the flag and keeps its persisted slot.
        isTerminating = true
        return .terminateNow
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // `windowWillClose` is not reliably delivered to every window during
        // app termination, so flush each live window's store here — the 1s
        // `scheduleSave` debounce would otherwise drop changes made in the
        // final second before ⌘Q.
        for controller in windowControllers {
            controller.store.flushPersistence()
        }
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

        // App menu — system-routed selectors via the responder chain. About
        // routes to our own handler so we can populate the panel without a
        // bundled Info.plist (the responder-chain default reads from there).
        mainMenu.addItem(submenu(buildMenu(title: KookyApp.name, entries: [
            selfRow("About \(KookyApp.name)", #selector(handleAbout)),
            selfRow("Check for Updates…", #selector(handleCheckForUpdates(_:))),
            .separator,
            selfRow("Settings…", #selector(handleOpenSettings), ","),
            .separator,
            responderRow("Hide \(KookyApp.name)", #selector(NSApplication.hide(_:)), "h"),
            responderRow("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
            responderRow("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator,
            responderRow("Quit \(KookyApp.name)", #selector(NSApplication.terminate(_:)), "q"),
        ])))

        mainMenu.addItem(submenu(buildMenu(title: "File", entries: [
            selfRow("New Tab", #selector(handleNewTab), "t"),
            selfRow("New Workspace", #selector(handleNewWorkspace), "n"),
            selfRow("New Window", #selector(handleNewWindow), "n", modifiers: [.command, .shift]),
            .separator,
            selfRow("Quick Open…", #selector(handleQuickOpen), "p"),
            selfRow("Open Folder…", #selector(handleOpenFolder), "o"),
            .separator,
            selfRow("Close Tab", #selector(handleCloseTab), "w"),
            selfRow("Reopen Closed Tab", #selector(handleReopenClosedTab), "t", modifiers: [.command, .shift]),
            selfRow("Close Workspace", #selector(handleCloseWorkspace), "w", modifiers: [.command, .shift]),
            .separator,
            selfRow("Rename Tab…", #selector(handleRenameTab), "r"),
            selfRow("Rename Workspace…", #selector(handleRenameWorkspace), "r", modifiers: [.command, .shift]),
        ])))

        // Edit menu — first-responder selectors so libghostty's NSResponder
        // implementation handles copy/paste inside the surface.
        mainMenu.addItem(submenu(buildMenu(title: "Edit", entries: [
            responderRow("Cut", #selector(NSText.cut(_:)), "x"),
            responderRow("Copy", #selector(NSText.copy(_:)), "c"),
            responderRow("Paste", #selector(NSText.paste(_:)), "v"),
            responderRow("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator,
            selfRow("Find…", #selector(handleFind), "f"),
            selfRow("Find Next", #selector(handleFindNext), "g"),
            selfRow("Find Previous", #selector(handleFindPrevious), "g", modifiers: [.command, .shift]),
        ])))

        let tabSwitchRows: [MenuEntry] = MenuTag.tabRange.map { n in
            selfRow("Tab \(n)", #selector(handleSwitchTab(_:)), "\(n)", tag: MenuTag.tab(n))
        }
        let workspaceSwitchRows: [MenuEntry] = (1...9).map { n in
            selfRow("Workspace \(n)", #selector(handleSwitchWorkspace(_:)), "\(n)",
                    modifiers: [.command, .option], tag: MenuTag.workspace(n))
        }
        let viewEntries: [MenuEntry] = [
            selfRow("Toggle Sidebar", #selector(handleToggleSidebar), "s", modifiers: [.command, .control]),
            .separator,
            selfRow("Increase Font Size", #selector(handleIncreaseFontSize), "="),
            selfRow("Decrease Font Size", #selector(handleDecreaseFontSize), "-"),
            selfRow("Default Font Size", #selector(handleResetFontSize), "0"),
            .separator,
            selfRow("Clear Pane", #selector(handleClearScrollback), "k"),
            .separator,
            // Arrow function-keys via NSEvent's specialKey codepoints — AppKit
            // renders them as ↑/↓ glyphs in the menu. Routed through libghostty
            // bindings so the engine is the single source of truth on what
            // counts as a prompt boundary.
            selfRow("Jump to Previous Prompt", #selector(handleJumpToPreviousPrompt), "\u{F700}"),
            selfRow("Jump to Next Prompt", #selector(handleJumpToNextPrompt), "\u{F701}"),
            .separator,
            selfRow("Split Right", #selector(handleSplitRight), "d"),
            selfRow("Split Down", #selector(handleSplitDown), "d", modifiers: [.command, .shift]),
            selfRow("Zoom Pane", #selector(handleToggleZoom), "e", modifiers: [.command, .shift]),
            selfRow("Focus Previous Pane", #selector(handleFocusPreviousPane), "["),
            selfRow("Focus Next Pane", #selector(handleFocusNextPane), "]"),
            .separator,
            // ⌃⇥ / ⌃⇧⇥ cycle within the focused pane's tab list — same gesture
            // browsers use. Discrete from ⌘1-⌘9 below which jumps to a tab by
            // ordinal; cycle wraps at the ends and doesn't need a digit key.
            selfRow("Next Tab", #selector(handleNextTab), "\t", modifiers: [.control]),
            selfRow("Previous Tab", #selector(handlePreviousTab), "\t", modifiers: [.control, .shift]),
            .separator,
        ]
        + tabSwitchRows
        + [.separator]
        + workspaceSwitchRows
        + [
            .separator,
            responderRow("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]),
        ]
        let viewMenu = buildMenu(title: "View", entries: viewEntries)
        viewMenu.delegate = self
        mainMenu.addItem(submenu(viewMenu))

        let windowMenu = buildMenu(title: "Window", entries: [
            responderRow("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            responderRow("Zoom", #selector(NSWindow.performZoom(_:))),
            selfRow("Center", #selector(handleCenterWindow)),
        ])
        mainMenu.addItem(submenu(windowMenu))

        #if DEBUG
        mainMenu.addItem(submenu(buildMenu(title: "Debug", entries: [
            selfRow("Cycle Activity", #selector(handleCycleActivity), "a", modifiers: [.command, .shift]),
        ])))
        #endif

        let helpMenu = buildMenu(title: "Help", entries: [
            selfRow("Report an Issue", #selector(handleOpenIssues)),
            selfRow("View on GitHub", #selector(handleOpenRepo)),
        ])
        mainMenu.addItem(submenu(helpMenu))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - Menu DSL

    private struct MenuRow {
        let title: String
        let selector: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let target: AnyObject?
        let tag: Int
    }

    private enum MenuEntry {
        case row(MenuRow)
        case separator
    }

    /// Item routed to `self` — used for the AppDelegate's own `handle*`
    /// methods that need a concrete target.
    private func selfRow(_ title: String, _ selector: Selector, _ key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> MenuEntry {
        .row(MenuRow(title: title, selector: selector, key: key,
                     modifiers: modifiers, target: self, tag: tag))
    }

    /// Item with `target: nil` — AppKit dispatches via the responder chain.
    /// Used for system selectors like `NSWindow.performZoom(_:)` and
    /// `NSText.cut(_:)`, which let libghostty / the active window handle them.
    private func responderRow(_ title: String, _ selector: Selector, _ key: String = "",
                              modifiers: NSEvent.ModifierFlags = .command) -> MenuEntry {
        .row(MenuRow(title: title, selector: selector, key: key,
                     modifiers: modifiers, target: nil, tag: 0))
    }

    private func buildMenu(title: String, entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu(title: title)
        for entry in entries {
            switch entry {
            case .row(let row):
                let item = NSMenuItem(title: row.title, action: row.selector, keyEquivalent: row.key)
                item.keyEquivalentModifierMask = row.modifiers
                item.target = row.target
                item.tag = row.tag
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
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

    @objc private func handleNewWindow() {
        addWindow()
    }

    @objc private func handleNewTab() {
        guard let store = activeStore, let workspace = store.active else { return }
        // Keyboard convention: ⌘T is deterministic — open the user's default
        // agent if set, otherwise Terminal. The visual `+` button keeps the
        // "Ask each time" popover for mouse interaction.
        let template = AgentTemplate.defaultLaunchTemplate(model: KookySettingsModel.shared) ?? .terminal
        store.addTab(in: workspace, template: template)
    }

    @objc private func handleNewWorkspace() {
        activeStore?.addWorkspace()
    }

    /// Internal (not `private`) so `#selector` in `ContentView` can typecheck.
    /// The runtime dispatch goes through Obj-C selectors either way.
    @objc func handleQuickOpen() {
        // Built fresh every open so a workspace added / tab renamed since
        // the panel was last shown reflects in the index without us
        // tracking invalidations. `toggle` makes ⌘P symmetric — press to
        // open, press again (or Esc) to dismiss.
        CommandPaletteWindowController.shared.toggle(
            items: { [weak self] in
                guard let self else { return [] }
                return PaletteIndex.build(controllers: self.windowControllers, model: KookySettingsModel.shared)
            },
            anchor: activeController?.window,
            onActivate: { [weak self] item in self?.activate(item) }
        )
    }

    /// Routes a palette pick to the owning window + workspace. Workspace
    /// and tab picks raise their owning window first so a cross-window
    /// jump lands in front. Agent / preset picks spawn in the *currently*
    /// active workspace (matches the muscle memory of ⌘T).
    private func activate(_ item: PaletteItem) {
        switch item.kind {
        case .workspace(let wsId, let winId):
            guard let target = windowControllers.first(where: { $0.windowId == winId }),
                  let ws = target.store.workspaces.first(where: { $0.id == wsId }) else { return }
            target.window?.makeKeyAndOrderFront(nil)
            target.store.activateWorkspace(ws)
        case .tab(let sId, let wsId, let winId):
            // `pane(containingSessionId:)` short-circuits on the first
            // matching pane; the codebase prefers it over `allPanes.first(where:)`
            // for tree walks (per PaneNode.swift doc).
            guard let target = windowControllers.first(where: { $0.windowId == winId }),
                  let ws = target.store.workspaces.first(where: { $0.id == wsId }),
                  let pane = ws.root.pane(containingSessionId: sId),
                  let session = pane.tabs.first(where: { $0.id == sId }) else { return }
            target.window?.makeKeyAndOrderFront(nil)
            target.store.activateWorkspace(ws)
            target.store.activateTab(session, in: ws)
        case .createWorktree(let wsId, let winId):
            guard let target = windowControllers.first(where: { $0.windowId == winId }),
                  let ws = target.store.workspaces.first(where: { $0.id == wsId }) else { return }
            target.window?.makeKeyAndOrderFront(nil)
            target.store.activateWorkspace(ws)
            target.store.pendingCreateWorktreeRequest = ws
            if target.store.sidebarMode == .hidden {
                // Matches ContentView / View menu's reveal behaviour — without
                // the animation wrap the sidebar snaps from 0 to 220pt the moment
                // the palette routes a worktree-create request through.
                withAnimation(Theme.chromeTransition) {
                    target.store.setSidebarMode(.full)
                }
            }
        case .agent(let templateId):
            guard let store = activeStore, let ws = store.active else { return }
            let template = AgentTemplate.visibleOrdered(model: KookySettingsModel.shared)
                .first(where: { $0.id == templateId }) ?? .terminal
            store.addTab(in: ws, template: template)
        }
    }

    @objc private func handleOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Open Folder"
        panel.message = "Choose a folder to open as a workspace."

        let controller = activeController
        let store = controller?.store
        // Start the picker at the active workspace's cwd — the user is
        // usually picking something nearby (sibling project, parent dir).
        panel.directoryURL = store?.active?.workingDirectory

        let openPicked: () -> Void = {
            for url in panel.urls { store?.addWorkspace(workingDirectory: url) }
        }
        if let window = controller?.window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { openPicked() }
            }
        } else if panel.runModal() == .OK {
            openPicked()
        }
    }

    @objc private func handleCloseTab() {
        guard let store = activeStore, let workspace = store.active,
              let session = workspace.activeSession else { return }
        store.closeTab(session, in: workspace)
    }

    @objc private func handleReopenClosedTab() {
        activeStore?.reopenLastClosedTab()
    }

    @objc private func handleNextTab() {
        guard let store = activeStore, let workspace = store.active else { return }
        store.cycleTab(in: workspace, direction: 1)
    }

    @objc private func handlePreviousTab() {
        guard let store = activeStore, let workspace = store.active else { return }
        store.cycleTab(in: workspace, direction: -1)
    }

    @objc private func handleSplitRight() {
        guard let store = activeStore, let workspace = store.active,
              let pane = workspace.activePane else { return }
        store.splitPane(pane, orientation: .horizontal, in: workspace)
    }

    @objc private func handleSplitDown() {
        guard let store = activeStore, let workspace = store.active,
              let pane = workspace.activePane else { return }
        store.splitPane(pane, orientation: .vertical, in: workspace)
    }

    @objc private func handleToggleZoom() {
        guard let store = activeStore, let workspace = store.active else { return }
        // `withAnimation` (matching `handleToggleSidebar`) propagates the
        // transaction to *every* view change triggered by the mutation —
        // SplitContainer's fraction/offset morph AND the outer
        // PaneStatusBar visibility transition both animate together.
        withAnimation(Theme.chromeTransition) {
            store.toggleZoom(in: workspace)
        }
    }

    @objc private func handleFocusNextPane() {
        cyclePaneFocus(forward: true)
    }

    @objc private func handleFocusPreviousPane() {
        cyclePaneFocus(forward: false)
    }

    private func cyclePaneFocus(forward: Bool) {
        guard let store = activeStore, let workspace = store.active else { return }
        let panes = workspace.root.allPanes
        guard panes.count > 1 else { return }
        let currentId = workspace.activePaneId ?? panes.first?.id
        let idx = panes.firstIndex(where: { $0.id == currentId }) ?? 0
        store.focusPane(panes[panes.cyclicIndex(from: idx, step: forward ? 1 : -1)], in: workspace)
    }

    @objc private func handleCloseWorkspace() {
        guard let store = activeStore, let workspace = store.active else { return }
        store.requestCloseWorkspace(workspace)
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Hidden NSMenuItems don't fire their keyEquivalents — pressing ⌘5
        // with 3 tabs is a no-op, matching what the menu shows.
        let store = activeStore
        let tabCount = store?.active?.activePane?.tabs.count ?? 0
        let workspaceCount = store?.workspaces.count ?? 0
        for item in menu.items {
            if MenuTag.tabRange.contains(item.tag) {
                item.isHidden = item.tag > tabCount
            } else if MenuTag.workspaceRange.contains(item.tag) {
                item.isHidden = MenuTag.workspaceIndex(from: item.tag) >= workspaceCount
            }
        }
    }

    @objc private func handleIncreaseFontSize() {
        activeStore?.active?.activeSession?.engine.performAction("increase_font_size:1")
    }

    @objc private func handleDecreaseFontSize() {
        activeStore?.active?.activeSession?.engine.performAction("decrease_font_size:1")
    }

    @objc private func handleResetFontSize() {
        activeStore?.active?.activeSession?.engine.performAction("reset_font_size")
    }

    @objc private func handleClearScrollback() {
        activeStore?.active?.activeSession?.engine.performAction("clear_screen")
    }

    @objc private func handleJumpToPreviousPrompt() {
        activeStore?.active?.activeSession?.engine.performAction("jump_to_prompt:-1")
    }

    @objc private func handleJumpToNextPrompt() {
        activeStore?.active?.activeSession?.engine.performAction("jump_to_prompt:1")
    }

    @objc private func handleToggleSidebar() {
        guard let store = activeStore else { return }
        withAnimation(Theme.chromeTransition) {
            store.setSidebarMode(store.sidebarMode.next)
        }
    }

    @objc private func handleFind() {
        guard let session = activeStore?.active?.activeSession else { return }
        // ⌘F is a toggle on the active tab. Search state is per-session, so
        // ⌘F in pane A doesn't affect pane B's open search bar — both can
        // be active simultaneously, each with their own needle / count.
        if session.searchActive {
            session.engine.performAction("end_search")
        } else {
            session.engine.performAction("start_search")
        }
    }

    @objc private func handleFindNext() {
        activeStore?.active?.activeSession?.engine.performAction("navigate_search:next")
    }

    @objc private func handleFindPrevious() {
        activeStore?.active?.activeSession?.engine.performAction("navigate_search:previous")
    }

    @objc private func handleRenameTab() {
        activeStore?.requestRenameActiveTab()
    }

    @objc private func handleRenameWorkspace() {
        activeStore?.requestRenameActiveWorkspace()
    }

    @objc private func handleAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: KookyApp.name,
            .applicationVersion: KookyApp.displayVersion,
            // Suppress the parenthesized build number — Info.plist sets
            // CFBundleVersion to the same string as CFBundleShortVersionString,
            // and the default "Version X (X)" reads as a typo.
            .version: "",
            .credits: aboutCredits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private var aboutCredits: NSAttributedString {
        // Two paragraph styles: `tight` for adjacent lines within a block,
        // `blockGap` for the first line of a new block (adds a uniform gap
        // above, independent of surrounding font sizes). Without this, blank
        // lines inherit the previous paragraph's font and the spacing wobbles
        // as the font drops from 11pt headline to 9pt footnote.
        let tight = NSMutableParagraphStyle()
        tight.alignment = .center
        tight.lineSpacing = 1

        let blockGap = NSMutableParagraphStyle()
        blockGap.alignment = .center
        blockGap.lineSpacing = 1
        blockGap.paragraphSpacingBefore = 12

        let body = NSFont.systemFont(ofSize: 11)
        let foot = NSFont.systemFont(ofSize: 9)

        func attrs(_ font: NSFont, _ color: NSColor, _ style: NSParagraphStyle, link: URL? = nil) -> [NSAttributedString.Key: Any] {
            var dict: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            if let link { dict[.link] = link }
            return dict
        }

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: KookyApp.tagline,
            attributes: attrs(body, .labelColor, tight)
        ))
        credits.append(NSAttributedString(
            string: "\nGithub ↗",
            attributes: attrs(body, .linkColor, tight, link: KookyApp.repositoryURL)
        ))
        credits.append(NSAttributedString(
            string: "\n© \(KookyApp.copyrightYear) \(KookyApp.name). All rights reserved.",
            attributes: attrs(foot, .secondaryLabelColor, blockGap)
        ))
        credits.append(NSAttributedString(
            string: "\nBuilt with ❤️ by ",
            attributes: attrs(foot, .secondaryLabelColor, tight)
        ))
        credits.append(NSAttributedString(
            string: KookyApp.author,
            attributes: attrs(foot, .linkColor, tight, link: KookyApp.authorURL)
        ))
        return credits
    }

    @objc private func handleOpenIssues() {
        NSWorkspace.shared.open(KookyApp.issuesURL)
    }

    @objc private func handleOpenRepo() {
        NSWorkspace.shared.open(KookyApp.repositoryURL)
    }

    @objc private func handleCheckForUpdates(_ sender: NSMenuItem) {
        let originalTitle = sender.title
        sender.title = "Checking for Updates…"
        sender.isEnabled = false
        // KOOKY_FAKE_VERSION lets us preview the "newer release" prompt without
        // mutating KookyApp.displayVersion. Launch via:
        //   open --env KOOKY_FAKE_VERSION=0.11.0 /Applications/Kooky.app
        let currentVersion = ProcessInfo.processInfo.environment["KOOKY_FAKE_VERSION"]
            ?? KookyApp.displayVersion
        Task { @MainActor in
            let outcome = await UpdateChecker.check(currentVersion: currentVersion)
            sender.title = originalTitle
            sender.isEnabled = true
            UpdatePromptWindowController.present(outcome: outcome, currentVersion: currentVersion)
        }
    }

    @objc private func handleOpenSettings() {
        // Pass a live resolver, not a snapshot — the Settings window is a
        // singleton that outlives any one window; a captured store would
        // dangle once its window closed.
        KookySettingsWindowController.show(storeProvider: { [weak self] in self?.activeStore })
    }

    @objc private func handleCenterWindow() {
        // NSWindow.center() takes no sender arg, so it can't be a direct
        // first-responder selector — wrap it.
        NSApp.keyWindow?.center()
    }

    @objc private func handleSwitchTab(_ sender: NSMenuItem) {
        let index = MenuTag.tabIndex(from: sender.tag)
        guard let store = activeStore, let workspace = store.active,
              let pane = workspace.activePane,
              index >= 0, index < pane.tabs.count else { return }
        store.activateTab(pane.tabs[index], in: workspace)
    }

    @objc private func handleSwitchWorkspace(_ sender: NSMenuItem) {
        let index = MenuTag.workspaceIndex(from: sender.tag)
        guard let store = activeStore,
              index >= 0, index < store.workspaces.count else { return }
        store.activateWorkspace(store.workspaces[index])
    }

    #if DEBUG
    /// Cycles through every dot state in precedence order: idle → running
    /// → failure → attention → idle. Used to preview the dot palette without
    /// running real agents / commands.
    @objc private func handleCycleActivity() {
        guard let session = activeStore?.active?.activeSession else { return }
        let isFailure = session.lastCommandExit.map { $0 != 0 } ?? false
        switch (session.activityState, isFailure) {
        case (.idle, false):
            session.activityState = .running
        case (.running, _):
            session.activityState = .idle
            session.lastCommandExit = 1
            session.lastCommandDuration = 0.42
        case (.idle, true):
            session.activityState = .attention
        case (.attention, _):
            session.activityState = .idle
            session.lastCommandExit = nil
            session.lastCommandDuration = nil
        }
    }
    #endif
}
