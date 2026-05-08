import Foundation

@MainActor
@Observable
final class Session: Identifiable {
    let id: UUID
    let engine: any TerminalEngine
    let agent: AgentTemplate
    /// Per-tab cwd. Initialized from the workspace's cwd at spawn, then kept in
    /// sync via OSC 7 (`engine.onPwdChange`). Drives the tab title so users see
    /// where they are, not which agent template the tab was launched from.
    var currentDirectory: URL

    /// `lastPathComponent` of the cwd, with `~` for $HOME. Empty path falls
    /// back to the agent name so a degenerate URL doesn't render as blank.
    var title: String {
        if currentDirectory.standardizedFileURL.path == NSHomeDirectory() { return "~" }
        let last = currentDirectory.lastPathComponent
        return last.isEmpty ? agent.title : last
    }

    init(id: UUID = UUID(), engine: any TerminalEngine, currentDirectory: URL, agent: AgentTemplate) {
        self.id = id
        self.engine = engine
        self.currentDirectory = currentDirectory
        self.agent = agent
    }
}
