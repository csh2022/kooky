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
    func fill(field: String, text: String)
    func type(text: String)
    func press(key: String)
    func scroll(direction: String, amount: Double?)
}
