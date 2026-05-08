import Foundation

@MainActor
@Observable
final class Workspace: Identifiable {
    let id: UUID
    var title: String
    /// Project root. New tabs spawn here; the active tab's OSC 7 reports keep
    /// this in sync — `cd` in any tab updates the workspace, the next new tab
    /// inherits the latest cwd.
    var workingDirectory: URL
    var tabs: [Session] = []
    var activeTabId: UUID?

    var activeTab: Session? {
        tabs.first { $0.id == activeTabId }
    }

    /// Distinct non-terminal agents currently running in this workspace, in
    /// first-tab order. Lets the sidebar surface "what's running here".
    var distinctAgents: [AgentTemplate] {
        var seen: Set<String> = []
        var result: [AgentTemplate] = []
        for tab in tabs where tab.agent.id != AgentTemplate.terminal.id && !seen.contains(tab.agent.id) {
            seen.insert(tab.agent.id)
            result.append(tab.agent)
        }
        return result
    }

    init(id: UUID = UUID(), title: String, workingDirectory: URL) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }
}
