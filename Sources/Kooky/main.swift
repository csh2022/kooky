import AppKit
import KookyKit

if KookyHookCommand.isInvocation(CommandLine.arguments) {
    exit(KookyHookCommand.run(CommandLine.arguments))
}

ChromiumApplicationBootstrap.installIfAvailable()

if CommandLine.arguments.contains("--chromium-agent-smoke") {
    let url = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "https://example.com"
    exit(ChromiumBrowserSmoke.runAgentCommands(urlString: url))
}

if CommandLine.arguments.contains("--chromium-smoke") {
    let url = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "https://example.com"
    exit(ChromiumBrowserSmoke.run(urlString: url))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
