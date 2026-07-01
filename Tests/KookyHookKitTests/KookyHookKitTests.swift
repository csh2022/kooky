import XCTest
@testable import KookyHookKit

final class KookyHookKitTests: XCTestCase {
    private let codexSessionId = "019eef55-2456-78f2-9368-7f321e6126bd"

    // MARK: env payload

    func testBuildEnvPayloadFullArgs() {
        let payload = KookyHookKit.buildEnvPayload(
            surface: "abc-123",
            args: [
                "/path/venv",
                "myenv",
                "/nvm/bin",
                "/nvm",
                "v20.11.0",
                "http://proxy:8080",
                "http://proxy:8080",
                "socks5://proxy",
            ]
        )
        XCTAssertEqual(payload["kind"], "env")
        XCTAssertEqual(payload["surface"], "abc-123")
        XCTAssertEqual(payload["VIRTUAL_ENV"], "/path/venv")
        XCTAssertEqual(payload["CONDA_DEFAULT_ENV"], "myenv")
        XCTAssertEqual(payload["NVM_BIN"], "/nvm/bin")
        XCTAssertEqual(payload["NVM_DIR"], "/nvm")
        XCTAssertEqual(payload["KOOKY_NODE_VERSION"], "v20.11.0")
        XCTAssertEqual(payload["https_proxy"], "http://proxy:8080")
        XCTAssertEqual(payload["http_proxy"], "http://proxy:8080")
        XCTAssertEqual(payload["all_proxy"], "socks5://proxy")
    }

    func testBuildEnvPayloadShortArgsFillsBlanks() {
        // Caller supplies only 2 of 8 env values — remaining positions
        // must populate with empty strings so the HookServer parser sees
        // a complete record (it reads all 8 keys unconditionally).
        let payload = KookyHookKit.buildEnvPayload(surface: "s", args: ["/venv", "myenv"])
        XCTAssertEqual(payload["VIRTUAL_ENV"], "/venv")
        XCTAssertEqual(payload["CONDA_DEFAULT_ENV"], "myenv")
        XCTAssertEqual(payload["NVM_BIN"], "")
        XCTAssertEqual(payload["NVM_DIR"], "")
        XCTAssertEqual(payload["KOOKY_NODE_VERSION"], "")
        XCTAssertEqual(payload["https_proxy"], "")
        XCTAssertEqual(payload["http_proxy"], "")
        XCTAssertEqual(payload["all_proxy"], "")
    }

    func testBuildEnvPayloadEmptyArgs() {
        let payload = KookyHookKit.buildEnvPayload(surface: "s", args: [])
        XCTAssertEqual(payload["kind"], "env")
        XCTAssertEqual(payload["surface"], "s")
        XCTAssertEqual(payload["VIRTUAL_ENV"], "")
    }

    // MARK: lifecycle payload

    func testBuildLifecyclePayload() {
        let payload = KookyHookKit.buildLifecyclePayload(
            agent: "claude",
            event: "running",
            surface: "abc"
        )
        XCTAssertEqual(payload, ["agent": "claude", "event": "running", "surface": "abc"])
    }

    // MARK: Claude conversationId parsing

    func testParseClaudeConversationIdValid() {
        let json = #"{"session_id":"sess_abc123","transcript_path":"/tmp/x","hook_event_name":"SessionStart"}"#
        let data = Data(json.utf8)
        XCTAssertEqual(KookyHookKit.parseClaudeConversationId(from: data), "sess_abc123")
    }

    func testParseClaudeConversationIdMissingField() {
        let json = #"{"transcript_path":"/tmp/x"}"#
        XCTAssertNil(KookyHookKit.parseClaudeConversationId(from: Data(json.utf8)))
    }

    func testParseClaudeConversationIdEmptyValue() {
        let json = #"{"session_id":""}"#
        XCTAssertNil(KookyHookKit.parseClaudeConversationId(from: Data(json.utf8)))
    }

    func testParseClaudeConversationIdWrongType() {
        // session_id arrives as a number (Anthropic schema change) — must
        // be treated as missing rather than crashing or stringifying it.
        let json = #"{"session_id":12345}"#
        XCTAssertNil(KookyHookKit.parseClaudeConversationId(from: Data(json.utf8)))
    }

    func testParseClaudeConversationIdMalformedJSON() {
        let data = Data("not valid json {{{".utf8)
        XCTAssertNil(KookyHookKit.parseClaudeConversationId(from: data))
    }

