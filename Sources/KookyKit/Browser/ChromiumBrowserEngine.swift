import AppKit
import Darwin
import Foundation

@MainActor
final class ChromiumBrowserEngine: BrowserEngine {
    let view: NSView
    var onSnapshotChange: ((BrowserEngineSnapshot) -> Void)?

    private let bridge: ChromiumBrowserBridge
    private let browser: CEFPointer
    private let callbackContext: CEFPointer
    private var currentSnapshot = BrowserEngineSnapshot(
        title: "Chromium",
        urlString: "",
        canGoBack: false,
        canGoForward: false,
        isLoading: false,
        errorMessage: nil
    )

    init(runtime: ChromiumBrowserRuntime = .bundledRuntime()) throws {
        bridge = try ChromiumBrowserBridge.load(runtime: runtime)
        let cacheURL = Self.cacheDirectoryURL()
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        guard bridge.initialize(cacheURL.path) != 0 else {
            throw ChromiumBrowserError.initializationFailed
        }
        let stateBox = ChromiumBrowserStateBox()
        let context = Unmanaged.passRetained(stateBox).toOpaque()
        guard let browser = bridge.createBrowser("about:blank", ChromiumBrowserEngine.stateCallback, context),
              let rawView = bridge.getView(browser)
        else {
            Unmanaged<ChromiumBrowserStateBox>.fromOpaque(context).release()
            throw ChromiumBrowserError.browserCreationFailed
        }
        callbackContext = CEFPointer(context)
        self.browser = CEFPointer(browser)
        view = Unmanaged<NSView>.fromOpaque(rawView).takeUnretainedValue()
        stateBox.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.apply(snapshot)
            }
        }
        apply(currentSnapshot)
    }

    deinit {
        bridge.closeBrowser(browser.raw)
        Unmanaged<ChromiumBrowserStateBox>.fromOpaque(callbackContext.raw).release()
    }

    var snapshot: BrowserEngineSnapshot {
        currentSnapshot
    }

    func load(_ request: BrowserLoadRequest) {
        bridge.loadURL(browser.raw, request.url.absoluteString)
        currentSnapshot.urlString = request.url.absoluteString
        currentSnapshot.isLoading = true
        apply(currentSnapshot)
    }

    func reload() {
        bridge.reload(browser.raw)
    }

    func stopLoading() {
        bridge.stopLoading(browser.raw)
    }

    func goBack() {
        guard currentSnapshot.canGoBack else { return }
        bridge.goBack(browser.raw)
    }

    func goForward() {
        guard currentSnapshot.canGoForward else { return }
        bridge.goForward(browser.raw)
    }

    func click(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { _ = await evaluateString(WebKitBrowserEngine.clickJavaScript(text: trimmed)) }
    }

    func clickElement(id: String, double: Bool) async -> String {
        let result = await evaluateString(WebKitBrowserEngine.clickElementJavaScript(id: id, double: double))
        return result == "true" ? "ok clicked id: \(id)\n" : "element not found: \(id)\n"
    }

    func clickAt(x: Double, y: Double) async -> String {
        let result = await evaluateString(WebKitBrowserEngine.clickAtJavaScript(x: x, y: y))
        return result == "true" ? "ok clicked at: \(x),\(y)\n" : "click target not found at: \(x),\(y)\n"
    }

    func fill(field: String, text: String) async -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "field not found\n" }
        let result = await evaluateString(WebKitBrowserEngine.fillJavaScript(field: trimmed, text: text))
        return result == "true" ? "ok filled field: \(trimmed)\n" : "field not found: \(trimmed)\n"
    }

    func fillElement(id: String, text: String) async -> String {
        let result = await evaluateString(WebKitBrowserEngine.fillElementJavaScript(id: id, text: text))
        return result == "true" ? "ok filled id: \(id)\n" : "element not found or not fillable: \(id)\n"
    }

    func clear(field: String?) async -> String {
        let result = await evaluateString(WebKitBrowserEngine.clearJavaScript(field: field ?? ""))
        return result == "true" ? "ok cleared\n" : "field not found\n"
    }

    func type(text: String) {
        guard !text.isEmpty else { return }
        Task { _ = await evaluateString(WebKitBrowserEngine.typeJavaScript(text: text)) }
    }

    func paste(text: String) {
        guard !text.isEmpty else { return }
        Task { _ = await evaluateString(WebKitBrowserEngine.typeJavaScript(text: text)) }
    }

    func press(key: String) async -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "key press failed\n" }
        let result = await evaluateString(WebKitBrowserEngine.pressJavaScript(key: trimmed))
        switch result {
        case "submitted":
            return "ok pressed key: \(trimmed)\nsubmitted: true\n"
        case "clicked-submit":
            return "ok pressed key: \(trimmed)\nclickedSubmit: true\n"
        case "pressed":
            return "ok pressed key: \(trimmed)\n"
        default:
            return "key press failed: \(trimmed)\n"
        }
    }

    func hotkey(_ combo: String) {
        let trimmed = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { _ = await evaluateString(WebKitBrowserEngine.hotkeyJavaScript(combo: trimmed)) }
    }

    func scroll(direction: String, amount: Double?) async -> String {
        let result = await evaluateString(WebKitBrowserEngine.scrollJavaScript(direction: direction, amount: amount))
        return result.isEmpty ? "scroll failed\n" : result.ensuringTrailingNewline()
    }

    func hover(id: String) async -> String {
        let result = await evaluateString(WebKitBrowserEngine.hoverJavaScript(id: id))
        return result == "true" ? "ok hovered id: \(id)\n" : "element not found: \(id)\n"
    }

    func waitForText(_ text: String, timeoutMilliseconds: Int) async -> String {
        await waitForCondition(label: "text", text: text, timeoutMilliseconds: timeoutMilliseconds) { [weak self] in
            guard let self else { return "" }
            return await self.pageText()
        }
    }

    func waitForURL(_ text: String, timeoutMilliseconds: Int) async -> String {
        await waitForCondition(label: "url", text: text, timeoutMilliseconds: timeoutMilliseconds) { [weak self] in
            self?.snapshot.urlString ?? ""
        }
    }

    func waitForTitle(_ text: String, timeoutMilliseconds: Int) async -> String {
        await waitForCondition(label: "title", text: text, timeoutMilliseconds: timeoutMilliseconds) { [weak self] in
            self?.snapshot.title ?? ""
        }
    }

    func pageText() async -> String {
        await evaluateString(WebKitBrowserEngine.pageTextJavaScript()).trimmedForCLI()
    }

    func pageHTML() async -> String {
        await evaluateString("document.documentElement ? document.documentElement.outerHTML : ''").trimmedForCLI()
    }

    func linksJSONLines() async -> String {
        await evaluateString(WebKitBrowserEngine.linksJavaScript()).ensuringTrailingNewline()
    }

    func elementsJSONLines() async -> String {
        await evaluateString(WebKitBrowserEngine.elementsJavaScript()).ensuringTrailingNewline()
    }
    func pageSnapshot() async -> String {
        let state = browserStateText(prefix: "Kooky Chromium browser snapshot")
        let elements = await elementsJSONLines()
        let text = await pageText()
        return """
        \(state)
        Elements:
        \(elements)
        Text:
        \(text)
        """.ensuringTrailingNewline()
    }

    func saveScreenshot(to path: String?) async -> String {
        let resolved = screenshotPath(path)
        let bounds = view.bounds.width > 0 && view.bounds.height > 0
            ? view.bounds
            : NSRect(x: 0, y: 0, width: 1280, height: 800)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return "screenshot failed\n"
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return "screenshot failed\n"
        }
        do {
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: resolved, options: .atomic)
            return resolved.path + "\n"
        } catch {
            return "screenshot failed: \(error.localizedDescription)\n"
        }
    }

    func credentialForm() async -> BrowserCredentialForm? {
        let json = await evaluateString(WebKitBrowserEngine.credentialFormJavaScript())
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let site = object["site"] as? String,
              let account = object["account"] as? String,
              let password = object["password"] as? String
        else { return nil }
        return BrowserCredentialForm(site: site, account: account, password: password)
    }

    func fillCredential(_ credential: BrowserCredential) async -> String {
        guard !credential.account.isEmpty, !credential.password.isEmpty else {
            return "credential is empty\n"
        }
        let result = await evaluateString(WebKitBrowserEngine.fillCredentialJavaScript(
            account: credential.account,
            password: credential.password
        ))
        return result == "true" ? "ok filled credential: \(credential.account)\n" : "credential form not found\n"
    }

    private func apply(_ snapshot: BrowserEngineSnapshot) {
        currentSnapshot = snapshot
        onSnapshotChange?(snapshot)
    }

    private func evaluateString(_ script: String) async -> String {
        await withCheckedContinuation { continuation in
            let box = ChromiumEvaluateCallbackBox(continuation)
            let context = Unmanaged.passRetained(box).toOpaque()
            bridge.evaluateJavaScript(browser.raw, script, ChromiumBrowserEngine.evaluateCallback, context)
        }
    }

    private func waitForCondition(
        label: String,
        text: String,
        timeoutMilliseconds: Int,
        value: () async -> String
    ) async -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(max(timeoutMilliseconds, 0)) / 1000.0)
        repeat {
            let current = await value()
            if current.localizedCaseInsensitiveContains(text) {
                return browserStateText(prefix: "ok found \(label): \(text)", condition: label)
            }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        } while true
        return browserStateText(prefix: "timed out waiting for \(label): \(text)", condition: label)
    }

    private func browserStateText(prefix: String, condition: String? = nil) -> String {
        let snapshot = self.snapshot
        let conditionLine = condition.map { "condition: \($0)\n" } ?? ""
        return """
        \(prefix)
        \(conditionLine)title: \(snapshot.title)
        url: \(snapshot.urlString)
        loading: \(snapshot.isLoading)

        """
    }

    private func screenshotPath(_ path: String?) -> URL {
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kooky-browser", isDirectory: true)
        let stamp = Self.screenshotTimestamp.string(from: Date())
        return dir.appendingPathComponent("screenshot-\(stamp).png")
    }

    private static let screenshotTimestamp: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt
    }()

    private static let evaluateCallback: ChromiumBrowserBridge.EvaluateCallback = { context, result in
        guard let context else { return }
        let box = Unmanaged<ChromiumEvaluateCallbackBox>.fromOpaque(context).takeRetainedValue()
        box.continuation.resume(returning: ChromiumBrowserEngine.string(from: result))
    }

    private static func cacheDirectoryURL() -> URL {
        let override = ProcessInfo.processInfo.environment["KOOKY_CHROMIUM_CACHE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kooky/chromium-root/default", isDirectory: true)
    }

    private static let stateCallback: ChromiumBrowserBridge.StateCallback = { context, title, url, canGoBack, canGoForward, isLoading in
        guard let context else { return }
        let box = Unmanaged<ChromiumBrowserStateBox>.fromOpaque(context).takeUnretainedValue()
        let snapshot = BrowserEngineSnapshot(
            title: ChromiumBrowserEngine.string(from: title),
            urlString: ChromiumBrowserEngine.string(from: url),
            canGoBack: canGoBack != 0,
            canGoForward: canGoForward != 0,
            isLoading: isLoading != 0,
            errorMessage: nil
        )
        box.publish(snapshot)
    }

    private static func string(from pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }
}

