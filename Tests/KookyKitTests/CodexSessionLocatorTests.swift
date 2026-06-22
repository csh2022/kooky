import Foundation
import XCTest
@testable import KookyKit

final class CodexSessionLocatorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-codex-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testLatestSessionIdReturnsNewestMatchingCwd() throws {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        try writeSession(
            id: "019eef55-2456-78f2-9368-7f321e6126bd",
            cwd: cwd.path,
            timestamp: "2026-06-22T12:36:35.063Z",
            name: "old.jsonl"
        )
        try writeSession(
            id: "019eef99-9ee4-72b0-a559-444c0d7cb764",
            cwd: cwd.path,
            timestamp: "2026-06-22T13:51:22.872Z",
            name: "new.jsonl"
        )
        try writeSession(
            id: "019eef5a-e9c2-76d0-ad9a-39f26b041fae",
            cwd: "/tmp/other",
            timestamp: "2026-06-22T14:00:00.000Z",
            name: "other.jsonl"
        )

        XCTAssertEqual(
            CodexSessionLocator.latestSessionId(cwd: cwd, sessionsRoot: tempRoot),
            "019eef99-9ee4-72b0-a559-444c0d7cb764"
        )
    }

    func testLatestSessionIdIgnoresMalformedAndNonUUIDMetadata() throws {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        try "{not json}\n".write(
            to: tempRoot.appendingPathComponent("bad.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try writeSession(
            id: "not-a-uuid",
            cwd: cwd.path,
            timestamp: "2026-06-22T14:00:00.000Z",
            name: "bad-id.jsonl"
        )
        try writeSession(
            id: "019eef55-2456-78f2-9368-7f321e6126bd",
            cwd: cwd.path,
            timestamp: "2026-06-22T12:36:35.063Z",
            name: "good.jsonl"
        )

        XCTAssertEqual(
            CodexSessionLocator.latestSessionId(cwd: cwd, sessionsRoot: tempRoot),
            "019eef55-2456-78f2-9368-7f321e6126bd"
        )
    }

    private func writeSession(id: String, cwd: String, timestamp: String, name: String) throws {
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": [
                "id": id,
                "timestamp": timestamp,
                "cwd": cwd,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var body = String(data: data, encoding: .utf8)!
        body.append("\n")
        body.append(#"{"type":"event_msg","payload":{"type":"task_started"}}"#)
        body.append("\n")
        try body.write(to: tempRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
