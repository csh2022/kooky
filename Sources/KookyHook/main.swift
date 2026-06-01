import Darwin
import Foundation
import KookyHookKit

// kooky-hook: invoked by an agent's hook system (Claude Code's `--settings`
// hooks, Codex equivalents, …) and the shell precmd hook (`env` mode) to
// ping the running kooky app over a unix socket. Payload building +
// stdin parsing live in `KookyHookKit` so they're unit-testable; this
// file stays a thin dispatcher.
//
// Exit codes:
//   0 — IPC succeeded, OR caller is outside kooky (no surface id) / args
//       malformed (programmer error). Both are "no retry needed."
//   1 — IPC failed (kooky not listening, socket gone, write error). Shell
//       callers use this to keep their dedup cache un-advanced so the next
//       prompt re-attempts. Without this distinction, a single transient
//       failure (kooky restarting, socket recreated) would freeze the env
//       cache permanently.
//
// Usage: kooky-hook <agent> <event>
//   <agent> ∈ claude | codex (or any AgentTemplate.id)
//   <event> ∈ running | attention | idle    (lifecycle events)
//           | PreToolUse | PostToolUse      (tool events — Claude only,
//                                            requires stdin JSON)
// Usage: kooky-hook env <VIRTUAL_ENV> <CONDA_DEFAULT_ENV> <NVM_BIN> <NVM_DIR> <NODE_VERSION> <https_proxy> <http_proxy> <all_proxy>
// Reads:  $KOOKY_SURFACE_ID       UUID of the originating session
// Reads:  stdin                   Claude pipes a JSON object on every
//                                 hook event. For PreToolUse/PostToolUse
//                                 it's the primary input; for lifecycle
//                                 events we use it to mirror `session_id`
//                                 back as a separate `kind: conversationId`
//                                 payload so kooky can prepend
//                                 `--resume <id>` on next launch.

let surface = ProcessInfo.processInfo.environment["KOOKY_SURFACE_ID"] ?? ""
guard !surface.isEmpty else { exit(0) }

let socketPath = KookyHookKit.socketPath

// Drain stdin once up-front. Both the tool-event parser (PreToolUse /
// PostToolUse argv) and the conversationId mirror (Claude lifecycle
// events) read the same Claude-supplied JSON; reading twice would block
// the second read (stdin is single-pass). `isatty == 0` says stdin is a
// pipe / regular file — safe to drain to EOF without stranding the tab
// when the wrapper's "binary not installed" branch leaves stdin attached
// to the user's tty.
let stdinData: Data = (isatty(fileno(stdin)) == 0)
    ? ((try? FileHandle.standardInput.readToEnd()) ?? Data())
    : Data()

let payloadObject: [String: String]
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "env" {
    let envArgs = Array(CommandLine.arguments.dropFirst(2))
    payloadObject = KookyHookKit.buildEnvPayload(surface: surface, args: envArgs)
} else if CommandLine.arguments.count >= 3 {
    let agent = CommandLine.arguments[1]
    let event = CommandLine.arguments[2]
    if event == "conversation" {
        // Extension-reported conversation id (Pi): the agent's extension hands
        // kooky the session id directly as argv[3] — no stdin JSON to parse
        // (unlike Claude's hook mirror below). Reuses the same conversationId
        // payload, so WorkspaceStore persists it + prepends `--session <id>`
        // on next launch.
        let id = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : ""
        guard !id.isEmpty else { exit(0) }
        let payload = KookyHookKit.buildConversationIdPayload(surface: surface, conversationId: id)
        exit(KookyHookKit.sendPayload(payload, to: socketPath) ? 0 : 1)
    }
    if event == "PreToolUse" || event == "PostToolUse" || event == "PostToolUseFailure" {
        // Tool event: stdin JSON is mandatory. Bail silently if it's
        // missing or malformed — pill UI just won't render this call.
        guard let tool = KookyHookKit.parseToolEventPayload(
            from: stdinData,
            surface: surface,
            agent: agent
        ) else { exit(0) }
        payloadObject = tool
    } else {
        payloadObject = KookyHookKit.buildLifecyclePayload(
            agent: agent,
            event: event,
            surface: surface
        )
    }
} else {
    exit(0)
}

let eventSent = KookyHookKit.sendPayload(payloadObject, to: socketPath)

// Bonus payload: Claude pipes `session_id` on every hook (lifecycle +
// tool). Mirror it so `WorkspaceStore` can persist the conversation id
// on `Session` and prepend `--resume <id>` on next launch. Gated on:
//   1. `agent == "claude"` — non-Claude agents skip it
//   2. `kind != "tool"` — tool payloads fire 10-100× per Claude turn and
//      each one ALSO carries session_id; mirroring on every Pre/PostToolUse
//      would multiply IPC by N tool calls per turn. Lifecycle events
//      (SessionStart/UserPromptSubmit/Stop/Notification/SessionEnd) carry
//      the same id and fire 5× per turn — plenty to keep WorkspaceStore's
//      `--resume` field fresh. applyConversationId dedups same-value writes
//      but each call still pays a socket connect+write+close roundtrip.
if payloadObject["agent"] == "claude",
   payloadObject["kind"] != "tool",
   let conversationId = KookyHookKit.parseClaudeConversationId(from: stdinData) {
    let payload = KookyHookKit.buildConversationIdPayload(
        surface: surface,
        conversationId: conversationId
    )
    _ = KookyHookKit.sendPayload(payload, to: socketPath)
}

exit(eventSent ? 0 : 1)
