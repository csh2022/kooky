import XCTest
@testable import KookyKit

@MainActor
final class AgentTemplateTests: XCTestCase {
    func testTerminalTemplateHasNoAgentEnv() {
        XCTAssertNil(AgentTemplate.terminal.makeSessionConfig().environment["KOOKY_AGENT"])
    }

    func testAgentTemplatesPublishKookyAgentEnv() {
        for template in AgentTemplate.all where template.id != "terminal" {
            XCTAssertEqual(
                template.makeSessionConfig().environment["KOOKY_AGENT"],
                template.initialCommand,
                "agent template \(template.id) must publish KOOKY_AGENT matching its initialCommand"
            )
        }
    }

    func testAllTemplatesAreUniqueAndIncludeTerminal() {
        let ids = AgentTemplate.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
        XCTAssertTrue(ids.contains("terminal"))
    }

    func testTerminalTemplateUsesUserDefaultShell() {
        let expected = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        XCTAssertEqual(AgentTemplate.terminal.makeSessionConfig().command, expected)
    }

    func testAgentTemplatesPickAShellWithIntegrationWrapper() {
        // Agent must run under one of our wrappers (zsh ZDOTDIR or bash
        // --rcfile) — anything else means KOOKY_AGENT never fires.
        for template in AgentTemplate.all where template.id != "terminal" {
            let cmd = template.makeSessionConfig().command
            XCTAssertTrue(
                cmd == "/bin/zsh" || cmd.contains("kooky-bash-launch-"),
                "agent template \(template.id) launched without a kooky shell wrapper: \(cmd)"
            )
        }
    }

    func testBuiltinTemplatesHaveNoBaseAgentId() {
        for template in AgentTemplate.builtin {
            XCTAssertNil(template.baseAgentId, "builtin \(template.id) must not declare a base")
        }
    }

    func testFromCustomSnapshotsBaseAgentId() {
        let data = CustomAgentData(id: "claude-opus", baseAgentId: "claude-code")
        XCTAssertEqual(AgentTemplate.fromCustom(data).baseAgentId, "claude-code")
    }

    func testFromCustomTreatsEmptyBaseAsNil() {
        let data = CustomAgentData(id: "loose-custom", command: "aichat")
        XCTAssertNil(AgentTemplate.fromCustom(data).baseAgentId)
    }

