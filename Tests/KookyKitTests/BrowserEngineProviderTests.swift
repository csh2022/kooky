import XCTest
@testable import KookyKit

@MainActor
final class BrowserEngineProviderTests: XCTestCase {
    func testDefaultProviderUsesWebKitWhenEnvironmentIsUnset() {
        let provider = BrowserEngineProvider.defaultProvider(environment: [:])

        XCTAssertEqual(provider.kind, .webKit)
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

    func testDefaultProviderFallsBackToWebKitForUnknownValues() {
        let provider = BrowserEngineProvider.defaultProvider(environment: ["KOOKY_BROWSER_ENGINE": "unknown"])

        XCTAssertEqual(provider.kind, .webKit)
    }

    func testChromiumSelectionCreatesExplicitUnavailableEngineUntilCefIsBundled() {
        let engine = BrowserEngineProvider(kind: .chromium).makeEngine()

        XCTAssertTrue(engine is UnsupportedChromiumBrowserEngine)
        XCTAssertEqual(engine.snapshot.title, "Chromium Unavailable")
        XCTAssertEqual(engine.snapshot.errorMessage, "Chromium browser engine is not bundled in this build.")
    }
}
