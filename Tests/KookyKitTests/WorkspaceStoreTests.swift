import XCTest
@testable import KookyKit

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/tmp/projectA")
    private let projectB = URL(fileURLWithPath: "/tmp/projectB")
    private let projectC = URL(fileURLWithPath: "/tmp/projectC")

    override func setUp() {
        super.setUp()
        // Restore-side cwd-existence check (in WorkspaceStore.restore) needs
        // these directories to actually be present, otherwise the engine is
        // spawned in $HOME and the assertion fails.
        let fm = FileManager.default
        for path in ["/tmp/projectA", "/tmp/projectA/sub", "/tmp/projectA/deep", "/tmp/projectB", "/tmp/projectC"] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private func makeStore(initial: PersistedState? = nil) -> WorkspaceStore {
        WorkspaceStore(
            persistence: InMemoryPersistence(initial: initial),
            engineFactory: { TestEngine() }
        )
    }

    func testInitialStateHasOneWorkspaceWithOneTab() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces.first?.tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, store.workspaces.first?.id)
    }

    func testFirstWorkspaceUsesHomeDirectory() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.first?.workingDirectory.path, NSHomeDirectory())
        XCTAssertEqual(store.workspaces.first?.title, "Home")
    }

    func testAddWorkspaceCreatesAdditionalWorkspaceWithTabAndActivatesIt() {
        let store = makeStore()
        let first = store.workspaces[0]
        let second = store.addWorkspace(workingDirectory: projectA)
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(second.tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, second.id)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testAddWorkspaceTitleDefaultsToLastPathComponent() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/sample-project"))
        XCTAssertEqual(ws.title, "sample-project")
    }

    func testAddTabPropagatesWorkspaceWorkingDirectory() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = store.addTab(in: ws, template: .terminal)
        let engine = session.engine as? TestEngine
        XCTAssertEqual(engine?.startedConfigs.last?.workingDirectory, projectA.path)
    }

    func testActiveTabPwdReportSyncsToWorkspace() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = ws.tabs[0]
        (tab.engine as! TestEngine).emitPwd("/tmp/projectA/sub")
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA/sub")
    }

    func testNewTabInheritsLatestPwdFromActiveTab() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        (ws.tabs[0].engine as! TestEngine).emitPwd("/tmp/projectA/sub")
        let session = store.addTab(in: ws, template: .terminal)
        let engine = session.engine as? TestEngine
        XCTAssertEqual(engine?.startedConfigs.last?.workingDirectory, "/tmp/projectA/sub")
    }

    func testAddTabRespectsTemplateAndStartsEngine() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode)
        XCTAssertEqual(session.agent.id, "claude-code")
        XCTAssertEqual(ws.activeTabId, session.id)
        let engine = session.engine as? TestEngine
        XCTAssertEqual(engine?.startedConfigs.first?.environment["KOOKY_AGENT"], "claude")
    }

    func testClosingActiveTabActivatesNeighborAndTerminatesEngine() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let firstTab = ws.tabs[0]
        let secondTab = store.addTab(in: ws)
        XCTAssertEqual(ws.activeTabId, secondTab.id)
        store.closeTab(secondTab, in: ws)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.activeTabId, firstTab.id)
        XCTAssertEqual((secondTab.engine as? TestEngine)?.terminateCount, 1)
    }

    func testClosingLastTabClosesWorkspace() {
        let store = makeStore()
        let ws = store.workspaces[0]
        store.closeTab(ws.tabs[0], in: ws)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    func testClosingMiddleWorkspaceActivatesNextNeighbor() {
        let store = makeStore()
        let a = store.workspaces[0]
        let b = store.addWorkspace(workingDirectory: projectB)
        let c = store.addWorkspace(workingDirectory: projectC)
        store.activateWorkspace(b)
        XCTAssertEqual(store.activeWorkspaceId, b.id)
        store.closeWorkspace(b)
        XCTAssertEqual(store.workspaces.map(\.id), [a.id, c.id])
        XCTAssertEqual(store.activeWorkspaceId, c.id)
    }

    func testClosingLastWorkspaceClearsActiveId() {
        let store = makeStore()
        let ws = store.workspaces[0]
        store.closeWorkspace(ws)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    // MARK: Persistence

    func testRestoreFromPersistedStateRebuildsWorkspacesAndTabs() {
        let wsId = UUID()
        let tab1 = UUID()
        let tab2 = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    title: "kookycode",
                    workingDirectoryPath: "/tmp/projectA",
                    tabs: [
                        PersistedTab(id: tab1, agentId: "terminal", currentDirectoryPath: "/tmp/projectA"),
                        PersistedTab(id: tab2, agentId: "claude-code", currentDirectoryPath: "/tmp/projectA/sub"),
                    ],
                    activeTabId: tab2
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        XCTAssertEqual(store.workspaces.count, 1)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.id, wsId)
        XCTAssertEqual(ws.title, "kookycode")
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA")
        XCTAssertEqual(ws.tabs.map(\.id), [tab1, tab2])
        XCTAssertEqual(ws.tabs[1].agent.id, "claude-code")
        XCTAssertEqual(ws.activeTabId, tab2)
        XCTAssertEqual(store.activeWorkspaceId, wsId)
    }

    func testRestoreSpawnsEngineWithSavedWorkingDirectory() {
        let wsId = UUID()
        let tabId = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    title: "x",
                    workingDirectoryPath: "/tmp/projectA",
                    tabs: [PersistedTab(id: tabId, agentId: "terminal", currentDirectoryPath: "/tmp/projectA/deep")],
                    activeTabId: tabId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        let engine = store.workspaces[0].tabs[0].engine as? TestEngine
        XCTAssertEqual(engine?.startedConfigs.last?.workingDirectory, "/tmp/projectA/deep")
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
}
