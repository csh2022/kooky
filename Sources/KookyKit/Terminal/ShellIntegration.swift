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
    /// Per-session env vars our wrappers + hook helper read. Caller supplies
    /// the surface UUID; everything else is process-wide. PATH prepends
    /// `kookyBinDirectory` so wrapper shims resolve before the real binaries.
    static func kookyEnvironment(for sessionId: UUID) -> [String: String] {
        let parentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return [
            "KOOKY_SURFACE_ID": sessionId.uuidString,
            "KOOKY_HOOKS_PATH": claudeHooksPath,
            "KOOKY_BIN_DIR": kookyBinDirectory,
            "KOOKY_HOOK_BIN": kookyHookBinaryPath,
            "PATH": "\(kookyBinDirectory):\(parentPath)",
            // libghostty defaults TERM to "xterm-ghostty"; not every system
            // ships its terminfo. Pinning to xterm-256color gives all TUIs a
            // well-known capability profile.
            "TERM": "xterm-256color",
        ]
    }

    static func installAgentHooks() {
        writeWrapper(name: "claude", script: claudeWrapperScript)
        writeWrapper(name: "codex", script: codexWrapperScript)

        // Claude Code hooks JSON — fully event-aware (running / attention / idle).
        // Each command also reports the agent name so the app can upgrade a
        // session's icon when the user runs `claude` inside a plain terminal.
        let hookCmd = kookyHookBinaryPath
        // No SessionStart hook on purpose: the agent template is either set
        // upfront (+ menu spawn) or promoted on the first real event below.
        // SessionEnd uses a distinct `ended` so the app can also revert the
        // session back to .terminal — agent's gone, the icon should reflect.
        let hooks: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": "\(hookCmd) claude running"]]]],
                "Stop":             [["hooks": [["type": "command", "command": "\(hookCmd) claude attention"]]]],
                "Notification":     [["hooks": [["type": "command", "command": "\(hookCmd) claude attention"]]]],
                "SessionEnd":       [["hooks": [["type": "command", "command": "\(hookCmd) claude ended"]]]],
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: claudeHooksPath), options: .atomic)
        }
    }

    private static func writeWrapper(name: String, script: String) {
        let path = (kookyBinDirectory as NSString).appendingPathComponent(name)
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    /// Common bash header for every wrapper: locate the real binary on
    /// `$PATH` skipping our own dir, abort if missing.
    private static func wrapperPreamble(binary: String) -> String {
        """
        #!/usr/bin/env bash
        self_dir="$(cd "$(dirname "$0")" && pwd)"
        real=""
        IFS=:
        for dir in $PATH; do
            [[ "$dir" == "$self_dir" ]] && continue
            if [[ -x "$dir/\(binary)" ]]; then
                real="$dir/\(binary)"
                break
            fi
        done
        unset IFS

        if [[ -z "$real" ]]; then
            echo "kooky: real '\(binary)' binary not found in PATH" >&2
            exit 127
        fi
        """
    }

    /// Inside a kooky session ($KOOKY_SURFACE_ID set), injects --settings so
    /// Claude Code's hooks report state back to the app via the bundled
    /// KookyHook helper. Outside, transparent passthrough.
    private static let claudeWrapperScript = """
    \(wrapperPreamble(binary: "claude"))

    if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOKS_PATH" ]]; then
        exec "$real" --settings "$KOOKY_HOOKS_PATH" "$@"
    fi
    exec "$real" "$@"
    """

    /// Codex doesn't expose a Claude-style hooks settings file we can override
    /// per-invocation, but it does have `notify = ["cmd", "arg", ...]` in
    /// config.toml — fired after each agent turn with a JSON payload appended
    /// as the final argv. We override `notify` inline via `-c` so user's
    /// ~/.codex/config.toml is left untouched. The single signal we get is
    /// "turn complete" which we map to `attention`.
    private static let codexWrapperScript = """
    \(wrapperPreamble(binary: "codex"))

    if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
        # Codex doesn't expose SessionStart / SessionEnd lifecycle hooks
        # we can override per-invocation. Bracket the run from the wrapper:
        # send `running` before codex starts (immediate icon promotion),
        # then `ended` after exit (revert to terminal). Mid-run state
        # transitions still come from Codex's `notify` config below.
        "$KOOKY_HOOK_BIN" codex running 2>/dev/null
        "$real" -c "notify=[\\"$KOOKY_HOOK_BIN\\",\\"codex\\",\\"attention\\"]" "$@"
        status=$?
        "$KOOKY_HOOK_BIN" codex ended 2>/dev/null
        exit $status
    fi
    exec "$real" "$@"
    """

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

        \(osc133Block)

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

    /// FinalTerm / OSC 133 prompt+command boundary markers. libghostty parses
    /// these and fires `GHOSTTY_ACTION_COMMAND_FINISHED` on `D`, which kooky
    /// uses to surface per-tab last-command status (exit + duration) and to
    /// power scroll-to-prompt jumps. Re-injects the `B` marker into PROMPT on
    /// every redraw because Starship / p10k-style themes rebuild PROMPT each
    /// `precmd` and would otherwise drop our suffix.
    private static let osc133Block = #"""
        __kooky_133_first=1
        __kooky_133_precmd() {
            local last=$?
            if (( ! __kooky_133_first )); then
                printf '\e]133;D;%s\e\\' "$last"
            fi
            __kooky_133_first=0
            printf '\e]133;A\e\\'
            [[ "$PROMPT" != *$'\e]133;B\e\\'* ]] && PROMPT="${PROMPT}"$'\e]133;B\e\\'
        }
        __kooky_133_preexec() { printf '\e]133;C\e\\' }
        add-zsh-hook precmd __kooky_133_precmd
        add-zsh-hook preexec __kooky_133_preexec
        """#

    private static func writeFile(at path: String, contents: String, executable: Bool = false) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { chmod(path, 0o755) }
    }
}
