import AppKit
import XCTest
@testable import KookyKit

@MainActor
final class BrowserPaneLifecycleTests: XCTestCase {
    private func makeStore(
        persistence: InMemoryPersistence = InMemoryPersistence(),
        browserEngines: BrowserEnginePool = BrowserEnginePool()
    ) -> WorkspaceStore {
        WorkspaceStore(
            persistence: persistence,
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true },
            browserEngineFactory: { browserEngines.make() },
            worktreeCapabilityProbe: { _ in false }
        )
    }

    func testUserBrowserOpensAsRightSplitWithoutReplacingTerminalPane() {
        let store = makeStore()
        let workspace = try! XCTUnwrap(store.active)
        let terminalPane = try! XCTUnwrap(workspace.root.firstPane)

        let browser = store.openBrowserSplit(in: workspace)

        XCTAssertNotNil(browser)
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [terminalPane.id])
        XCTAssertEqual(workspace.root.allBrowserPanes.map(\.id), [browser?.id])
        XCTAssertEqual(workspace.activePaneId, terminalPane.id)
        guard case .split(.horizontal, let first, let second, _) = workspace.root.content else {
            return XCTFail("browser should open in a horizontal split")
        }
        XCTAssertNotNil(first.pane(id: terminalPane.id))
        XCTAssertNotNil(second.browserPane(id: try! XCTUnwrap(browser?.id)))
    }

    func testAgentBrowserReusesExistingOwnedSplitAndNavigates() {
        let engines = BrowserEnginePool()
        let store = makeStore(browserEngines: engines)
        let workspace = try! XCTUnwrap(store.active)
        let agentId = try! XCTUnwrap(workspace.activeSession?.id)

        let first = store.openBrowserSplit(address: "localhost:3000", owner: .agent(agentId), in: workspace)
        let second = store.openBrowserSplit(address: "example.com", owner: .agent(agentId), in: workspace)

        XCTAssertTrue(first === second)
        XCTAssertEqual(workspace.root.allBrowserPanes.count, 1)
        XCTAssertEqual(engines.created.count, 1)
        XCTAssertEqual(
            engines.created.first?.loadedRequests.map(\.url.absoluteString),
            ["http://localhost:3000", "https://example.com"]
        )
    }

    func testAgentBrowserSplitsNextToCallingSessionNotActivePane() {
        let store = makeStore()
        let workspace = try! XCTUnwrap(store.active)
        let leftPane = try! XCTUnwrap(workspace.root.firstPane)
        let leftSessionId = try! XCTUnwrap(leftPane.activeTab?.id)
        let rightPane = try! XCTUnwrap(store.splitPane(leftPane, orientation: .horizontal, in: workspace))
        store.activateTab(try! XCTUnwrap(rightPane.activeTab), in: workspace)

        let browser = store.openBrowserSplit(address: "example.com", owner: .agent(leftSessionId), in: workspace)

        XCTAssertNotNil(browser)
        XCTAssertEqual(workspace.activePaneId, rightPane.id, "agent browser open must not depend on the currently active UI pane")
        guard case .split(.horizontal, let first, let second, _) = workspace.root.content else {
            return XCTFail("expected root split")
        }
        XCTAssertNotNil(second.pane(id: rightPane.id), "right session should remain the root-right sibling")
        guard case .split(.horizontal, let nestedFirst, let nestedSecond, _) = first.content else {
            return XCTFail("left session should have been split with its browser")
        }
        XCTAssertNotNil(nestedFirst.pane(id: leftPane.id))
        XCTAssertNotNil(nestedSecond.browserPane(id: try! XCTUnwrap(browser?.id)))
    }

    func testApplyBrowserCommandOpensAndClosesAgentOwnedBrowser() {
        let engines = BrowserEnginePool()
        let store = makeStore(browserEngines: engines)
        let workspace = try! XCTUnwrap(store.active)
        let agentId = try! XCTUnwrap(workspace.activeSession?.id)

        store.applyBrowserCommand(.open(address: "localhost:3000"), sessionId: agentId)

        let browser = try! XCTUnwrap(workspace.root.allBrowserPanes.first)
        XCTAssertEqual(engines.created.first?.loadedRequests.map(\.url.absoluteString), ["http://localhost:3000"])

        store.applyBrowserCommand(.close, sessionId: agentId)

        XCTAssertTrue(workspace.root.allBrowserPanes.isEmpty)
        XCTAssertNil(workspace.root.browserPane(id: browser.id))
    }

    func testApplyBrowserInteractionCommandsTargetAgentOwnedBrowser() {
        let engines = BrowserEnginePool()
        let store = makeStore(browserEngines: engines)
        let workspace = try! XCTUnwrap(store.active)
        let agentId = try! XCTUnwrap(workspace.activeSession?.id)

        store.applyBrowserCommand(.open(address: "localhost:3000"), sessionId: agentId)
        let engine = try! XCTUnwrap(engines.created.first)

        store.applyBrowserCommand(.click(text: "Wikipedia"), sessionId: agentId)
        store.applyBrowserCommand(.fill(field: "Search", text: "黄梅戏"), sessionId: agentId)
        store.applyBrowserCommand(.type(text: " extra"), sessionId: agentId)
        store.applyBrowserCommand(.press(key: "Enter"), sessionId: agentId)
        store.applyBrowserCommand(.scroll(direction: "down", amount: 500), sessionId: agentId)
        store.applyBrowserCommand(.back, sessionId: agentId)
        store.applyBrowserCommand(.forward, sessionId: agentId)
        store.applyBrowserCommand(.reload, sessionId: agentId)
        store.applyBrowserCommand(.stop, sessionId: agentId)

        XCTAssertEqual(engine.clickedTexts, ["Wikipedia"])
        XCTAssertEqual(engine.fills.map(\.field), ["Search"])
        XCTAssertEqual(engine.fills.map(\.text), ["黄梅戏"])
        XCTAssertEqual(engine.typedTexts, [" extra"])
        XCTAssertEqual(engine.pressedKeys, ["Enter"])
        XCTAssertEqual(engine.scrolls.map(\.direction), ["down"])
        XCTAssertEqual(engine.scrolls.map(\.amount), [500])
        XCTAssertEqual(engine.goBackCount, 1)
        XCTAssertEqual(engine.goForwardCount, 1)
        XCTAssertEqual(engine.reloadCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testAutoCloseRemovesAgentOwnedBrowser() {
        let store = makeStore()
        let workspace = try! XCTUnwrap(store.active)
        let agentId = try! XCTUnwrap(workspace.activeSession?.id)
        let browser = try! XCTUnwrap(
            store.openBrowserSplit(address: "example.com", owner: .agent(agentId), in: workspace)
        )

        XCTAssertTrue(store.closeBrowserIfAutoOwned(browserId: browser.id, in: workspace))

        XCTAssertTrue(workspace.root.allBrowserPanes.isEmpty)
        XCTAssertEqual(workspace.root.allPanes.count, 1)
    }

    func testAutoCloseRefusesPinnedOrUserTouchedBrowser() {
        let store = makeStore()
        let workspace = try! XCTUnwrap(store.active)
        let agentId = try! XCTUnwrap(workspace.activeSession?.id)
        let pinned = try! XCTUnwrap(store.openBrowserSplit(owner: .agent(agentId), in: workspace))
        pinned.isPinned = true

        XCTAssertFalse(store.closeBrowserIfAutoOwned(browserId: pinned.id, in: workspace))
        pinned.isPinned = false
        pinned.isUserTouched = true
        XCTAssertFalse(store.closeBrowserIfAutoOwned(browserId: pinned.id, in: workspace))
        XCTAssertEqual(workspace.root.allBrowserPanes.count, 1)
    }

    func testPersistenceCollapsesRuntimeBrowserLeaves() {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence: persistence)
        let workspace = try! XCTUnwrap(store.active)
        _ = store.openBrowserSplit(in: workspace)

        store.flushPersistence()

        let persistedWorkspace = try! XCTUnwrap(persistence.saved?.workspaces.first)
        guard case .pane = persistedWorkspace.root.kind else {
            return XCTFail("browser leaf should not be persisted")
        }
    }
}

