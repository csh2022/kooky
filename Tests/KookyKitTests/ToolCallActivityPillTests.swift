import XCTest
@testable import KookyKit

/// Unit tests for the pure helpers underlying `ToolCallActivityPill`.
/// The SwiftUI rendering itself is exercised manually (real Claude tab +
/// xushuhui mock per W2 design plan) — we test the data shaping
/// (counters, duration formatting, visibility predicate) so the chrome
/// row renders correct content without spinning up a SwiftUI host.
@MainActor
final class ToolCallActivityPillTests: XCTestCase {
    private func makeSession(agent: AgentTemplate = .claudeCode, activity: SessionActivityState = .running) -> Session {
        let session = Session(
            engine: TestEngine(),
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            agent: agent
        )
        session.activityState = activity
        return session
    }

    private func event(tool: String, state: ToolCallEventState, startedAt: Date = Date(), completedAt: Date? = nil) -> ToolCallEvent {
        ToolCallEvent(
            id: UUID(),
            toolUseId: nil,
            toolName: tool,
            identifier: "x",
            startedAt: startedAt,
            completedAt: completedAt,
            state: state
        )
    }

    // MARK: Counter aggregation

    func testToolCountsAggregatesByKind() {
        let session = makeSession()
        session.toolCallEvents = [
            event(tool: "Bash", state: .success),
            event(tool: "Bash", state: .running),
            event(tool: "Edit", state: .success),
            event(tool: "Edit", state: .failed),
            event(tool: "Write", state: .success),
            event(tool: "Read", state: .success),
            event(tool: "Read", state: .success),
            event(tool: "Read", state: .success),
            event(tool: "WebFetch", state: .success),
        ]
        let counts = ToolCallActivityPill.toolCounts(in: session.toolCallEvents)
        XCTAssertEqual(counts.bash, 2)
        XCTAssertEqual(counts.edit, 3, "Edit + Write + MultiEdit aggregate together")
        XCTAssertEqual(counts.read, 3)
        XCTAssertEqual(counts.other, 1, "WebFetch / Glob / Grep / Task / unknown all bucket as other")
    }

    func testToolCountsMultiEditCountsAsEdit() {
        let session = makeSession()
        session.toolCallEvents = [event(tool: "MultiEdit", state: .success)]
        XCTAssertEqual(ToolCallActivityPill.toolCounts(in: session.toolCallEvents).edit, 1)
    }

    func testToolCountsEmptyEventsZero() {
        let session = makeSession()
        let counts = ToolCallActivityPill.toolCounts(in: session.toolCallEvents)
        XCTAssertEqual(counts.bash, 0)
        XCTAssertEqual(counts.edit, 0)
        XCTAssertEqual(counts.read, 0)
        XCTAssertEqual(counts.other, 0)
    }

    // MARK: Duration formatting

    func testFormatElapsedSubSecond() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(0.4), "0.4s")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(0.95), "0.9s")
    }

    func testFormatElapsedSeconds() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(1.0), "1s")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(12.4), "12s")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(59.7), "60s")
    }

    func testFormatElapsedMinutes() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(60), "1:00")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(125), "2:05")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(599), "9:59")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(3661), "61:01")
    }

    func testDurationLabelUsesCompletedAtWhenAvailable() {
        let session = makeSession()
        let start = Date(timeIntervalSinceNow: -10)
        let end = Date(timeIntervalSinceNow: -8)
        let resolved = event(tool: "Bash", state: .success, startedAt: start, completedAt: end)
        let label = ToolCallActivityPill.durationLabel(for: resolved)
        XCTAssertEqual(label, "2s")
    }

    func testDurationLabelUsesNowForRunning() {
        // Running event with no completedAt — duration measured against now
        let session = makeSession()
        let start = Date(timeIntervalSinceNow: -3)
        let running = event(tool: "Bash", state: .running, startedAt: start, completedAt: nil)
        let label = ToolCallActivityPill.durationLabel(for: running)
        // Should be ~3s — allow small float drift
        XCTAssertTrue(label == "3s" || label == "2s" || label == "4s", "Expected ~3s, got \(label)")
    }

    // MARK: Tool kind → SF Symbol icon

    func testToolIconMappings() {
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Bash"), "terminal")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Edit"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Write"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("MultiEdit"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Read"), "doc.text")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Glob"), "magnifyingglass")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Grep"), "magnifyingglass")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("WebFetch"), "globe")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("WebSearch"), "globe")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Task"), "rectangle.stack")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("UnknownTool"), "questionmark.app")
    }

    // MARK: Visibility predicate

    func testShowStripForClaudeAgentWithActivity() {
        let session = makeSession(agent: .claudeCode, activity: .running)
        XCTAssertTrue(showToolCallActivityPill(for: session))
    }

    func testShowStripForClaudeWithAttentionState() {
        let session = makeSession(agent: .claudeCode, activity: .attention)
        XCTAssertTrue(showToolCallActivityPill(for: session))
    }

    func testHideStripForClaudeIdle() {
        let session = makeSession(agent: .claudeCode, activity: .idle)
        XCTAssertFalse(showToolCallActivityPill(for: session))
    }

    func testHideStripForNonClaudeAgent() {
        let session = makeSession(agent: .codex, activity: .running)
        XCTAssertFalse(showToolCallActivityPill(for: session))
    }

    func testHideStripForTerminal() {
        let session = makeSession(agent: .terminal, activity: .running)
        XCTAssertFalse(showToolCallActivityPill(for: session))
    }

    func testShowStripForClaudeBaseCustomAgent() {
        // Custom agent based on Claude Code (per CLAUDE.md M5.uu) — should
        // get the strip even though its `id` differs from "claude-code"
        // because `baseAgentId` resolves it to the Claude family.
        let custom = AgentTemplate(
            id: "claude-opus-custom",
            title: "Claude Opus Custom",
            symbol: "sparkles",
            iconAsset: "claude",
            tintHex: "FFFFFF",
            initialCommand: "claude",
            baseAgentId: AgentTemplate.claudeCodeID
        )
        let session = makeSession(agent: custom, activity: .running)
        XCTAssertTrue(showToolCallActivityPill(for: session))
    }
}