    func testMakeSessionConfigInjectsResumeFlagForClaude() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "abc-123")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude --resume abc-123")
    }

    func testMakeSessionConfigCombinesResumeAndExtras() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: "--model opus", resumeId: "abc-123")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude --resume abc-123 --model opus")
    }

    func testMakeSessionConfigSkipsResumeWhenIdEmpty() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude")
    }

    func testMakeSessionConfigIgnoresResumeOnUnsupportedBuiltins() {
        // Codex / Cursor / Gemini / OpenCode / Copilot / Amp / Grok all
        // support a resume flag syntactically but kooky doesn't have a
        // reliable id-capture path for them yet, so we don't inject the
        // flag — see AgentTemplate.supportsResume / resumeFlag.
        let codexConfig = AgentTemplate.codex.makeSessionConfig(resumeId: "abc-123")
        XCTAssertEqual(codexConfig.environment["KOOKY_AGENT"], "codex")
        let copilotConfig = AgentTemplate.copilot.makeSessionConfig(resumeId: "abc-123")
        XCTAssertEqual(copilotConfig.environment["KOOKY_AGENT"], "copilot")
        let grokConfig = AgentTemplate.grok.makeSessionConfig(resumeId: "abc-123")
        XCTAssertEqual(grokConfig.environment["KOOKY_AGENT"], "grok")
    }

    func testSupportsResumeMatchesResumeFlag() {
        XCTAssertTrue(AgentTemplate.claudeCode.supportsResume)
        XCTAssertFalse(AgentTemplate.codex.supportsResume)
        XCTAssertFalse(AgentTemplate.copilot.supportsResume)
        XCTAssertFalse(AgentTemplate.grok.supportsResume)
    }

    func testMakeSessionConfigInjectsResumeForClaudeBasedCustom() {
        let custom = CustomAgentData(id: "claude-opus", baseAgentId: "claude-code")
        let template = AgentTemplate.fromCustom(custom)
        let config = template.makeSessionConfig(resumeId: "xyz")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude --resume xyz")
    }

    // MARK: - initialPrompt (Ask <agent> right-click path)

    func testMakeSessionConfigPositionalPromptForClaude() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForCopilot() {
        let config = AgentTemplate.copilot.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "copilot -p 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForAmp() {
        let config = AgentTemplate.amp.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "amp -x 'fix this error'")
    }

    func testMakeSessionConfigPositionalPromptForCodexCursorGeminiOpencodeGrok() {
        let pairs: [(AgentTemplate, String)] = [
            (.codex, "codex"),
            (.cursor, "cursor-agent"),
            (.gemini, "gemini"),
            (.opencode, "opencode"),
            (.grok, "grok"),
        ]
        for (template, bin) in pairs {
            let config = template.makeSessionConfig(initialPrompt: "hello")
            XCTAssertEqual(config.environment["KOOKY_AGENT"], "\(bin) -- 'hello'", "agent \(template.id)")
        }
    }

    func testMakeSessionConfigQuotesSingleQuotesInPrompt() {
        // POSIX wrap: `'` inside single quotes becomes `'\''`
        let config = AgentTemplate.claudeCode.makeSessionConfig(initialPrompt: "don't fix it")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'don'\\''t fix it'")
    }

    func testMakeSessionConfigCombinesPromptAndExtras() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: "--model opus", initialPrompt: "review this")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'review this' --model opus")
    }

    func testInitialPromptSuppressesResume() {
        // Ask <agent> is a fresh question — don't graft onto a stale
        // conversation. Both supplied → prompt wins, resume dropped.
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "old-convo", initialPrompt: "new question")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'new question'")
    }

    func testEmptyInitialPromptIgnored() {
        let blankConfig = AgentTemplate.claudeCode.makeSessionConfig(initialPrompt: "   ")
        XCTAssertEqual(blankConfig.environment["KOOKY_AGENT"], "claude")
        let resumeConfig = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "abc", initialPrompt: "")
        XCTAssertEqual(resumeConfig.environment["KOOKY_AGENT"], "claude --resume abc")
    }

    func testFromCustomInheritsPromptLaunchFlagFromCopilotBase() {
        // Codex P2 (v0.10.9): a Copilot-based custom must inherit Copilot's
        // `-p` flag — otherwise right-click Ask sends the prompt as a
        // positional argv that Copilot ignores.
        let custom = CustomAgentData(id: "copilot-beta", baseAgentId: "copilot")
        let template = AgentTemplate.fromCustom(custom)
        let config = template.makeSessionConfig(initialPrompt: "hello")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "copilot -p 'hello'")
    }

    func testFromCustomInheritsPromptLaunchFlagFromAmpBase() {
        let custom = CustomAgentData(id: "amp-beta", baseAgentId: "amp")
        let template = AgentTemplate.fromCustom(custom)
        let config = template.makeSessionConfig(initialPrompt: "hello")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "amp -x 'hello'")
    }

    func testPositionalPromptWithDashPrefixRoutedThroughSeparator() {
        // Real-world bug: user right-clicks `ls -la` output, the first
        // line begins `-rw-r--r--@`. Without the `--` separator the
        // agent's argparse would reject it as an unknown flag. The
        // POSIX separator + POSIX-quoted prompt together neutralise it.
        let config = AgentTemplate.codex.makeSessionConfig(initialPrompt: "-rw-r--r--@  1 corey staff  44")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "codex -- '-rw-r--r--@  1 corey staff  44'")
    }
}
