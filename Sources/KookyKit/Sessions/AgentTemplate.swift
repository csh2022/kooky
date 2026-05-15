import AppKit
import Foundation
import SwiftUI

/// A named profile that turns into a `TerminalSessionConfig` when the user
/// picks it from the "+" menu. The shell starts under our wrapper `.zshrc`
/// (KookyShellIntegration), which sources the user's config, then — if
/// `KOOKY_AGENT` is set — invokes the agent inline. The user never sees the
/// shell prompt or the command echo, and on agent exit they land in a clean
/// shell prompt with their full PATH/aliases intact.
struct AgentTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    /// SF Symbol used when `iconAsset` is nil or fails to load.
    let symbol: String
    /// Filename (without extension) of a bundled PNG in `Resources/Icons/`.
    /// Sourced from github.com/lobehub/lobe-icons (MIT).
    let iconAsset: String?
    /// Brand-derived hue used for compact indicators (sidebar status pips).
    /// Picked from each lobe-icon's dominant fill so a row's pip group reads as
    /// the same family of marks shown elsewhere. sRGB hex.
    let tintHex: String?
    let initialCommand: String?
    /// For custom templates only — snapshot of `CustomAgentData.baseAgentId`
    /// taken at `fromCustom` time. Nil for builtins. Lives on the template
    /// (not on Session) because the wrapper-end revert in `applyHookEvent`
    /// must use the value present when the session *started*, not whatever
    /// the user has since changed in Settings → Agents (a mid-run
    /// edit/delete would otherwise leave the tab stuck in the custom-agent
    /// state forever).
    let baseAgentId: String?
    /// CLI flag the agent's binary expects when receiving a prompt argument.
    /// Nil = positional (`claude "<prompt>"`, the most common shape). Agents
    /// that need a flag set it on their builtin definition below — see the
    /// Copilot / Amp wirings. Drives the right-click "Ask <agent>" launch
    /// path via `makeSessionConfig(initialPrompt:)`. Templates with
    /// `initialCommand == nil` (Terminal) ignore this entirely.
    let promptLaunchFlag: String?

    init(
        id: String,
        title: String,
        symbol: String,
        iconAsset: String?,
        tintHex: String?,
        initialCommand: String?,
        baseAgentId: String? = nil,
        promptLaunchFlag: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.iconAsset = iconAsset
        self.tintHex = tintHex
        self.initialCommand = initialCommand
        self.baseAgentId = baseAgentId
        self.promptLaunchFlag = promptLaunchFlag
    }

    var tint: Color? {
        tintHex.flatMap(Color.init(hex:))
    }

    /// `extraOptions` is appended after `initialCommand` (space-separated)
    /// when forming `KOOKY_AGENT`. The wrapper rc's `eval` splits on
    /// whitespace, so the caller handles its own quoting for tokens that
    /// contain spaces.
    ///
    /// `resumeId`, when present and the template is Claude Code (or a custom
    /// based on Claude Code), prepends `--resume <id>` to the launch command
    /// so the new tab continues an existing conversation. Other agents
    /// silently ignore it for v1 — their CLIs support `--resume <id>` too,
    /// but the id-capture path (Claude's hook payload) is Claude-only today.
    ///
    /// `initialPrompt`, when non-empty, drives the right-click "Ask <agent>"
    /// path: the prompt is POSIX-quoted and inserted into `KOOKY_AGENT` as
    /// the first argv after the binary name (or after `promptLaunchFlag`
    /// when that's set — Copilot's `-p`, Amp's `-x`). Mutually exclusive
    /// with `resumeId` — asking a fresh question shouldn't graft onto a
    /// stale conversation, so `initialPrompt` wins and `resumeId` is
    /// silently dropped when both are supplied.
    func makeSessionConfig(
        extraOptions: String? = nil,
        resumeId: String? = nil,
        initialPrompt: String? = nil
    ) -> TerminalSessionConfig {
        // Pick a shell that has a kooky integration wrapper. Plain terminal
        // sessions respect $SHELL where we have a wrapper (zsh/bash); other
        // shells (fish/nu/...) get $SHELL too, just without cwd tracking.
        // Agent sessions force a wrapped shell so KOOKY_AGENT auto-launch
        // works — `.other` users get zsh as a working fallback.
        var config: TerminalSessionConfig
        switch (KookyShellIntegration.detectedUserShell, initialCommand) {
        case (.bash, _):
            config = .bashShell(launcher: KookyShellIntegration.bashLauncherPath)
        case (.zsh, _):
            config = .zshShell()
        case (.other, .none):
            config = .defaultShell()
        case (.other, .some):
            config = .zshShell()
        }
        if let initialCommand {
            let trimmedExtras = extraOptions?.trimmingCharacters(in: .whitespaces) ?? ""
            let trimmedPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Resume flag goes between binary name and options:
            //   `claude --resume <id> --model opus`
            // — Claude takes it as a positional argument to its top-level
            // command; appending after extras would still work but reads
            // worse in `ps`. Suppressed when `initialPrompt` is present —
            // "Ask <agent>" is a fresh question, not a continuation.
            var resumeFragment = ""
            if trimmedPrompt.isEmpty, supportsResume, let id = resumeId, !id.isEmpty {
                resumeFragment = " --resume \(id)"
            }
            var promptFragment = ""
            if !trimmedPrompt.isEmpty {
                let quoted = KookyShellIntegration.quote(trimmedPrompt)
                if let flag = promptLaunchFlag {
                    promptFragment = " \(flag) \(quoted)"
                } else {
                    promptFragment = " \(quoted)"
                }
            }
            let extrasFragment = trimmedExtras.isEmpty ? "" : " \(trimmedExtras)"
            config.environment["KOOKY_AGENT"] = "\(initialCommand)\(resumeFragment)\(promptFragment)\(extrasFragment)"
        }
        return config
    }

    /// Only Claude Code (and customs based on it) supports the
    /// `--resume <id>` injection path today: that's the only agent whose
    /// hooks pipe `session_id` back to kooky so we can persist + reuse it.
    /// Other agents' CLIs do accept `--resume <id>` syntactically, but we
    /// don't have a reliable id-capture mechanism for them yet.
    var supportsResume: Bool {
        id == "claude-code" || baseAgentId == "claude-code"
    }
}

