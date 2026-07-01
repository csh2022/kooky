import AppKit
import Foundation

struct BrowserEngineSnapshot: Equatable {
    var title: String
    var urlString: String
    var canGoBack: Bool
    var canGoForward: Bool
    var isLoading: Bool
    var errorMessage: String?

    static let empty = BrowserEngineSnapshot(
        title: "Browser",
        urlString: "",
        canGoBack: false,
        canGoForward: false,
        isLoading: false,
        errorMessage: nil
    )
}

@MainActor
protocol BrowserEngine: AnyObject {
    var view: NSView { get }
    var snapshot: BrowserEngineSnapshot { get }
    var onSnapshotChange: ((BrowserEngineSnapshot) -> Void)? { get set }

    func load(_ request: BrowserLoadRequest)
    func reload()
    func stopLoading()
    func goBack()
    func goForward()
    func click(text: String)
    func clickElement(id: String, double: Bool) async -> String
    func clickAt(x: Double, y: Double) async -> String
    func fill(field: String, text: String) async -> String
    func fillElement(id: String, text: String) async -> String
    func clear(field: String?) async -> String
    func type(text: String)
    func paste(text: String)
    func press(key: String) async -> String
    func hotkey(_ combo: String)
    func scroll(direction: String, amount: Double?) async -> String
    func hover(id: String) async -> String
    func waitForText(_ text: String, timeoutMilliseconds: Int) async -> String
    func waitForURL(_ text: String, timeoutMilliseconds: Int) async -> String
    func waitForTitle(_ text: String, timeoutMilliseconds: Int) async -> String
    func pageText() async -> String
    func pageHTML() async -> String
    func linksJSONLines() async -> String
    func elementsJSONLines() async -> String
    func pageSnapshot() async -> String
    func saveScreenshot(to path: String?) async -> String
    func credentialForm() async -> BrowserCredentialForm?
    func fillCredential(_ credential: BrowserCredential) async -> String
}
