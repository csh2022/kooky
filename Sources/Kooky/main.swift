import AppKit
import KookyKit

if KookyHookCommand.isInvocation(CommandLine.arguments) {
    exit(KookyHookCommand.run(CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
