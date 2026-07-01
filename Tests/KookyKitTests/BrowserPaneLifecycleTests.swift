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

    func testApplyBrowserCommandOpensAndClosesAgentOwnedBrowser() async {
        let engines = BrowserEnginePool()
        let store = makeStore(browserEngines: engines)
        let workspace = try! XCTUnwrap(store.active)
        let agentId = try! XCTUnwrap(workspace.activeSession?.id)

        await store.applyBrowserCommand(.open(address: "localhost:3000"), sessionId: agentId)

        let browser = try! XCTUnwrap(workspace.root.allBrowserPanes.first)
        XCTAssertEqual(engines.created.first?.loadedRequests.map(\.url.absoluteString), ["http://localhost:3000"])

        await store.applyBrowserCommand(.close, sessionId: agentId)

        XCTAssertTrue(workspace.root.allBrowserPanes.isEmpty)
        XCTAssertNil(workspace.root.browserPane(id: browser.id))
    }

    func testApplyBrowserInteractionCommandsTargetAgentOwnedBrowser() async {
        let engines = BrowserEnginePool()
        let store = makeStore(browserEngines: engines)
        let workspace = try! XCTUnwrap(store.active)
        let agentId = try! XCTUnwrap(workspace.activeSession?.id)

        await store.applyBrowserCommand(.open(address: "localhost:3000"), sessionId: agentId)
        let engine = try! XCTUnwrap(engines.created.first)

        await store.applyBrowserCommand(.click(text: "Wikipedia"), sessionId: agentId)
        await store.applyBrowserCommand(.clickId(id: "e1-button", double: true), sessionId: agentId)
        await store.applyBrowserCommand(.clickAt(x: 12, y: 34), sessionId: agentId)
        await store.applyBrowserCommand(.fill(field: "Search", text: "黄梅戏"), sessionId: agentId)
        await store.applyBrowserCommand(.fillId(id: "e2-input", text: "query"), sessionId: agentId)
        await store.applyBrowserCommand(.clear(field: "Search"), sessionId: agentId)
        await store.applyBrowserCommand(.type(text: " extra"), sessionId: agentId)
        await store.applyBrowserCommand(.paste(text: " paste"), sessionId: agentId)
        await store.applyBrowserCommand(.press(key: "Enter"), sessionId: agentId)
        await store.applyBrowserCommand(.hotkey(combo: "Meta+R"), sessionId: agentId)
        await store.applyBrowserCommand(.scroll(direction: "down", amount: 500), sessionId: agentId)
        await store.applyBrowserCommand(.hover(id: "e3-a"), sessionId: agentId)
        await store.applyBrowserCommand(.wait(text: "Loaded", timeoutMilliseconds: 10), sessionId: agentId)
        await store.applyBrowserCommand(.waitURL(text: "q=Loaded", timeoutMilliseconds: 10), sessionId: agentId)
        await store.applyBrowserCommand(.waitTitle(text: "Loaded - Search", timeoutMilliseconds: 10), sessionId: agentId)
        await store.applyBrowserCommand(.back, sessionId: agentId)
        await store.applyBrowserCommand(.forward, sessionId: agentId)
        await store.applyBrowserCommand(.reload, sessionId: agentId)
        await store.applyBrowserCommand(.stop, sessionId: agentId)

        XCTAssertEqual(engine.clickedTexts, ["Wikipedia"])
        XCTAssertEqual(engine.clickedIds.map(\.id), ["e1-button"])
        XCTAssertEqual(engine.clickedIds.map(\.double), [true])
        XCTAssertEqual(engine.clickPoints.map(\.x), [12])
        XCTAssertEqual(engine.clickPoints.map(\.y), [34])
        XCTAssertEqual(engine.fills.map(\.field), ["Search"])
        XCTAssertEqual(engine.fills.map(\.text), ["黄梅戏"])
        XCTAssertEqual(engine.fillIds.map(\.id), ["e2-input"])
        XCTAssertEqual(engine.fillIds.map(\.text), ["query"])
        XCTAssertEqual(engine.clears, ["Search"])
        XCTAssertEqual(engine.typedTexts, [" extra"])
        XCTAssertEqual(engine.pastedTexts, [" paste"])
        XCTAssertEqual(engine.pressedKeys, ["Enter"])
        XCTAssertEqual(engine.hotkeys, ["Meta+R"])
        XCTAssertEqual(engine.scrolls.map(\.direction), ["down"])
        XCTAssertEqual(engine.scrolls.map(\.amount), [500])
        XCTAssertEqual(engine.hoveredIds, ["e3-a"])
        XCTAssertEqual(engine.waits.map(\.text), ["Loaded", "q=Loaded", "Loaded - Search"])
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
    var clickedIds: [(id: String, double: Bool)] = []
    var clickPoints: [(x: Double, y: Double)] = []
    var fills: [(field: String, text: String)] = []
    var fillIds: [(id: String, text: String)] = []
    var clears: [String?] = []
    var typedTexts: [String] = []
    var pastedTexts: [String] = []
    var pressedKeys: [String] = []
    var hotkeys: [String] = []
    var scrolls: [(direction: String, amount: Double?)] = []
    var hoveredIds: [String] = []
    var waits: [(text: String, timeout: Int)] = []
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
    func clickElement(id: String, double: Bool) async -> String {
        clickedIds.append((id, double))
        return "ok clicked id: \(id)\n"
    }
    func clickAt(x: Double, y: Double) async -> String {
        clickPoints.append((x, y))
        return "ok clicked at: \(x),\(y)\n"
    }
    func fill(field: String, text: String) async -> String {
        fills.append((field, text))
        return "ok filled field: \(field)\n"
    }
    func fillElement(id: String, text: String) async -> String {
        fillIds.append((id, text))
        return "ok filled id: \(id)\n"
    }
    func clear(field: String?) async -> String {
        clears.append(field)
        return "ok cleared\n"
    }
    func type(text: String) { typedTexts.append(text) }
    func paste(text: String) { pastedTexts.append(text) }
    func press(key: String) async -> String {
        pressedKeys.append(key)
        return "ok pressed key: \(key)\n"
    }
    func hotkey(_ combo: String) { hotkeys.append(combo) }
    func scroll(direction: String, amount: Double?) async -> String {
        scrolls.append((direction, amount))
        return "ok scrolled \(direction)\n"
    }
    func hover(id: String) async -> String {
        hoveredIds.append(id)
        return "ok hovered id: \(id)\n"
    }
    func waitForText(_ text: String, timeoutMilliseconds: Int) async -> String {
        waits.append((text, timeoutMilliseconds))
        return "ok found text: \(text)\n"
    }
    func waitForURL(_ text: String, timeoutMilliseconds: Int) async -> String {
        waits.append((text, timeoutMilliseconds))
        return "ok found url: \(text)\n"
    }
    func waitForTitle(_ text: String, timeoutMilliseconds: Int) async -> String {
        waits.append((text, timeoutMilliseconds))
        return "ok found title: \(text)\n"
    }
    func pageText() async -> String { "page text\n" }
    func pageHTML() async -> String { "<html></html>\n" }
    func linksJSONLines() async -> String { #"{"id":"e1-a","text":"Home","href":"https://example.com"}"# + "\n" }
    func elementsJSONLines() async -> String { #"{"id":"e2-button","role":"button","text":"Go"}"# + "\n" }
    func pageSnapshot() async -> String { "snapshot\n" }
    func saveScreenshot(to path: String?) async -> String { (path ?? "/tmp/kooky-browser-test.png") + "\n" }
}