private final class ChromiumEvaluateCallbackBox {
    let continuation: CheckedContinuation<String, Never>

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }
}

private final class ChromiumBrowserStateBox {
    var onSnapshot: ((BrowserEngineSnapshot) -> Void)?

    func publish(_ snapshot: BrowserEngineSnapshot) {
        onSnapshot?(snapshot)
    }
}

private struct CEFPointer: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer

    init(_ raw: UnsafeMutableRawPointer) {
        self.raw = raw
    }
}

private enum ChromiumBrowserError: LocalizedError {
    case bridgeUnavailable(String)
    case missingSymbol(String)
    case initializationFailed
    case browserCreationFailed

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable(let message):
            return message
        case .missingSymbol(let symbol):
            return "Missing Chromium bridge symbol: \(symbol)"
        case .initializationFailed:
            return "CEF initialization failed"
        case .browserCreationFailed:
            return "CEF browser creation failed"
        }
    }
}

private final class ChromiumBrowserBridge: @unchecked Sendable {
    typealias StateCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        Int32,
        Int32,
        Int32
    ) -> Void

    typealias Initialize = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias CreateBrowser = @convention(c) (UnsafePointer<CChar>?, StateCallback?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias GetView = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias LoadURL = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    typealias EvaluateCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    typealias EvaluateJavaScript = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, EvaluateCallback?, UnsafeMutableRawPointer?) -> Void
    typealias BrowserCommand = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let handle: UnsafeMutableRawPointer
    let initialize: Initialize
    let createBrowser: CreateBrowser
    let getViewFunction: GetView
    let loadURLFunction: LoadURL
    let evaluateJavaScriptFunction: EvaluateJavaScript
    let reload: BrowserCommand
    let stopLoading: BrowserCommand
    let goBack: BrowserCommand
    let goForward: BrowserCommand
    let closeBrowser: BrowserCommand

    static func load(runtime: ChromiumBrowserRuntime) throws -> ChromiumBrowserBridge {
        if case .unavailable(let missing) = runtime.status() {
            throw ChromiumBrowserError.bridgeUnavailable(missing.joined(separator: ", "))
        }
        let path = runtime.bridgeExecutableURL.path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let message = String(cString: dlerror())
            throw ChromiumBrowserError.bridgeUnavailable(message)
        }
        return try ChromiumBrowserBridge(handle: handle)
    }

    private init(handle: UnsafeMutableRawPointer) throws {
        self.handle = handle
        initialize = try Self.symbol(handle, "KookyCEFInitialize", as: Initialize.self)
        createBrowser = try Self.symbol(handle, "KookyCEFCreateBrowser", as: CreateBrowser.self)
        getViewFunction = try Self.symbol(handle, "KookyCEFGetView", as: GetView.self)
        loadURLFunction = try Self.symbol(handle, "KookyCEFLoadURL", as: LoadURL.self)
        evaluateJavaScriptFunction = try Self.symbol(handle, "KookyCEFEvaluateJavaScript", as: EvaluateJavaScript.self)
        reload = try Self.symbol(handle, "KookyCEFReload", as: BrowserCommand.self)
        stopLoading = try Self.symbol(handle, "KookyCEFStopLoading", as: BrowserCommand.self)
        goBack = try Self.symbol(handle, "KookyCEFGoBack", as: BrowserCommand.self)
        goForward = try Self.symbol(handle, "KookyCEFGoForward", as: BrowserCommand.self)
        closeBrowser = try Self.symbol(handle, "KookyCEFCloseBrowser", as: BrowserCommand.self)
    }

    deinit {
        dlclose(handle)
    }

    func initialize(_ cachePath: String) -> Int32 {
        cachePath.withCString { initialize($0) }
    }

    func createBrowser(_ url: String, _ callback: StateCallback?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        url.withCString { createBrowser($0, callback, context) }
    }

    func getView(_ browser: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
        getViewFunction(browser)
    }

    func loadURL(_ browser: UnsafeMutableRawPointer, _ url: String) {
        url.withCString { loadURLFunction(browser, $0) }
    }

    func evaluateJavaScript(
        _ browser: UnsafeMutableRawPointer,
        _ script: String,
        _ callback: EvaluateCallback?,
        _ context: UnsafeMutableRawPointer?
    ) {
        script.withCString { evaluateJavaScriptFunction(browser, $0, callback, context) }
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw ChromiumBrowserError.missingSymbol(name)
        }
        return unsafeBitCast(pointer, to: type)
    }
}

private extension String {
    func ensuringTrailingNewline() -> String {
        hasSuffix("\n") ? self : self + "\n"
    }

    func trimmedForCLI() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).ensuringTrailingNewline()
    }
}
