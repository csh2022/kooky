import Darwin
import Foundation

/// Pure helpers for Kooky's hook CLI mode: builds the JSON payloads it ships to
/// `HookServer` and writes them across the unix socket the running app owns.
/// Lives in its own library target so unit tests can verify parsing logic
/// (malformed JSON, missing fields, wrong types, future PreToolUse /
/// PostToolUse payloads) without spawning a subprocess. Stays off
/// `KookyKit` on purpose so the hook payload layer stays small and reusable.
public enum KookyHookKit {
    public static let browserHelpText = """
    Kooky built-in browser commands:

      Kooky browser help
          Show this help. Agents should run this before browser-page tasks to discover current capabilities.

      Kooky browser open <url-or-query>
          Open or reuse this agent's browser split and navigate to a URL or search query.
          Examples:
            Kooky browser open https://example.com
            Kooky browser open localhost:3000
            Kooky browser open "weather shanghai"

      Kooky browser state
          Print the current built-in browser title, URL, and loading state.

      Kooky browser snapshot [path]
          Print a structured page snapshot with stable element ids, visible text, and links.
          If path is provided, write the snapshot text to that file and print the path.

      Kooky browser elements
          Print visible clickable/form elements as JSON lines. Use element ids with click-id/fill-id/hover.

      Kooky browser text
          Print the current page's readable text.

      Kooky browser html [path]
          Print the current page HTML. If path is provided, write it to path and print the path.

      Kooky browser links
          Print visible links as JSON lines with text, href, and element id.

      Kooky browser screenshot [path]
          Save a PNG screenshot of the visible browser viewport. Prints the saved path.

      Kooky browser credentials
          List saved accounts for the current page origin. Does not print passwords.

      Kooky browser save-credential
          Save the current page's filled username/password form to macOS Keychain.

      Kooky browser fill-credential [account]
          Fill a saved username/password for the current page origin. If account is omitted, uses the first saved account.

      Kooky browser click <visible-text>
          Click the first visible link, button, or clickable element whose text contains <visible-text>.

      Kooky browser click-id <element-id>
          Click an element id returned by snapshot/elements/links.

      Kooky browser click-at <x> <y>
          Click viewport coordinates inside the browser page.

      Kooky browser fill <field-label-or-placeholder> <text>
          Focus and replace the value of a visible input/textarea/contenteditable field.

      Kooky browser fill-id <element-id> <text>
          Replace the value of an input/textarea/contenteditable element id from snapshot/elements.

      Kooky browser clear [field-label-or-placeholder]
          Clear the focused field, or the matching field when a label/placeholder is provided.

      Kooky browser type <text>
          Type text into the currently focused page element.

      Kooky browser paste <text>
          Paste text into the focused page element.

      Kooky browser press <key>
          Press a page key such as Enter, Escape, Tab, Backspace, ArrowDown, or ArrowUp.

      Kooky browser hotkey <combo>
          Press a browser/page shortcut such as Meta+L, Meta+R, Meta+F, Escape, or Enter.

      Kooky browser scroll <up|down|left|right> [amount]
          Scroll the nearest page or internal scroll container and print its position. Amount is optional pixels; default is about one viewport.

      Kooky browser hover <element-id>
          Move hover/focus state to an element id returned by snapshot/elements.

      Kooky browser wait <text> [timeout-ms]
          Wait until page text contains <text>, then print state.

      Kooky browser wait-url <url-substring> [timeout-ms]
          Wait until the current page URL contains <url-substring>, then print state.

      Kooky browser wait-title <title-substring> [timeout-ms]
          Wait until the current page title contains <title-substring>, then print state.

      Kooky browser back
      Kooky browser forward
      Kooky browser reload
      Kooky browser stop
          Browser navigation controls.

      Kooky browser close
          Close this agent's browser split if it is still auto-owned by the agent.

    Notes:
      - These commands target Kooky's built-in browser, not an external browser.
      - The browser opens as a split next to the calling Kooky session.
      - Future commands will be listed here as they are added.
    """