extension AgentTemplate {
    static let terminal = AgentTemplate(
        id: "terminal",
        title: "Terminal",
        symbol: "terminal",
        iconAsset: nil,
        tintHex: nil,
        initialCommand: nil
    )

    static let claudeCode = AgentTemplate(
        id: "claude-code",
        title: "Claude Code",
        symbol: "sparkle",
        iconAsset: "claudecode",
        tintHex: "D97757",
        initialCommand: "claude"
    )

    static let codex = AgentTemplate(
        id: "codex",
        title: "Codex",
        symbol: "chevron.left.forwardslash.chevron.right",
        iconAsset: "codex",
        tintHex: "7A9DFF",
        initialCommand: "codex"
    )

    static let gemini = AgentTemplate(
        id: "gemini",
        title: "Gemini CLI",
        symbol: "diamond",
        iconAsset: "gemini",
        tintHex: "3186FF",
        initialCommand: "gemini"
    )

    static let opencode = AgentTemplate(
        id: "opencode",
        title: "OpenCode",
        symbol: "curlybraces",
        iconAsset: "opencode",
        tintHex: "B0B0B0",
        initialCommand: "opencode"
    )

    static let amp = AgentTemplate(
        id: "amp",
        title: "Amp",
        symbol: "bolt.fill",
        iconAsset: "amp",
        tintHex: "E8B168",
        initialCommand: "amp",
        promptLaunchFlag: "-x"
    )

    static let cursor = AgentTemplate(
        id: "cursor",
        title: "Cursor CLI",
        symbol: "cube",
        iconAsset: "cursor",
        tintHex: "F54E00",
        initialCommand: "cursor-agent"
    )

    static let copilot = AgentTemplate(
        id: "copilot",
        title: "Copilot CLI",
        symbol: "hexagon.fill",
        iconAsset: "githubcopilot",
        tintHex: "6E40C9",
        initialCommand: "copilot",
        promptLaunchFlag: "-p"
    )

    /// The 8 templates shipped with kooky. User-defined custom agents are
    /// merged on top via `all` at runtime.
    static let builtin: [AgentTemplate] = [.terminal, .claudeCode, .codex, .gemini, .opencode, .amp, .cursor, .copilot]

    /// All templates available right now — `builtin` plus the user's custom
    /// agents from Settings → Agents. MainActor-isolated because it
    /// reads `KookySettingsModel.shared` to materialise custom entries.
    @MainActor
    static var all: [AgentTemplate] {
        builtin + KookySettingsModel.shared.customAgents.map(AgentTemplate.fromCustom)
    }

    /// Looks up a template by the slug an agent's hook system reports — the
    /// same string as the template's `initialCommand` (the binary name the
    /// user types). Returns nil for unknown slugs. MainActor because it
    /// pulls the live `all` (built-in + custom).
    @MainActor
    static func from(hookSlug: String) -> AgentTemplate? {
        all.first { $0.initialCommand == hookSlug }
    }

