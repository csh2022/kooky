import AppKit
import Foundation

enum BrowserEngineKind: Equatable {
    case webKit
    case chromium

    init?(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "webkit", "wkwebview":
            self = .webKit
        case "chromium", "cef":
            self = .chromium
        default:
            return nil
        }
    }
}

struct BrowserEngineProvider: Equatable {
    var kind: BrowserEngineKind

    static func defaultProvider(environment: [String: String] = ProcessInfo.processInfo.environment) -> BrowserEngineProvider {
        let rawKind = environment["KOOKY_BROWSER_ENGINE"] ?? ""
        return BrowserEngineProvider(kind: BrowserEngineKind(rawValue: rawKind) ?? .chromium)
    }

    @MainActor
    func makeEngine() -> any BrowserEngine {
        switch kind {
        case .webKit:
            return WebKitBrowserEngine()
        case .chromium:
            let runtime = ChromiumBrowserRuntime.bundledRuntime()
            if case .unavailable(let missing) = runtime.status() {
                return UnsupportedChromiumBrowserEngine(missingRequirements: missing)
            }
            do {
                return try ChromiumBrowserEngine(runtime: runtime)
            } catch {
                return UnsupportedChromiumBrowserEngine(missingRequirements: [error.localizedDescription])
            }
        }
    }
}

@MainActor
final class UnsupportedChromiumBrowserEngine: BrowserEngine {
    let view: NSView
    var onSnapshotChange: ((BrowserEngineSnapshot) -> Void)?

    private var currentURLString = ""
    private let message: String

    init(missingRequirements: [String] = ["Chromium browser engine"]) {
        let labels = missingRequirements.joined(separator: ", ")
        self.message = "Chromium browser engine is not available. Missing: \(labels)."
        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)

        let container = NSView(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        self.view = container
    }

    var snapshot: BrowserEngineSnapshot {
        BrowserEngineSnapshot(
            title: "Chromium Unavailable",
            urlString: currentURLString,
            canGoBack: false,
            canGoForward: false,
            isLoading: false,
            errorMessage: message
        )
    }

    func load(_ request: BrowserLoadRequest) {
        currentURLString = request.url.absoluteString
        publish()
    }

    func reload() { publish() }
    func stopLoading() { publish() }
    func goBack() {}
    func goForward() {}
    func click(text: String) {}
    func clickElement(id: String, double: Bool) async -> String { unavailable() }
    func clickAt(x: Double, y: Double) async -> String { unavailable() }
    func fill(field: String, text: String) async -> String { unavailable() }
    func fillElement(id: String, text: String) async -> String { unavailable() }
    func clear(field: String?) async -> String { unavailable() }
    func type(text: String) {}
    func paste(text: String) {}
    func press(key: String) async -> String { unavailable() }
    func hotkey(_ combo: String) {}
    func scroll(direction: String, amount: Double?) async -> String { unavailable() }
    func hover(id: String) async -> String { unavailable() }
    func waitForText(_ text: String, timeoutMilliseconds: Int) async -> String { unavailable() }
    func waitForURL(_ text: String, timeoutMilliseconds: Int) async -> String { unavailable() }
    func waitForTitle(_ text: String, timeoutMilliseconds: Int) async -> String { unavailable() }
    func pageText() async -> String { "\(message)\n" }
    func pageHTML() async -> String { "" }
    func linksJSONLines() async -> String { "" }
    func elementsJSONLines() async -> String { "" }
    func pageSnapshot() async -> String { "Chromium unavailable\n\(message)\n" }
    func saveScreenshot(to path: String?) async -> String { unavailable() }
    func credentialForm() async -> BrowserCredentialForm? { nil }
    func fillCredential(_ credential: BrowserCredential) async -> String { unavailable() }

    private func publish() {
        onSnapshotChange?(snapshot)
    }

    private func unavailable() -> String {
        "\(message)\n"
    }
}
