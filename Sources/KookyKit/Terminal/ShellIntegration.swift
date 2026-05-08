import Foundation

/// We don't bundle ghostty's shell-integration assets, so we ship a small zsh
/// wrapper that:
///   1. sources the user's real `~/.zshrc` so their config still applies, then
///   2. installs a `chpwd` hook that emits OSC 7 (`\e]7;file://host/path\e\\`).
///
/// Libghostty's `GHOSTTY_ACTION_PWD` then fires whenever the shell `cd`s, which
/// is what `WorkspaceStore` listens to for cwd-tracking.
enum KookyShellIntegration {
    static let zshPath = "/bin/zsh"
    static let bashPath = "/bin/bash"
    static let zdotdirKey = "ZDOTDIR"

    /// Directory we prepend to spawned-shell `PATH` so wrapper scripts (e.g.
    /// `claude` shim) get found before the real binaries on disk.
    static let kookyBinDirectory: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    /// Path to the generated Claude Code hooks JSON. Passed to `claude` via
    /// `--settings <path>` by the wrapper script when `KOOKY_SURFACE_ID` is set.
    static let claudeHooksPath: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky/hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude.json").path
    }()

    /// Absolute path to the bundled `KookyHook` helper binary. Lives next to
    /// the main executable for both `swift run` (`.build/<config>/`) and
    /// `.app` bundles (`Contents/MacOS/`).
    static let kookyHookBinaryPath: String = {
        guard let exe = Bundle.main.executablePath else { return "" }
        let dir = (exe as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("KookyHook")
    }()

    /// Writes the `claude` wrapper script and the hooks JSON to disk. Idempotent
    /// — call on every app launch so the hook command tracks the latest
    /// `KookyHook` location.
    static func installAgentHooks() {
        let claudeWrapper = """
        #!/usr/bin/env bash
        # kooky claude wrapper. Inside a kooky session ($KOOKY_SURFACE_ID set),
        # injects --settings so Claude Code's hooks report state back to the
        # app via the bundled KookyHook helper. Outside, transparent passthrough.

        self_dir="$(cd "$(dirname "$0")" && pwd)"
        real=""
        IFS=:
        for dir in $PATH; do
            [[ "$dir" == "$self_dir" ]] && continue
            if [[ -x "$dir/claude" ]]; then
                real="$dir/claude"
                break
            fi
        done
        unset IFS

        if [[ -z "$real" ]]; then
            echo "kooky: real 'claude' binary not found in PATH" >&2
            exit 127
        fi

        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOKS_PATH" ]]; then
            exec "$real" --settings "$KOOKY_HOOKS_PATH" "$@"
        fi
        exec "$real" "$@"
        """
        let claudeWrapperPath = (kookyBinDirectory as NSString).appendingPathComponent("claude")
        try? claudeWrapper.write(toFile: claudeWrapperPath, atomically: true, encoding: .utf8)
        chmod(claudeWrapperPath, 0o755)

        let hookCmd = kookyHookBinaryPath
        let hooks: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": "\(hookCmd) running"]]]],
                "Stop":             [["hooks": [["type": "command", "command": "\(hookCmd) attention"]]]],
                "Notification":     [["hooks": [["type": "command", "command": "\(hookCmd) attention"]]]],
                "SessionEnd":       [["hooks": [["type": "command", "command": "\(hookCmd) idle"]]]],
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: claudeHooksPath), options: .atomic)
        }
    }

    enum DetectedUserShell { case zsh, bash, other }

    static var detectedUserShell: DetectedUserShell {
        let path = ProcessInfo.processInfo.environment["SHELL"] ?? zshPath
        if path.hasSuffix("/zsh") { return .zsh }
        if path.hasSuffix("/bash") { return .bash }
        return .other
    }

    /// Path to a tiny launcher script that re-execs bash as an interactive,
    /// non-login shell with our `--rcfile`. Required because libghostty starts
    /// every `command` as a login shell (`argv[0]` prefixed with `-`), and
    /// login bash ignores `--rcfile` entirely (it reads `~/.bash_profile`
    /// instead). The launcher is a degenerate `bash` itself, so it gets the
    /// login prefix; it then `exec`s a fresh bash without the prefix.
    static let bashLauncherPath: String = {
        let dir = NSTemporaryDirectory()
        let launcherPath = dir.appending("kooky-bash-launch-\(getpid()).sh")
        let rcfilePath = dir.appending("kooky-bashrc-\(getpid())")

        let bashrc = """
        [[ -r "$HOME/.bashrc" ]] && source "$HOME/.bashrc"

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOSTNAME" "$PWD"; }
        PROMPT_COMMAND="_kooky_osc7_pwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        _kooky_osc7_pwd

        \(agentLaunchBlock)
        """
        writeFile(at: rcfilePath, contents: bashrc)

        let launcher = """
        #!/bin/bash
        exec \(bashPath) --rcfile "\(rcfilePath)" -i

        """
        writeFile(at: launcherPath, contents: launcher, executable: true)
        return launcherPath
    }()

    /// Path to a per-process directory containing our wrapper `.zshrc`. Pass
    /// this as `ZDOTDIR` when spawning zsh so it loads the wrapper instead of
    /// `~/.zshrc` directly.
    static let zshDirectory: String = {
        let dir = NSTemporaryDirectory().appending("kooky-zsh-\(getpid())")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir), withIntermediateDirectories: true
        )
        let zshrc = """
        [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        autoload -Uz add-zsh-hook
        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOST" "$PWD" }
        add-zsh-hook chpwd _kooky_osc7_pwd
        _kooky_osc7_pwd

        \(agentLaunchBlock)
        """
        writeFile(at: (dir as NSString).appendingPathComponent(".zshrc"), contents: zshrc)
        return dir
    }()

    /// Removes per-process temp files. Wired into `applicationWillTerminate`
    /// so wrappers don't accumulate in `NSTemporaryDirectory()` across runs.
    static func cleanup() {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory()
        let pid = getpid()
        for path in [
            dir.appending("kooky-bash-launch-\(pid).sh"),
            dir.appending("kooky-bashrc-\(pid)"),
            dir.appending("kooky-zsh-\(pid)"),
        ] {
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Internals

    /// Inline agent launch — invoked by both wrapper rcs to start KOOKY_AGENT
    /// before the first prompt prints. KOOKY_AGENT_LAUNCHED guards against
    /// re-entry from subshells the agent itself may spawn.
    private static let agentLaunchBlock = """
        if [[ -n "$KOOKY_AGENT" && -z "$KOOKY_AGENT_LAUNCHED" ]]; then
            export KOOKY_AGENT_LAUNCHED=1
            _kooky_cmd="$KOOKY_AGENT"
            unset KOOKY_AGENT
            "$_kooky_cmd"
        fi
        """

    private static func writeFile(at path: String, contents: String, executable: Bool = false) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { chmod(path, 0o755) }
    }
}