    public static let surfaceIdEnvironmentKey = "KOOKY_SURFACE_ID"
    public static let socketPathEnvironmentKey = "KOOKY_HOOK_SOCKET"

    public static let missingSurfaceDiagnostic = """
    Kooky built-in browser is unavailable because KOOKY_SURFACE_ID is not set. \
    Start this command from a Kooky session or open a new Kooky tab so browser commands can route to the calling split.
    """

    public static func surfaceId(from environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let value = environment[surfaceIdEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    public static var legacySocketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("kooky/socket").path
    }

    public static var socketPath: String {
        let env = ProcessInfo.processInfo.environment[socketPathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return env.isEmpty ? legacySocketPath : env
    }

    /// One-shot socket write. Returns true on success. `HookServer` accepts
    /// one payload per connection so each call opens / writes / closes.
    public static func sendPayload(_ object: [String: String], to path: String) -> Bool {
        sendPayloadAndReadResponse(object, to: path) != nil
    }

    public static func sendPayloadAndReadResponse(_ object: [String: String], to path: String) -> String? {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard connected == 0 else { return nil }

        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written >= 0 else { return nil }
        shutdown(fd, SHUT_WR)

        var response = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let maxResponseBytes = 2 * 1024 * 1024
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
                if response.count >= maxResponseBytes { break }
            } else {
                break
            }
        }
        guard !response.isEmpty else { return "" }
        return String(decoding: response, as: UTF8.self)
    }

    /// Env-snapshot payload from positional args. Order follows the
    /// `Kooky env ...` calling convention in `ShellIntegration.swift`'s
    /// precmd hook: VIRTUAL_ENV, CONDA_DEFAULT_ENV, NVM_BIN, NVM_DIR,
    /// KOOKY_NODE_VERSION, https_proxy, http_proxy, all_proxy.
    public static func buildEnvPayload(surface: String, args: [String]) -> [String: String] {
        func arg(_ index: Int) -> String { args.indices.contains(index) ? args[index] : "" }
        return [
            "kind": "env",
            "surface": surface,
            "VIRTUAL_ENV": arg(0),
            "CONDA_DEFAULT_ENV": arg(1),
            "NVM_BIN": arg(2),
            "NVM_DIR": arg(3),
            "KOOKY_NODE_VERSION": arg(4),
            "https_proxy": arg(5),
            "http_proxy": arg(6),
            "all_proxy": arg(7),
        ]
    }

    /// Lifecycle payload (running / attention / idle / ended).
    public static func buildLifecyclePayload(agent: String, event: String, surface: String) -> [String: String] {
        [
            "agent": agent,
            "event": event,
            "surface": surface,
        ]
    }

    /// Pulls `session_id` out of Claude Code's hook stdin JSON. Returns nil
    /// on malformed input, missing field, wrong type, or empty string —
    /// callers should treat nil as "nothing to relay" and move on. Other
    /// agents either don't pipe stdin or don't expose a session id; the
    /// caller gates on `agent == "claude"` before invoking this.
    public static func parseClaudeConversationId(from data: Data) -> String? {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = parsed["session_id"] as? String,
              !sessionId.isEmpty
        else { return nil }
        return sessionId
    }

    /// Pulls Codex's resumable session id out of the JSON payload appended to
    /// the configured `notify` command. Codex session ids are UUID-shaped; we
    /// reject non-UUID strings so unrelated notification fields don't become
    /// bogus `codex resume <id>` launches.
    public static func parseCodexConversationId(from data: Data) -> String? {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return findCodexConversationId(in: parsed, allowBareId: false)
    }

    /// ConversationId payload routed to `HookServer` so `WorkspaceStore`
    /// can persist it on `Session` and prepend `--resume <id>` to
    /// `KOOKY_AGENT` on next launch.
    public static func buildConversationIdPayload(surface: String, conversationId: String) -> [String: String] {
        [
            "kind": "conversationId",
            "surface": surface,
            "conversationId": conversationId,
        ]
    }

