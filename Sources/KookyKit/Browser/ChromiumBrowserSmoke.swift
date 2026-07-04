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

    @MainActor
    public static func runAgentCommands(urlString: String = "https://example.com") -> Int32 {
        log("agent smoke starting")
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
            _ = NSApplication.shared
            let engine = try ChromiumBrowserEngine(runtime: runtime)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = engine.view
            window.orderFrontRegardless()

            guard let request = BrowserLoadRequest(url.absoluteString) else {
                fputs("invalid smoke URL: \(urlString)\n", stderr)
                return 2
            }
            log("agent smoke loading \(url.absoluteString)")
            engine.load(request)
            guard waitUntil(timeout: 15, predicate: {
                !engine.snapshot.isLoading
                    && !engine.snapshot.urlString.isEmpty
                    && engine.snapshot.urlString != "about:blank"
            }) else {
                fputs("agent smoke failed: page did not load\n", stderr)
                return 1
            }

            log("agent smoke reading DOM")
            try assertContains(try runAsync("page text") { await engine.pageText() }, "Kooky Browser Agent Test", "text")
            try assertContains(try runAsync("page html") { await engine.pageHTML() }, "Submit Agent Test", "html")
            let elements = try runAsync("elements") { await engine.elementsJSONLines() }
            try assertContains(elements, "Submit Agent Test", "elements")
            try assertContains(try runAsync("links") { await engine.linksJSONLines() }, "Go Bottom Link", "links")
            try assertContains(try runAsync("snapshot") { await engine.pageSnapshot() }, "Elements:", "snapshot")
            let notesId = try elementId(containing: "Notes", in: elements)
            let submitId = try elementId(containing: "Submit Agent Test", in: elements)
            let hoverId = try elementId(containing: "Go Bottom Link", in: elements)

            log("agent smoke interacting")
            try assertCommand(try runAsync("fill") { await engine.fill(field: "Name", text: "Alice") }, contains: "ok", label: "fill")
            engine.click(text: "Submit Agent Test")
            try assertContains(try runAsync("wait clicked by text") { await engine.waitForText("clicked:Alice", timeoutMilliseconds: 3000) }, "clicked:Alice", "click text")
            try assertCommand(try runAsync("clear") { await engine.clear(field: "Name") }, contains: "ok", label: "clear")
            try assertCommand(try runAsync("refill") { await engine.fill(field: "Name", text: "Alice") }, contains: "ok", label: "refill")
            try assertCommand(try runAsync("fill id") { await engine.fillElement(id: notesId, text: "memo") }, contains: "ok", label: "fill-id")
            try assertCommand(try runAsync("click id") { await engine.clickElement(id: submitId, double: false) }, contains: "ok", label: "click-id")
            try assertContains(try runAsync("wait text") { await engine.waitForText("clicked:Alice", timeoutMilliseconds: 3000) }, "clicked:Alice", "wait text")
            try assertCommand(try runAsync("click at") { await engine.clickAt(x: 10, y: 10) }, contains: "ok", label: "click-at")
            try assertCommand(try runAsync("press") { await engine.press(key: "Tab") }, contains: "ok", label: "press")
            try assertCommand(try runAsync("scroll") { await engine.scroll(direction: "down", amount: 900) }, contains: "scroll", label: "scroll")
            try assertCommand(try runAsync("hover") { await engine.hover(id: hoverId) }, contains: "ok", label: "hover")
            try assertContains(try runAsync("wait url") { await engine.waitForURL("kooky-browser-agent-test", timeoutMilliseconds: 1000) }, "kooky-browser-agent-test", "wait-url")
            try assertContains(try runAsync("wait title") { await engine.waitForTitle("Kooky Browser Agent Test", timeoutMilliseconds: 1000) }, "Kooky Browser Agent Test", "wait-title")

            let screenshotPath = "/tmp/kooky-chromium-agent-smoke.png"
            try assertContains(try runAsync("screenshot") { await engine.saveScreenshot(to: screenshotPath) }, screenshotPath, "screenshot")
            guard let size = try? FileManager.default.attributesOfItem(atPath: screenshotPath)[.size] as? NSNumber,
                  size.intValue > 0 else {
                throw SmokeFailure("screenshot file was not written")
            }

            print("agent-smoke: ok")
            window.close()
            log("agent smoke finished")
            return 0
        } catch {
            fputs("agent smoke failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    @MainActor
    public static func runHookCommands(urlString: String = "https://example.com") -> Int32 {
        log("hook smoke starting")
        guard URL(string: urlString) != nil else {
            fputs("invalid smoke URL: \(urlString)\n", stderr)
            return 2
        }
        let runtime = ChromiumBrowserRuntime.bundledRuntime()
        guard case .available = runtime.status() else {
            fputs((runtime.status().message ?? "Chromium runtime unavailable") + "\n", stderr)
            return 1
        }

        do {
            _ = NSApplication.shared
            let store = WorkspaceStore(
                persistence: SmokePersistence(),
                engineFactory: { SmokeTerminalEngine() },
                optionsProvider: { _ in nil },
                resumeProvider: { true },
                browserEngineFactory: {
                    do {
                        return try ChromiumBrowserEngine(runtime: runtime)
                    } catch {
                        return UnsupportedChromiumBrowserEngine(missingRequirements: [error.localizedDescription])
                    }
                },
                worktreeCapabilityProbe: { _ in false }
            )
            guard let workspace = store.active,
                  let sessionId = workspace.activeSession?.id
            else {
                fputs("hook smoke failed: no active session\n", stderr)
                return 1
            }
            func command(_ label: String, _ command: HookBrowserCommand) throws -> String {
                try runAsync(label) {
                    await store.applyBrowserCommand(command, sessionId: sessionId) ?? ""
                }
            }

            log("hook smoke opening \(urlString)")
            let opened = try command("open", .open(address: urlString))
            try assertContains(opened, "title:", "open")
            guard let browser = workspace.root.allBrowserPanes.first else {
                throw SmokeFailure("browser pane was not created")
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = browser.surface.engine.view
            window.orderFrontRegardless()

            guard waitUntil(timeout: 15, predicate: {
                !browser.surface.snapshot.isLoading
                    && !browser.surface.snapshot.urlString.isEmpty
                    && browser.surface.snapshot.urlString != "about:blank"
            }) else {
                throw SmokeFailure("page did not load")
            }

            log("hook smoke reading DOM")
            try assertContains(try command("text", .text), "Kooky Browser Agent Test", "text")
            let elements = try command("elements", .elements)
            try assertContains(elements, "Submit Agent Test", "elements")
            try assertContains(try command("links", .links), "Go Bottom Link", "links")
            try assertContains(try command("snapshot", .snapshot(path: nil)), "Elements:", "snapshot")
            let notesId = try elementId(containing: "Notes", in: elements)
            let submitId = try elementId(containing: "Submit Agent Test", in: elements)
            let hoverId = try elementId(containing: "Go Bottom Link", in: elements)

            log("hook smoke interacting")
            try assertCommand(try command("fill", .fill(field: "Name", text: "Alice")), contains: "ok", label: "fill")
            try assertCommand(try command("click", .click(text: "Submit Agent Test")), contains: "ok", label: "click")
            try assertContains(try command("wait text", .wait(text: "clicked:Alice", timeoutMilliseconds: 3000)), "clicked:Alice", "wait text")
            try assertCommand(try command("clear", .clear(field: "Name")), contains: "ok", label: "clear")
            try assertCommand(try command("refill", .fill(field: "Name", text: "Alice")), contains: "ok", label: "refill")
            try assertCommand(try command("fill-id", .fillId(id: notesId, text: "memo")), contains: "ok", label: "fill-id")
            try assertCommand(try command("click-id", .clickId(id: submitId, double: false)), contains: "ok", label: "click-id")
            try assertCommand(try command("click-at", .clickAt(x: 10, y: 10)), contains: "ok", label: "click-at")
            try assertCommand(try command("press", .press(key: "Tab")), contains: "ok", label: "press")
            try assertCommand(try command("scroll", .scroll(direction: "down", amount: 900)), contains: "scroll", label: "scroll")
            try assertCommand(try command("hover", .hover(id: hoverId)), contains: "ok", label: "hover")
            try assertContains(try command("wait-url", .waitURL(text: "127.0.0.1", timeoutMilliseconds: 1000)), "127.0.0.1", "wait-url")
            try assertContains(try command("wait-title", .waitTitle(text: "Kooky Browser Agent Test", timeoutMilliseconds: 1000)), "Kooky Browser Agent Test", "wait-title")

            let screenshotPath = "/tmp/kooky-chromium-hook-smoke.png"
            try assertContains(try command("screenshot", .screenshot(path: screenshotPath)), screenshotPath, "screenshot")
            guard let size = try? FileManager.default.attributesOfItem(atPath: screenshotPath)[.size] as? NSNumber,
                  size.intValue > 0 else {
                throw SmokeFailure("screenshot file was not written")
            }

            try assertCommand(try command("close", .close), contains: "ok", label: "close")
            window.close()
            print("hook-smoke: ok")
            log("hook smoke finished")
            return 0
        } catch {
            fputs("hook smoke failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    @MainActor
    private static func runAsync<T>(
        _ label: String,
        timeout: TimeInterval = 20,
        _ operation: @escaping @MainActor () async -> T
    ) throws -> T {
        var outcome: T?
        Task { @MainActor in
            outcome = await operation()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome { return outcome }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        throw SmokeFailure("\(label) timed out")
    }

    private static func log(_ message: String) {
        fputs("chromium smoke: \(message)\n", stderr)
        fflush(stderr)
    }

    private static func assertContains(_ value: String, _ expected: String, _ label: String) throws {
        guard value.contains(expected) else {
            throw SmokeFailure("\(label) did not contain \(expected). Got: \(value.prefix(500))")
        }
    }

    private static func assertCommand(_ value: String, contains expected: String, label: String) throws {
        guard value.localizedCaseInsensitiveContains(expected) else {
            throw SmokeFailure("\(label) returned unexpected output: \(value)")
        }
    }

    private static func elementId(containing text: String, in jsonLines: String) throws -> String {
        for line in jsonLines.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String
            else { continue }
            let haystack = object.values.compactMap { $0 as? String }.joined(separator: " ")
            if haystack.localizedCaseInsensitiveContains(text) {
                return id
            }
        }
        throw SmokeFailure("element id not found for \(text)")
    }

    private struct SmokeFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private struct SmokePersistence: Persistence {
    func load() -> PersistedState? { nil }
    func save(_ state: PersistedState) {}
}

@MainActor
private final class SmokeTerminalEngine: TerminalEngine {
    let view: NSView = NSView()
    var backgroundColor: NSColor { .black }
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var foregroundPid: pid_t? { nil }
    var onProcessExitedCleanly: (() -> Void)?
    var suspendsSizePropagation = false
    var grabsFocusOnMount = true
    var isRenderingActive = true

    func start(config: TerminalSessionConfig) {}
    func terminate() {}
    func flushSize() {}
    @discardableResult
    func performAction(_ name: String) -> Bool { true }
    func sendInput(_ text: String) {}
    func paste(_ text: String) {}
    func readSelection() -> String? { nil }
}
