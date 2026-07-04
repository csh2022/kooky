import XCTest
@testable import KookyKit

final class ChromiumBrowserObservedHistoryTests: XCTestCase {
    func testBackAndForwardTargetsUseObservedStableURLs() {
        var history = ChromiumBrowserObservedHistory()

        history.observe("https://www.google.com/search?q=gamma")
        history.observe("https://www.google.com/search?q=clean")
        history.observe("https://www.google.com/search?q=clean&udm=2")

        XCTAssertEqual(history.backTarget()?.url, "https://www.google.com/search?q=clean")

        history.move(to: history.backTarget()!.index)

        XCTAssertEqual(history.forwardTarget()?.url, "https://www.google.com/search?q=clean&udm=2")
    }

    func testNewObservationTruncatesForwardHistory() {
        var history = ChromiumBrowserObservedHistory()

        history.observe("https://example.com/a")
        history.observe("https://example.com/b")
        history.observe("https://example.com/c")
        history.move(to: history.backTarget()!.index)
        history.observe("https://example.com/d")

        XCTAssertEqual(history.urls, [
            "https://example.com/a",
            "https://example.com/b",
            "https://example.com/d",
        ])
        XCTAssertNil(history.forwardTarget())
    }

    func testObservingCurrentURLBeforeBackPreservesForwardTarget() {
        var history = ChromiumBrowserObservedHistory()

        history.observe("https://www.google.com/search?q=gamma")
        history.observe("https://www.google.com/search?q=clean")
        // Mirrors ChromiumBrowserEngine.goBack recording the current page just
        // before choosing a target when a navigation callback missed it.
        history.observe("https://www.google.com/search?q=clean&udm=2")

        let backTarget = history.backTarget()!
        history.move(to: backTarget.index)

        XCTAssertEqual(backTarget.url, "https://www.google.com/search?q=clean")
        XCTAssertEqual(history.forwardTarget()?.url, "https://www.google.com/search?q=clean&udm=2")
    }

    func testReplacingPendingTargetURLPreservesForwardTail() {
        var history = ChromiumBrowserObservedHistory()

        history.observe("https://www.google.com/search?q=clean")
        history.observe("https://www.google.com/search?q=clean&udm=2")
        let target = history.backTarget()!

        history.move(to: target.index)
        history.replaceCurrentURL(with: "https://www.google.com/search?q=clean&sca_esv=canonical")

        XCTAssertEqual(history.currentURL, "https://www.google.com/search?q=clean&sca_esv=canonical")
        XCTAssertEqual(history.forwardTarget()?.url, "https://www.google.com/search?q=clean&udm=2")
    }

    func testBackLandingPreservesForwardTailWhenObservedPendingWasMissed() {
        var history = ChromiumBrowserObservedHistory()

        history.observe("https://www.google.com/search?q=gamma&ei=original")
        history.observe("https://www.google.com/search?q=gamma&udm=2&dpr=2")

        history.recordBackLanding(
            "https://www.google.com/search?q=gamma&ei=canonical",
            forwardURL: "https://www.google.com/search?q=gamma&udm=2&dpr=2"
        )

        XCTAssertEqual(history.currentURL, "https://www.google.com/search?q=gamma&ei=canonical")
        XCTAssertEqual(history.forwardTarget()?.url, "https://www.google.com/search?q=gamma&udm=2&dpr=2")
    }
}
