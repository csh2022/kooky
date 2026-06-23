import XCTest
@testable import KookyKit

@MainActor
final class StatusBarItemKindTests: XCTestCase {
    private func makeSession() -> Session {
        Session(engine: TestEngine(), currentDirectory: URL(fileURLWithPath: "/tmp"), agent: .terminal)
    }

    private func withDefaultStatusBarSettings(_ body: (KookySettingsModel) -> Void) {
        let model = KookySettingsModel.shared
        let savedItems = model.statusBarItems
        let savedHidden = model.hiddenStatusBarItems
        let savedHiddenToolCallAgents = model.hiddenToolCallAgents
        defer {
            model.statusBarItems = savedItems
            model.hiddenStatusBarItems = savedHidden
            model.hiddenToolCallAgents = savedHiddenToolCallAgents
        }
        model.statusBarItems = StatusBarItemKind.defaultOrder
        model.hiddenStatusBarItems = []
        model.hiddenToolCallAgents = []
        body(model)
    }

    func testDefaultOrderCoversAllCases() {
        // If a new case is added and someone forgets to drop it into
        // `defaultOrder`, users who haven't customised Settings → Status
        // Bar would silently miss the new slot. This guard catches that
        // at test time.
        XCTAssertEqual(
            Set(StatusBarItemKind.defaultOrder),
            Set(StatusBarItemKind.allCases)
        )
        XCTAssertEqual(StatusBarItemKind.defaultOrder.count, StatusBarItemKind.allCases.count)
    }

    func testRawValuesAreStable() {
        // `rawValue` is persisted in settings.json — renaming a case
        // silently invalidates every user's saved configuration. Pin the
        // mapping so renames force an explicit test update.
        XCTAssertEqual(StatusBarItemKind.promptComposer.rawValue, "prompt-composer")
        XCTAssertEqual(StatusBarItemKind.toolCallActivity.rawValue, "tool-call-activity")
        XCTAssertEqual(StatusBarItemKind.pythonVenv.rawValue, "python-venv")
        XCTAssertEqual(StatusBarItemKind.nodeVersion.rawValue, "node-version")
        XCTAssertEqual(StatusBarItemKind.proxy.rawValue, "proxy")
        XCTAssertEqual(StatusBarItemKind.remoteLogin.rawValue, "remote-login")
        XCTAssertEqual(StatusBarItemKind.gitBranch.rawValue, "git-branch")
        XCTAssertEqual(StatusBarItemKind.gitDiff.rawValue, "git-diff")
    }

    func testPromptComposerKeepsStatusBarVisibleByDefault() {
        withDefaultStatusBarSettings { _ in
            XCTAssertTrue(showPromptComposerControl())
            XCTAssertTrue(paneStatusBarHasData(session: makeSession()))
        }
    }

    func testHidingEveryStatusBarItemReclaimsEmptyStatusBar() {
        withDefaultStatusBarSettings { model in
            model.hiddenStatusBarItems = Set(StatusBarItemKind.allCases)

            XCTAssertFalse(showPromptComposerControl())
            XCTAssertFalse(paneStatusBarHasData(session: makeSession()))
        }
    }

    func testStatusDataStillShowsWhenPromptComposerIsHidden() {
        withDefaultStatusBarSettings { model in
            model.hiddenStatusBarItems = [.promptComposer]
            let session = makeSession()
            session.gitStatus = GitStatus(branch: "dev", filesChanged: 0, insertions: 0, deletions: 0)

            XCTAssertFalse(showPromptComposerControl())
            XCTAssertTrue(paneStatusBarHasData(session: session))
        }
    }
}
