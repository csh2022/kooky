import Foundation

/// We don't bundle ghostty's shell-integration assets, so we ship a small zsh
/// wrapper that:
///   1. sources the user's real `~/.zshrc` so their config still applies, then
///   2. installs a `chpwd` hook that emits OSC 7 (`\e]7;file://host/path\e\\`).
///
/// Libghostty's `GHOSTTY_ACTION_PWD` then fires whenever the shell `cd`s, which
/// is what `WorkspaceStore` listens to for cwd-tracking.
enum KookyShellIntegration {
    /// POSIX single-quote wrap (escape internal `'` by `'\''`). Safe for
    /// arbitrary file paths and argv-style values; reused by anyone that
    /// builds a shell-command string for `engine.sendInput` or PTY spawn.
    static func quote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

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
        hooksDirectory.appendingPathComponent("claude.json").path
    }()

    /// Path to the kooky-managed Gemini system-defaults file. Surfaced to
    /// gemini-cli via `GEMINI_CLI_SYSTEM_SETTINGS_PATH`. Hook arrays merge
    /// with CONCAT semantics across tiers (verified in google-gemini/gemini-cli
    /// `settingsSchema.ts`), so this layers on top of user hooks instead of
    /// replacing them — non-intrusive.
    static let geminiDefaultsPath: String = {
        hooksDirectory.appendingPathComponent("gemini-defaults.json").path
    }()

    /// XDG plugin directory OpenCode auto-loads at startup. Honors
    /// `XDG_CONFIG_HOME` when set (the OpenCode launch is a child of the same
    /// shell, so a user-relocated config dir routes consistently between us
    /// and OpenCode); falls back to `~/.config`.
    static let opencodePluginPath: String = {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        let dir = base.appendingPathComponent("opencode/plugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kooky.ts").path
    }()

    private static let hooksDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky/hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Absolute path to the bundled `KookyHook` helper binary. Lives next to
    /// the main executable for both `swift run` (`.build/<config>/`) and
    /// `.app` bundles (`Contents/MacOS/`).
    static let kookyHookBinaryPath: String = {
        guard let exe = Bundle.main.executablePath else { return "" }
        let dir = (exe as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("KookyHook")
    }()

    /// Per-session env vars our wrappers + hook helper read. Caller supplies
    /// the surface UUID; everything else is process-wide. PATH prepends
    /// `kookyBinDirectory` so wrapper shims resolve before the real binaries.
    static func kookyEnvironment(for sessionId: UUID) -> [String: String] {
        let parentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        var env: [String: String] = [
            "KOOKY_SURFACE_ID": sessionId.uuidString,
            "KOOKY_HOOKS_PATH": claudeHooksPath,
            "KOOKY_BIN_DIR": kookyBinDirectory,
            "KOOKY_HOOK_BIN": kookyHookBinaryPath,
            "PATH": "\(kookyBinDirectory):\(parentPath)",
            // Gemini CLI loads this as the lowest-precedence settings tier,
            // but its hooks arrays use CONCAT-merge — so our entries fire
            // alongside whatever the user has in `~/.gemini/settings.json`,
            // not instead of. The file is ours, regenerated each launch.
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": geminiDefaultsPath,
            // libghostty defaults TERM to "xterm-ghostty"; not every system
            // ships its terminfo. Pinning to xterm-256color gives all TUIs a
            // well-known capability profile.
            "TERM": "xterm-256color",
        ]
        // Preserve the user's original ZDOTDIR (if they had one — rare, mostly
        // dotfile organizers). The wrapper rc consumes this to restore ZDOTDIR
        // after sourcing ~/.zshrc; child installer scripts then see the real
        // value (or no ZDOTDIR at all) and write PATH exports to ~/.zshrc
        // instead of our ephemeral wrapper rc.
        if let original = ProcessInfo.processInfo.environment["ZDOTDIR"], !original.isEmpty {
            env["KOOKY_ORIGINAL_ZDOTDIR"] = original
        }
        return env
    }

    /// Writes wrapper shims, hook configs, and the OpenCode plugin to disk.
    /// Idempotent — call on every app launch so each agent's hook command
    /// tracks the latest `KookyHook` location.
    static func installAgentHooks() {
        writeWrapper(name: "claude", script: claudeWrapperScript)
        writeWrapper(name: "codex", script: codexWrapperScript)
        // Gemini doesn't need a wrapper — `GEMINI_CLI_SYSTEM_SETTINGS_PATH`
        // in the spawned shell is enough for hooks to fire from gemini itself.
        writeWrapper(name: "opencode", script: bracketWrapperScript(slug: "opencode"))
        writeWrapper(name: "amp", script: bracketWrapperScript(slug: "amp"))

        let hookCmd = kookyHookBinaryPath
        writeJSON(at: claudeHooksPath, object: claudeHooksObject(hookCmd: hookCmd))
        writeJSON(at: geminiDefaultsPath, object: geminiDefaultsObject(hookCmd: hookCmd))
        writeManagedFile(at: opencodePluginPath, contents: opencodePluginScript)
    }

    /// Wired via `claude --settings <path>`. SessionStart promotes manually-typed
    /// `claude` immediately; without it the tab icon waits for the user's first
    /// prompt.
    static func claudeHooksObject(hookCmd: String) -> [String: Any] {
        hooksObject(slug: "claude", hookCmd: hookCmd, events: [
            "SessionStart":      .running,
            "UserPromptSubmit":  .running,
            "Stop":              .attention,
            "Notification":      .attention,
            "SessionEnd":        .ended,
        ])
    }

    /// Gemini's hook event names diverge from Claude's (BeforeAgent / AfterAgent
    /// instead of UserPromptSubmit / Stop). Hook scripts must not write to
    /// stdout — `KookyHook` only writes to its socket so this is safe.
    /// SessionStart promotes manually-typed `gemini` to `.gemini` immediately,
    /// same pattern as Claude.
    static func geminiDefaultsObject(hookCmd: String) -> [String: Any] {
        hooksObject(slug: "gemini", hookCmd: hookCmd, events: [
            "SessionStart": .running,
            "BeforeAgent":  .running,
            "AfterAgent":   .attention,
            "Notification": .attention,
            "SessionEnd":   .ended,
        ])
    }

    /// Builds a `claude --settings`-style hooks object for any agent that
    /// follows the `{"hooks": {<EventName>: [{"hooks": [{"type": "command",
    /// "command": "..."}]}]}}` shape (Claude Code, Gemini CLI). Routing
    /// `HookEvent` cases through `.rawValue` keeps the wrapper-emitted strings
    /// in sync with the receiver in `HookServer`.
    private static func hooksObject(
        slug: String,
        hookCmd: String,
        events: [String: HookEvent]
    ) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (event, state) in events {
            hooks[event] = [["hooks": [["type": "command", "command": "\(hookCmd) \(slug) \(state.rawValue)"]]]]
        }
        return ["hooks": hooks]
    }

    /// Marker we embed at the top of every kooky-generated user-config file
    /// (currently the OpenCode plugin). `writeManagedFile` reads existing
    /// files and refuses to overwrite anything that doesn't carry this tag —
    /// so a user's same-named plugin stays untouched on upgrade.
    private static let managedFileMarker = "kooky-managed-do-not-edit"

    private static func writeJSON(at path: String, object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Writes a file in user-config space (e.g. OpenCode plugin) only when
    /// either the path is unused or the existing content carries our marker.
    /// A user-owned file with the same name is left alone — better to skip a
    /// feature than nuke their plugin.
    private static func writeManagedFile(at path: String, contents: String) {
        let url = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.contains(managedFileMarker) {
            return
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
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
            printf '\\n  \\033[33m⚠\\033[0m  %s is not installed.\\n\\n' "\(binary)" >&2
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

    /// Generic bracket wrapper for agents we can't drive mid-run state from
    /// (no hook system or no installed plugin yet). Sends `running` before
    /// exec and `ended` after exit; activity dot stays green for the whole
    /// run, then drops to idle on quit. Used for `amp` (no plugin) and
    /// `opencode` — opencode's plugin upgrades mid-run state once installed.
    static func bracketWrapperScript(slug: String) -> String {
        """
        \(wrapperPreamble(binary: slug))

        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
            "$KOOKY_HOOK_BIN" \(slug) running 2>/dev/null
            "$real" "$@"
            status=$?
            "$KOOKY_HOOK_BIN" \(slug) ended 2>/dev/null
            exit $status
        fi
        exec "$real" "$@"
        """
    }

    /// OpenCode auto-loads any `.ts`/`.js` file in
    /// `$XDG_CONFIG_HOME/opencode/plugin/` (or `~/.config/opencode/plugin/`)
    /// at startup. The plugin runs in opencode's own Bun runtime, inherits
    /// KOOKY_SURFACE_ID + KOOKY_HOOK_BIN from the shell, and shells out to
    /// KookyHook on each lifecycle event. The first-line marker
    /// (`managedFileMarker`) lets `writeManagedFile` recognise the file as
    /// kooky-generated on upgrade — a user's own `kooky.ts` plugin would
    /// not carry the marker and stays untouched.
    static let opencodePluginScript = """
    // \(managedFileMarker) — pings KookyHook on prompt-submit and turn-end so
    // the sidebar agent dot tracks per-session activity. Safe to delete; will
    // be regenerated next time kooky launches.
    export const KookyPlugin = async ({ $ }) => {
      const surface = process.env.KOOKY_SURFACE_ID
      const hookBin = process.env.KOOKY_HOOK_BIN
      if (!surface || !hookBin) return {}

      const ping = async (state) => {
        try { await $`${hookBin} opencode ${state}`.quiet() } catch {}
      }

      return {
        "chat.message": async () => { await ping("running") },
        event: async ({ event }) => {
          if (event?.type === "session.idle") await ping("attention")
        },
      }
    }
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
        # Default word-jump bindings; readline doesn't bind Ctrl/Alt+arrow on
        # macOS by default. See the matching block in zshDirectory.
        bind '"\\e[1;5D": backward-word'     # Ctrl+Left
        bind '"\\e[1;5C": forward-word'      # Ctrl+Right
        bind '"\\e[1;3D": backward-word'     # Alt+Left
        bind '"\\e[1;3C": forward-word'      # Alt+Right

        [[ -r "$HOME/.bashrc" ]] && source "$HOME/.bashrc"

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOSTNAME" "$PWD"; }
        \(envStatusBlock)

        PROMPT_COMMAND="_kooky_osc7_pwd;_kooky_env_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        _kooky_osc7_pwd
        _kooky_env_status

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
        # Default word-jump bindings. zsh ZLE only binds Alt+B/F by default;
        # most other terminals (iTerm2, ghostty, Apple Terminal) remap the
        # Ctrl/Alt+arrow sequences to ESC+B/F so users don't notice. kooky
        # binds them directly here. Placed before sourcing ~/.zshrc so user
        # rc files retain final say if they override the same sequences.
        bindkey '^[[1;5D' backward-word    # Ctrl+Left
        bindkey '^[[1;5C' forward-word     # Ctrl+Right
        bindkey '^[[1;3D' backward-word    # Alt+Left
        bindkey '^[[1;3C' forward-word     # Alt+Right

        [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"

        # zsh has now consumed ZDOTDIR to locate this rc; restore the user's
        # original (almost always empty) so child processes look at the real
        # ~/.zshrc. Without this, `curl | bash`-style installers (opencode,
        # rustup, etc.) detect `$ZDOTDIR/.zshrc` and append PATH exports to
        # our ephemeral wrapper rc — gone the moment kooky exits.
        if [[ -n "$KOOKY_ORIGINAL_ZDOTDIR" ]]; then
            export ZDOTDIR="$KOOKY_ORIGINAL_ZDOTDIR"
            unset KOOKY_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        autoload -Uz add-zsh-hook
        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOST" "$PWD" }
        add-zsh-hook chpwd _kooky_osc7_pwd
        _kooky_osc7_pwd

        \(envStatusBlock)

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
            # `eval` lets KOOKY_AGENT carry multi-word commands (e.g. an
            # editor + file path); single-word agent commands like `claude`
            # behave identically.
            eval "$_kooky_cmd"
        fi
        """

    /// Two layers of memoization in this hook avoid heavy per-prompt work:
    /// (a) `node --version` is the dominant cost (~50-200ms for V8 cold-start
    ///     on every prompt). We cache its result against the resolved `node`
    ///     binary path + NVM_BIN — if neither changed, the cached version is
    ///     still valid.
    /// (b) the `kooky-hook env` IPC fork is skipped entirely when no env key
    ///     differs from the previous send. Most prompts have steady env, so
    ///     this turns the hook into a no-op the vast majority of the time.
    static let envStatusBlock = """
        _kooky_env_status() {
            [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" && -x "$KOOKY_HOOK_BIN" ]] || return 0
            local _kooky_node_path=""
            command -v node >/dev/null 2>&1 && _kooky_node_path="$(command -v node)"
            local _kooky_node_key="${_kooky_node_path}|${NVM_BIN:-}"
            if [[ "$_kooky_node_key" != "$_KOOKY_NODE_KEY_LAST" ]]; then
                _KOOKY_NODE_VERSION_LAST=""
                [[ -n "$_kooky_node_path" ]] && _KOOKY_NODE_VERSION_LAST="$("$_kooky_node_path" --version 2>/dev/null)"
                _KOOKY_NODE_KEY_LAST="$_kooky_node_key"
            fi
            # Accept both lowercase and uppercase forms — curl / git / requests
            # respect lowercase; some tools (and many corp setups) export
            # uppercase only. Fall through to uppercase when lowercase is unset.
            local _kooky_https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
            local _kooky_http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
            local _kooky_all_proxy="${all_proxy:-${ALL_PROXY:-}}"
            local _kooky_env_now="${VIRTUAL_ENV:-}|${CONDA_DEFAULT_ENV:-}|${NVM_BIN:-}|${NVM_DIR:-}|$_KOOKY_NODE_VERSION_LAST|$_kooky_https_proxy|$_kooky_http_proxy|$_kooky_all_proxy"
            [[ "$_kooky_env_now" == "$_KOOKY_ENV_LAST" ]] && return 0
            # Only advance the dedup cache when the IPC actually succeeded —
            # if kooky-hook returns non-zero (kooky restarting, socket gone
            # before the hook server bound), the next prompt will retry
            # instead of staying frozen at the unsent value.
            "$KOOKY_HOOK_BIN" env "${VIRTUAL_ENV:-}" "${CONDA_DEFAULT_ENV:-}" "${NVM_BIN:-}" "${NVM_DIR:-}" "$_KOOKY_NODE_VERSION_LAST" "$_kooky_https_proxy" "$_kooky_http_proxy" "$_kooky_all_proxy" 2>/dev/null \
                && _KOOKY_ENV_LAST="$_kooky_env_now"
            # Mask our internal IPC status so user precmd hooks downstream in
            # zsh's precmd_functions chain don't see `$?=1` and bleed it into
            # their prompt rendering. The dedup logic is internal — its
            # success/failure must not leak into the rest of the shell.
            return 0
        }
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
            _kooky_env_status
            # Same masking concern as `_kooky_env_status` itself: the kooky
            # hooks must not leak `$?` into user prompts that downstream
            # precmd hooks may sample.
            return 0
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
