import AppKit

struct TerminalSessionConfig {
    var command: String
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]

    static func defaultShell() -> TerminalSessionConfig {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? KookyShellIntegration.zshPath
        return TerminalSessionConfig(command: shell, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Pinned zsh — pairs with the ZDOTDIR wrapper for KOOKY_AGENT + OSC 7.
    static func zshShell() -> TerminalSessionConfig {
        TerminalSessionConfig(command: KookyShellIntegration.zshPath, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Bash via launcher script — direct `--rcfile` flags don't work because
    /// libghostty makes every `command` a login shell, which strips
    /// `--rcfile` semantics. Launcher re-execs as interactive non-login.
    static func bashShell(launcher: String) -> TerminalSessionConfig {
        TerminalSessionConfig(command: launcher, arguments: [], workingDirectory: nil, environment: [:])
    }
}

/// Item to prepend onto the terminal-pane right-click menu. The engine
/// owns the menu (libghostty has no built-in menu, GhosttySurfaceView
/// pops up an NSMenu in `rightMouseDown`); the kooky layer hands it the
/// "Ask <agent>" rows through this struct so the AppKit menu code stays
/// agnostic of WorkspaceStore / AgentTemplate.
@MainActor
struct ContextMenuExtra {
    let title: String
    /// Render with a leading `▸` glyph so the one-click default-agent
    /// path reads as the obvious choice. (NSMenu doesn't let us bold
    /// arbitrary items without a custom view, so the glyph is the affordance.)
    let isDefault: Bool
    let action: () -> Void
}

@MainActor
protocol TerminalEngine: AnyObject {
    var view: NSView { get }
    var backgroundColor: NSColor { get }
    /// Called when the engine observes a working-directory change (libghostty's
    /// `GHOSTTY_ACTION_PWD`, fired when the shell emits OSC 7). Lets the
    /// workspace track the active tab's cwd so new tabs inherit the latest path.
    var onPwdChange: ((String) -> Void)? { get set }
    /// Called when this engine's surface becomes the window's first responder
    /// (i.e. the user clicked into it). Lets the workspace mark the matching
    /// leaf as focused so split-aware operations (cwd tracking, ⌘D inheritance)
    /// follow the visually-active pane.
    var onFocus: (() -> Void)? { get set }
    /// Called when libghostty sees `OSC 133;D` from the shell — the
    /// most-recent command's exit code and run duration. `exitCode` is `nil`
    /// when the shell omitted it from the OSC sequence.
    var onCommandFinished: ((Int?, TimeInterval) -> Void)? { get set }
    /// Search lifecycle from libghostty's `start_search` / `end_search` /
    /// `navigate_search` keybinds. While `onSearchStart` is the most recent
    /// signal, libghostty owns the input loop and reports the current needle
    /// + total / selected match index back through these callbacks. The UI
    /// is a passive mirror — kooky doesn't push the needle string itself.
    var onSearchStart: ((String) -> Void)? { get set }
    var onSearchEnd: (() -> Void)? { get set }
    var onSearchTotal: ((Int) -> Void)? { get set }
    var onSearchSelected: ((Int) -> Void)? { get set }
    /// PID of the foreground process inside the surface. Used only as an
    /// initial/fallback env snapshot before the prompt hook reports live
    /// `VIRTUAL_ENV` / `NVM_BIN`.
    var foregroundPid: pid_t? { get }
    /// Fires when the surface's child process exits cleanly (exit code 0
    /// — `exit` / `logout` typed in the shell). Non-zero exits intentionally
    /// don't fire this — libghostty's "press any key to close" message
    /// stays so the user can read crash output before dismissing.
    var onProcessExitedCleanly: (() -> Void)? { get set }
    func start(config: TerminalSessionConfig)
    func terminate()
    /// Trigger a libghostty named action (e.g. `increase_font_size:1`,
    /// `decrease_font_size:1`, `reset_font_size`, `clear_screen`). Returns
    /// `true` when the engine recognised and dispatched the action.
    @discardableResult
    func performAction(_ name: String) -> Bool
    /// Sends committed text into the PTY as if the user typed it.
    func sendInput(_ text: String)
    /// Returns the current selection as a UTF-8 string, or nil if no
    /// selection is active. Powers the right-click "Ask agent" path and
    /// the menu-bar Copy item — same surface, two callers.
    func readSelection() -> String?
    /// Called by the engine at right-click time. Returning a non-empty
    /// array prepends these as menu rows above the engine's own Copy /
    /// Paste / Select All / Clear. Returning empty leaves the menu as
    /// kooky-vanilla. The callback runs on each right-click so the row
    /// list can be derived from live Settings → Agents state and the
    /// current selection.
    var contextMenuExtrasProvider: (() -> [ContextMenuExtra])? { get set }
}
