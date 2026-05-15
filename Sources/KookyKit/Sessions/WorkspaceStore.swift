import Foundation

extension Array {
    /// Step `direction` from `current`, wrapping at both ends. Used by tab
    /// and pane cycling. Direction can be any non-zero `Int`; positive walks
    /// forward, negative walks backward. Returns 0 for an empty array so
    /// callers can index without bounds checks (subscripting into an empty
    /// array would still trap, so guard `!isEmpty` before subscripting).
    func cyclicIndex(from current: Int, step direction: Int) -> Int {
        guard !isEmpty else { return 0 }
        return ((current + direction) % count + count) % count
    }
}

/// Returns `path` as a directory URL if it exists, otherwise the user's
/// home dir. The fallback prevents kooky from spawning a shell at a deleted
/// project path (deleted between sessions, externally unmounted disk),
/// which manifests as the new tab dying with a confusing one-line error.
func resolvedSpawnCwd(_ path: String) -> URL {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
       isDir.boolValue {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
}

/// Three-state sidebar visibility. `next` cycles full → compact → hidden →
/// full so each toggle hides more and eventually wraps around.
enum SidebarMode: String, Codable, Equatable, Sendable {
    case full
    case compact
    case hidden

    var next: SidebarMode {
        switch self {
        case .full: return .compact
        case .compact: return .hidden
        case .hidden: return .full
        }
    }
}

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceId: UUID?
    /// Session id currently being dragged in any pane's tab bar. Shared across
    /// all `TabBarView` instances so target panes can show drop indicators
    /// even when the source lives in a different pane.
    var draggingTabId: UUID?
    var sidebarMode: SidebarMode = .full

    /// Mutate + schedule save. UI sites wrap in `withAnimation(Theme.chromeTransition)`.
    func setSidebarMode(_ mode: SidebarMode) {
        guard sidebarMode != mode else { return }
        sidebarMode = mode
        scheduleSave()
    }

    private let engineFactory: @MainActor () -> any TerminalEngine
    /// Resolves per-agent launch options at spawn time. Production wires this
    /// to `KookySettingsModel.shared.agentOptions[id]`; tests pass a closure
    /// that returns nil so unit tests stay independent of the developer's
    /// real `~/.kooky/settings.json`.
    private let optionsProvider: @MainActor (String) -> String?
    /// Reads `KookySettingsModel.shared.resumeConversations` at spawn time;
    /// tests inject a static value (typically `true`) for the same reason
    /// as `optionsProvider`.
    private let resumeProvider: @MainActor () -> Bool
    private let persistence: any Persistence
    private let gitStatusFetcher = GitStatusFetcher()
    /// One watcher per session — refreshes git status when `.git/HEAD` or
    /// `.git/index` changes from any source (agent subprocess, external
    /// terminal, file-level git ops). The OSC 7 / OSC 133 paths only see
    /// the outer shell, so an agent running its own subprocess shell never
    /// trips them; the filesystem layer catches everyone.
    private var gitWatchers: [UUID: GitWatcher] = [:]

    /// Snapshot of a closed tab's reopenable state. Workspace + pane IDs
    /// are best-effort routing — if either is gone by the time the user
    /// hits ⌘⇧T, `reopenLastClosedTab` falls back to the active workspace
    /// / pane.
    private struct ClosedTabState {
        let agent: AgentTemplate
        let cwd: URL
        let customTitle: String?
        let workspaceId: UUID
        let paneId: UUID
        /// Captured conversation id so `⌘⇧T` resumes the Claude session
        /// the user just closed (subject to `resumeConversations` setting).
        let conversationId: String?
    }

    /// LIFO stack of recently-closed tabs for ⌘⇧T (reopen). Capped at
    /// `closedTabHistoryLimit` so a long session doesn't unbounded-grow.
    /// Runtime-only — closed tabs do not survive an app restart.
    private var recentlyClosed: [ClosedTabState] = []
    private static let closedTabHistoryLimit = 50

    private var pendingSave: Task<Void, Never>?
    private static let saveDebounce: UInt64 = 1_000_000_000

    var active: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    init(
        persistence: any Persistence = FilePersistence.shared,
        engineFactory: @escaping @MainActor () -> any TerminalEngine = { LibghosttyEngine() },
        optionsProvider: @escaping @MainActor (String) -> String? = { KookySettingsModel.shared.agentOptions[$0] },
        resumeProvider: @escaping @MainActor () -> Bool = { KookySettingsModel.shared.resumeConversations }
    ) {
        self.persistence = persistence
        self.engineFactory = engineFactory
        self.optionsProvider = optionsProvider
        self.resumeProvider = resumeProvider
        if let saved = persistence.load(), !saved.workspaces.isEmpty {
            restore(from: saved)
        } else {
            addWorkspace()
        }
    }

    // MARK: - Workspaces

    @discardableResult
    func addWorkspace(workingDirectory: URL? = nil) -> Workspace {
        let dir = workingDirectory
            ?? active?.workingDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let pane = Pane()
        let root = PaneNode(pane: pane)
        let workspace = Workspace(workingDirectory: dir, root: root)
        let session = spawnSession(template: .terminal, initialCwd: dir)
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
        pane.tabs.append(session)
        pane.activeTabId = session.id
        workspaces.append(workspace)
        activeWorkspaceId = workspace.id
        scheduleSave()
        return workspace
    }

    func closeWorkspace(_ workspace: Workspace) {
        for pane in workspace.root.allPanes {
            for tab in pane.tabs {
                gitWatchers.removeValue(forKey: tab.id)?.cancel()
                tab.engine.terminate()
            }
        }
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces.remove(at: idx)
        if workspaces.isEmpty {
            activeWorkspaceId = nil
        } else if activeWorkspaceId == workspace.id {
            let nextIdx = min(idx, workspaces.count - 1)
            activeWorkspaceId = workspaces[nextIdx].id
        }
        scheduleSave()
    }

    func activateWorkspace(_ workspace: Workspace) {
        guard activeWorkspaceId != workspace.id else { return }
        activeWorkspaceId = workspace.id
        scheduleSave()
    }

    @discardableResult
    func duplicateWorkspace(_ workspace: Workspace) -> Workspace {
        addWorkspace(workingDirectory: workspace.workingDirectory)
    }

    /// Set or clear a user-provided workspace title. Empty / whitespace input
    /// clears the override so the sidebar label resumes tracking the cwd.
    func renameWorkspace(_ workspace: Workspace, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = trimmed.isEmpty ? nil : trimmed
        guard workspace.customTitle != next else { return }
        workspace.customTitle = next
        scheduleSave()
    }

    /// Reorder workspaces in the sidebar — dragged workspace takes the
    /// destination index, others shift.
    func moveWorkspace(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex != destIndex,
              (0..<workspaces.count).contains(sourceIndex),
              (0..<workspaces.count).contains(destIndex) else { return }
        let ws = workspaces.remove(at: sourceIndex)
        workspaces.insert(ws, at: destIndex)
        scheduleSave()
    }

    func closeOtherWorkspaces(keeping workspace: Workspace) {
        let others = workspaces.filter { $0.id != workspace.id }
        for ws in others { closeWorkspace(ws) }
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(
        in workspace: Workspace,
        pane: Pane? = nil,
        template: AgentTemplate = .terminal,
        initialCwd: URL? = nil,
        conversationId: String? = nil,
        initialPrompt: String? = nil
    ) -> Session {
        guard let target = pane ?? workspace.activePane ?? workspace.root.firstPane else {
            preconditionFailure("workspace has no panes")
        }
        let cwd = initialCwd ?? workspace.workingDirectory
        let session = spawnSession(template: template, initialCwd: cwd, conversationId: conversationId, initialPrompt: initialPrompt)
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
        target.tabs.append(session)
        target.activeTabId = session.id
        if workspace.activePaneId != target.id {
            workspace.activePaneId = target.id
        }
        scheduleSave()
        return session
    }

    @discardableResult
    func duplicateTab(_ session: Session, in workspace: Workspace) -> Session? {
        guard let pane = pane(containing: session, in: workspace) else { return nil }
        return addTab(in: workspace, pane: pane, template: session.agent, initialCwd: session.currentDirectory)
    }

    /// Set or clear a user-provided tab title. Empty / whitespace input clears
    /// the override so the title resumes tracking the working directory.
    func renameTab(_ session: Session, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = trimmed.isEmpty ? nil : trimmed
        guard session.customTitle != next else { return }
        session.customTitle = next
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destIndex: Int, in pane: Pane) {
        guard sourceIndex != destIndex,
              (0..<pane.tabs.count).contains(sourceIndex),
              (0..<pane.tabs.count).contains(destIndex) else { return }
        let tab = pane.tabs.remove(at: sourceIndex)
        pane.tabs.insert(tab, at: destIndex)
        scheduleSave()
    }

    /// Move a tab from its current pane to a different pane at a specific
    /// index. If the source pane runs out of tabs as a result, it collapses
    /// (sibling pane takes its place in the split tree). The session itself
    /// is preserved — same engine, same scrollback, same agent state.
    func moveTab(_ session: Session, to destPane: Pane, at destIndex: Int, in workspace: Workspace) {
        guard let sourcePane = workspace.root.pane(containingSessionId: session.id) else { return }
        if sourcePane.id == destPane.id { return }
        guard let sourceIndex = sourcePane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        sourcePane.tabs.remove(at: sourceIndex)
        if sourcePane.activeTabId == session.id {
            sourcePane.activeTabId = sourcePane.tabs.first?.id
        }
        let insertIndex = min(max(destIndex, 0), destPane.tabs.count)
        destPane.tabs.insert(session, at: insertIndex)
        destPane.activeTabId = session.id
        workspace.activePaneId = destPane.id
        // Cross-pane move promotes the dragged session to active; mirror what
        // `activateTab` does so the sidebar title + next-spawned tab cwd
        // follow the new focus instead of waiting for the next OSC 7.
        if workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
        }
        if sourcePane.tabs.isEmpty {
            closePane(sourcePane, in: workspace)
        }
        scheduleSave()
    }

    /// One-shot drop handler for tab reorder gestures. Dispatches to the
    /// same-pane index-to-index reorder when source == dest, or the cross-pane
    /// session move otherwise. `destIndex` is the target item's current index
    /// in `destPane.tabs` (or `destPane.tabs.count` for "drop at end").
    @discardableResult
    func handleTabDrop(droppedId: UUID, to destPane: Pane, at destIndex: Int, in workspace: Workspace) -> Bool {
        guard let sourcePane = workspace.root.pane(containingSessionId: droppedId),
              let session = sourcePane.tabs.first(where: { $0.id == droppedId }) else { return false }
        if sourcePane.id == destPane.id {
            guard let from = sourcePane.tabs.firstIndex(where: { $0.id == droppedId }) else { return false }
            let to = min(max(destIndex, 0), sourcePane.tabs.count - 1)
            guard from != to else { return false }
            moveTab(from: from, to: to, in: sourcePane)
        } else {
            moveTab(session, to: destPane, at: destIndex, in: workspace)
        }
        return true
    }

    func closeOtherTabs(keeping session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace) else { return }
        let toClose = pane.tabs.filter { $0.id != session.id }
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    func closeTabsToRight(of session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Snapshot direct refs — `closeTab` mutates `pane.tabs` mid-iteration.
        let toClose = Array(pane.tabs[(idx + 1)...])
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    func closeTab(_ session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        recordClosedTab(session, pane: pane, workspace: workspace)
        gitWatchers.removeValue(forKey: session.id)?.cancel()
        session.engine.terminate()
        pane.tabs.remove(at: idx)
        if pane.tabs.isEmpty {
            closePane(pane, in: workspace)
            return
        }
        if pane.activeTabId == session.id {
            let next = pane.tabs[min(idx, pane.tabs.count - 1)]
            pane.activeTabId = next.id
            if workspace.activePane?.id == pane.id, workspace.workingDirectory != next.currentDirectory {
                workspace.workingDirectory = next.currentDirectory
            }
        }
        scheduleSave()
    }

    private func recordClosedTab(_ session: Session, pane: Pane, workspace: Workspace) {
        recentlyClosed.append(ClosedTabState(
            agent: session.agent,
            cwd: session.currentDirectory,
            customTitle: session.customTitle,
            workspaceId: workspace.id,
            paneId: pane.id,
            conversationId: session.conversationId
        ))
        if recentlyClosed.count > Self.closedTabHistoryLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.closedTabHistoryLimit)
        }
    }

    /// Pops the most recently closed tab off the history stack and re-spawns
    /// it. Routes back to the original workspace + pane when both still
    /// exist, falling back to the current workspace's active pane otherwise
    /// (a tab closed under a since-deleted workspace lands wherever the user
    /// is now). Returns the new session, or nil when the stack is empty.
    @discardableResult
    func reopenLastClosedTab() -> Session? {
        guard let state = recentlyClosed.popLast() else { return nil }
        guard let workspace = workspaces.first(where: { $0.id == state.workspaceId }) ?? active else {
            return nil
        }
        let pane = workspace.root.allPanes.first { $0.id == state.paneId }
            ?? workspace.activePane
            ?? workspace.root.firstPane
        let cwd = resolvedSpawnCwd(state.cwd.path)
        let session = addTab(
            in: workspace,
            pane: pane,
            template: state.agent,
            initialCwd: cwd,
            conversationId: state.conversationId
        )
        if let custom = state.customTitle, !custom.isEmpty {
            session.customTitle = custom
        }
        activateWorkspace(workspace)
        activateTab(session, in: workspace)
        return session
    }

    /// Cycle the active pane's tab selection. `direction` of `+1` advances
    /// to the next tab, `-1` to the previous; both wrap at the end. Per-pane,
    /// not workspace-wide — focus shouldn't jump panes when the user is
    /// asking to step through tabs in the pane they're looking at.
    func cycleTab(in workspace: Workspace, direction: Int) {
        guard let pane = workspace.activePane,
              let active = pane.activeTab,
              let currentIdx = pane.tabs.firstIndex(where: { $0 === active })
        else { return }
        activateTab(pane.tabs[pane.tabs.cyclicIndex(from: currentIdx, step: direction)], in: workspace)
    }

    func activateTab(_ session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace) else { return }
        var changed = false
        if pane.activeTabId != session.id {
            pane.activeTabId = session.id
            changed = true
        }
        if workspace.activePaneId != pane.id {
            workspace.activePaneId = pane.id
            changed = true
        }
        if workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: - Panes

    /// Splits `pane` in two. The existing pane stays as the first child of the
    /// new split; the second child is a fresh `Pane` with a single new tab
    /// inheriting the source pane's active-tab agent + cwd. Returns the new
    /// pane (now focused) or nil if `pane` isn't found.
    @discardableResult
    func splitPane(_ pane: Pane, orientation: SplitOrientation, in workspace: Workspace) -> Pane? {
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return nil }
        guard case .pane(let existing) = leafNode.content else { return nil }
        let template = existing.activeTab?.agent ?? .terminal
        let cwd = existing.activeTab?.currentDirectory ?? workspace.workingDirectory
        let newSession = spawnSession(template: template, initialCwd: cwd)
        wireSessionCallbacks(engine: newSession.engine, session: newSession, workspace: workspace)
        let newPane = Pane(tabs: [newSession], activeTabId: newSession.id)
        let firstChild = PaneNode(pane: existing)
        let secondChild = PaneNode(pane: newPane)
        leafNode.content = .split(orientation: orientation, first: firstChild, second: secondChild, fraction: 0.5)
        workspace.activePaneId = newPane.id
        scheduleSave()
        return newPane
    }

    /// Removes `pane` and its tabs. If it's the workspace's only pane, the
    /// whole workspace closes. Otherwise the sibling pane collapses up to
    /// take the parent split's place.
    func closePane(_ pane: Pane, in workspace: Workspace) {
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return }
        for tab in pane.tabs { tab.engine.terminate() }
        // Object identity, not id equality. After `splitPane`, the workspace
        // root keeps its original id but its content becomes a `.split`, while
        // a freshly-constructed child `PaneNode(pane: existing)` reuses the
        // same `pane.id`. Comparing ids would falsely match a leaf child whose
        // pane shares an id with the root and route through `closeWorkspace`.
        if leafNode === workspace.root {
            closeWorkspace(workspace)
            return
        }
        guard let info = workspace.root.parentInfo(forPane: pane.id) else { return }
        info.parent.content = info.sibling.content
        // After collapse, focus whichever pane is now nearest.
        if workspace.activePaneId == pane.id {
            workspace.activePaneId = info.sibling.firstPane?.id
            if let session = workspace.activeSession,
               workspace.workingDirectory != session.currentDirectory {
                workspace.workingDirectory = session.currentDirectory
            }
        }
        scheduleSave()
    }

    func focusPane(_ pane: Pane, in workspace: Workspace) {
        guard workspace.root.pane(id: pane.id) != nil else { return }
        var changed = false
        if workspace.activePaneId != pane.id {
            workspace.activePaneId = pane.id
            changed = true
        }
        if let session = pane.activeTab, workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Adjusts the divider fraction of the split node containing `pane` as a
    /// direct child (used by drag-to-resize).
    func setSplitFraction(_ fraction: Double, parentOf pane: Pane, in workspace: Workspace) {
        guard let info = workspace.root.parentInfo(forPane: pane.id) else { return }
        guard case .split(let orient, let first, let second, let current) = info.parent.content else { return }
        let clamped = min(max(fraction, 0.1), 0.9)
        guard abs(clamped - current) > .ulpOfOne else { return }
        info.parent.content = .split(orientation: orient, first: first, second: second, fraction: clamped)
        scheduleSave()
    }

    /// Routes a hook event to the named session. On `.ended`, drops the leaf
    /// back to `.terminal` only if the agent reporting end matches the
    /// session's current agent — otherwise a Codex run inside a Claude tab
    /// (or a delayed `ended`) would wipe the still-active icon.
    func applyHookEvent(agent: AgentTemplate, event: HookEvent, sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        let agentBefore = session.agent.id
        if event == .ended {
            // A custom agent based on this builtin shares its binary's
            // wrapper shim — the `ended` ping arrives with the builtin's
            // slug, not the custom's id. Match on the template's
            // baseAgentId snapshot (frozen at spawn time, see
            // `AgentTemplate.baseAgentId`) so a mid-run Settings edit
            // can't leave the tab pill stuck.
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                session.agent = .terminal
            }
        } else if session.agent.id == AgentTemplate.terminal.id {
            session.agent = agent
        }
        // SessionStart → UserPromptSubmit on Claude (and BeforeAgent on Gemini)
        // re-fires `.running` per turn; the @Observable setter notifies every
        // sidebar/tab observer even on same-value assignment, so guard.
        if session.activityState != event.activityState {
            session.activityState = event.activityState
        }
        if session.agent.id != agentBefore { scheduleSave() }
    }

    func applyShellEnvironment(_ env: [String: String], sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        session.shellEnvironment = env
        refreshEnvironment(for: session)
    }

    /// Stores the conversation id reported by an agent's hook payload onto
    /// the originating Session and schedules a save so the value survives
    /// across kooky launches. Same-value writes are dropped so we don't
    /// churn persistence on every hook firing — Claude pings `session_id`
    /// on every SessionStart / UserPromptSubmit / Stop / SessionEnd, so the
    /// dedup keeps the debounce loop quiet.
    func applyConversationId(conversationId: String, sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        guard session.conversationId != conversationId else { return }
        session.conversationId = conversationId
        scheduleSave()
    }

    private func findSession(id: UUID) -> Session? {
        for ws in workspaces {
            if let pane = ws.root.pane(containingSessionId: id) {
                return pane.tabs.first { $0.id == id }
            }
        }
        return nil
    }

    func flushPersistence() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence.save(snapshot())
    }

    // MARK: - Internals

    private func pane(containing session: Session, in workspace: Workspace) -> Pane? {
        workspace.root.pane(containingSessionId: session.id)
    }

    private func restore(from state: PersistedState) {
        let fm = FileManager.default
        for ws in state.workspaces {
            guard let root = restorePane(ws.root, fm: fm) else { continue }
            let workspace = Workspace(
                id: ws.id,
                workingDirectory: URL(fileURLWithPath: ws.workingDirectoryPath),
                root: root
            )
            workspace.customTitle = ws.customTitle
            // Wire engines now that workspace is constructed (engines need
            // the workspace ref for cwd-sync callbacks).
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
                }
            }
            if let id = ws.activePaneId, workspace.root.allPanes.contains(where: { $0.id == id }) {
                workspace.activePaneId = id
            } else {
                workspace.activePaneId = workspace.root.firstPane?.id
            }
            workspaces.append(workspace)
        }
        activeWorkspaceId = workspaces.contains(where: { $0.id == state.activeWorkspaceId })
            ? state.activeWorkspaceId
            : workspaces.first?.id
        sidebarMode = state.sidebarMode ?? .full
    }

    private func restorePane(_ persisted: PersistedPaneNode, fm: FileManager) -> PaneNode? {
        switch persisted.kind {
        case .pane(let p):
            let pane = Pane(id: p.id)
            for tab in p.tabs {
                let agent = AgentTemplate.all.first { $0.id == tab.agentId } ?? .terminal
                let session = spawnSession(
                    template: agent,
                    initialCwd: resolvedSpawnCwd(tab.currentDirectoryPath),
                    sessionId: tab.id,
                    conversationId: tab.conversationId
                )
                session.customTitle = tab.customTitle
                pane.tabs.append(session)
            }
            pane.activeTabId = pane.tabs.contains(where: { $0.id == p.activeTabId })
                ? p.activeTabId
                : pane.tabs.first?.id
            return PaneNode(pane: pane)
        case .split(let orientation, let first, let second, let fraction):
            guard let firstChild = restorePane(first, fm: fm),
                  let secondChild = restorePane(second, fm: fm) else { return nil }
            return PaneNode(
                id: persisted.id,
                content: .split(
                    orientation: orientation,
                    first: firstChild,
                    second: secondChild,
                    fraction: fraction
                )
            )
        }
    }

    /// Spawns the engine + Session. Caller wires `onPwdChange` / `onFocus`
    /// after a workspace ref is available — `restore` builds sessions before
    /// the workspace exists, so callbacks can't capture it here.
    private func spawnSession(template: AgentTemplate, initialCwd: URL, sessionId: UUID = UUID(), conversationId: String? = nil, initialPrompt: String? = nil) -> Session {
        let engine = engineFactory()
        // Resume gated by user setting — `resumeConversations` flips this off
        // when the user wants every Claude tab to start fresh without
        // losing the persisted conversation id (it stays on disk so the
        // setting can be flipped back on later). Non-resumable templates
        // ignore the value via `makeSessionConfig`'s own `supportsResume`
        // gate, so we don't have to re-check here.
        let resumeId = resumeProvider() ? conversationId : nil
        var config = template.makeSessionConfig(
            extraOptions: optionsProvider(template.id),
            resumeId: resumeId,
            initialPrompt: initialPrompt
        )
        config.workingDirectory = initialCwd.path
        config.environment.merge(KookyShellIntegration.kookyEnvironment(for: sessionId)) { _, new in new }
        engine.start(config: config)
        return Session(
            id: sessionId,
            engine: engine,
            currentDirectory: initialCwd,
            agent: template,
            conversationId: conversationId
        )
    }

    private func wireSessionCallbacks(engine: any TerminalEngine, session: Session, workspace: Workspace) {
        // Initial refresh — without these, the status bar stays empty until
        // the user `cd`s or runs a command. Both fetchers silently hide
        // results for non-applicable cwds, so the calls are harmless.
        refreshGitStatus(for: session)
        refreshEnvironment(for: session)
        installGitWatcher(for: session)
        engine.onPwdChange = { [weak self, weak session, weak workspace] pwd in
            guard let session else { return }
            let url = URL(fileURLWithPath: pwd)
            if session.currentDirectory.path != pwd {
                session.currentDirectory = url
            }
            if let workspace, workspace.activeSession?.id == session.id, workspace.workingDirectory.path != pwd {
                workspace.workingDirectory = url
            }
            self?.refreshGitStatus(for: session)
            self?.refreshEnvironment(for: session)
            self?.gitWatchers[session.id]?.watch(cwd: session.currentDirectory)
            self?.scheduleSave()
        }
        engine.onFocus = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.activateTab(session, in: workspace)
        }
        engine.onCommandFinished = { [weak self, weak session] exit, duration in
            guard let session else { return }
            session.lastCommandExit = exit
            session.lastCommandDuration = duration
            // A finished command may have changed the working tree (commit /
            // git add / file edits) or installed a venv / dropped an .nvmrc.
            // Refresh so the bar doesn't lie.
            self?.refreshGitStatus(for: session)
            self?.refreshEnvironment(for: session)
        }
        engine.onProcessExitedCleanly = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.closeTab(session, in: workspace)
        }
        engine.onSearchStart = { [weak session] needle in
            guard let session else { return }
            session.searchActive = true
            session.searchNeedle = needle
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchEnd = { [weak session] in
            guard let session else { return }
            session.searchActive = false
            session.searchNeedle = ""
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchTotal = { [weak session] total in
            guard let session, session.searchTotal != total else { return }
            session.searchTotal = total
        }
        engine.onSearchSelected = { [weak session] selected in
            guard let session, session.searchSelected != selected else { return }
            session.searchSelected = selected
        }
        engine.contextMenuExtrasProvider = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return [] }
            guard let selection = session.engine.readSelection(), !selection.isEmpty else {
                return []
            }
            let model = KookySettingsModel.shared
            let defaultId = AgentTemplate.defaultLaunchTemplate(model: model)
                .flatMap { $0.id == "terminal" ? nil : $0.id }
            let visible = AgentTemplate.visibleOrdered(model: model).filter { $0.id != "terminal" }
            // Default first (with the leading ▸ glyph), then everyone else
            // in their visibleOrdered position. `visibleOrdered` already
            // honours user reordering + hiding, so the second block reads
            // in the same order the user sees in `+`.
            var rows: [(template: AgentTemplate, isDefault: Bool)] = []
            if let defaultId, let def = visible.first(where: { $0.id == defaultId }) {
                rows.append((def, true))
            }
            for t in visible where t.id != defaultId {
                rows.append((t, false))
            }
            return rows.map { row in
                let template = row.template
                return ContextMenuExtra(title: "Ask \(template.title)", isDefault: row.isDefault) { [weak self, weak workspace, weak session] in
                    guard let self, let workspace, let session else { return }
                    guard let live = session.engine.readSelection(), !live.isEmpty else { return }
                    let tab = self.addTab(
                        in: workspace,
                        template: template,
                        initialCwd: session.currentDirectory,
                        initialPrompt: live
                    )
                    self.activateTab(tab, in: workspace)
                }
            }
        }
    }

    private func refreshGitStatus(for session: Session) {
        gitStatusFetcher.fetch(sessionId: session.id, cwd: session.currentDirectory) { [weak session] status in
            guard let session, session.gitStatus != status else { return }
            session.gitStatus = status
        }
    }

    private func installGitWatcher(for session: Session) {
        let watcher = GitWatcher { [weak self, weak session] in
            guard let self, let session else { return }
            self.refreshGitStatus(for: session)
        }
        watcher.watch(cwd: session.currentDirectory)
        gitWatchers[session.id] = watcher
    }

    private func refreshEnvironment(for session: Session) {
        let pid = session.engine.foregroundPid
        let env: ProjectEnvironment
        if session.shellEnvironment.isEmpty {
            env = EnvironmentDetector.detect(cwd: session.currentDirectory, pid: pid)
        } else {
            env = EnvironmentDetector.extract(
                shellEnv: session.shellEnvironment,
                cwd: session.currentDirectory,
                allowProjectFallback: false
            )
        }
        guard session.environment != env else { return }
        session.environment = env
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard let self, !Task.isCancelled else { return }
            self.persistence.save(self.snapshot())
        }
    }

    private func snapshot() -> PersistedState {
        PersistedState(
            workspaces: workspaces.map(PersistedWorkspace.init),
            activeWorkspaceId: activeWorkspaceId,
            sidebarMode: sidebarMode
        )
    }
}
