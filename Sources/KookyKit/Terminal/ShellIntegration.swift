import AppKit
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

    /// Backslash-escape every POSIX shell metacharacter — matches the
    /// `\ ` / `\'` style Finder uses when dragging a file onto Terminal.app
    /// or ghostty.app. Picks this over `quote(_:)` for the drag-and-drop
    /// path so the user sees the same untouched-looking path they'd see in
    /// any other macOS terminal, rather than a surrounding pair of quotes.
    /// Non-ASCII bytes (Chinese / emoji / accented chars) pass through
    /// unescaped — every modern shell accepts them as raw UTF-8.
    ///
    /// Edge case: filenames with embedded newlines are legal on macOS but
    /// POSIX shells eat `\<newline>` as line-continuation, dropping both
    /// chars instead of preserving the literal newline. We fall back to
    /// `quote(_:)` for those — visible quotes are uglier than `\ `, but
    /// silent path corruption is worse.
    static func backslashEscape(_ s: String) -> String {
        if s.contains("\n") {
            return quote(s)
        }
        var result = ""
        result.reserveCapacity(s.count)
        for char in s {
            if shellMetacharacters.contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }

    private static let shellMetacharacters: Set<Character> = [
        " ", "\t", "\n", "\\", "\"", "'", "`", "$",
        "(", ")", "|", "&", ";", "<", ">", "*", "?",
        "[", "]", "{", "}", "~", "!", "#",
    ]

    /// Filter `urls` to fileURLs, `backslashEscape` each path, join by
    /// spaces. Nil when nothing survives the filter — the caller falls
    /// through to other paste sources. Shared between Finder drag-drop
    /// (v0.11.3 `performDragOperation`) and Cmd+V on a Finder Copy
    /// (v0.18.2 paste path): both produce a multi-URL pasteboard the
    /// user expects to render as terminal argv.
    static func backslashEscapedFileURLs(_ urls: [URL]) -> String? {
        let escaped = urls.compactMap { $0.isFileURL ? backslashEscape($0.path) : nil }
        return escaped.isEmpty ? nil : escaped.joined(separator: " ")
    }

    /// Resolve pasteboard contents into a terminal-safe text payload —
    /// what Cmd+V and the right-click "Paste" entry should inject.
    ///
    /// Precedence:
    /// 1. **File URLs** (Finder Copy on a file — including images) →
    ///    `backslashEscape($0.path)` joined by spaces. Without this,
    ///    `pb.string(forType: .string)` for a fileURL returns just the
    ///    last path component (the filename), which agents can't open.
    ///    Warp / iTerm2 both do this; matches user expectation.
    /// 2. **Raw image data** (`Cmd+Ctrl+Shift+4` screenshot to
    ///    clipboard, Preview "Edit → Copy" on an open image) →
    ///    spilled to `~/Library/Caches/kooky/pastes/screenshot-<ts>.png`,
    ///    then `backslashEscape(file.path)`. Agents (Claude / Cursor /
    ///    Codex) take a file path as input; storing the bytes inline
    ///    would dump base64 garbage into the prompt.
    /// 3. **Plain string** → raw, no escaping (we'd corrupt `ls -la`).
    ///    `bracketed-paste` mode already isolates it from shell parsing.
    static func readTerminalPasteText(from pb: NSPasteboard) -> String? {
        if pb.availableType(from: [.fileURL]) != nil,
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let joined = backslashEscapedFileURLs(urls)
        {
            return joined
        }
        if pb.availableType(from: [.png, .tiff]) != nil,
           let cached = writePasteboardImageToCache(pb)
        {
            return backslashEscape(cached.path)
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            return text
        }
        return nil
    }

    /// Cheap probe used by the right-click "Paste" menu's enabled gate.
    /// Mirrors `readTerminalPasteText`'s precedence but skips the
    /// image-to-disk write so a menu open never spills cache files.
    /// `availableType(...)` is preferred over `pb.string(...)` for the
    /// string check — `pb.string` materialises the full pasted bytes
    /// into a Swift heap copy (~100ms for a 10MB clipboard) just for
    /// an emptiness check; `availableType` is constant-time.
    static func pasteboardHasTerminalPasteContent(_ pb: NSPasteboard) -> Bool {
        if pb.availableType(from: [.fileURL]) != nil,
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: { $0.isFileURL })
        {
            return true
        }
        if pb.availableType(from: [.png, .tiff, .string]) != nil {
            return true
        }
        return false
    }

    /// Spill a pasteboard image to a kooky-owned cache file. Returns
    /// the resulting URL on success. Prefers `.png` bytes verbatim;
    /// re-encodes `.tiff` to PNG via `NSBitmapImageRep` when only TIFF
    /// is offered (Cmd+Shift+3 screenshots land as TIFF, not PNG) —
    /// agents accept PNG universally, TIFF support is uneven.
    private static func writePasteboardImageToCache(_ pb: NSPasteboard) -> URL? {
        guard let data = pasteboardPNGData(pb) else { return nil }
        let ts = pasteFilenameTimestamp.string(from: Date())
        let file = pastesCacheDirectory.appendingPathComponent("screenshot-\(ts).png")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    private static func pasteboardPNGData(_ pb: NSPasteboard) -> Data? {
        if let direct = pb.data(forType: .png) { return direct }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let encoded = rep.representation(using: .png, properties: [:])
        {
            return encoded
        }
        return nil
    }

    private static let pasteFilenameTimestamp: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt
    }()

    /// Lazy-created `~/Library/Caches/kooky/pastes/`. Mirrors the
    /// `kookyBinDirectory` / `hooksDirectory` pattern: one
    /// `createDirectory` at first access, all subsequent paste-spills
    /// skip the FS check.
    private static let pastesCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("kooky/pastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Sweep stale paste-cache files. macOS evicts Caches under disk
    /// pressure but only when free space is critical — meanwhile a
    /// daily-paste-screenshots workflow accumulates GBs. Call at app
    /// startup via `Task.detached` so it doesn't block launch. The
    /// 30-day default matches Chrome / Firefox HTTP-cache policy.
    static func prunePastesCache(olderThan: TimeInterval = 30 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: pastesCacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        for url in contents {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mod, mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
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

    /// Path to the kooky-managed Copilot hooks file. Copilot CLI auto-loads
    /// every `~/.copilot/hooks/*.json` and merges events across files, so a
    /// dedicated `kooky.json` co-exists with anything the user has dropped
    /// in there. Pure path computation — the directory is materialised
    /// (and the file written) only when `~/.copilot/` already exists, so
    /// non-Copilot users don't get an empty kooky-owned vendor dir in their
    /// home. We don't honor `COPILOT_HOME` from the user's shell here —
    /// kooky.app runs out-of-process, can't see interactive shell env — so
    /// users who customise `COPILOT_HOME` would drop the file themselves.
    static let copilotHooksPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/kooky.json").path
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
    /// `claudeCustomSettingsAgentId`, when set, routes `KOOKY_HOOKS_PATH` to
    /// that custom agent's per-agent Claude settings file (endpoint / key)
    /// instead of the shared `claude.json`.
    static func kookyEnvironment(
        for sessionId: UUID,
        claudeCustomSettingsAgentId: String? = nil
    ) -> [String: String] {
        let parentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let hooksPath = claudeCustomSettingsAgentId.map(claudeCustomSettingsPath(agentId:)) ?? claudeHooksPath
        var env: [String: String] = [
            "KOOKY_SURFACE_ID": sessionId.uuidString,
            "KOOKY_HOOKS_PATH": hooksPath,
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
        writeWrapper(name: "cursor-agent", script: bracketWrapperScript(slug: "cursor-agent"))
        writeWrapper(name: "copilot", script: bracketWrapperScript(slug: "copilot"))
        writeWrapper(name: "grok", script: bracketWrapperScript(slug: "grok"))
        writeWrapper(name: "agy", script: antigravityWrapperScript)
        writeWrapper(name: "kimi", script: bracketWrapperScript(slug: "kimi"))

        let hookCmd = kookyHookBinaryPath
        writeJSON(at: claudeHooksPath, object: claudeHooksObject(hookCmd: hookCmd))
        writeJSON(at: geminiDefaultsPath, object: geminiDefaultsObject(hookCmd: hookCmd))
        installCopilotHooksIfPresent(hookCmd: hookCmd)
        writeManagedFile(at: opencodePluginPath, contents: opencodePluginScript)
        // Grok CLI has no JSON hook file like Claude — its `~/.grok/hooks/`
        // is a script directory driven by env vars (GROK_HOOK_EVENT /
        // GROK_SESSION_ID), so the bracket wrapper handles running/ended
        // and full lifecycle integration requires a different code path.
        //
        // Kimi Code's hooks are TOML-only (`~/.kimi-code/config.toml`
        // `[[hooks]]`) with no system-settings env-var override — so unlike
        // Gemini we can't point it at a kooky-owned defaults file, and unlike
        // Copilot it has no per-event hooks directory; the bracket wrapper
        // gives running/ended until a config.toml-merge path exists.
    }

    /// Writes the Copilot hooks JSON only when the user already has a
    /// `~/.copilot/` directory — i.e. they've at least run Copilot CLI once.
    /// Skips otherwise so kooky doesn't pre-stage a vendor namespace for
    /// users who may never install Copilot. Installing Copilot later then
    /// requires one kooky restart to pick up the hooks (acceptable: the
    /// bracket wrapper still gives running/ended on the first run).
    private static func installCopilotHooksIfPresent(hookCmd: String) {
        let copilotHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
        guard FileManager.default.fileExists(atPath: copilotHome.path) else { return }
        let hooksDir = copilotHome.appendingPathComponent("hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        writeManagedJSON(at: copilotHooksPath, object: copilotHooksObject(hookCmd: hookCmd))
    }

    /// Wired via `claude --settings <path>`. SessionStart promotes manually-typed
    /// `claude` immediately; without it the tab icon waits for the user's first
    /// prompt. PreToolUse / PostToolUse / PostToolUseFailure subscribe Claude's
    /// tool-call lifecycle so the activity strip can render pills — they pass
    /// their raw event name as `argv[2]` (not a `HookEvent` rawValue) because
    /// `main.swift` reads stdin for those events and routes through
    /// `parseToolEventPayload`, not `buildLifecyclePayload`. Without
    /// `PostToolUseFailure`, a failed tool call's Pre record sits in `.running`
    /// for 60s before flipping to `.stalled` instead of immediately showing the
    /// red failure pill.
    static func claudeHooksObject(hookCmd: String) -> [String: Any] {
        hooksObject(
            slug: "claude",
            hookCmd: hookCmd,
            events: [
                "SessionStart":      .running,
                "UserPromptSubmit":  .running,
                "Stop":              .attention,
                "Notification":      .attention,
                "SessionEnd":        .ended,
            ],
            passthroughEvents: ["PreToolUse", "PostToolUse", "PostToolUseFailure"]
        )
    }

    /// Path to a per-custom-agent Claude settings file. Same directory as
    /// `claudeHooksPath`; named `claude-<agentId>.json` (id sanitised so a
    /// hand-edited settings.json can't escape the directory). Written by
    /// `refreshClaudeCustomSettings` and passed to `claude` via `--settings`
    /// for that agent's sessions, overriding `KOOKY_HOOKS_PATH`.
    static func claudeCustomSettingsPath(agentId: String) -> String {
        let safe = String(agentId.map {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" ? $0 : "_"
        })
        return hooksDirectory.appendingPathComponent("claude-\(safe).json").path
    }

    /// A Claude `settings.json` fragment for a custom agent: the hooks
    /// `claudeHooksObject` produces, plus an `env` block carrying the
    /// agent's custom environment (endpoint / key / …). Passed to `claude`
    /// via `--settings`, so the variables apply to that Claude process
    /// only — kooky never exports them to the shell.
    static func claudeCustomSettingsObject(env: [String: String], hookCmd: String) -> [String: Any] {
        var object = claudeHooksObject(hookCmd: hookCmd)
        object["env"] = env
        return object
    }

    /// Materialises a per-agent Claude settings file for every Claude-Code-
    /// based custom agent that carries an env block, and deletes any stale
    /// `claude-<id>.json` no longer matching one (a since-deleted agent, or
    /// an env block the user cleared — the file can hold an API token).
    /// Called at launch and after every Settings save, so the on-disk files
    /// always track the current custom-agent set.
    static func refreshClaudeCustomSettings(customAgents: [CustomAgentData]) {
        let hookCmd = kookyHookBinaryPath
        var liveFiles: Set<String> = []
        for agent in customAgents where agent.baseAgentId == AgentTemplate.claudeCodeID {
            let env = AgentTemplate.parseEnv(agent.env)
            guard !env.isEmpty else { continue }
            let path = claudeCustomSettingsPath(agentId: agent.id)
            writeJSON(at: path, object: claudeCustomSettingsObject(env: env, hookCmd: hookCmd))
            liveFiles.insert((path as NSString).lastPathComponent)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: hooksDirectory.path)
        else { return }
        for name in names
        where name.hasPrefix("claude-") && name.hasSuffix(".json") && !liveFiles.contains(name) {
            try? FileManager.default.removeItem(at: hooksDirectory.appendingPathComponent(name))
        }
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

    /// Copilot CLI's hooks schema diverges from Claude/Gemini's enough that
    /// it doesn't fit `hooksObject`: top-level `version: 1`, camelCase event
    /// names, no inner `{"hooks": [...]}` wrapper, and the command goes in
    /// a `bash` field (not `command`). Event mapping mirrors Claude's
    /// (sessionStart / userPromptSubmitted → running; agentStop / notification
    /// → attention; sessionEnd → ended). The `_kookyManaged` sentinel is the
    /// JSON-friendly equivalent of the text marker — `writeManagedJSON` reads
    /// it back to decide whether the file is ours to overwrite.
    static func copilotHooksObject(hookCmd: String) -> [String: Any] {
        let events: [(String, HookEvent)] = [
            ("sessionStart",        .running),
            ("userPromptSubmitted", .running),
            ("agentStop",           .attention),
            ("notification",        .attention),
            ("sessionEnd",          .ended),
        ]
        var hooks: [String: Any] = [:]
        let quotedCmd = quote(hookCmd)
        for (event, state) in events {
            hooks[event] = [
                ["type": "command", "bash": "\(quotedCmd) copilot \(state.rawValue)", "timeoutSec": 5]
            ]
        }
        return ["version": 1, "_kookyManaged": managedFileMarker, "hooks": hooks]
    }

    /// Builds a `claude --settings`-style hooks object for any agent that
    /// follows the `{"hooks": {<EventName>: [{"hooks": [{"type": "command",
    /// "command": "..."}]}]}}` shape (Claude Code, Gemini CLI). Routing
    /// `HookEvent` cases through `.rawValue` keeps the wrapper-emitted strings
    /// in sync with the receiver in `HookServer`.
    /// Builds a Claude / Gemini-style hooks JSON object. `events` maps hook
    /// names → lifecycle state (running / attention / idle / ended); kooky-hook
    /// is invoked with the state's rawValue as `argv[2]`. `passthroughEvents`
    /// is for events whose handler needs the raw event name preserved (e.g.
    /// Claude's `PreToolUse` / `PostToolUse` — kooky-hook reads stdin for
    /// those and dispatches via `parseToolEventPayload`, so the raw name is
    /// what main.swift gates on, not a HookEvent rawValue).
    private static func hooksObject(
        slug: String,
        hookCmd: String,
        events: [String: HookEvent],
        passthroughEvents: [String] = []
    ) -> [String: Any] {
        // `events` and `passthroughEvents` MUST be disjoint — a collision
        // would silently overwrite the lifecycle dispatch with the passthrough
        // variant (or vice versa, depending on the loop order below). Better
        // to crash here at install time than ship a hook config that drops
        // an .attention/.running ping with no test failure. Currently disjoint
        // (Claude lifecycle = SessionStart/UserPromptSubmit/Stop/Notification/
        // SessionEnd, passthrough = PreToolUse/PostToolUse), but any new
        // caller adding richer payloads needs to pick a side per event.
        let lifecycleKeys = Set(events.keys)
        let passthroughSet = Set(passthroughEvents)
        precondition(
            lifecycleKeys.isDisjoint(with: passthroughSet),
            "hooksObject: events and passthroughEvents share key(s) \(lifecycleKeys.intersection(passthroughSet)) — collision would silently drop a hook"
        )

        var hooks: [String: Any] = [:]
        // Claude / Gemini run `command` through `/bin/sh -c`, so an unquoted
        // `KookyHook` path breaks the moment the app lives under a path with
        // spaces or shell metacharacters (e.g. `/Applications/Kooky 2.app/…`).
        let quotedCmd = quote(hookCmd)
        for (event, state) in events {
            hooks[event] = [["hooks": [["type": "command", "command": "\(quotedCmd) \(slug) \(state.rawValue)"]]]]
        }
        for event in passthroughEvents {
            hooks[event] = [["hooks": [["type": "command", "command": "\(quotedCmd) \(slug) \(event)"]]]]
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

    /// JSON variant of `writeManagedFile` — preserves a user-authored
    /// `kooky.json` that happens to live at the same path by looking for the
    /// `_kookyManaged` sentinel field. The Copilot hooks dir is user-owned
    /// (`~/.copilot/hooks/`), so a same-named user file is plausible enough
    /// to guard against. A corrupt-or-non-JSON file at the same path is
    /// treated as ours to overwrite — same policy `writeManagedFile` uses
    /// for non-UTF-8 / marker-less text. The alternative (silently skipping)
    /// would leave the user without working hooks and no signal as to why.
    private static func writeManagedJSON(at path: String, object: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (parsed["_kookyManaged"] as? String) != managedFileMarker {
            return
        }
        writeJSON(at: path, object: object)
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
            printf '\\n  \\033[33m%s is not installed.\\033[0m\\n\\n' "\(binary)" >&2
            # The new-tab path eagerly sets session.agent based on the template,
            # expecting bracket wrapper to ping `running` next. We never got
            # there — revert the icon so it doesn't lie about what's running.
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" \(binary) ended 2>/dev/null
            fi
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

    /// Antigravity CLI shares its binary name (`agy`) with Antigravity 2.0
    /// IDE's command-line launcher (`~/.antigravity/antigravity/bin/agy`
    /// is a symlink into `/Applications/Antigravity.app/...`). With only
    /// the IDE installed, PATH-resolution would pick up the launcher and
    /// a plain `exec agy` opens the GUI — surprising the user who picked
    /// "Antigravity CLI" from the `+` menu. Detect the IDE shim by
    /// resolving one symlink hop and matching `/Antigravity.app/`; on
    /// match, route through the same "not installed" path the preamble
    /// uses (red message + KookyHook `ended` ping so the tab icon
    /// reverts) plus surface the official CLI install command.
    static let antigravityWrapperScript = """
    \(wrapperPreamble(binary: "agy"))

    real_target="$(readlink "$real" 2>/dev/null || true)"
    case "${real_target:-$real}" in
        */Antigravity.app/*)
            printf '\\n  \\033[33mThe `agy` on PATH is the Antigravity IDE launcher, not the CLI.\\033[0m\\n' >&2
            printf '  Install the CLI:\\n' >&2
            printf '    \\033[36mcurl -fsSL https://antigravity.google/cli/install.sh | bash\\033[0m\\n\\n' >&2
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" agy ended 2>/dev/null
            fi
            exit 127
            ;;
    esac

    \(bracketBody(slug: "agy"))
    """

    /// Generic bracket wrapper for agents we can't drive mid-run state from
    /// (no hook system or no installed plugin yet). Sends `running` before
    /// exec and `ended` after exit; activity dot stays green for the whole
    /// run, then drops to idle on quit. Used for `amp` (no plugin) and
    /// `opencode` — opencode's plugin upgrades mid-run state once installed.
    static func bracketWrapperScript(slug: String) -> String {
        """
        \(wrapperPreamble(binary: slug))

        \(bracketBody(slug: slug))
        """
    }

    /// The `running` → exec → `ended` body shared by `bracketWrapperScript`
    /// and `antigravityWrapperScript`. Outside a kooky session
    /// (`$KOOKY_SURFACE_ID` unset) the bracket is a no-op — `exec "$real"`
    /// is the only line that runs so the wrapper is transparent when the
    /// user invokes the binary from a plain Terminal.app shell.
    private static func bracketBody(slug: String) -> String {
        """
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

        # bash is launched as interactive non-login (`--rcfile` is incompatible
        # with `-l`), so it would normally skip the login rc chain. macOS users
        # traditionally put PATH / env in ~/.bash_profile (Apple Terminal starts
        # bash as login), so without this they'd see env vars vanish. Replay
        # the first existing login rc, matching bash's own lookup order.
        _kooky_login_rc_loaded=
        for _kooky_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [[ -r "$_kooky_rc" ]]; then
                source "$_kooky_rc"
                _kooky_login_rc_loaded=1
                break
            fi
        done
        unset _kooky_rc

        # No login rc existed, so its standard `source ~/.bashrc` chain never
        # ran — fall back so the user's interactive config still loads. Skip
        # when a login rc was found: bash login shells don't auto-source
        # .bashrc, and the user's profile chain (if they want it) handles
        # that. Avoids double-load when .bash_profile already chained .bashrc
        # (NVM / oh-my-bash / PROMPT_COMMAND duplication = 150-300ms).
        if [[ -z "$_kooky_login_rc_loaded" && -r "$HOME/.bashrc" ]]; then
            source "$HOME/.bashrc"
        fi
        unset _kooky_login_rc_loaded

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOSTNAME" "$PWD"; }
        # Re-assert the cwd as the OSC title each prompt (see zsh wrapper) —
        # prepended so it runs before the user's PROMPT_COMMAND title hook.
        _kooky_title_pwd() { printf '\\e]2;%s\\a' "$PWD"; }
        \(envStatusBlock)

        PROMPT_COMMAND="_kooky_title_pwd;_kooky_osc7_pwd;_kooky_env_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
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

        # Restore ZDOTDIR to the user's original (almost always unset) *before*
        # replaying their rc chain. zsh has already consumed ZDOTDIR to locate
        # this wrapper rc — changing it now is safe and ensures any
        # `$ZDOTDIR/...` reference inside .zshenv / .zprofile / .zshrc
        # (compinit's `.zcompdump`, plugin caches, znap/zinit roots, HISTFILE
        # overrides) resolves to real `$HOME` instead of our ephemeral
        # kooky-zsh-<pid> dir. Also stops `curl | bash`-style installers
        # (opencode, rustup) from writing PATH exports to our ephemeral rc.
        if [[ -n "$KOOKY_ORIGINAL_ZDOTDIR" ]]; then
            export ZDOTDIR="$KOOKY_ORIGINAL_ZDOTDIR"
            unset KOOKY_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi

        # macOS `/etc/zshrc` (already ran) resolved HISTFILE against our
        # ephemeral ZDOTDIR; `cleanup()` deletes that dir on quit, taking
        # history with it. Reset to the real path *before* user rc so a user
        # HISTFILE override in any of the three files below still wins.
        export HISTFILE="$HOME/.zsh_history"

        # Re-assert the cwd as the OSC title each prompt — registered before
        # the user rc so it runs first in precmd_functions. Drops a stale
        # ssh / TUI title; a title the user's theme sets later this prompt
        # still wins (it runs after). kooky maps a cwd-shaped title to the
        # bare basename. `return $_s` keeps $? intact for the user hooks.
        autoload -Uz add-zsh-hook
        _kooky_title_pwd() { local _s=$?; printf '\\e]2;%s\\a' "$PWD"; return $_s }
        add-zsh-hook precmd _kooky_title_pwd

        # Replay the rc files zsh would have run if ZDOTDIR had pointed at the
        # user's real dir. Resolve via `${ZDOTDIR:-$HOME}` after each source —
        # so users who park their zsh config in a custom dir (e.g.
        # `~/.config/zsh` via parent-shell ZDOTDIR, or via `export ZDOTDIR=...`
        # inside .zshenv itself) get the full chain. Re-resolve after each
        # source because .zshenv / .zprofile may mutate ZDOTDIR.
        [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
        [[ -r "${ZDOTDIR:-$HOME}/.zprofile" ]] && source "${ZDOTDIR:-$HOME}/.zprofile"
        [[ -r "${ZDOTDIR:-$HOME}/.zshrc" ]] && source "${ZDOTDIR:-$HOME}/.zshrc"

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

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
    /// these and fires `GHOSTTY_ACTION_COMMAND_FINISHED` on `D` (per-tab
    /// last-command status + duration, scroll-to-prompt jumps), and uses
    /// `A;cl=line` to anchor `cursor-click-to-move` so option-/single-click
    /// on a prompt jumps the shell cursor to that column. Re-injects the
    /// `B` marker into PROMPT on every redraw because Starship / p10k-style
    /// themes rebuild PROMPT each `precmd` and would otherwise drop our suffix.
    private static let osc133Block = #"""
        __kooky_133_first=1
        __kooky_133_precmd() {
            local last=$?
            if (( ! __kooky_133_first )); then
                printf '\e]133;D;%s\a' "$last"
            fi
            __kooky_133_first=0
            # `cl=line` is ghostty's required marker metadata — without it
            # libghostty silently ignores the prompt sentinel and features
            # that depend on it (`cursor-click-to-move`, jump-to-prompt)
            # stay dormant. `\a` (BEL) terminator matches ghostty's own
            # zsh shell-integration script exactly.
            printf '\e]133;A;cl=line\a'
            # Wrap the OSC 133 B marker in zsh's zero-width brackets (%{ ... %}).
            # Without them zsh counts every byte of the escape sequence (ESC, ],
            # `133;B`, BEL) toward the PROMPT's visible width, miscalculates the
            # wrap column by ~8 cells, and ZLE redraws the input on the wrong
            # row the moment a long input wraps — wiping the first visible line.
            [[ "$PROMPT" != *$'\e]133;B\a'* ]] && PROMPT="${PROMPT}"$'%{\e]133;B\a%}'
            _kooky_env_status
            # Same masking concern as `_kooky_env_status` itself: the kooky
            # hooks must not leak `$?` into user prompts that downstream
            # precmd hooks may sample.
            return 0
        }
        __kooky_133_preexec() { printf '\e]133;C\a' }
        add-zsh-hook precmd __kooky_133_precmd
        add-zsh-hook preexec __kooky_133_preexec
        """#

    private static func writeFile(at path: String, contents: String, executable: Bool = false) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { chmod(path, 0o755) }
    }
}
