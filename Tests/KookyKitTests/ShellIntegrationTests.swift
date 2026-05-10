import XCTest
@testable import KookyKit

/// Verifies the *content* the integration generates. Tests do not invoke
/// `installAgentHooks()` because that writes to user-config dirs using a
/// hookCmd derived from the running binary (xctest's helpers under
/// `/Applications/Xcode.app/...`), which would pollute and corrupt
/// real user config files. Self-heals on next kooky launch but better
/// avoided: the writers are trivial, the content getters are the
/// load-bearing surface.
final class ShellIntegrationTests: XCTestCase {
    private static let stubHook = "/usr/local/bin/KookyHook"

    func testGeminiDefaultsExposesAllFourLifecycleEvents() throws {
        let object = KookyShellIntegration.geminiDefaultsObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        let expected: [String: String] = [
            "BeforeAgent": "running",
            "AfterAgent": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ]
        for (event, state) in expected {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["type"] as? String, "command")
            XCTAssertEqual(inner["command"] as? String, "\(Self.stubHook) gemini \(state)")
        }
    }

    func testClaudeHooksObjectStaysWiredAfterRefactor() throws {
        let object = KookyShellIntegration.claudeHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for (event, state) in [
            "UserPromptSubmit": "running",
            "Stop": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["command"] as? String, "\(Self.stubHook) claude \(state)")
        }
    }

    func testBracketWrapperPassesThroughWhenSurfaceIdMissing() {
        let script = KookyShellIntegration.bracketWrapperScript(slug: "amp")

        XCTAssertTrue(script.contains("self_dir"), "must skip own dir on PATH walk")
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp running"))
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp ended"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testOpencodePluginShellsOutToHookBinForBothEvents() {
        let body = KookyShellIntegration.opencodePluginScript

        XCTAssertTrue(body.contains("chat.message"), "plugin must subscribe to per-prompt event")
        XCTAssertTrue(body.contains("session.idle"), "plugin must subscribe to turn-end event")
        XCTAssertTrue(body.contains(#"ping("running")"#))
        XCTAssertTrue(body.contains(#"ping("attention")"#))
        XCTAssertTrue(body.contains("opencode"), "plugin must pass agent slug to KookyHook")
        XCTAssertTrue(body.contains("KOOKY_SURFACE_ID"))
        XCTAssertTrue(body.contains("kooky-managed-do-not-edit"), "plugin must carry the upgrade-safety marker")
    }
}
