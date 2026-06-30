import Darwin
import Foundation
import KookyHookKit

enum KookyHookCommand {
    private static let hookEvents: Set<String> = [
        "running", "attention", "idle", "ended",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "conversation", "tool",
    ]

    static func isInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count >= 2 else { return false }
        let args = normalizedArguments(arguments)
        guard args.count >= 2 else { return false }
        if args[1] == "browser" || args[1] == "env" { return true }
        return args.count >= 3 && hookEvents.contains(args[2])
    }

    static func run(_ rawArguments: [String]) -> Int32 {
        let arguments = normalizedArguments(rawArguments)

        if arguments.count >= 2, arguments[1] == "browser" {
            let command = arguments.count >= 3 ? arguments[2] : "help"
            if command == "help" || command == "-h" || command == "--help" {
                print(KookyHookKit.browserHelpText)
                return 0
            }
        }

        let surface = ProcessInfo.processInfo.environment["KOOKY_SURFACE_ID"] ?? ""
        guard !surface.isEmpty else { return 0 }

        let socketPath = KookyHookKit.socketPath
        let agentArg = arguments.count >= 2 ? arguments[1] : ""
        let stdinData: Data = (agentArg == "claude" && isatty(fileno(stdin)) == 0)
            ? ((try? FileHandle.standardInput.readToEnd()) ?? Data())
            : Data()
        let codexNotifyData: Data = (agentArg == "codex" && arguments.count >= 4)
            ? Data(arguments[3].utf8)
            : Data()

        let payloadObject: [String: String]
        if arguments.count >= 3, arguments[1] == "browser" {
            let command = arguments[2]
            if command == "open" {
                let address = arguments.dropFirst(3).joined(separator: " ")
                guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
                payloadObject = KookyHookKit.buildBrowserOpenPayload(surface: surface, address: address)
            } else if command == "state" {
                payloadObject = KookyHookKit.buildBrowserStatePayload(surface: surface)
            } else if command == "click" {
                let text = arguments.dropFirst(3).joined(separator: " ")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
                payloadObject = KookyHookKit.buildBrowserClickPayload(surface: surface, text: text)
            } else if command == "fill" {
                let args = Array(arguments.dropFirst(3))
                guard args.count >= 2 else { return 0 }
                let field = args[0]
                let text = args.dropFirst().joined(separator: " ")
                guard !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
                payloadObject = KookyHookKit.buildBrowserFillPayload(surface: surface, field: field, text: text)
            } else if command == "type" {
                let text = arguments.dropFirst(3).joined(separator: " ")
                guard !text.isEmpty else { return 0 }
                payloadObject = KookyHookKit.buildBrowserTypePayload(surface: surface, text: text)
            } else if command == "press" {
                let key = arguments.dropFirst(3).joined(separator: " ")
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
                payloadObject = KookyHookKit.buildBrowserPressPayload(surface: surface, key: key)
            } else if command == "scroll" {
                let direction = arguments.count >= 4 ? arguments[3] : "down"
                let amount = arguments.count >= 5 ? arguments[4] : ""
                payloadObject = KookyHookKit.buildBrowserScrollPayload(surface: surface, direction: direction, amount: amount)
            } else if ["back", "forward", "reload", "stop"].contains(command) {
                payloadObject = KookyHookKit.buildBrowserSimplePayload(surface: surface, command: command)
            } else if command == "close" {
                payloadObject = KookyHookKit.buildBrowserClosePayload(surface: surface)
            } else {
                return 0
            }
        } else if arguments.count >= 2, arguments[1] == "env" {
            let envArgs = Array(arguments.dropFirst(2))
            payloadObject = KookyHookKit.buildEnvPayload(surface: surface, args: envArgs)
        } else if arguments.count >= 3 {
            let agent = arguments[1]
            let event = arguments[2]
            if event == "conversation" {
                let id = arguments.count >= 4 ? arguments[3] : ""
                guard !id.isEmpty else { return 0 }
                let payload = KookyHookKit.buildConversationIdPayload(surface: surface, conversationId: id)
                return KookyHookKit.sendPayload(payload, to: socketPath) ? 0 : 1
            }
            if event == "tool" {
                func at(_ index: Int) -> String { arguments.indices.contains(index) ? arguments[index] : "" }
                let phase = at(3)
                let toolName = at(5)
                guard phase == "pre" || phase == "post", !toolName.isEmpty else { return 0 }
                let success: Bool? = phase == "post" ? (at(7) != "fail") : nil
                let toolUseId = at(4)
                let payload = KookyHookKit.buildToolEventPayload(
                    surface: surface,
                    agent: agent,
                    toolName: toolName,
                    identifier: at(6),
                    event: phase,
                    toolUseId: toolUseId.isEmpty ? nil : toolUseId,
                    success: success
                )
                return KookyHookKit.sendPayload(payload, to: socketPath) ? 0 : 1
            }
            if event == "PreToolUse" || event == "PostToolUse" || event == "PostToolUseFailure" {
                guard let tool = KookyHookKit.parseToolEventPayload(
                    from: stdinData,
                    surface: surface,
                    agent: agent
                ) else { return 0 }
                payloadObject = tool
            } else {
                payloadObject = KookyHookKit.buildLifecyclePayload(
                    agent: agent,
                    event: event,
                    surface: surface
                )
            }
        } else {
            return 0
        }

        let eventSent: Bool
        if payloadObject["kind"] == "browser" {
            if let response = KookyHookKit.sendPayloadAndReadResponse(payloadObject, to: socketPath) {
                if !response.isEmpty {
                    print(response, terminator: response.hasSuffix("\n") ? "" : "\n")
                }
                eventSent = true
            } else {
                eventSent = false
            }
        } else {
            eventSent = KookyHookKit.sendPayload(payloadObject, to: socketPath)
        }

        if payloadObject["agent"] == "claude",
           payloadObject["kind"] != "tool",
           let conversationId = KookyHookKit.parseClaudeConversationId(from: stdinData) {
            let payload = KookyHookKit.buildConversationIdPayload(
                surface: surface,
                conversationId: conversationId
            )
            _ = KookyHookKit.sendPayload(payload, to: socketPath)
        }

        if payloadObject["agent"] == "codex",
           payloadObject["kind"] != "tool",
           let conversationId = KookyHookKit.parseCodexConversationId(from: codexNotifyData) {
            let payload = KookyHookKit.buildConversationIdPayload(
                surface: surface,
                conversationId: conversationId
            )
            _ = KookyHookKit.sendPayload(payload, to: socketPath)
        }

        return eventSent ? 0 : 1
    }

    private static func normalizedArguments(_ arguments: [String]) -> [String] {
        guard arguments.count >= 2, arguments[1] == "hook" else { return arguments }
        return [arguments[0]] + arguments.dropFirst(2)
    }
}
