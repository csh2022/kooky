import Foundation

/// On-disk shape of `WorkspaceStore`. Just the metadata — engine state
/// (scrollback, in-flight processes) can't survive PTY exit, so a restored
/// workspace re-spawns a fresh `LibghosttyEngine` per tab and lands it in
/// the saved cwd via `TerminalSessionConfig.workingDirectory`.
struct PersistedState: Codable, Equatable {
    var workspaces: [PersistedWorkspace]
    var activeWorkspaceId: UUID?
}

struct PersistedWorkspace: Codable, Equatable {
    var id: UUID
    var title: String
    var workingDirectoryPath: String
    var tabs: [PersistedTab]
    var activeTabId: UUID?

    @MainActor
    init(_ ws: Workspace) {
        self.id = ws.id
        self.title = ws.title
        self.workingDirectoryPath = ws.workingDirectory.path
        self.tabs = ws.tabs.map(PersistedTab.init)
        self.activeTabId = ws.activeTabId
    }

    init(id: UUID, title: String, workingDirectoryPath: String, tabs: [PersistedTab], activeTabId: UUID?) {
        self.id = id
        self.title = title
        self.workingDirectoryPath = workingDirectoryPath
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

struct PersistedTab: Codable, Equatable {
    var id: UUID
    var agentId: String
    var currentDirectoryPath: String

    @MainActor
    init(_ session: Session) {
        self.id = session.id
        self.agentId = session.agent.id
        self.currentDirectoryPath = session.currentDirectory.path
    }

    init(id: UUID, agentId: String, currentDirectoryPath: String) {
        self.id = id
        self.agentId = agentId
        self.currentDirectoryPath = currentDirectoryPath
    }
}

/// Implementations must write atomically — a partial file would fail the
/// next `load()` decode and lose user state. Reads, by contrast, are best-effort.
@MainActor
protocol Persistence {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
}

/// Atomic JSON read/write under `~/Library/Application Support/kooky/state.json`.
@MainActor
final class FilePersistence: Persistence {
    static let shared = FilePersistence()

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
