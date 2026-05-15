import AppKit
@testable import KookyKit

/// In-memory stand-in for `TerminalEngine` so `WorkspaceStore` tests don't
/// need libghostty or a real PTY. Records calls so tests can assert on them.
@MainActor
final class TestEngine: TerminalEngine {
    let view: NSView = NSView()
    var backgroundColor: NSColor { .black }
    var onPwdChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onProcessExitedCleanly: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var foregroundPid: pid_t? { nil }

    private(set) var startedConfigs: [TerminalSessionConfig] = []
    private(set) var terminateCount = 0

    func start(config: TerminalSessionConfig) {
        startedConfigs.append(config)
    }

    func terminate() {
        terminateCount += 1
    }

    private(set) var performedActions: [String] = []
    @discardableResult
    func performAction(_ name: String) -> Bool {
        performedActions.append(name)
        return true
    }

    private(set) var sentInputs: [String] = []
    func sendInput(_ text: String) {
        sentInputs.append(text)
    }

    var nextSelection: String?
    func readSelection() -> String? {
        nextSelection
    }

    var contextMenuExtrasProvider: (() -> [ContextMenuExtra])?

    func emitPwd(_ path: String) {
        onPwdChange?(path)
    }

    func emitCommandFinished(exit: Int?, duration: TimeInterval) {
        onCommandFinished?(exit, duration)
    }
}
