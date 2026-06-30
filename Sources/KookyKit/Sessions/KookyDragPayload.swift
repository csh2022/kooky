import Foundation

enum KookyDragPayload: Equatable {
    case tab(UUID)
    case workspace(UUID)

    private static let prefix = "kooky"

    var encoded: String {
        switch self {
        case .tab(let id): return "\(Self.prefix):tab:\(id.uuidString)"
        case .workspace(let id): return "\(Self.prefix):workspace:\(id.uuidString)"
        }
    }

    init?(encoded raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == Self.prefix,
              let id = UUID(uuidString: String(parts[2]))
        else { return nil }
        switch parts[1] {
        case "tab": self = .tab(id)
        case "workspace": self = .workspace(id)
        default: return nil
        }
    }

    static func tabId(from raw: String) -> UUID? {
        guard case .tab(let id) = KookyDragPayload(encoded: raw) else { return nil }
        return id
    }

    static func workspaceId(from raw: String) -> UUID? {
        guard case .workspace(let id) = KookyDragPayload(encoded: raw) else { return nil }
        return id
    }
}
