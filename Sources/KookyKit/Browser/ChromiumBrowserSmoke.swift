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
    public static func runWindowClose(urlString: String) -> Int32 {
        log("window-close smoke starting")
        guard let request = BrowserLoadRequest(urlString) else {
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
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = engine.view
            window.orderFrontRegardless()

            var closeRequested = false
            engine.onCloseRequested = { [weak engine] in
                closeRequested = true
                engine?.close()
            }
            engine.load(request)
            guard waitUntil(timeout: 15, predicate: {
                !engine.snapshot.isLoading
                    && engine.snapshot.urlString != "about:blank"
            }) else {
                throw SmokeFailure("window-close page did not load")
            }

            engine.click(text: "Close via JavaScript")
            guard waitUntil(timeout: 5, predicate: { closeRequested }) else {
                throw SmokeFailure("page did not request browser close")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            guard window.isVisible else {
                throw SmokeFailure("window.close() closed the top-level Kooky window")
            }

            print("window-close-smoke: ok")
            window.close()
            return 0
        } catch {
            fputs("window-close smoke failed: \(error.localizedDescription)\n", stderr)
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
                !engine.snapshot.urlString.isEmpty
                    && engine.snapshot.urlString != "about:blank"
                    && ((try? runAsync("preload text", timeout: 2) { await engine.pageText() }) ?? "")
                        .contains("Kooky Browser Agent Test")
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
            try assertScrollMoved(try runAsync("scroll") { await engine.scroll(direction: "down", amount: 900) }, label: "scroll")
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
                !browser.surface.snapshot.urlString.isEmpty
                    && browser.surface.snapshot.urlString != "about:blank"
                    && ((try? command("preload text", .text)) ?? "")
                        .contains("Kooky Browser Agent Test")
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
            try assertScrollMoved(try command("scroll", .scroll(direction: "down", amount: 900)), label: "scroll")
            try assertCommand(try command("hover", .hover(id: hoverId)), contains: "ok", label: "hover")
            try assertContains(try command("wait-url", .waitURL(text: "127.0.0.1", timeoutMilliseconds: 1000)), "127.0.0.1", "wait-url")
            try assertContains(try command("wait-title", .waitTitle(text: "Kooky Browser Agent Test", timeoutMilliseconds: 1000)), "Kooky Browser Agent Test", "wait-title")
            if elements.contains("Push History") {
                try assertCommand(try command("push history", .click(text: "Push History")), contains: "ok", label: "push history")
                try assertContains(try command("wait pushed url", .waitURL(text: "view=images", timeoutMilliseconds: 3000)), "view=images", "wait pushed url")
                let backState = try command("back", .back)
                guard !backState.contains("view=images") else {
                    throw SmokeFailure("back did not leave pushed history URL. Got: \(backState)")
                }
                try assertContains(backState, "canGoForward: true", "back state")
                let forwardState = try command("forward", .forward)
                try assertContains(forwardState, "view=images", "forward state")
            }
            if elements.contains("Native Normal") {
                try assertCommand(try command("native normal", .click(text: "Native Normal")), contains: "ok", label: "native normal")
                try assertContains(try command("wait native normal", .waitURL(text: "mode=normal", timeoutMilliseconds: 3000)), "mode=normal", "native normal url")
                try assertCommand(try command("native images", .click(text: "Native Images")), contains: "ok", label: "native images")
                try assertContains(try command("wait native images", .waitURL(text: "mode=images", timeoutMilliseconds: 3000)), "mode=images", "native images url")
                let nativeBackState = try command("native back", .back)
                try assertContains(nativeBackState, "mode=normal", "native back state")
                try assertContains(nativeBackState, "canGoForward: true", "native back state")
                let nativeForwardState = try command("native forward", .forward)
                try assertContains(nativeForwardState, "mode=images", "native forward state")
            }

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
    public static func runGoogleCommands() -> Int32 {
        log("google smoke starting")
        let runtime = ChromiumBrowserRuntime.bundledRuntime()
        guard case .available = runtime.status() else {
            fputs((runtime.status().message ?? "Chromium runtime unavailable") + "\n", stderr)
            return 1
        }

        do {
            _ = NSApplication.shared
            let engine = try ChromiumBrowserEngine(runtime: runtime)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 744, height: 999),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = engine.view
            window.orderFrontRegardless()

            guard let request = BrowserLoadRequest("https://www.google.com") else {
                throw SmokeFailure("invalid Google URL")
            }
            log("google smoke loading https://www.google.com")
            engine.load(request)
            try assertContains(
                try runAsync("wait home title") {
                    await engine.waitForTitle("Google", timeoutMilliseconds: 15_000)
                },
                "Google",
                "home title"
            )

            log("google smoke reading home")
            guard waitUntil(timeout: 15, predicate: {
                ((try? runAsync("home elements probe", timeout: 1) { await engine.elementsJSONLines() }) ?? "")
                    .contains("\"role\":\"combobox\"")
            }) else {
                throw SmokeFailure("Google home DOM elements did not become available")
            }
            let homeElements = try runAsync("home elements") { await engine.elementsJSONLines() }
            if !homeElements.contains("\"role\":\"combobox\"") {
                fputs("google smoke home elements:\n\(homeElements.prefix(2_000))\n", stderr)
            }
            let homeSearchId = try elementId(where: { object in
                object["role"] as? String == "combobox"
            }, in: homeElements, label: "home search combobox")
            try assertContains(try runAsync("home links") { await engine.linksJSONLines() }, "\"href\"", "home links")
            try assertContains(try runAsync("home text") { await engine.pageText() }, "Sign in", "home text")
            try assertContains(try runAsync("home html") { await engine.pageHTML() }, "Google", "home html")
            try assertContains(try runAsync("home snapshot") { await engine.pageSnapshot() }, "Elements:", "home snapshot")
            let homeScreenshot = "/tmp/kooky-google-smoke-home.png"
            try assertContains(try runAsync("home screenshot") { await engine.saveScreenshot(to: homeScreenshot) }, homeScreenshot, "home screenshot")

            log("google smoke searching alpha")
            try assertCommand(
                try runAsync("fill alpha") { await engine.fillElement(id: homeSearchId, text: "Kooky google smoke alpha") },
                contains: "ok",
                label: "fill alpha"
            )
            try assertCommand(try runAsync("press alpha") { await engine.press(key: "Enter") }, contains: "ok", label: "press alpha")
            try assertContains(
                try runAsync("wait alpha url") {
                    await engine.waitForURL("Kooky+google+smoke+alpha", timeoutMilliseconds: 15_000)
                },
                "Kooky+google+smoke+alpha",
                "alpha url"
            )
            try assertContains(
                try runAsync("wait alpha title") {
                    await engine.waitForTitle("alpha", timeoutMilliseconds: 15_000)
                },
                "alpha",
                "alpha title"
            )

            let staleFill = try runAsync("stale fill") {
                await engine.fillElement(id: homeSearchId, text: "stale should fail")
            }
            guard staleFill.localizedCaseInsensitiveContains("not found") else {
                throw SmokeFailure("stale home search id unexpectedly filled current page: \(staleFill)")
            }

            log("google smoke searching beta")
            let alphaElements = try runAsync("alpha elements") { await engine.elementsJSONLines() }
            let alphaSearchId = try elementId(where: { object in
                object["role"] as? String == "combobox"
            }, in: alphaElements, label: "alpha search combobox")
            try assertCommand(
                try runAsync("fill beta") { await engine.fillElement(id: alphaSearchId, text: "Kooky google smoke beta") },
                contains: "ok",
                label: "fill beta"
            )
            try assertCommand(try runAsync("press beta") { await engine.press(key: "Enter") }, contains: "ok", label: "press beta")
            try assertContains(
                try runAsync("wait beta title") {
                    await engine.waitForTitle("beta", timeoutMilliseconds: 15_000)
                },
                "beta",
                "beta title"
            )

            log("google smoke paste/type gamma")
            try assertCommand(try runAsync("clear search") { await engine.clear(field: "Search") }, contains: "ok", label: "clear")
            engine.paste(text: "Kooky google smoke ")
            _ = waitUntil(timeout: 0.5) { false }
            engine.type(text: "gamma")
            _ = waitUntil(timeout: 0.5) { false }
            try assertCommand(try runAsync("press gamma") { await engine.press(key: "Enter") }, contains: "ok", label: "press gamma")
            try assertContains(
                try runAsync("wait gamma url") {
                    await engine.waitForURL("Kooky+google+smoke+gamma", timeoutMilliseconds: 15_000)
                },
                "Kooky+google+smoke+gamma",
                "gamma url"
            )
            try assertContains(
                try runAsync("wait gamma title") {
                    await engine.waitForTitle("gamma", timeoutMilliseconds: 15_000)
                },
                "gamma",
                "gamma title"
            )

            log("google smoke page interactions")
            guard waitUntil(timeout: 20, predicate: {
                let elements = (try? runAsync("gamma nav probe", timeout: 1) { await engine.elementsJSONLines() }) ?? ""
                return elements.localizedCaseInsensitiveContains("Images") || elements.contains("udm=2")
            }) else {
                let elements = (try? runAsync("gamma nav timeout elements", timeout: 2) { await engine.elementsJSONLines() }) ?? ""
                throw SmokeFailure("Google result navigation did not become available: \(elements.prefix(1_000))")
            }
            var gammaElements = try runAsync("gamma elements") { await engine.elementsJSONLines() }
            if !gammaElements.localizedCaseInsensitiveContains("images") && !gammaElements.contains("udm=2") {
                fputs("google smoke gamma elements:\n\(gammaElements.prefix(3_000))\n", stderr)
            }
            let imagesId = try googleImagesElementId(in: gammaElements)
            try assertCommand(try runAsync("hover images") { await engine.hover(id: imagesId) }, contains: "ok", label: "hover images")
            try assertCommand(try runAsync("click at") { await engine.clickAt(x: 20, y: 20) }, contains: "ok", label: "click at")
            try assertScrollMoved(try runAsync("scroll down") { await engine.scroll(direction: "down", amount: 600) }, label: "scroll down")
            try assertScrollMoved(try runAsync("scroll up") { await engine.scroll(direction: "up", amount: 300) }, label: "scroll up")
            let gammaScreenshot = "/tmp/kooky-google-smoke-gamma.png"
            try assertContains(try runAsync("gamma screenshot") { await engine.saveScreenshot(to: gammaScreenshot) }, gammaScreenshot, "gamma screenshot")
            engine.reload()
            try assertContains(
                try runAsync("wait reloaded gamma") {
                    await engine.waitForTitle("gamma", timeoutMilliseconds: 15_000)
                },
                "gamma",
                "reloaded gamma title"
            )
            engine.stopLoading()

            log("google smoke images history")
            _ = try runAsync("scroll top") { await engine.scroll(direction: "up", amount: 2_000) }
            gammaElements = try runAsync("gamma top elements") { await engine.elementsJSONLines() }
            let topImagesId = try googleImagesElementId(in: gammaElements)
            try assertCommand(try runAsync("click images") { await engine.clickElement(id: topImagesId, double: false) }, contains: "ok", label: "click images")
            try assertContains(
                try runAsync("wait images url") {
                    await engine.waitForURL("udm=2", timeoutMilliseconds: 15_000)
                },
                "udm=2",
                "images url"
            )
            engine.goBack()
            guard waitUntil(timeout: 15, predicate: {
                engine.snapshot.urlString.contains("q=Kooky+google+smoke+gamma")
                    && !engine.snapshot.urlString.contains("udm=2")
                    && engine.snapshot.canGoForward
            }) else {
                throw SmokeFailure("google images back did not restore normal URL with forward available: \(engine.snapshot)")
            }
            engine.goForward()
            guard waitUntil(timeout: 15, predicate: {
                engine.snapshot.urlString.contains("udm=2")
            }) else {
                throw SmokeFailure("google images forward did not restore images URL: \(engine.snapshot)")
            }

            print("google-smoke: ok")
            window.close()
            log("google smoke finished")
            return 0
        } catch {
            fputs("google smoke failed: \(error.localizedDescription)\n", stderr)
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

    private static func assertScrollMoved(_ value: String, label: String) throws {
        guard value.localizedCaseInsensitiveContains("ok scrolled") else {
            throw SmokeFailure("\(label) did not move: \(value)")
        }
        let movedYLine = value
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("movedY:") }
        let movedY = movedYLine
            .flatMap { Double($0.replacingOccurrences(of: "movedY:", with: "").trimmingCharacters(in: .whitespaces)) }
            ?? 0
        guard abs(movedY) > 0 else {
            throw SmokeFailure("\(label) reported no vertical movement: \(value)")
        }
        let target = value
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("target:") }
            .map(String.init)
            ?? ""
        guard !target.localizedCaseInsensitiveContains("target: button"),
              !target.localizedCaseInsensitiveContains("target: span"),
              !target.localizedCaseInsensitiveContains("target: input")
        else {
            throw SmokeFailure("\(label) scrolled a small control instead of the page/body: \(value)")
        }
    }

    private static func elementId(containing text: String, in jsonLines: String) throws -> String {
        try elementId(where: { object in
            let haystack = object.values.compactMap { $0 as? String }.joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(text)
        }, in: jsonLines, label: text)
    }

    private static func googleImagesElementId(in jsonLines: String) throws -> String {
        if let id = try? elementId(where: { object in
            guard let href = object["href"] as? String else { return false }
            return href.contains("udm=2")
        }, in: jsonLines, label: "Google Images href") {
            return id
        }
        return try elementId(containing: "Images", in: jsonLines)
    }

    private static func elementId(
        where predicate: ([String: Any]) -> Bool,
        in jsonLines: String,
        label: String
    ) throws -> String {
        for line in jsonLines.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String
            else { continue }
            if predicate(object) {
                return id
            }
        }
        throw SmokeFailure("element id not found for \(label)")
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
