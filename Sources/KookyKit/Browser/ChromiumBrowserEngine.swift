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

    func click(text: String) {}
    func clickElement(id: String, double: Bool) async -> String { commandUnavailable() }
    func clickAt(x: Double, y: Double) async -> String { commandUnavailable() }
    func fill(field: String, text: String) async -> String { commandUnavailable() }
    func fillElement(id: String, text: String) async -> String { commandUnavailable() }
    func clear(field: String?) async -> String { commandUnavailable() }
    func type(text: String) {}
    func paste(text: String) {}
    func press(key: String) async -> String { commandUnavailable() }
    func hotkey(_ combo: String) {}
    func scroll(direction: String, amount: Double?) async -> String { commandUnavailable() }
    func hover(id: String) async -> String { commandUnavailable() }
    func waitForText(_ text: String, timeoutMilliseconds: Int) async -> String { commandUnavailable() }
    func waitForURL(_ text: String, timeoutMilliseconds: Int) async -> String { commandUnavailable() }
    func waitForTitle(_ text: String, timeoutMilliseconds: Int) async -> String { commandUnavailable() }
    func pageText() async -> String { commandUnavailable() }
    func pageHTML() async -> String { "" }
    func linksJSONLines() async -> String { "" }
    func elementsJSONLines() async -> String { "" }
    func pageSnapshot() async -> String {
        """
        Kooky Chromium browser snapshot
        title: \(currentSnapshot.title)
        url: \(currentSnapshot.urlString)
        loading: \(currentSnapshot.isLoading)
        commands: Chromium DOM automation is not implemented yet.
        \n
        """
    }
    func saveScreenshot(to path: String?) async -> String { commandUnavailable() }
    func credentialForm() async -> BrowserCredentialForm? { nil }
    func fillCredential(_ credential: BrowserCredential) async -> String { commandUnavailable() }

    private func apply(_ snapshot: BrowserEngineSnapshot) {
        currentSnapshot = snapshot
        onSnapshotChange?(snapshot)
    }

    private func commandUnavailable() -> String {
        "Chromium browser command is not implemented yet.\n"
    }

    private static func cacheDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
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
    typealias BrowserCommand = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let handle: UnsafeMutableRawPointer
    let initialize: Initialize
    let createBrowser: CreateBrowser
    let getViewFunction: GetView
    let loadURLFunction: LoadURL
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

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw ChromiumBrowserError.missingSymbol(name)
        }
        return unsafeBitCast(pointer, to: type)
    }
}