    func testParseClaudeConversationIdEmptyData() {
        XCTAssertNil(KookyHookKit.parseClaudeConversationId(from: Data()))
    }

    func testParseClaudeConversationIdTopLevelArray() {
        // Top-level array is valid JSON but not the expected object shape.
        let data = Data(#"["session_id","sess_abc"]"#.utf8)
        XCTAssertNil(KookyHookKit.parseClaudeConversationId(from: data))
    }

    // MARK: Codex conversationId parsing

    func testParseCodexConversationIdFromSessionId() {
        let json = #"{"session_id":"\#(codexSessionId)","hook_event_name":"Notification"}"#
        XCTAssertEqual(KookyHookKit.parseCodexConversationId(from: Data(json.utf8)), codexSessionId)
    }

    func testParseCodexConversationIdFromCamelCaseSessionId() {
        let json = #"{"sessionId":"\#(codexSessionId)"}"#
        XCTAssertEqual(KookyHookKit.parseCodexConversationId(from: Data(json.utf8)), codexSessionId)
    }

    func testParseCodexConversationIdFromConversationId() {
        let json = #"{"conversationId":"\#(codexSessionId)"}"#
        XCTAssertEqual(KookyHookKit.parseCodexConversationId(from: Data(json.utf8)), codexSessionId)
    }

    func testParseCodexConversationIdFromNestedPayloadId() {
        // Codex session transcript metadata uses payload.id; accept that
        // shape if notify mirrors it, but still require UUID syntax.
        let json = #"{"type":"session_meta","payload":{"id":"\#(codexSessionId)"}}"#
        XCTAssertEqual(KookyHookKit.parseCodexConversationId(from: Data(json.utf8)), codexSessionId)
    }

    func testParseCodexConversationIdRejectsNonUUIDStrings() {
        let json = #"{"session_id":"not-a-codex-session"}"#
        XCTAssertNil(KookyHookKit.parseCodexConversationId(from: Data(json.utf8)))
    }

    func testParseCodexConversationIdRejectsBareTopLevelId() {
        // A top-level id in a notification payload could name the event, not
        // the resumable session. Only explicit session/conversation keys or
        // payload.id are accepted.
        let json = #"{"id":"\#(codexSessionId)"}"#
        XCTAssertNil(KookyHookKit.parseCodexConversationId(from: Data(json.utf8)))
    }

    func testParseCodexConversationIdRejectsMalformedJSON() {
        XCTAssertNil(KookyHookKit.parseCodexConversationId(from: Data("not valid json {{{".utf8)))
    }

    func testParseCodexConversationIdRejectsEmptyData() {
        XCTAssertNil(KookyHookKit.parseCodexConversationId(from: Data()))
    }

    func testParseCodexConversationIdRejectsTopLevelArray() {
        let data = Data(#"[{"session_id":"\#(codexSessionId)"}]"#.utf8)
        XCTAssertNil(KookyHookKit.parseCodexConversationId(from: data))
    }

    // MARK: conversationId payload

    func testBuildConversationIdPayload() {
        let payload = KookyHookKit.buildConversationIdPayload(
            surface: "abc",
            conversationId: "sess_123"
        )
        XCTAssertEqual(payload, [
            "kind": "conversationId",
            "surface": "abc",
            "conversationId": "sess_123",
        ])
    }

    // MARK: browser payload

    func testBrowserHelpDocumentsCurrentCommands() {
        let help = KookyHookKit.browserHelpText

        XCTAssertTrue(help.contains("browser help"))
        XCTAssertTrue(help.contains("browser open <url-or-query>"))
        XCTAssertTrue(help.contains("browser state"))
        XCTAssertTrue(help.contains("browser snapshot [path]"))
        XCTAssertTrue(help.contains("browser elements"))
        XCTAssertTrue(help.contains("browser text"))
        XCTAssertTrue(help.contains("browser html [path]"))
        XCTAssertTrue(help.contains("browser links"))
        XCTAssertTrue(help.contains("browser screenshot [path]"))
        XCTAssertTrue(help.contains("browser click <visible-text>"))
        XCTAssertTrue(help.contains("browser click-id <element-id>"))
        XCTAssertTrue(help.contains("browser click-at <x> <y>"))
        XCTAssertTrue(help.contains("browser fill <field-label-or-placeholder> <text>"))
        XCTAssertTrue(help.contains("browser fill-id <element-id> <text>"))
        XCTAssertTrue(help.contains("browser clear [field-label-or-placeholder]"))
        XCTAssertTrue(help.contains("browser type <text>"))
        XCTAssertTrue(help.contains("browser paste <text>"))
        XCTAssertTrue(help.contains("browser press <key>"))
        XCTAssertTrue(help.contains("browser hotkey <combo>"))
        XCTAssertTrue(help.contains("browser scroll <up|down|left|right> [amount]"))
        XCTAssertTrue(help.contains("browser hover <element-id>"))
        XCTAssertTrue(help.contains("browser wait <text> [timeout-ms]"))
        XCTAssertTrue(help.contains("browser back"))
        XCTAssertTrue(help.contains("browser close"))
        XCTAssertTrue(help.contains("Future commands will be listed here"))
    }

    func testBuildBrowserOpenPayload() {
        let payload = KookyHookKit.buildBrowserOpenPayload(surface: "abc", address: "http://localhost:3000")
        XCTAssertEqual(payload["kind"], "browser")
        XCTAssertEqual(payload["surface"], "abc")
        XCTAssertEqual(payload["command"], "open")
        XCTAssertEqual(payload["address"], "http://localhost:3000")
    }

    func testBuildBrowserClosePayload() {
        let payload = KookyHookKit.buildBrowserClosePayload(surface: "abc")
        XCTAssertEqual(payload, [
            "kind": "browser",
            "surface": "abc",
            "command": "close",
        ])
    }

    func testBuildBrowserInteractionPayloads() {
        XCTAssertEqual(KookyHookKit.buildBrowserStatePayload(surface: "abc")["command"], "state")
        XCTAssertEqual(KookyHookKit.buildBrowserClickPayload(surface: "abc", text: "Wikipedia")["text"], "Wikipedia")
        XCTAssertEqual(KookyHookKit.buildBrowserFillPayload(surface: "abc", field: "Search", text: "query")["field"], "Search")
        XCTAssertEqual(KookyHookKit.buildBrowserFillPayload(surface: "abc", field: "Search", text: "query")["text"], "query")
        XCTAssertEqual(KookyHookKit.buildBrowserOutputPayload(surface: "abc", command: "snapshot", path: "/tmp/s.txt")["path"], "/tmp/s.txt")
        XCTAssertEqual(KookyHookKit.buildBrowserClickIdPayload(surface: "abc", id: "e1-button", double: true)["double"], "true")
        XCTAssertEqual(KookyHookKit.buildBrowserClickAtPayload(surface: "abc", x: "1", y: "2")["x"], "1")
        XCTAssertEqual(KookyHookKit.buildBrowserFillIdPayload(surface: "abc", id: "e2-input", text: "query")["id"], "e2-input")
        XCTAssertEqual(KookyHookKit.buildBrowserClearPayload(surface: "abc", field: "Search")["field"], "Search")
        XCTAssertEqual(KookyHookKit.buildBrowserTypePayload(surface: "abc", text: "typed")["text"], "typed")
        XCTAssertEqual(KookyHookKit.buildBrowserPastePayload(surface: "abc", text: "pasted")["command"], "paste")
        XCTAssertEqual(KookyHookKit.buildBrowserPressPayload(surface: "abc", key: "Enter")["key"], "Enter")
        XCTAssertEqual(KookyHookKit.buildBrowserHotkeyPayload(surface: "abc", combo: "Meta+R")["key"], "Meta+R")
        XCTAssertEqual(KookyHookKit.buildBrowserScrollPayload(surface: "abc", direction: "down", amount: "600")["amount"], "600")
        XCTAssertEqual(KookyHookKit.buildBrowserHoverPayload(surface: "abc", id: "e3-a")["id"], "e3-a")
        XCTAssertEqual(KookyHookKit.buildBrowserWaitPayload(surface: "abc", text: "Ready", timeout: "1000")["timeout"], "1000")
        XCTAssertEqual(KookyHookKit.buildBrowserSimplePayload(surface: "abc", command: "reload")["command"], "reload")
    }

    // MARK: Tool event payload — happy paths per tool kind

    // MARK: tool_use_id + PostToolUseFailure

    func testParseToolEventExtractsToolUseId() {
        let json = #"""
        {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"x"},"tool_use_id":"toolu_abc123"}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["tool_use_id"], "toolu_abc123")
    }