    /// All non-terminal templates resolved against the user's saved order.
    /// Templates absent from `model.agentOrder` (typically: a fresh kooky
    /// install, or an agent shipped in a newer version) are appended in
    /// their `AgentTemplate.all` position so nothing silently disappears.
    @MainActor
    static func ordered(model: KookySettingsModel) -> [AgentTemplate] {
        let nonTerminal = all.filter { $0.id != "terminal" }
        // Use `uniquingKeysWith` so a hand-edited settings.json that puts a
        // custom agent on a builtin id (or two customs on the same id) lands
        // on the first occurrence instead of crashing the launcher. Builtin
        // entries are appended first in `all`, so they win the tie.
        let byId = Dictionary(nonTerminal.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let userOrderIds = model.agentOrder.filter { byId.keys.contains($0) }
        let userOrderSet = Set(userOrderIds)
        let missing = nonTerminal.filter { !userOrderSet.contains($0.id) }
        return userOrderIds.compactMap { byId[$0] } + missing
    }

    /// What the `+` menu renders: Terminal pinned first (not user-controlled),
    /// then `ordered(model:)` filtered to visible agents whose `initialCommand`
    /// is set. The `initialCommand != nil` gate skips half-configured custom
    /// agents (just-added or command-cleared) so the launch surface never
    /// offers a row that would spawn a plain Terminal but get recorded as
    /// that custom agent. They still appear in Settings → Agents so
    /// the user can finish editing them.
    @MainActor
    static func visibleOrdered(model: KookySettingsModel) -> [AgentTemplate] {
        [.terminal] + ordered(model: model).filter {
            !model.hiddenAgents.contains($0.id) && $0.initialCommand != nil
        }
    }

    /// Resolves the user's chosen default template for `+` / `⌘T`. Returns
    /// `nil` (meaning "no default, show the picker") when the saved id is
    /// missing, unknown, or points to an agent the user has since hidden.
    /// Looking the id up in `visibleOrdered` gives the stale-default-after-
    /// hide fallback for free; Terminal is always present there so it stays
    /// selectable even though it's not customisable from the Settings list.
    @MainActor
    static func defaultLaunchTemplate(model: KookySettingsModel) -> AgentTemplate? {
        guard let id = model.defaultAgentId else { return nil }
        return visibleOrdered(model: model).first { $0.id == id }
    }

    /// Materialises a user-defined custom agent into a runtime `AgentTemplate`.
    /// When `baseAgentId` matches a builtin, the custom inherits that
    /// builtin's `iconAsset` / `symbol` / `tintHex` *and* its `initialCommand`
    /// when the user's own `command` is blank — so picking "Claude Code" as
    /// the base and leaving `command` empty launches the base's binary
    /// (`claude`) with the custom's options appended (`--model opus`). A
    /// `(none)` base with empty command stays nil so the `+` menu filter
    /// skips half-configured customs.
    static func fromCustom(_ data: CustomAgentData) -> AgentTemplate {
        let base = builtin.first { $0.id == data.baseAgentId }
        // `promptLaunchFlag` follows the base unconditionally — it's a
        // property of the binary (Copilot needs `-p`, Amp needs `-x`),
        // not something the user could meaningfully override per custom.
        // Without inheritance, a "Copilot Beta" custom built on Copilot
        // would lose the flag and right-click Ask would feed the prompt
        // as a positional argv that Copilot ignores.
        return AgentTemplate(
            id: data.id,
            title: data.title.isEmpty ? data.id : data.title,
            symbol: data.symbol.isEmpty ? (base?.symbol ?? "wand.and.stars") : data.symbol,
            iconAsset: data.iconAsset.isEmpty ? base?.iconAsset : data.iconAsset,
            tintHex: data.tintHex.isEmpty ? base?.tintHex : data.tintHex,
            initialCommand: data.command.isEmpty ? base?.initialCommand : data.command,
            baseAgentId: data.baseAgentId.isEmpty ? nil : data.baseAgentId,
            promptLaunchFlag: base?.promptLaunchFlag
        )
    }
}

/// User-defined agent entry. Stored in `settings.json` under
/// `agents.custom`; round-tripped through `KookySettingsModel.customAgents`.
struct CustomAgentData: Hashable, Identifiable {
    /// Slug — must be unique across builtin + custom. Generated as
    /// `custom-N` on creation; user-editable from Settings.
    var id: String
    /// Display title shown in the `+` menu and Settings row.
    var title: String
    /// Full launch command, e.g. `aichat --model gpt-4o`. Whitespace-split
    /// by the wrapper's `eval`, same as the `agents.options` field.
    var command: String
    /// `id` of a builtin agent whose icon / tint / SF Symbol the custom
    /// should inherit. Empty = no inheritance (generic `wand.and.stars` +
    /// no tint). Surfaced as the "based on" picker in Settings so a user
    /// can build "Claude Opus" variants that visually belong to the Claude
    /// family without touching iconAsset / tintHex directly.
    var baseAgentId: String
    /// Bundled PNG asset name (matches files in `Resources/Icons/`). Power-
    /// user override; UI doesn't expose this in v1. Empty falls back to
    /// the `baseAgentId` builtin's iconAsset, or nil if no base.
    var iconAsset: String
    /// SF Symbol override. Power-user; UI hides this. Empty falls back to
    /// the base's symbol, then to `wand.and.stars`.
    var symbol: String
    /// sRGB hex (no `#`) for the sidebar pip tint. Power-user; UI hides
    /// this. Empty falls back to base's tintHex, then nil.
    var tintHex: String

    init(
        id: String,
        title: String = "",
        command: String = "",
        baseAgentId: String = "",
        iconAsset: String = "",
        symbol: String = "",
        tintHex: String = ""
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.baseAgentId = baseAgentId
        self.iconAsset = iconAsset
        self.symbol = symbol
        self.tintHex = tintHex
    }
}