@MainActor
private final class BrowserEnginePool {
    private(set) var created: [TestBrowserEngineForPane] = []

    func make() -> TestBrowserEngineForPane {
        let engine = TestBrowserEngineForPane()
        created.append(engine)
        return engine
    }
}

@MainActor
private final class TestBrowserEngineForPane: BrowserEngine {
    let view: NSView = NSView()
    var snapshot: BrowserEngineSnapshot = .empty
    var onSnapshotChange: ((BrowserEngineSnapshot) -> Void)?
    var loadedRequests: [BrowserLoadRequest] = []
    var clickedTexts: [String] = []
    var fills: [(field: String, text: String)] = []
    var typedTexts: [String] = []
    var pressedKeys: [String] = []
    var scrolls: [(direction: String, amount: Double?)] = []
    var reloadCount = 0
    var stopCount = 0
    var goBackCount = 0
    var goForwardCount = 0

    func load(_ request: BrowserLoadRequest) {
        loadedRequests.append(request)
    }

    func reload() { reloadCount += 1 }
    func stopLoading() { stopCount += 1 }
    func goBack() { goBackCount += 1 }
    func goForward() { goForwardCount += 1 }
    func click(text: String) { clickedTexts.append(text) }
    func fill(field: String, text: String) { fills.append((field, text)) }
    func type(text: String) { typedTexts.append(text) }
    func press(key: String) { pressedKeys.append(key) }
    func scroll(direction: String, amount: Double?) { scrolls.append((direction, amount)) }
}