    func testParseToolEventOmitsToolUseIdWhenMissing() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"x"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertNil(payload?["tool_use_id"])
    }

    func testParseToolEventOmitsEmptyToolUseId() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"x"},"tool_use_id":""}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertNil(payload?["tool_use_id"])
    }

    func testParseToolEventPostToolUseFailureForcesSuccessFalse() {
        // Claude fires PostToolUseFailure when a tool errors — success
        // must be forced to false without inspecting tool_response
        // (Claude's own signal beats the heuristic text scan).
        let json = #"""
        {"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":"some output that doesn't say error"}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["event"], "post")
        XCTAssertEqual(payload?["success"], "false", "PostToolUseFailure must force success=false regardless of tool_response heuristic")
    }

    func testParseToolEventBashPre() {
        let json = #"""
        {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status","description":"check"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "abc", agent: "claude")
        XCTAssertEqual(payload?["kind"], "tool")
        XCTAssertEqual(payload?["surface"], "abc")
        XCTAssertEqual(payload?["agent"], "claude")
        XCTAssertEqual(payload?["tool_name"], "Bash")
        XCTAssertEqual(payload?["identifier"], "git status")
        XCTAssertEqual(payload?["event"], "pre")
        XCTAssertNil(payload?["success"])  // PreToolUse 不带 success
    }

    func testParseToolEventEditPre() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/repo/Session.swift","old_string":"a","new_string":"b"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["tool_name"], "Edit")
        XCTAssertEqual(payload?["identifier"], "/repo/Session.swift")
        XCTAssertEqual(payload?["event"], "pre")
    }

    func testParseToolEventReadPre() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/repo/main.swift"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["tool_name"], "Read")
        XCTAssertEqual(payload?["identifier"], "/repo/main.swift")
    }

    func testParseToolEventWritePre() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/new.swift","content":"x"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["identifier"], "/new.swift")
    }

    func testParseToolEventGlobPre() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"Glob","tool_input":{"pattern":"**/*.swift","path":"/repo"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["identifier"], "**/*.swift")
    }

    func testParseToolEventGrepPre() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"TODO","path":"/repo"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["identifier"], "TODO")
    }

    func testParseToolEventWebFetchPre() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"WebFetch","tool_input":{"url":"https://example.com","prompt":"summarize"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["identifier"], "https://example.com")
    }

    func testParseToolEventUnknownToolFallsBackToFirstString() {
        let json = #"""
        {"hook_event_name":"PreToolUse","tool_name":"CustomTool","tool_input":{"arg":"fallback-value"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["tool_name"], "CustomTool")
        XCTAssertEqual(payload?["identifier"], "fallback-value")
    }

    // MARK: PostToolUse — success heuristic

    func testParseToolEventBashPostSuccess() {
        let json = #"""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo ok"},"tool_response":"ok\n"}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["event"], "post")
        XCTAssertEqual(payload?["success"], "true")
    }

    func testParseToolEventBashPostFailureErrorPrefix() {
        let json = #"""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"missing"},"tool_response":"Error: command not found"}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["success"], "false")
    }

    func testParseToolEventPostFailureMidstringMarker() {
        let json = #"""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":"some output\nFailed: bad thing"}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["success"], "false")
    }

    func testParseToolEventPostNoResponseDefaultsSuccess() {
        // Some tools don't populate tool_response — treat as success
        let json = #"""
        {"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/x"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["success"], "true")
    }

    func testParseToolEventPostNonStringResponseDefaultsSuccess() {
        // tool_response could be a dict / array — v1 doesn't introspect, treat as success
        let json = #"""
        {"hook_event_name":"PostToolUse","tool_name":"Task","tool_input":{"description":"x"},"tool_response":{"nested":"value"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["success"], "true")
    }

    // MARK: Identifier truncation + control chars

    func testParseToolEventIdentifierTruncatedAt80() {
        let longPath = String(repeating: "a", count: 100) + "_END"  // 104 chars
        let json = #"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"\#(longPath)"}}"#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["identifier"]?.count, 80)
        XCTAssertEqual(payload?["identifier"], String(repeating: "a", count: 80))
        XCTAssertFalse(payload?["identifier"]?.contains("END") ?? true)
    }

    func testParseToolEventCJKIdentifierNotMidCodepoint() {
        // 中 = 1 Character (3 UTF-8 bytes). Truncating by Character count
        // keeps each char whole; truncating by byte count would risk
        // landing mid-codepoint and corrupting output.
        let cjk = String(repeating: "中", count: 100)
        let json = #"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"\#(cjk)"}}"#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["identifier"]?.count, 80)
        XCTAssertEqual(payload?["identifier"], String(repeating: "中", count: 80))
        // No replacement-character corruption
        XCTAssertFalse(payload?["identifier"]?.contains("\u{FFFD}") ?? true)
    }

    func testParseToolEventStripsControlCharacters() {
        // A heredoc Bash command with embedded newlines should render
        // single-line — newlines → spaces, no mid-line wraps in pill UI.
        // JSON-encoded \n / \t / \r in the wire payload (raw-string here
        // means each two-char backslash sequence reaches the JSON parser
        // intact, which decodes them to literal LF / TAB / CR characters).
        let json = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"line1\nline2\tindented\rline3"}}"#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["identifier"], "line1 line2 indented line3")
        XCTAssertFalse(payload?["identifier"]?.contains("\n") ?? true)
        XCTAssertFalse(payload?["identifier"]?.contains("\t") ?? true)
        XCTAssertFalse(payload?["identifier"]?.contains("\r") ?? true)
    }

    // MARK: Rejection paths

    func testParseToolEventRejectsNonToolEvent() {
        // SessionStart, UserPromptSubmit etc. must NOT produce a tool payload —
        // those go through the lifecycle path
        let json = #"""
        {"hook_event_name":"SessionStart","tool_name":"Bash","tool_input":{"command":"x"}}
        """#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertNil(payload)
    }

    func testParseToolEventRejectsMissingHookEventName() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"x"}}"#
        XCTAssertNil(KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude"))
    }

    func testParseToolEventRejectsMissingToolName() {
        let json = #"{"hook_event_name":"PreToolUse","tool_input":{"command":"x"}}"#
        XCTAssertNil(KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude"))
    }

    func testParseToolEventRejectsEmptyToolName() {
        let json = #"{"hook_event_name":"PreToolUse","tool_name":"","tool_input":{}}"#
        XCTAssertNil(KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude"))
    }

    func testParseToolEventEmptyToolInputProducesEmptyIdentifier() {
        // Missing tool_input → identifier empty but payload still ships
        let json = #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#
        let payload = KookyHookKit.parseToolEventPayload(from: Data(json.utf8), surface: "s", agent: "claude")
        XCTAssertEqual(payload?["tool_name"], "Bash")
        XCTAssertEqual(payload?["identifier"], "")
    }

    func testParseToolEventRejectsMalformedJSON() {
        let data = Data("not valid json {{{".utf8)
        XCTAssertNil(KookyHookKit.parseToolEventPayload(from: data, surface: "s", agent: "claude"))
    }

    func testParseToolEventRejectsEmptyData() {
        XCTAssertNil(KookyHookKit.parseToolEventPayload(from: Data(), surface: "s", agent: "claude"))
    }

    // MARK: Helper unit tests (extractIdentifier, detectSuccess)

    func testExtractIdentifierUnknownToolWithMultipleKeys() {
        // Unknown tool fallback picks A non-empty string. We don't assert
        // which one (dict order undefined), just that it's non-empty when
        // any string value exists.
        let id = KookyHookKit.extractIdentifier(
            toolName: "Mystery",
            toolInput: ["x": "value-x", "y": "value-y"]
        )
        XCTAssertTrue(["value-x", "value-y"].contains(id))
    }

    func testExtractIdentifierAllEmptyStringsReturnsEmpty() {
        let id = KookyHookKit.extractIdentifier(
            toolName: "Mystery",
            toolInput: ["x": "", "y": ""]
        )
        XCTAssertEqual(id, "")
    }

    func testExtractIdentifierNonStringValuesIgnored() {
        // Numbers / arrays / dicts in tool_input shouldn't crash; helper
        // returns "" when no string value exists.
        let id = KookyHookKit.extractIdentifier(
            toolName: "Mystery",
            toolInput: ["count": 42, "flag": true, "items": ["a", "b"]]
        )
        XCTAssertEqual(id, "")
    }

    func testDetectSuccessHandlesNonString() {
        // dict / number / nil → success (conservative default)
        XCTAssertTrue(KookyHookKit.detectSuccess(toolResponse: nil))
        XCTAssertTrue(KookyHookKit.detectSuccess(toolResponse: 42))
        XCTAssertTrue(KookyHookKit.detectSuccess(toolResponse: ["nested": "value"]))
    }

    func testDetectSuccessErrorMarkers() {
        // Tests the full marker list — each maps to failure
        XCTAssertFalse(KookyHookKit.detectSuccess(toolResponse: "Error: bad"))
        XCTAssertFalse(KookyHookKit.detectSuccess(toolResponse: "stderr: command not found"))
        XCTAssertFalse(KookyHookKit.detectSuccess(toolResponse: "Permission Denied"))  // case-insensitive
        XCTAssertFalse(KookyHookKit.detectSuccess(toolResponse: "Fatal: oom"))
        XCTAssertFalse(KookyHookKit.detectSuccess(toolResponse: "<error>X</error>"))
    }

    func testDetectSuccessNoMarkers() {
        XCTAssertTrue(KookyHookKit.detectSuccess(toolResponse: "all good output here"))
        XCTAssertTrue(KookyHookKit.detectSuccess(toolResponse: ""))
    }

    // MARK: buildToolEventPayload (shared by Claude parser + Pi extension feed)

    func testBuildToolEventPayloadPre() {
        let p = KookyHookKit.buildToolEventPayload(
            surface: "surf", agent: "pi", toolName: "bash", identifier: "ls -la",
            event: "pre", toolUseId: "call_1", success: nil
        )
        XCTAssertEqual(p["kind"], "tool")
        XCTAssertEqual(p["surface"], "surf")
        XCTAssertEqual(p["agent"], "pi")
        XCTAssertEqual(p["tool_name"], "bash")  // Pi's lowercase name passes through verbatim
        XCTAssertEqual(p["identifier"], "ls -la")
        XCTAssertEqual(p["event"], "pre")
        XCTAssertEqual(p["tool_use_id"], "call_1")
        XCTAssertNil(p["success"], "pre carries no success")
    }

    func testBuildToolEventPayloadPostOk() {
        let p = KookyHookKit.buildToolEventPayload(
            surface: "s", agent: "pi", toolName: "edit", identifier: "/x.swift",
            event: "post", toolUseId: "call_2", success: true
        )
        XCTAssertEqual(p["event"], "post")
        XCTAssertEqual(p["success"], "true")
    }

    func testBuildToolEventPayloadPostFail() {
        let p = KookyHookKit.buildToolEventPayload(
            surface: "s", agent: "pi", toolName: "bash", identifier: "boom",
            event: "post", toolUseId: nil, success: false
        )
        XCTAssertEqual(p["success"], "false")
        XCTAssertNil(p["tool_use_id"], "nil toolUseId is omitted")
    }

    func testBuildToolEventPayloadOmitsEmptyToolUseId() {
        let p = KookyHookKit.buildToolEventPayload(
            surface: "s", agent: "pi", toolName: "read", identifier: "/y",
            event: "pre", toolUseId: "", success: nil
        )
        XCTAssertNil(p["tool_use_id"])
    }

    func testBuildToolEventPayloadSuccessIgnoredOnPre() {
        // success only rides event=="post"; a stray Bool on a pre is dropped.
        let p = KookyHookKit.buildToolEventPayload(
            surface: "s", agent: "pi", toolName: "bash", identifier: "x",
            event: "pre", toolUseId: nil, success: true
        )
        XCTAssertNil(p["success"])
    }

    func testBuildToolEventPayloadTruncatesAndStripsIdentifier() {
        // Single source of truncation/control-stripping — the Pi argv feed
        // doesn't pre-clean, so the helper must. Newline → space, 100→80 chars.
        let raw = "line1\nline2" + String(repeating: "z", count: 100)
        let p = KookyHookKit.buildToolEventPayload(
            surface: "s", agent: "pi", toolName: "bash", identifier: raw,
            event: "pre", toolUseId: nil, success: nil
        )
        XCTAssertEqual(p["identifier"]?.count, 80)
        XCTAssertFalse(p["identifier"]?.contains("\n") ?? true)
        XCTAssertTrue(p["identifier"]?.hasPrefix("line1 line2") ?? false)
    }
}
