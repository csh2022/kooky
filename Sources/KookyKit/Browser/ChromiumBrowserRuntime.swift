import Foundation

struct ChromiumBrowserRuntime: Equatable {
    enum Status: Equatable {
        case available
        case unavailable([String])

        var message: String? {
            switch self {
            case .available:
                return nil
            case .unavailable(let missing):
                let labels = missing.joined(separator: ", ")
                return "Chromium browser engine is not available. Missing: \(labels)."
            }
        }
    }

    var bundleURL: URL
    var fileManager: FileManager = .default

    static func bundledRuntime(bundle: Bundle = .main) -> ChromiumBrowserRuntime {
        ChromiumBrowserRuntime(bundleURL: bundle.bundleURL)
    }

    func status() -> Status {
        let missing = requiredPaths().filter { !fileManager.fileExists(atPath: $0.url.path) }.map(\.label)
        return missing.isEmpty ? .available : .unavailable(missing)
    }

    private func requiredPaths() -> [(label: String, url: URL)] {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return [
            (
                "Chromium Embedded Framework.framework",
                frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
            ),
            (
                "Kooky Helper.app",
                frameworks.appendingPathComponent("Kooky Helper.app", isDirectory: true)
            ),
            (
                "Kooky Helper (GPU).app",
                frameworks.appendingPathComponent("Kooky Helper (GPU).app", isDirectory: true)
            ),
            (
                "Kooky Helper (Plugin).app",
                frameworks.appendingPathComponent("Kooky Helper (Plugin).app", isDirectory: true)
            ),
            (
                "Kooky Helper (Renderer).app",
                frameworks.appendingPathComponent("Kooky Helper (Renderer).app", isDirectory: true)
            ),
            (
                "KookyCEFBridge.framework",
                frameworks.appendingPathComponent("KookyCEFBridge.framework", isDirectory: true)
            ),
        ]
    }
}
