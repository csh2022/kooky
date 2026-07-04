import XCTest
@testable import KookyKit

@MainActor
final class BrowserCommandJavaScriptTests: XCTestCase {
    func testElementIdLookupRejectsStaleTagMismatches() {
        let script = WebKitBrowserEngine.domUtilityJavaScript()

        XCTAssertTrue(script.contains(#"^e(\d+)-([a-z0-9-]+)$"#))
        XCTAssertTrue(script.contains("candidate.tagName"))
        XCTAssertFalse(script.contains("window.__kookyElementById = window.__kookyElementById ||"))
    }

    func testElementInteractionCommandsRequireVisibleCurrentTarget() {
        XCTAssertTrue(WebKitBrowserEngine.clickElementJavaScript(id: "e1-button", double: false).contains("__kookyVisible(target)"))
        XCTAssertTrue(WebKitBrowserEngine.fillElementJavaScript(id: "e2-input", text: "query").contains("__kookyVisible(target)"))
        XCTAssertTrue(WebKitBrowserEngine.hoverJavaScript(id: "e3-a").contains("__kookyVisible(target)"))
    }

    func testScrollReportsNoMovementReason() {
        let script = WebKitBrowserEngine.scrollJavaScript(direction: "down", amount: 500)

        XCTAssertTrue(script.contains("no scroll movement down"))
        XCTAssertTrue(script.contains("'reason: ' + reason"))
        XCTAssertTrue(script.contains("already at bottom edge"))
    }
}
