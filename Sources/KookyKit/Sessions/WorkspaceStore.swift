import Foundation

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceId: UUID?

    /// Factory for the terminal engine backing each new tab. Tests inject a
    /// no-op engine to avoid pulling in libghostty / spawning a PTY.
    private let engineFactory: @MainActor () -> any TerminalEngine

    /// Where workspace + tab metadata is persisted. Tests inject in-memory.
    private let persistence: any Persistence

    /// Debounced save handle. Cancelled and reissued on every mutation so
    /// rapid changes (drag-resize, multi-key add) collapse to a single write.
    private var pendingSave: Task<Void, Never>?

    private static let saveDebounce: UInt64 = 1_000_000_000  // 1 s in nanoseconds

    var active: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    init(
        persistence: any Persistence = FilePersistence.shared,
        engineFactory: @escaping @MainActor () -> any TerminalEngine = { LibghosttyEngine() }
    ) {
        self.persistence = persistence
        self.engineFactory = engineFactory
        if let saved = persistence.load(), !saved.workspaces.isEmpty {
            restore(from: saved)
        } else {
            addWorkspace()
        }
    }

    @discardableResult
    func addWorkspace(workingDirectory: URL? = nil, title: String? = nil) -> Workspace {
        // Default: inherit active workspace's current cwd (which itself tracks
        // the active tab's OSC 7 reports). Falls back to $HOME on first launch.
        let dir = workingDirectory
            ?? active?.workingDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let resolvedTitle = title ?? Self.defaultTitle(for: dir)
        let ws = Workspace(title: resolvedTitle, workingDirectory: dir)
        workspaces.append(ws)
        activeWorkspaceId = ws.id
        addTab(in: ws)
        return ws
    }

    func closeWorkspace(_ workspace: Workspace) {
        for tab in workspace.tabs { tab.engine.terminate() }
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
    func addTab(in workspace: Workspace, template: AgentTemplate = .terminal) -> Session {
        let session = startSession(in: workspace, template: template, initialCwd: workspace.workingDirectory)
        workspace.tabs.append(session)
        workspace.activeTabId = session.id
        scheduleSave()
        return session
    }

    func closeTab(_ session: Session, in workspace: Workspace) {
        session.engine.terminate()
        guard let idx = workspace.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        workspace.tabs.remove(at: idx)
        if workspace.tabs.isEmpty {
            closeWorkspace(workspace)
            return
        }
        if workspace.activeTabId == session.id {
            let nextIdx = min(idx, workspace.tabs.count - 1)
            workspace.activeTabId = workspace.tabs[nextIdx].id
        }
        scheduleSave()
    }

    func activateTab(_ session: Session, in workspace: Workspace) {
        guard workspace.activeTabId != session.id else { return }
        workspace.activeTabId = session.id
        if workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
        }
        scheduleSave()
    }

    /// Cancels any debounced write and persists synchronously. Call from
    /// `applicationWillTerminate` so the latest state survives quit-on-close.
    func flushPersistence() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence.save(snapshot())
    }

    // MARK: - Restore

    private func restore(from state: PersistedState) {
        let fm = FileManager.default
        for ws in state.workspaces {
            let workspace = Workspace(
                id: ws.id,
                title: ws.title,
                workingDirectory: URL(fileURLWithPath: ws.workingDirectoryPath)
            )
            for persisted in ws.tabs {
                let agent = AgentTemplate.all.first { $0.id == persisted.agentId } ?? {
                    NSLog("kooky: persisted agent id '\(persisted.agentId)' not found, falling back to terminal")
                    return .terminal
                }()
                // Saved cwd may have been deleted between launches; an
                // unreachable working directory makes the spawned shell hang
                // confusingly. Fall back to $HOME instead.
                let cwd = fm.fileExists(atPath: persisted.currentDirectoryPath)
                    ? URL(fileURLWithPath: persisted.currentDirectoryPath)
                    : URL(fileURLWithPath: NSHomeDirectory())
                let session = startSession(
                    in: workspace,
                    template: agent,
                    initialCwd: cwd,
                    sessionId: persisted.id
                )
                workspace.tabs.append(session)
            }
            // Reject stale activeTabId — file corruption or older schema
            // could point at a tab we didn't restore.
            workspace.activeTabId = workspace.tabs.contains(where: { $0.id == ws.activeTabId })
                ? ws.activeTabId
                : workspace.tabs.first?.id
            workspaces.append(workspace)
        }
        activeWorkspaceId = workspaces.contains(where: { $0.id == state.activeWorkspaceId })
            ? state.activeWorkspaceId
            : workspaces.first?.id
    }

    // MARK: - Internals

    /// Spawns an engine + Session tied to this store's pwd-tracking. Shared by
    /// `addTab` and `restore` so the wiring is identical.
    private func startSession(
        in workspace: Workspace,
        template: AgentTemplate,
        initialCwd: URL,
        sessionId: UUID = UUID()
    ) -> Session {
        let engine = engineFactory()
        var config = template.makeSessionConfig()
        config.workingDirectory = initialCwd.path
        engine.start(config: config)
        let session = Session(id: sessionId, engine: engine, currentDirectory: initialCwd, agent: template)
        wirePwdSync(engine: engine, session: session, workspace: workspace)
        return session
    }

    private func wirePwdSync(engine: any TerminalEngine, session: Session, workspace: Workspace) {
        // OSC 7 fires per chpwd. Guard against no-op writes; sync session and
        // (when active) workspace; schedule a save so cwd survives a relaunch.
        engine.onPwdChange = { [weak self, weak session, weak workspace] pwd in
            guard let session else { return }
            let url = URL(fileURLWithPath: pwd)
            if session.currentDirectory.path != pwd {
                session.currentDirectory = url
            }
            if let workspace, workspace.activeTabId == session.id, workspace.workingDirectory.path != pwd {
                workspace.workingDirectory = url
            }
            self?.scheduleSave()
        }
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
            activeWorkspaceId: activeWorkspaceId
        )
    }

    /// Last path component; "Home" when the dir is `$HOME` (reads nicer than "corey").
    private static func defaultTitle(for url: URL) -> String {
        if url.standardizedFileURL.path == NSHomeDirectory() { return "Home" }
        return url.lastPathComponent
    }
}
