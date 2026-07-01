import XCTest
@testable import KookyKit

/// Tests for HookServer's socket identity and `parseMessage` wire-payload
/// decoder. These are direct in-process tests so malformed payload edge cases
/// stay fast and deterministic. `@MainActor` because `HookServer` is
/// `@MainActor` and `parseMessage` inherits the isolation.
@MainActor
final class HookServerTests: XCTestCase {
    private static let surfaceUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: Socket paths

    func testDefaultSocketPathIsPerProcess() {
        XCTAssertTrue(HookServer.socketPath.contains("/kooky/sockets/s-"))
        XCTAssertFalse(HookServer.socketPath.hasSuffix("/kooky/socket"))
    }

    func testHookServerAcceptsSocketPathOverride() {
        let server = HookServer(socketPath: "/tmp/kooky-test.sock") { _ in nil }
        XCTAssertEqual(server.socketPath, "/tmp/kooky-test.sock")
    }

    // MARK: Regression — existing message kinds keep working

    func testParseAgentLifecyclePayload() throws {
        let json = #"{"surface":"\#(Self.surfaceUUID.uuidString)","agent":"claude","event":"running"}"#
        let message = HookServer.parseMessage(data(json))
        guard case let .agent(agent, event, sessionId) = message else {
            return XCTFail("Expected .agent, got \(String(describing: message))")
        }
        XCTAssertEqual(agent.id, AgentTemplate.claudeCodeID)
        XCTAssertEqual(event, .running)
        XCTAssertEqual(sessionId, Self.surfaceUUID)
    }

