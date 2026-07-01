import Foundation

enum BrowserPaneOwner: Equatable {
    case user
    case agent(UUID)
}

@MainActor
@Observable
final class BrowserPane: Identifiable {
    let id: UUID
    let surface: BrowserSurface
    var owner: BrowserPaneOwner
    var isPinned: Bool
    var isUserTouched: Bool

    init(
        id: UUID = UUID(),
        surface: BrowserSurface,
        owner: BrowserPaneOwner = .user,
        isPinned: Bool = false,
        isUserTouched: Bool = false
    ) {
        self.id = id
        self.surface = surface
        self.owner = owner
        self.isPinned = isPinned
        self.isUserTouched = isUserTouched
    }

    var canAutoClose: Bool {
        guard case .agent = owner else { return false }
        return !isPinned && !isUserTouched
    }

    func isVisible(activeSessionId: UUID?) -> Bool {
        if isPinned { return true }
        switch owner {
        case .user:
            return true
        case .agent(let sessionId):
            return sessionId == activeSessionId
        }
    }
}
