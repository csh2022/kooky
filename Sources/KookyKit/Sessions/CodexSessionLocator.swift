import Foundation

enum CodexSessionLocator {
    static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static func latestSessionId(cwd: URL, sessionsRoot: URL = defaultSessionsRoot) -> String? {
        let targetCwd = cwd.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: CodexSessionMetadata?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let metadata = metadata(from: url),
                  URL(fileURLWithPath: metadata.cwd).standardizedFileURL.path == targetCwd
            else { continue }
            if let current = best {
                if metadata.sortDate > current.sortDate {
                    best = metadata
                }
            } else {
                best = metadata
            }
        }
        return best?.id
    }

    private struct CodexSessionMetadata {
        let id: String
        let cwd: String
        let sortDate: Date
    }

    private static func metadata(from url: URL) -> CodexSessionMetadata? {
        guard let line = firstLine(from: url),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              UUID(uuidString: id) != nil,
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty
        else { return nil }

        let sortDate = (payload["timestamp"] as? String).flatMap(parseISODate)
            ?? fileModificationDate(url)
            ?? .distantPast
        return CodexSessionMetadata(id: id, cwd: cwd, sortDate: sortDate)
    }

    private static func firstLine(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        while true {
            let chunk = (try? handle.read(upToCount: 4096)) ?? Data()
            if chunk.isEmpty { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[..<newline])
                break
            }
            data.append(chunk)
            if data.count > 1_000_000 { return nil }
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