    func testParseEnvPayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"env","VIRTUAL_ENV":"/v","CONDA_DEFAULT_ENV":"","NVM_BIN":"","NVM_DIR":"","KOOKY_NODE_VERSION":"","https_proxy":"","http_proxy":"","all_proxy":""}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .shellEnvironment(env, _) = message else {
            return XCTFail("Expected .shellEnvironment, got \(String(describing: message))")
        }
        XCTAssertEqual(env["VIRTUAL_ENV"], "/v")
    }

    func testParseConversationIdPayload() throws {
        let json = #"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"conversationId","conversationId":"sess_abc"}"#
        let message = HookServer.parseMessage(data(json))
        guard case let .conversationId(conversationId, _) = message else {
            return XCTFail("Expected .conversationId, got \(String(describing: message))")
        }
        XCTAssertEqual(conversationId, "sess_abc")
    }

    func testParseBrowserOpenPayload() throws {
        let json = #"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"open","address":"http://localhost:3000"}"#
        let message = HookServer.parseMessage(data(json))
        guard case let .browser(command, sessionId) = message else {
            return XCTFail("Expected .browser, got \(String(describing: message))")
        }
        XCTAssertEqual(command, .open(address: "http://localhost:3000"))
        XCTAssertEqual(sessionId, Self.surfaceUUID)
    }

    func testParseBrowserClosePayload() throws {
        let json = #"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"close"}"#
        let message = HookServer.parseMessage(data(json))
        guard case let .browser(command, sessionId) = message else {
            return XCTFail("Expected .browser, got \(String(describing: message))")
        }
        XCTAssertEqual(command, .close)
        XCTAssertEqual(sessionId, Self.surfaceUUID)
    }

    func testParseBrowserInteractionPayloads() throws {
        let cases: [(String, HookBrowserCommand)] = [
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"state"}"#, .state),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"snapshot","path":"/tmp/snapshot.txt"}"#, .snapshot(path: "/tmp/snapshot.txt")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"elements"}"#, .elements),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"text"}"#, .text),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"html","path":"/tmp/page.html"}"#, .html(path: "/tmp/page.html")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"links"}"#, .links),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"screenshot","path":"/tmp/page.png"}"#, .screenshot(path: "/tmp/page.png")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"click","text":"Wikipedia"}"#, .click(text: "Wikipedia")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"click-id","id":"e1-button","double":"true"}"#, .clickId(id: "e1-button", double: true)),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"click-at","x":"12","y":"34"}"#, .clickAt(x: 12, y: 34)),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"fill","field":"Search","text":"query"}"#, .fill(field: "Search", text: "query")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"fill-id","id":"e2-input","text":"query"}"#, .fillId(id: "e2-input", text: "query")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"clear","field":"Search"}"#, .clear(field: "Search")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"type","text":"typed"}"#, .type(text: "typed")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"paste","text":"pasted"}"#, .paste(text: "pasted")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"press","key":"Enter"}"#, .press(key: "Enter")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"hotkey","key":"Meta+R"}"#, .hotkey(combo: "Meta+R")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"scroll","direction":"down","amount":"600"}"#, .scroll(direction: "down", amount: 600)),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"hover","id":"e3-a"}"#, .hover(id: "e3-a")),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"wait","text":"Ready","timeout":"2500"}"#, .wait(text: "Ready", timeoutMilliseconds: 2500)),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"wait-url","text":"q=Ready","timeout":"2500"}"#, .waitURL(text: "q=Ready", timeoutMilliseconds: 2500)),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"wait-title","text":"Ready","timeout":"2500"}"#, .waitTitle(text: "Ready", timeoutMilliseconds: 2500)),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"back"}"#, .back),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"forward"}"#, .forward),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"reload"}"#, .reload),
            (#"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"stop"}"#, .stop),
        ]

        for (json, expected) in cases {
            let message = HookServer.parseMessage(data(json))
            guard case let .browser(command, _) = message else {
                return XCTFail("Expected .browser, got \(String(describing: message))")
            }
            XCTAssertEqual(command, expected)
        }
    }

    func testParseBrowserOpenRejectsMissingAddress() {
        let json = #"{"surface":"\#(Self.surfaceUUID.uuidString)","kind":"browser","command":"open"}"#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    // MARK: Tool event payload — happy paths

    func testParseToolCallPrePayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"git status","event":"pre"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(agent, toolName, identifier, event, success, _, sessionId) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(agent.id, AgentTemplate.claudeCodeID)
        XCTAssertEqual(toolName, "Bash")
        XCTAssertEqual(identifier, "git status")
        XCTAssertEqual(event, .pre)
        XCTAssertNil(success, "Pre events should not carry a success flag")
        XCTAssertEqual(sessionId, Self.surfaceUUID)
    }

    func testParseToolCallPostSuccessPayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Edit","identifier":"/repo/x.swift","event":"post","success":"true"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, event, success, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(event, .post)
        XCTAssertEqual(success, true)
    }

    func testParseToolCallPostFailurePayload() throws {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"missing","event":"post","success":"false"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, _, success, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(success, false)
    }

    // MARK: Tool event payload — rejection paths

    func testParseToolCallRejectsMissingToolName() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","identifier":"x","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallRejectsEmptyToolName() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"","identifier":"x","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallRejectsMissingIdentifier() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallAcceptsEmptyIdentifier() {
        // Empty identifier is valid — happens for tools with no input or
        // unknown tool kinds whose first-string fallback returned nothing.
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"","event":"pre"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case .toolCall = message else {
            return XCTFail("Expected .toolCall with empty identifier, got \(String(describing: message))")
        }
    }

    func testParseToolCallRejectsUnknownAgentSlug() {
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"unknown-agent","tool_name":"Bash","identifier":"x","event":"pre"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallRejectsUnknownEvent() {
        // event must be "pre" or "post" — anything else is malformed wire.
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"mid"}
        """#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }

    func testParseToolCallPostWithMalformedSuccessFlagDefaultsToFalse() {
        // success field present but not "true" — treated as false (only
        // exact "true" passes the equality check). This is the v1
        // permissive contract: garbage in the success slot doesn't reject
        // the whole message.
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"post","success":"yes"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, _, success, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertEqual(success, false)
    }

    func testParseToolCallPostWithMissingSuccessFlagIsNil() {
        // No success field at all on .post — message still parses; success
        // ends up nil. Consumer falls back to its own default (true per
        // WorkspaceStore.applyToolCallEvent).
        let json = #"""
        {"surface":"\#(Self.surfaceUUID.uuidString)","kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"post"}
        """#
        let message = HookServer.parseMessage(data(json))
        guard case let .toolCall(_, _, _, _, success, _, _) = message else {
            return XCTFail("Expected .toolCall, got \(String(describing: message))")
        }
        XCTAssertNil(success)
    }

    func testParseRejectsMalformedJSON() {
        XCTAssertNil(HookServer.parseMessage(Data("{{not json".utf8)))
    }

    func testParseRejectsMissingSurface() {
        let json = #"{"kind":"tool","agent":"claude","tool_name":"Bash","identifier":"x","event":"pre"}"#
        XCTAssertNil(HookServer.parseMessage(data(json)))
    }
}
