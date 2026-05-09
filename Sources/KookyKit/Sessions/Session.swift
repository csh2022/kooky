import Foundation

/// Coarse "what's the agent doing" status, surfaced as a sidebar dot. Stage 1
/// is UI-only; Stage 2 will drive these from real agent hooks (Claude Code's
/// `--settings` hooks, Codex equivalents) over a unix socket.
enum SessionActivityState: Equatable {
    case idle
    case running
    case attention
}

@MainActor
@Observable
final class Session: Identifiable {
    let id: UUID
    let engine: any TerminalEngine
    /// Initial template the tab was opened with. Promoted at runtime when an
    /// agent's hooks fire from a plain `terminal` session — e.g. user types
    /// `claude` inside a Terminal tab → upgraded to `.claudeCode` so the
    /// sidebar / tab icon and agent state-tracking start working.
    var agent: AgentTemplate
    /// Per-tab cwd. Initialized from the workspace's cwd at spawn, then kept in
    /// sync via OSC 7 (`engine.onPwdChange`). Drives the tab title so users see
    /// where they are, not which agent template the tab was launched from.
    var currentDirectory: URL
    /// Runtime state; not persisted. Resets to `.idle` after relaunch.
    var activityState: SessionActivityState = .idle
    /// Empty / whitespace input via `renameTab` clears this back to `nil` so
    /// the tab title resumes tracking the cwd.
    var customTitle: String?

    /// `lastPathComponent` of the cwd, with `~` for $HOME — unless `customTitle`
    /// is set, which always wins. Empty cwd path falls back to the agent name
    /// so a degenerate URL doesn't render as blank.
    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if currentDirectory.standardizedFileURL.path == NSHomeDirectory() { return "~" }
        let last = currentDirectory.lastPathComponent
        return last.isEmpty ? agent.title : last
    }

    init(
        id: UUID = UUID(),
        engine: any TerminalEngine,
        currentDirectory: URL,
        agent: AgentTemplate,
        customTitle: String? = nil
    ) {
        self.id = id
        self.engine = engine
        self.currentDirectory = currentDirectory
        self.agent = agent
        self.customTitle = customTitle
    }
}