    public static func buildBrowserOpenPayload(surface: String, address: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "open",
            "address": address,
        ]
    }

    public static func buildBrowserClosePayload(surface: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "close",
        ]
    }

    public static func buildBrowserStatePayload(surface: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "state",
        ]
    }

    public static func buildBrowserOutputPayload(surface: String, command: String, path: String = "") -> [String: String] {
        var payload = [
            "kind": "browser",
            "surface": surface,
            "command": command,
        ]
        if !path.isEmpty {
            payload["path"] = path
        }
        return payload
    }

    public static func buildBrowserCredentialPayload(surface: String, command: String, account: String = "") -> [String: String] {
        var payload = [
            "kind": "browser",
            "surface": surface,
            "command": command,
        ]
        if !account.isEmpty {
            payload["account"] = account
        }
        return payload
    }

    public static func buildBrowserClickPayload(surface: String, text: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "click",
            "text": text,
        ]
    }

    public static func buildBrowserClickIdPayload(surface: String, id: String, double: Bool = false) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "click-id",
            "id": id,
            "double": double ? "true" : "false",
        ]
    }

    public static func buildBrowserClickAtPayload(surface: String, x: String, y: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "click-at",
            "x": x,
            "y": y,
        ]
    }

    public static func buildBrowserFillPayload(surface: String, field: String, text: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "fill",
            "field": field,
            "text": text,
        ]
    }

    public static func buildBrowserFillIdPayload(surface: String, id: String, text: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "fill-id",
            "id": id,
            "text": text,
        ]
    }

    public static func buildBrowserClearPayload(surface: String, field: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "clear",
            "field": field,
        ]
    }

    public static func buildBrowserTypePayload(surface: String, text: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "type",
            "text": text,
        ]
    }

    public static func buildBrowserPastePayload(surface: String, text: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "paste",
            "text": text,
        ]
    }

    public static func buildBrowserPressPayload(surface: String, key: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "press",
            "key": key,
        ]
    }

    public static func buildBrowserHotkeyPayload(surface: String, combo: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "hotkey",
            "key": combo,
        ]
    }

    public static func buildBrowserScrollPayload(surface: String, direction: String, amount: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "scroll",
            "direction": direction,
            "amount": amount,
        ]
    }

    public static func buildBrowserHoverPayload(surface: String, id: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "hover",
            "id": id,
        ]
    }

    public static func buildBrowserWaitPayload(surface: String, text: String, timeout: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "wait",
            "text": text,
            "timeout": timeout,
        ]
    }

    public static func buildBrowserWaitURLPayload(surface: String, text: String, timeout: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "wait-url",
            "text": text,
            "timeout": timeout,
        ]
    }

    public static func buildBrowserWaitTitlePayload(surface: String, text: String, timeout: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": "wait-title",
            "text": text,
            "timeout": timeout,
        ]
    }

    public static func buildBrowserSimplePayload(surface: String, command: String) -> [String: String] {
        [
            "kind": "browser",
            "surface": surface,
            "command": command,
        ]
    }

    /// Maximum bytes / characters carried by the cross-boundary `identifier`
    /// field. Per `/plan-eng-review` D2 — the hook CLI truncates at source so
    /// large `tool_input` payloads (Edit / Write file content) never reach
    /// the 4 KiB HookServer buffer. Counted in `Character`s, not UTF-8
    /// bytes — CJK identifiers stay readable instead of mid-codepoint cut.
    public static let identifierMaxLength = 80

    /// Parse a Claude Code PreToolUse / PostToolUse / PostToolUseFailure
    /// stdin JSON into a minimal tool-event payload routed to `HookServer`.
    /// Returns nil for any non-tool event (`SessionStart`,
    /// `UserPromptSubmit`, etc.) or malformed input — caller doesn't have
    /// to pre-filter.
    ///
    /// Payload shape:
    /// ```
    /// {
    ///   "kind": "tool",
    ///   "surface": <UUID>,
    ///   "agent":   <claude | claude-base custom agent slug>,
    ///   "tool_name": <Bash | Edit | Read | ...>,
    ///   "identifier": <truncated file path / command / url>,
    ///   "event":     <"pre" | "post">,
    ///   "success":   <"true" | "false">   (only on event=="post")
    ///   "tool_use_id": <Claude's per-call id>  (when present)
    /// }
    /// ```
    ///
    /// `identifier` is extracted from `tool_input` per tool kind, control
    /// characters collapsed to spaces, then truncated to 80 chars. Bulk
    /// data (full file content, Bash output) never crosses this boundary.
    ///
    /// `PostToolUseFailure` is recognised as a Post variant whose `success`
    /// is forced to `false` without inspecting `tool_response` — Claude
    /// fires this distinct event only when the tool itself errored, so
    /// the heuristic-free signal beats the `tool_response` text scan.
    public static func parseToolEventPayload(
        from data: Data,
        surface: String,
        agent: String
    ) -> [String: String]? {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = parsed["hook_event_name"] as? String,
              let toolName = parsed["tool_name"] as? String,
              !toolName.isEmpty
        else { return nil }

        let event: String
        let postSuccessOverride: Bool?  // nil → heuristic, true/false → forced
        switch hookEventName {
        case "PreToolUse":         event = "pre";  postSuccessOverride = nil
        case "PostToolUse":        event = "post"; postSuccessOverride = nil
        case "PostToolUseFailure": event = "post"; postSuccessOverride = false
        default:                   return nil  // not a tool event we handle
        }

        let toolInput = parsed["tool_input"] as? [String: Any] ?? [:]
        let rawIdentifier = extractIdentifier(toolName: toolName, toolInput: toolInput)

        // PostToolUseFailure forces success=false (Claude's own signal);
        // PostToolUse falls back to the heuristic over `tool_response`. Pre
        // carries no success.
        let success: Bool? = event == "post"
            ? (postSuccessOverride ?? detectSuccess(toolResponse: parsed["tool_response"]))
            : nil

        return buildToolEventPayload(
            surface: surface,
            agent: agent,
            toolName: toolName,
            identifier: rawIdentifier,
            event: event,
            toolUseId: parsed["tool_use_id"] as? String,
            success: success
        )
    }

    /// Assemble the agent-agnostic `kind:"tool"` payload routed to
    /// `HookServer` → `WorkspaceStore.applyToolCallEvent` → the status-bar
    /// pill. Single source for the wire shape so it can't drift between the
    /// two producers: `parseToolEventPayload` (Claude — extracts these
    /// fields from hook stdin JSON) and the hook CLI's `tool` argv branch (Pi —
    /// the extension hands the fields straight from `tool_execution_*`
    /// events). `identifier` is control-stripped + truncated here, the one
    /// place it happens; `toolUseId` is emitted only when non-empty (Pi's
    /// `toolCallId` and Claude's `tool_use_id` both land here so Pre/Post
    /// match by stable id); `success` only rides `event == "post"`.
    public static func buildToolEventPayload(
        surface: String,
        agent: String,
        toolName: String,
        identifier: String,
        event: String,
        toolUseId: String?,
        success: Bool?
    ) -> [String: String] {
        var payload: [String: String] = [
            "kind":       "tool",
            "surface":    surface,
            "agent":      agent,
            "tool_name":  toolName,
            "identifier": truncateForPayload(identifier),
            "event":      event,
        ]
        if let toolUseId, !toolUseId.isEmpty {
            payload["tool_use_id"] = toolUseId
        }
        if event == "post", let success {
            payload["success"] = success ? "true" : "false"
        }
        return payload
    }

    /// Pick the most descriptive single string out of `tool_input` per
    /// tool kind — what pill UI shows as the "what" of the call. Unknown
    /// tools fall back to the first non-empty string value (alphabetised
    /// by key so the choice is deterministic across runs — Swift dict
    /// iteration order isn't stable). Empty if everything's empty.
    static func extractIdentifier(toolName: String, toolInput: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return toolInput["command"] as? String ?? ""
        case "Edit", "Write", "Read", "NotebookEdit", "MultiEdit":
            return toolInput["file_path"] as? String ?? ""
        case "Glob":
            return toolInput["pattern"] as? String ?? toolInput["path"] as? String ?? ""
        case "Grep":
            return toolInput["pattern"] as? String ?? ""
        case "WebFetch", "WebSearch":
            return (toolInput["url"] as? String) ?? (toolInput["query"] as? String) ?? ""
        case "Task":
            return (toolInput["description"] as? String) ?? (toolInput["prompt"] as? String) ?? ""
        default:
            // Unknown tool — pick the first non-empty String value, with
            // keys sorted alphabetically so the choice is deterministic
            // (Swift dictionary iteration order isn't stable across runs,
            // and the pill would otherwise show different identifiers for
            // the same payload between invocations). Common-case tools
            // above have explicit dispatch.
            for key in toolInput.keys.sorted() {
                if let str = toolInput[key] as? String, !str.isEmpty { return str }
            }
            return ""
        }
    }

    /// Collapse ALL C0 control bytes (0x00-0x1F) + DEL (0x7F) to single
    /// spaces, then truncate to `identifierMaxLength` characters. Strips
    /// the whole control range — not just `\n` `\r` `\t` — because pill
    /// UI is a single-line `Text` view and any embedded NUL / BEL / ESC /
    /// FS/GS/RS/US can perturb rendering, screen-reader output, or the
    /// Pre/Post match key used in `Session.recordToolCallEnd`. Truncates
    /// by `Character` count so CJK stays whole.
    static func truncateForPayload(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.map { scalar -> Character in
            // C0 controls (0x00-0x1F) + DEL (0x7F)
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return " "
            }
            return Character(scalar)
        })
        return String(cleaned.prefix(identifierMaxLength))
    }

    /// PostToolUse success heuristic — Claude doesn't expose a structured
    /// success/failure flag in PostToolUse hook stdin, so we read
    /// `tool_response` (when present + a String) and look for common
    /// error markers. Missing / non-string response → defaults to true
    /// (don't false-flag tools we can't read). Conservative for v1.
    static func detectSuccess(toolResponse: Any?) -> Bool {
        guard let response = toolResponse as? String, !response.isEmpty else { return true }
        let lowered = response.lowercased()
        let errorMarkers = [
            "error:",
            "failed:",
            "exception:",
            "fatal:",
            "<error>",
            "permission denied",
            "command not found",
            "no such file",
        ]
        return !errorMarkers.contains { lowered.contains($0) }
    }

    private static let codexConversationIdKeys = ["session_id", "sessionId", "conversationId"]
    private static let codexConversationIdContainerKeys = ["payload", "event", "data", "notification"]

    private static func findCodexConversationId(in value: Any, allowBareId: Bool) -> String? {
        if let dict = value as? [String: Any] {
            let directKeys = allowBareId
                ? codexConversationIdKeys + ["id"]
                : codexConversationIdKeys
            for key in directKeys {
                if let id = dict[key] as? String, isCodexConversationId(id) {
                    return id
                }
            }

            for key in codexConversationIdContainerKeys {
                guard let nested = dict[key] else { continue }
                if let id = findCodexConversationId(
                    in: nested,
                    allowBareId: allowBareId || key == "payload"
                ) {
                    return id
                }
            }

            for key in dict.keys.sorted() where !codexConversationIdContainerKeys.contains(key) {
                guard let nested = dict[key] else { continue }
                if nested is [String: Any] || nested is [Any],
                   let id = findCodexConversationId(in: nested, allowBareId: false) {
                    return id
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let id = findCodexConversationId(in: item, allowBareId: false) {
                    return id
                }
            }
        }
        return nil
    }

    private static func isCodexConversationId(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}
