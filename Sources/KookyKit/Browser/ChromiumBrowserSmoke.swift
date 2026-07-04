import AppKit
import Foundation

public enum ChromiumBrowserSmoke {
    @MainActor
    public static func run(urlString: String = "https://example.com") -> Int32 {
        log("starting")
        guard let url = URL(string: urlString) else {
            fputs("invalid smoke URL: \(urlString)\n", stderr)
            return 2
        }
        let runtime = ChromiumBrowserRuntime.bundledRuntime()
        guard case .available = runtime.status() else {
            fputs((runtime.status().message ?? "Chromium runtime unavailable") + "\n", stderr)
            return 1
        }
        do {
            log("creating NSApplication")
            _ = NSApplication.shared
            log("creating Chromium engine")
            let engine = try ChromiumBrowserEngine(runtime: runtime)
            log("creating window")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = engine.view
            window.orderFrontRegardless()
            log("loading \(url.absoluteString)")
            guard let request = BrowserLoadRequest(url.absoluteString) else {
                fputs("invalid smoke URL: \(urlString)\n", stderr)
                return 2
            }
            engine.load(request)

            let deadline = Date().addingTimeInterval(15)
            log("running main loop")
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
                if !engine.snapshot.isLoading,
                   !engine.snapshot.urlString.isEmpty,
                   engine.snapshot.urlString != "about:blank" {
                    break
                }
            }
            let snapshot = engine.snapshot
            print("title: \(snapshot.title)")
            print("url: \(snapshot.urlString)")
            print("loading: \(snapshot.isLoading)")
            window.close()
            log("finished")
            return snapshot.urlString.isEmpty || snapshot.urlString == "about:blank" ? 1 : 0
        } catch {
            fputs("chromium smoke failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func log(_ message: String) {
        fputs("chromium smoke: \(message)\n", stderr)
        fflush(stderr)
    }
}
