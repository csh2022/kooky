import AppKit
import XCTest
@testable import KookyKit

@MainActor
final class BrowserSurfaceTests: XCTestCase {
    func testLoadAddressTextDelegatesToEngineAndMirrorsDisplayURL() throws {
        let engine = TestBrowserEngine()
        let surface = BrowserSurface(engine: engine)

        surface.addressText = "localhost:5173"
        surface.loadAddressText()

        XCTAssertEqual(engine.loadedRequests.map(\.url.absoluteString), ["http://localhost:5173"])
        XCTAssertEqual(surface.addressText, "http://localhost:5173")
    }

    func testSnapshotChangesUpdateSurfaceState() {
        let engine = TestBrowserEngine()
        let surface = BrowserSurface(engine: engine)

        engine.publish(BrowserEngineSnapshot(
            title: "Docs",
            urlString: "https://example.com/docs",
            canGoBack: true,
            canGoForward: false,
            isLoading: false,
            errorMessage: nil
        ))

        XCTAssertEqual(surface.title, "Docs")
        XCTAssertEqual(surface.addressText, "https://example.com/docs")
        XCTAssertTrue(surface.snapshot.canGoBack)
    }
}

@MainActor
private final class TestBrowserEngine: BrowserEngine {
    let view: NSView = NSView()
    var snapshot: BrowserEngineSnapshot = .empty
    var onSnapshotChange: ((BrowserEngineSnapshot) -> Void)?
    var loadedRequests: [BrowserLoadRequest] = []

    func load(_ request: BrowserLoadRequest) {
        loadedRequests.append(request)
    }

    func reload() {}
    func stopLoading() {}
    func goBack() {}
    func goForward() {}
    func click(text: String) {}
    func fill(field: String, text: String) {}
    func type(text: String) {}
    func press(key: String) {}
    func scroll(direction: String, amount: Double?) {}

    func publish(_ snapshot: BrowserEngineSnapshot) {
        self.snapshot = snapshot
        onSnapshotChange?(snapshot)
    }
}
