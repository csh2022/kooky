import XCTest
@testable import KookyKit

final class KookyDragPayloadTests: XCTestCase {
    func testTabPayloadRoundTripsAndRejectsWorkspaceLookup() {
        let id = UUID()
        let encoded = KookyDragPayload.tab(id).encoded

        XCTAssertEqual(KookyDragPayload.tabId(from: encoded), id)
        XCTAssertNil(KookyDragPayload.workspaceId(from: encoded))
        XCTAssertEqual(KookyDragPayload(encoded: encoded), .tab(id))
    }

    func testWorkspacePayloadRoundTripsAndRejectsTabLookup() {
        let id = UUID()
        let encoded = KookyDragPayload.workspace(id).encoded

        XCTAssertEqual(KookyDragPayload.workspaceId(from: encoded), id)
        XCTAssertNil(KookyDragPayload.tabId(from: encoded))
        XCTAssertEqual(KookyDragPayload(encoded: encoded), .workspace(id))
    }

    func testBareUuidPayloadIsRejected() {
        XCTAssertNil(KookyDragPayload(encoded: UUID().uuidString))
    }
}
