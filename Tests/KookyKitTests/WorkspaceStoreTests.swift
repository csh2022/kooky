import XCTest
@testable import KookyKit

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/tmp/projectA")
    private let projectB = URL(fileURLWithPath: "/tmp/projectB")
    private let projectC = URL(fileURLWithPath: "/tmp/projectC")

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        for path in ["/tmp/projectA", "/tmp/projectA/sub", "/tmp/projectA/deep", "/tmp/projectB", "/tmp/projectC"] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private func makeStore(initial: PersistedState? = nil) -> WorkspaceStore {
        WorkspaceStore(
            persistence: InMemoryPersistence(initial: initial),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
        )
    }

    /// Two independent stores wired as each other's peers — models two kooky
    /// windows for cross-window tab-drag tests.
    private func makeWindowPair() -> (WorkspaceStore, WorkspaceStore) {
        // `peers` reads `stores` lazily — both inits run (neither invokes
        // `peerStores`) before the array is backfilled on the line below.
        var stores: [WorkspaceStore] = []
        let peers: @MainActor () -> [WorkspaceStore] = { stores }
        let a = WorkspaceStore(
            persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { true }, peerStores: peers
        )
        let b = WorkspaceStore(
            persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { true }, peerStores: peers
        )
        stores = [a, b]
        return (a, b)
    }

    private func engine(_ session: Session) -> TestEngine {
        guard let e = session.engine as? TestEngine else { preconditionFailure("expected TestEngine") }
        return e
    }

    private func firstPane(_ ws: Workspace) -> Pane {
        guard let pane = ws.root.firstPane else { preconditionFailure("expected at least one pane") }
        return pane
    }

    func testInitialStateHasOneWorkspaceWithOnePaneAndOneTab() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.count, 1)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(firstPane(ws).tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, ws.id)
    }

    func testFirstWorkspaceUsesHomeDirectory() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.first?.workingDirectory.path, NSHomeDirectory())
        XCTAssertEqual(store.workspaces.first?.title, "Home")
    }

    func testAddWorkspaceCreatesNewWorkspaceAndActivatesIt() {
        let store = makeStore()
        let first = store.workspaces[0]
        let second = store.addWorkspace(workingDirectory: projectA)
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(second.root.allPanes.count, 1)
        XCTAssertEqual(firstPane(second).tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, second.id)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testAddWorkspaceTitleDefaultsToLastPathComponent() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/sample-project"))
        XCTAssertEqual(ws.title, "sample-project")
    }

    func testAddTabAppendsToActivePaneAndStartsEngine() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let session = store.addTab(in: ws, template: .terminal)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTabId, session.id)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, projectA.path)
    }

    func testActiveTabPwdReportSyncsToWorkspace() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let session = pane.tabs[0]
        engine(session).emitPwd("/tmp/projectA/sub")
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA/sub")
    }

    func testCommandFinishedUpdatesSessionStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]
        XCTAssertNil(session.lastCommandExit)
        XCTAssertNil(session.lastCommandDuration)
        engine(session).emitCommandFinished(exit: 1, duration: 0.42)
        XCTAssertEqual(session.lastCommandExit, 1)
        XCTAssertEqual(session.lastCommandDuration, 0.42)
        // Subsequent zero-exit overwrites the failure (so the dot disappears
        // when the next command succeeds, instead of sticking forever).
        engine(session).emitCommandFinished(exit: 0, duration: 0.05)
        XCTAssertEqual(session.lastCommandExit, 0)
    }

    func testTerminalTitleReportUpdatesTabAndWorkspaceName() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        // An `ssh` remote shell emits its own OSC 0/2 title.
        engine(session).emitTitle("corey@web-prod: ~/srv")

        XCTAssertEqual(session.title, "corey@web-prod: ~/srv")
        XCTAssertEqual(ws.title, "corey@web-prod: ~/srv")
    }

    func testCustomTitleWinsOverTerminalTitle() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("corey@web-prod")
        store.renameTab(session, to: "deploy")

        XCTAssertEqual(session.title, "deploy")
    }

    func testCommandFinishedKeepsTerminalTitle() {
        // P2 regression: a shell theme's `precmd` title hook sets the title
        // just before kooky's OSC 133;D fires (kooky's 133 hook runs last in
        // `precmd_functions`). Clearing on command-finished would wipe that
        // fresh title — so `onCommandFinished` must leave `terminalTitle`
        // alone. Stale titles are reset by the wrapper's per-prompt
        // `_kooky_title_pwd`, not here.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("corey@web-prod")
        engine(session).emitCommandFinished(exit: 0, duration: 0.1)

        XCTAssertEqual(session.terminalTitle, "corey@web-prod")
        XCTAssertEqual(session.title, "corey@web-prod")
    }

    func testEmptyTerminalTitleReportFallsBackToCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("   ")

        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.title, "projectA")
    }

    func testBareCwdPathTitleIsIgnoredSoTabKeepsBasename() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        // libghostty derives a SET_TITLE that's just the absolute cwd path.
        // The tab must keep showing the basename, not `/tmp/projectA`.
        engine(session).emitTitle("/tmp/projectA")
        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.title, "projectA")

        // A `~`-abbreviated path is the same noise.
        engine(session).emitTitle("~/tmp/projectA")
        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.title, "projectA")
    }

    func testShellEnvironmentReportUpdatesSessionEnvironment() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        store.applyShellEnvironment([
            "VIRTUAL_ENV": "/tmp/projectA/.venv",
            "CONDA_DEFAULT_ENV": "",
            "NVM_BIN": "/Users/corey/.nvm/versions/node/v22.3.0/bin",
            "NVM_DIR": "/Users/corey/.nvm",
            "KOOKY_NODE_VERSION": "v22.3.0",
        ], sessionId: session.id)

        XCTAssertEqual(session.environment.pythonVenv, ".venv")
        XCTAssertEqual(session.environment.nodeVersion, "v22.3.0")
        XCTAssertEqual(session.environment.nvmDirectory, "/Users/corey/.nvm")
    }

    func testWorkspaceFailureAggregatesAcrossPanes() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        // Failure-bearing tab must live in a different pane from the active
        // one to verify the DFS picks it up regardless of focus.
        store.splitPane(pane, orientation: .horizontal, in: ws)
        let firstTab = pane.tabs[0]
        let secondPaneTab = ws.root.allPanes.last!.tabs[0]
        XCTAssertFalse(ws.hasCommandFailure)
        engine(secondPaneTab).emitCommandFinished(exit: 1, duration: 0.1)
        XCTAssertTrue(ws.hasCommandFailure)
        engine(secondPaneTab).emitCommandFinished(exit: 0, duration: 0.1)
        XCTAssertFalse(ws.hasCommandFailure)
        engine(firstTab).emitCommandFinished(exit: 2, duration: 0.1)
        XCTAssertTrue(ws.hasCommandFailure)
    }

    func testFailureSurfacesEvenWhenAttentionFiresFirstInDFS() {
        // Regression: `sidebarReadout`'s walk used to short-circuit on attention,
        // leaving `hasCommandFailure` false when a sibling pane held a non-zero
        // exit. The walk now runs to completion so each field is independent.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        store.splitPane(pane, orientation: .horizontal, in: ws)
        let firstPaneTab = pane.tabs[0]
        let secondPaneTab = ws.root.allPanes.last!.tabs[0]
        firstPaneTab.activityState = .attention
        engine(secondPaneTab).emitCommandFinished(exit: 1, duration: 0.1)
        XCTAssertEqual(ws.activityState, .attention)
        XCTAssertTrue(ws.hasCommandFailure)
    }

    func testPresetTabsAreTreatedAsShellsInSidebarReadout() {
        // Regression: when `Workspace.sidebarReadout` filtered with
        // `id != AgentTemplate.terminal.id`, preset tabs (id `preset-N`)
        // counted as "agents" — the sidebar would show a pip per preset
        // and a `+N` indicator for a workspace that just held a few
        // pinned-cwd terminals. `isShell` covers Terminal + all presets.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pinned = AgentTemplate.fromTerminalPreset(
            TerminalPreset(id: "preset-b", title: "B", path: projectB.path)
        )
        store.addTab(in: ws, template: pinned)
        XCTAssertTrue(ws.distinctAgents.isEmpty,
                      "preset tabs are shells, not agents — sidebar must not list them")
    }

    func testAddTabUsesTemplateExtraCwdOverWorkspaceCwd() {
        // Terminal preset pinned to /tmp/projectB spawns there even when
        // the active workspace lives in /tmp/projectA. Models issue #12 —
        // `+` menu entries that always open at a fixed path.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pinned = AgentTemplate.fromTerminalPreset(
            TerminalPreset(id: "preset-b", title: "B", path: projectB.path)
        )
        let session = store.addTab(in: ws, template: pinned)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, projectB.path)
    }

    func testAddTabInitialCwdOverridesTemplateExtraCwd() {
        // Explicit `initialCwd` (right-click "Ask <agent>" path,
        // `reopenLastClosedTab`) wins over the template's pinned cwd —
        // the caller is asking for that exact path, not the template's
        // default.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pinned = AgentTemplate.fromTerminalPreset(
            TerminalPreset(id: "preset-b", title: "B", path: projectB.path)
        )
        let session = store.addTab(in: ws, template: pinned, initialCwd: projectC)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, projectC.path)
    }

    func testNewTabInheritsLatestPwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        engine(pane.tabs[0]).emitPwd("/tmp/projectA/sub")
        let session = store.addTab(in: ws)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, "/tmp/projectA/sub")
    }

    func testAddTabRespectsTemplate() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode)
        XCTAssertEqual(session.agent.id, "claude-code")
        XCTAssertEqual(engine(session).startedConfigs.first?.environment["KOOKY_AGENT"], "claude")
    }

    func testReopenLastClosedTabRestoresAgentAndCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = store.addTab(in: ws, template: .claudeCode, initialCwd: projectB)
        session.customTitle = "release prep"
        XCTAssertEqual(firstPane(ws).tabs.count, 2)

        store.closeTab(session, in: ws)
        XCTAssertEqual(firstPane(ws).tabs.count, 1)

        let reopened = store.reopenLastClosedTab()
        let pane = firstPane(ws)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(reopened?.agent.id, "claude-code")
        XCTAssertEqual(reopened?.currentDirectory.path, projectB.path)
        XCTAssertEqual(reopened?.customTitle, "release prep")
        XCTAssertEqual(pane.activeTabId, reopened?.id)
    }

    func testReopenIsLifoStack() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let a = store.addTab(in: ws)
        let b = store.addTab(in: ws)
        store.closeTab(a, in: ws)
        store.closeTab(b, in: ws)

        let firstReopen = store.reopenLastClosedTab()
        let secondReopen = store.reopenLastClosedTab()

        // LIFO: most-recently-closed (`b`) comes back first.
        XCTAssertEqual(firstReopen?.currentDirectory.path, b.currentDirectory.path)
        XCTAssertEqual(secondReopen?.currentDirectory.path, a.currentDirectory.path)
        XCTAssertEqual(pane.tabs.count, 3)
    }

    func testReopenWithEmptyStackReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.reopenLastClosedTab())
    }

    func testCycleTabAdvancesAndWrapsAroundEnd() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let a = pane.tabs[0]
        let b = store.addTab(in: ws)
        let c = store.addTab(in: ws)
        XCTAssertEqual(pane.activeTabId, c.id)

        store.cycleTab(in: ws, direction: 1)  // c → a (wrap)
        XCTAssertEqual(pane.activeTabId, a.id)

        store.cycleTab(in: ws, direction: 1)  // a → b
        XCTAssertEqual(pane.activeTabId, b.id)
    }

    func testCycleTabBackwardsWrapsAtStart() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let a = pane.tabs[0]
        let b = store.addTab(in: ws)
        store.activateTab(a, in: ws)

        store.cycleTab(in: ws, direction: -1)  // a → b (wrap backward)
        XCTAssertEqual(pane.activeTabId, b.id)
    }

    func testClosingActiveTabActivatesNeighbor() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let first = pane.tabs[0]
        let second = store.addTab(in: ws)
        XCTAssertEqual(pane.activeTabId, second.id)
        store.closeTab(second, in: ws)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.activeTabId, first.id)
        XCTAssertEqual(engine(second).terminateCount, 1)
    }

    func testClosingLastTabClosesPaneAndWorkspaceWhenSinglePane() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        store.closeTab(pane.tabs[0], in: ws)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    func testClosingMiddleWorkspaceActivatesNextNeighbor() {
        let store = makeStore()
        let a = store.workspaces[0]
        let b = store.addWorkspace(workingDirectory: projectB)
        let c = store.addWorkspace(workingDirectory: projectC)
        store.activateWorkspace(b)
        store.closeWorkspace(b)
        XCTAssertEqual(store.workspaces.map(\.id), [a.id, c.id])
        XCTAssertEqual(store.activeWorkspaceId, c.id)
    }

    func testClosingLastWorkspaceClearsActiveId() {
        let store = makeStore()
        store.closeWorkspace(store.workspaces[0])
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    // MARK: Splits

    func testSplitPaneCreatesSiblingPaneAndFocusesIt() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)
        XCTAssertNotNil(new)
        XCTAssertEqual(ws.root.allPanes.count, 2)
        XCTAssertEqual(ws.activePaneId, new?.id)
        XCTAssertEqual(new?.tabs.count, 1)
    }

    func testSplitPaneInheritsActiveTabAgentAndCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        store.addTab(in: ws, template: .claudeCode)
        engine(pane.tabs.last!).emitPwd("/tmp/projectA/sub")
        let new = store.splitPane(pane, orientation: .vertical, in: ws)
        let newSession = new?.tabs.first
        XCTAssertEqual(newSession?.agent.id, "claude-code")
        XCTAssertEqual((newSession?.engine as? TestEngine)?.startedConfigs.last?.workingDirectory, "/tmp/projectA/sub")
    }

    func testClosePaneCollapsesSiblingUp() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        XCTAssertEqual(ws.root.allPanes.count, 2)
        store.closePane(new, in: ws)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(ws.root.allPanes.first?.id, pane.id)
    }

    func testClosingLastTabInSecondPaneCollapsesSplit() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        // Close the lone tab in `new`. Should collapse the split, leaving `pane` alone.
        store.closeTab(new.tabs[0], in: ws)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(ws.root.allPanes.first?.id, pane.id)
    }

    func testFocusPaneSwitchesActivePane() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        store.focusPane(pane, in: ws)
        XCTAssertEqual(ws.activePaneId, pane.id)
        store.focusPane(new, in: ws)
        XCTAssertEqual(ws.activePaneId, new.id)
    }

    func testCrossPaneMoveOfRootSoleTabKeepsWorkspaceAlive() {
        // Regression: after splitPane, the root PaneNode kept the original
        // pane's id; the wrapper for that pane (now `firstChild`) reused the
        // same id. Closing the now-empty source pane via id-equality would
        // route to closeWorkspace and terminate the freshly-moved session.
        let store = makeStore()
        let ws = store.workspaces[0]
        let original = firstPane(ws)
        let originalSession = original.tabs[0]
        let new = store.splitPane(original, orientation: .horizontal, in: ws)!
        XCTAssertEqual(ws.root.allPanes.count, 2)
        store.moveTab(originalSession, to: new, at: new.tabs.count, in: ws)
        XCTAssertFalse(store.workspaces.isEmpty)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertTrue(new.tabs.contains { $0.id == originalSession.id })
        XCTAssertEqual(engine(originalSession).terminateCount, 0)
    }

    func testCrossPaneMoveSyncsWorkspaceWorkingDirectory() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let source = firstPane(ws)
        let session = source.tabs[0]
        engine(session).emitPwd("/tmp/projectA/sub")
        let dest = store.splitPane(source, orientation: .horizontal, in: ws)!
        // splitPane spawns a new session in dest; switch active away first so
        // the move into dest is the thing that has to sync the cwd.
        store.focusPane(source, in: ws)
        store.moveTab(session, to: dest, at: dest.tabs.count, in: ws)
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA/sub")
    }

    // MARK: Persistence

    func testRestoreSinglePaneWorkspace() {
        let wsId = UUID()
        let paneId = UUID()
        let leafA = UUID()
        let leafB = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: paneId,
                        kind: .pane(PersistedPane(
                            id: paneId,
                            tabs: [
                                PersistedTab(id: leafA, agentId: "terminal", currentDirectoryPath: "/tmp/projectA"),
                                PersistedTab(id: leafB, agentId: "claude-code", currentDirectoryPath: "/tmp/projectA/sub"),
                            ],
                            activeTabId: leafB
                        ))
                    ),
                    activePaneId: paneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        XCTAssertEqual(store.workspaces.count, 1)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.id, wsId)
        XCTAssertEqual(ws.title, "projectA")
        let pane = firstPane(ws)
        XCTAssertEqual(pane.tabs.map(\.id), [leafA, leafB])
        XCTAssertEqual(pane.tabs[1].agent.id, "claude-code")
        XCTAssertEqual(pane.activeTabId, leafB)
        XCTAssertEqual(ws.activePaneId, paneId)
    }

    func testRestoreSpawnsEngineWithSavedWorkingDirectory() {
        let wsId = UUID()
        let paneId = UUID()
        let leafId = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: paneId,
                        kind: .pane(PersistedPane(
                            id: paneId,
                            tabs: [PersistedTab(id: leafId, agentId: "terminal", currentDirectoryPath: "/tmp/projectA/deep")],
                            activeTabId: leafId
                        ))
                    ),
                    activePaneId: paneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        let pane = firstPane(store.workspaces[0])
        XCTAssertEqual(engine(pane.tabs[0]).startedConfigs.last?.workingDirectory, "/tmp/projectA/deep")
    }

    func testRestoreSplitTreeReconstructsBothPanes() {
        let wsId = UUID()
        let rootId = UUID()
        let firstPaneId = UUID()
        let secondPaneId = UUID()
        let leafA = UUID()
        let leafB = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: rootId,
                        kind: .split(
                            orientation: .horizontal,
                            first: PersistedPaneNode(id: firstPaneId, kind: .pane(PersistedPane(id: firstPaneId, tabs: [PersistedTab(id: leafA, agentId: "terminal", currentDirectoryPath: "/tmp/projectA")], activeTabId: leafA))),
                            second: PersistedPaneNode(id: secondPaneId, kind: .pane(PersistedPane(id: secondPaneId, tabs: [PersistedTab(id: leafB, agentId: "terminal", currentDirectoryPath: "/tmp/projectA")], activeTabId: leafB))),
                            fraction: 0.6
                        )
                    ),
                    activePaneId: secondPaneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.root.allPanes.count, 2)
        XCTAssertEqual(ws.activePaneId, secondPaneId)
        if case .split(_, _, _, let fraction) = ws.root.content {
            XCTAssertEqual(fraction, 0.6, accuracy: 0.0001)
        } else {
            XCTFail("expected split content at root")
        }
    }

    func testFlushPersistenceWritesCurrentSnapshot() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/projectB"))
        store.flushPersistence()
        let saved = try XCTUnwrap(persistence.saved)
        XCTAssertEqual(saved.workspaces.count, 2)
        XCTAssertEqual(saved.workspaces.last?.workingDirectoryPath, "/tmp/projectB")
        XCTAssertEqual(saved.activeWorkspaceId, store.activeWorkspaceId)
    }

    func testApplyConversationIdWritesToCorrectSessionOnly() {
        // Two Claude tabs running in parallel — each gets its own conversation
        // id via separate `applyConversationId` calls, neither stomps the
        // other. Same isolation we get in prod via KOOKY_SURFACE_ID routing.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let tabA = store.addTab(in: ws, template: .claudeCode)
        let tabB = store.addTab(in: ws, template: .claudeCode)
        _ = pane

        store.applyConversationId(conversationId: "convo-a", sessionId: tabA.id)
        store.applyConversationId(conversationId: "convo-b", sessionId: tabB.id)

        XCTAssertEqual(tabA.conversationId, "convo-a")
        XCTAssertEqual(tabB.conversationId, "convo-b")
    }

    func testConversationIdSurvivesPersistenceRoundTrip() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .claudeCode)
        store.applyConversationId(conversationId: "convo-roundtrip", sessionId: tab.id)
        store.flushPersistence()

        let saved = try XCTUnwrap(persistence.saved)
        let persistedTab = saved.workspaces
            .flatMap(\.root.allTabs)
            .first { $0.id == tab.id }
        XCTAssertEqual(persistedTab?.conversationId, "convo-roundtrip")
    }

    func testReopenLastClosedTabRestoresConversationId() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .claudeCode)
        store.applyConversationId(conversationId: "convo-reopen", sessionId: tab.id)
        store.closeTab(tab, in: ws)

        let reopened = store.reopenLastClosedTab()
        XCTAssertEqual(reopened?.conversationId, "convo-reopen")
    }

    func testAddTabPropagatesInitialPromptToSpawnedEngine() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .claudeCode, initialPrompt: "explain this")
        let cfg = engine(tab).startedConfigs.last
        XCTAssertEqual(cfg?.environment["KOOKY_AGENT"], "claude -- 'explain this'")
    }

    // MARK: - Multi-window teardown

    func testTerminateReleasesEverySessionEngine() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        store.addTab(in: ws, template: .terminal)
        store.splitPane(firstPane(ws), orientation: .horizontal, in: ws)
        let engines = store.workspaces
            .flatMap { $0.root.allPanes.flatMap(\.tabs) }
            .map { engine($0) }
        XCTAssertTrue(engines.allSatisfy { $0.terminateCount == 0 })
        store.terminate()
        XCTAssertTrue(engines.allSatisfy { $0.terminateCount == 1 },
                      "terminate() must release every session's engine")
    }

    func testOnBecameEmptyFiresWhenLastWorkspaceCloses() {
        let store = makeStore()   // starts with one workspace
        var fired = 0
        store.onBecameEmpty = { fired += 1 }
        let extra = store.addWorkspace(workingDirectory: projectA)
        store.closeWorkspace(extra)
        XCTAssertEqual(fired, 0, "one workspace still open — store is not empty")
        store.closeWorkspace(store.workspaces[0])
        XCTAssertEqual(fired, 1, "closing the last workspace empties the store")
    }

    // MARK: - Cross-window tab drag

    func testHandleTabDropMovesTabBetweenPanesInSameWindow() {
        // The same-window path through `handleTabDrop` still works after the
        // cross-window branch was added.
        let store = makeStore()
        let ws = store.workspaces[0]
        let source = firstPane(ws)
        let session = source.tabs[0]
        let dest = store.splitPane(source, orientation: .horizontal, in: ws)!
        let ok = store.handleTabDrop(droppedId: session.id, to: dest, at: dest.tabs.count, in: ws)
        XCTAssertTrue(ok)
        XCTAssertTrue(dest.tabs.contains { $0 === session })
    }

    func testCrossWindowDropMovesSessionToOtherWindow() {
        let (a, b) = makeWindowPair()
        let wsA = a.workspaces[0]
        let moved = a.addTab(in: wsA, template: .claudeCode)
        let wsB = b.workspaces[0]
        let destPane = firstPane(wsB)

        let ok = b.handleTabDrop(droppedId: moved.id, to: destPane, at: destPane.tabs.count, in: wsB)

        XCTAssertTrue(ok)
        XCTAssertTrue(destPane.tabs.contains { $0 === moved }, "session now lives in window B")
        XCTAssertFalse(firstPane(wsA).tabs.contains { $0 === moved }, "session left window A")
        XCTAssertEqual(firstPane(wsA).tabs.count, 1, "window A keeps its remaining tab")
        XCTAssertEqual(engine(moved).terminateCount, 0, "the move must not terminate the engine")
    }

    func testCrossWindowDropRewiresEngineCallbacksToDestination() {
        let (a, b) = makeWindowPair()
        let wsA = a.workspaces[0]
        let moved = a.addTab(in: wsA, template: .terminal)
        let wsB = b.workspaces[0]
        b.handleTabDrop(droppedId: moved.id, to: firstPane(wsB), at: 0, in: wsB)

        // The engine's callbacks must now drive window B, not the window the
        // tab was dragged out of.
        engine(moved).emitPwd("/tmp/projectC")
        XCTAssertEqual(wsB.workingDirectory.path, "/tmp/projectC", "pwd change reaches window B")
        XCTAssertNotEqual(wsA.workingDirectory.path, "/tmp/projectC", "window A is untouched")
    }

    func testCrossWindowDropOfLastTabEmptiesSourceWindow() {
        let (a, b) = makeWindowPair()
        var aBecameEmpty = 0
        a.onBecameEmpty = { aBecameEmpty += 1 }
        let onlyTab = firstPane(a.workspaces[0]).tabs[0]
        let wsB = b.workspaces[0]

        b.handleTabDrop(droppedId: onlyTab.id, to: firstPane(wsB), at: firstPane(wsB).tabs.count, in: wsB)

        XCTAssertTrue(a.workspaces.isEmpty, "window A's last tab left — its workspace collapsed away")
        XCTAssertEqual(aBecameEmpty, 1, "store A signalled empty so its window can close")
        XCTAssertTrue(firstPane(wsB).tabs.contains { $0 === onlyTab })
        XCTAssertEqual(engine(onlyTab).terminateCount, 0, "engine survives the source window emptying")
    }

    func testHandleTabDropReturnsFalseWhenSessionExistsNowhere() {
        let (_, b) = makeWindowPair()
        let wsB = b.workspaces[0]
        XCTAssertFalse(b.handleTabDrop(droppedId: UUID(), to: firstPane(wsB), at: 0, in: wsB))
    }

    func testMoveTabToNewWindowForwardsRequestToInjectedClosure() {
        var captured: UUID?
        let store = WorkspaceStore(
            persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { true },
            moveToNewWindow: { captured = $0 }
        )
        let id = UUID()
        store.moveTabToNewWindow(id)
        XCTAssertEqual(captured, id)
    }

    func testDiscardTabDoesNotRecordToReopenHistory() {
        // `discardTab` is for synthetic tabs the user never knowingly opened
        // (e.g. the placeholder in a freshly-spawned Move-to-New-Window
        // window). It must not pollute the `⌘⇧T` reopen stack.
        let store = makeStore()
        let ws = store.workspaces[0]
        let tab = store.addTab(in: ws)
        store.discardTab(tab, in: ws)
        XCTAssertNil(store.reopenLastClosedTab(), "discardTab must not feed the reopen stack")
    }
}

private extension PersistedPaneNode {
    /// Recursive flatten used by tests to assert per-tab persisted fields
    /// without re-implementing the pane-tree walker.
    var allTabs: [PersistedTab] {
        switch kind {
        case .pane(let p): return p.tabs
        case .split(_, let a, let b, _): return a.allTabs + b.allTabs
        }
    }
}
