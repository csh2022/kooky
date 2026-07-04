import XCTest
@testable import KookyKit

@MainActor
final class BrowserEngineProviderTests: XCTestCase {
    func testDefaultProviderUsesChromiumWhenEnvironmentIsUnset() {
        let provider = BrowserEngineProvider.defaultProvider(environment: [:])

        XCTAssertEqual(provider.kind, .chromium)
    }

    func testDefaultProviderAcceptsChromiumAndCefAliases() {
        XCTAssertEqual(
            BrowserEngineProvider.defaultProvider(environment: ["KOOKY_BROWSER_ENGINE": "chromium"]).kind,
            .chromium
        )
        XCTAssertEqual(
            BrowserEngineProvider.defaultProvider(environment: ["KOOKY_BROWSER_ENGINE": "cef"]).kind,
            .chromium
        )
    }

    func testDefaultProviderFallsBackToChromiumForUnknownValues() {
        let provider = BrowserEngineProvider.defaultProvider(environment: ["KOOKY_BROWSER_ENGINE": "unknown"])

        XCTAssertEqual(provider.kind, .chromium)
    }

    func testChromiumSelectionCreatesExplicitUnavailableEngineUntilCefIsBundled() {
        let engine = BrowserEngineProvider(kind: .chromium).makeEngine()

        XCTAssertTrue(engine is UnsupportedChromiumBrowserEngine)
        XCTAssertEqual(engine.snapshot.title, "Chromium Unavailable")
        XCTAssertTrue(engine.snapshot.errorMessage?.contains("Chromium browser engine is not available.") == true)
    }
}
