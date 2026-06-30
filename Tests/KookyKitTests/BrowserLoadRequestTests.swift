import XCTest
@testable import KookyKit

final class BrowserLoadRequestTests: XCTestCase {
    func testKeepsExplicitHTTPSURL() {
        let request = BrowserLoadRequest("https://example.com/path?q=1")
        XCTAssertEqual(request?.url.absoluteString, "https://example.com/path?q=1")
    }

    func testAddsHTTPSForHostLikeInput() {
        let request = BrowserLoadRequest("example.com")
        XCTAssertEqual(request?.url.absoluteString, "https://example.com")
    }

    func testSupportsLocalhostWithPort() {
        let request = BrowserLoadRequest("localhost:3000")
        XCTAssertEqual(request?.url.absoluteString, "http://localhost:3000")
    }

    func testTurnsPlainTextIntoSearchURL() {
        let request = BrowserLoadRequest("swift webkit docs")
        XCTAssertEqual(request?.url.scheme, "https")
        XCTAssertEqual(request?.url.host, "www.google.com")
        XCTAssertEqual(request?.url.path, "/search")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value,
            "swift webkit docs"
        )
    }

    func testRejectsBlankInput() {
        XCTAssertNil(BrowserLoadRequest("  \n\t  "))
    }
}
