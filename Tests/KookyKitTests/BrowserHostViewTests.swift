import AppKit
import XCTest
@testable import KookyKit

@MainActor
final class BrowserHostViewTests: XCTestCase {
    func testAttachNotifiesEngineWhenViewMovesBetweenHosts() {
        let engine = HostRefreshBrowserEngine()
        let firstHost = BrowserHostNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let secondHost = BrowserHostNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))

        firstHost.attach(engine: engine)
        XCTAssertEqual(engine.hostAttachmentRefreshCount, 1)
        XCTAssertTrue(engine.view.superview === firstHost)

        secondHost.attach(engine: engine)

        XCTAssertEqual(engine.hostAttachmentRefreshCount, 2)
        XCTAssertTrue(engine.view.superview === secondHost)
        XCTAssertFalse(engine.view.isHidden)
    }
}

@MainActor
private final class HostRefreshBrowserEngine: BrowserEngine {
    let view: NSView = NSView()
    var snapshot: BrowserEngineSnapshot = .empty
    var onSnapshotChange: ((BrowserEngineSnapshot) -> Void)?
    var hostAttachmentRefreshCount = 0

    func browserHostViewDidAttach() {
        hostAttachmentRefreshCount += 1
    }

    func load(_ request: BrowserLoadRequest) {}
    func reload() {}
    func stopLoading() {}
    func goBack() {}
    func goForward() {}
    func click(text: String) {}
    func clickElement(id: String, double: Bool) async -> String { "" }
    func clickAt(x: Double, y: Double) async -> String { "" }
    func fill(field: String, text: String) async -> String { "" }
    func fillElement(id: String, text: String) async -> String { "" }
    func clear(field: String?) async -> String { "" }
    func type(text: String) {}
    func paste(text: String) {}
    func press(key: String) async -> String { "" }
    func hotkey(_ combo: String) {}
    func scroll(direction: String, amount: Double?) async -> String { "" }
    func hover(id: String) async -> String { "" }
    func waitForText(_ text: String, timeoutMilliseconds: Int) async -> String { "" }
    func waitForURL(_ text: String, timeoutMilliseconds: Int) async -> String { "" }
    func waitForTitle(_ text: String, timeoutMilliseconds: Int) async -> String { "" }
    func pageText() async -> String { "" }
    func pageHTML() async -> String { "" }
    func linksJSONLines() async -> String { "" }
    func elementsJSONLines() async -> String { "" }
    func pageSnapshot() async -> String { "" }
    func saveScreenshot(to path: String?) async -> String { "" }
    func credentialForm() async -> BrowserCredentialForm? { nil }
    func fillCredential(_ credential: BrowserCredential) async -> String { "" }
}
