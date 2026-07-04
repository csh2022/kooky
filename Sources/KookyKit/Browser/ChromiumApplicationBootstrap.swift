import Darwin
import Foundation

@MainActor
public enum ChromiumApplicationBootstrap {
    private static var bridgeHandle: UnsafeMutableRawPointer?

    public static func installIfAvailable(bundle: Bundle = .main) {
        if bridgeHandle != nil { return }
        let runtime = ChromiumBrowserRuntime.bundledRuntime(bundle: bundle)
        guard case .available = runtime.status() else { return }
        guard let handle = dlopen(runtime.bridgeExecutableURL.path, RTLD_NOW | RTLD_LOCAL) else { return }
        guard let symbol = dlsym(handle, "KookyCEFInstallApplication") else { return }
        typealias Install = @convention(c) () -> Int32
        let install = unsafeBitCast(symbol, to: Install.self)
        if install() != 0 {
            bridgeHandle = handle
        } else {
            dlclose(handle)
        }
    }
}
