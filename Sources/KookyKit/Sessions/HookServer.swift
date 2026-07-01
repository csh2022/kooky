import Darwin
import Foundation

/// Listens on a per-user unix socket for one-shot JSON event lines from
/// hooks (sent by Kooky's hook CLI mode): agent lifecycle events and prompt-time
/// shell env snapshots. Wire format is one JSON object per line.
///
/// The hooks themselves run as short-lived child processes of the agent (e.g.
/// Claude Code spawns them per Stop / UserPromptSubmit / Notification). They
/// connect, write one line, close — we accept and read in a single pass.
/// Lifecycle signal an agent's hook fired. Wire format is the raw String
/// case names; the enum lets `WorkspaceStore` switch exhaustively.
enum HookEvent: String {
    case running, attention, idle, ended

    var activityState: SessionActivityState {
        switch self {
        case .running: return .running
        case .attention: return .attention
        case .idle, .ended: return .idle
        }
    }
}

/// PreToolUse / PostToolUse phase carried on `HookMessage.toolCall`. Pre
/// fires before Claude runs the tool; Post fires after — duration / orphan
/// timing are computed `WorkspaceStore`-side from the gap between matched
/// events (the hook CLI is process-per-event and can't keep state).
enum HookToolEvent: String {
    case pre, post
}

enum HookBrowserCommand: Equatable {
    case open(address: String)
    case state
    case snapshot(path: String?)
    case elements
    case text
    case html(path: String?)
    case links
    case screenshot(path: String?)
    case click(text: String)
    case clickId(id: String, double: Bool)
    case clickAt(x: Double, y: Double)
    case fill(field: String, text: String)
    case fillId(id: String, text: String)
    case clear(field: String?)
    case type(text: String)
    case paste(text: String)
    case press(key: String)
    case hotkey(combo: String)
    case scroll(direction: String, amount: Double?)
    case hover(id: String)
    case wait(text: String, timeoutMilliseconds: Int)
    case waitURL(text: String, timeoutMilliseconds: Int)
    case waitTitle(text: String, timeoutMilliseconds: Int)
    case back
    case forward
    case reload
    case stop
    case close
}

enum HookMessage {
    case agent(agent: AgentTemplate, event: HookEvent, sessionId: UUID)
    case shellEnvironment(env: [String: String], sessionId: UUID)
    /// Agent hook/extension payload carrying a conversation or session id.
    /// The hook CLI emits this message so kooky can persist the id on the
    /// originating Session and reuse it on next launch. The matching agent
    /// template is tracked on `Session.resumeAgent`, so the payload only
    /// carries surface + id.
    case conversationId(conversationId: String, sessionId: UUID)
    /// PreToolUse / PostToolUse event for the activity strip. `agent` is
    /// the base AgentTemplate the slug resolves to (Claude builtin today —
    /// custom Claude-based agents share its slug since `from(hookSlug:)`
    /// matches by `initialCommand`). `success` is non-nil only for
    /// `.post` events. `toolUseId` is Claude's per-call stable id when
    /// present (used by `Session.recordToolCallEnd` to match Pre/Post
    /// pairs even when two concurrent calls share `toolName` + truncated
    /// identifier).
    case toolCall(
        agent: AgentTemplate,
        toolName: String,
        identifier: String,
        event: HookToolEvent,
        success: Bool?,
        toolUseId: String?,
        sessionId: UUID
    )
    case browser(command: HookBrowserCommand, sessionId: UUID)
}

@MainActor
final class HookServer {
    typealias Handler = @MainActor (_ message: HookMessage) async -> String?

    private let handler: Handler
    let socketPath: String
    private var listenFd: Int32 = -1
    private var source: DispatchSourceRead?

    init(socketPath: String = HookServer.socketPath, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// Per-process path that prevents multiple Kooky instances from stealing
    /// each other's hook/browser traffic. Sessions receive this path in
    /// `KOOKY_HOOK_SOCKET`; older sessions without that env fall back to the
    /// legacy shared path in `KookyHookKit`.
    nonisolated static let socketPath: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky/sockets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("s-\(getpid())").path
    }()

    func start() {
        let path = socketPath
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("kooky: HookServer socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            NSLog("kooky: HookServer socket path too long")
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0 else {
            NSLog("kooky: HookServer bind() failed errno=\(errno)")
            close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            NSLog("kooky: HookServer listen() failed errno=\(errno)")
            close(fd)
            return
        }

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptOne() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }

        // Single read up to 4 KiB. Hook payloads are < 200 B and unix
        // SOCK_STREAM kernel-buffers small writes whole, so partial reads
        // aren't a practical concern at our message size.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBufferPointer { read(clientFd, $0.baseAddress, $0.count) }
        guard n > 0 else {
            close(clientFd)
            return
        }
        let data = Data(bytes: buffer, count: n)
        guard let message = Self.parseMessage(data) else {
            close(clientFd)
            return
        }
        Task { @MainActor [handler] in
            if let response = await handler(message), !response.isEmpty {
                response.withCString { pointer in
                    _ = write(clientFd, pointer, strlen(pointer))
                }
            }
            close(clientFd)
        }
    }

    private static let envKeys = [
        "VIRTUAL_ENV", "CONDA_DEFAULT_ENV",
        "NVM_BIN", "NVM_DIR", "KOOKY_NODE_VERSION",
        "https_proxy", "http_proxy", "all_proxy",
    ]

    private static func optionalString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    static func parseMessage(_ data: Data) -> HookMessage? {
        guard
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let surface = dict["surface"] as? String,
            let id = UUID(uuidString: surface)
        else { return nil }

        if dict["kind"] as? String == "env" {
            let env = Dictionary(uniqueKeysWithValues: envKeys.map { key in
                (key, dict[key] as? String ?? "")
            })
            return .shellEnvironment(env: env, sessionId: id)
        }

        if dict["kind"] as? String == "conversationId",
           let conversationId = dict["conversationId"] as? String,
           !conversationId.isEmpty {
            return .conversationId(conversationId: conversationId, sessionId: id)
        }

        if dict["kind"] as? String == "browser",
           let command = dict["command"] as? String {
            switch command {
            case "open":
                guard let address = dict["address"] as? String,
                      !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .browser(command: .open(address: address), sessionId: id)
            case "state":
                return .browser(command: .state, sessionId: id)
            case "snapshot":
                return .browser(command: .snapshot(path: optionalString(dict["path"])), sessionId: id)
            case "elements":
                return .browser(command: .elements, sessionId: id)
            case "text":
                return .browser(command: .text, sessionId: id)
            case "html":
                return .browser(command: .html(path: optionalString(dict["path"])), sessionId: id)
            case "links":
                return .browser(command: .links, sessionId: id)
            case "screenshot":
                return .browser(command: .screenshot(path: optionalString(dict["path"])), sessionId: id)
            case "click":
                guard let text = dict["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .browser(command: .click(text: text), sessionId: id)
            case "click-id":
                guard let elementId = dict["id"] as? String,
                      !elementId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .browser(
                    command: .clickId(id: elementId, double: dict["double"] as? String == "true"),
                    sessionId: id
                )
            case "click-at":
                guard let xString = dict["x"] as? String,
                      let yString = dict["y"] as? String,
                      let x = Double(xString),
                      let y = Double(yString) else { return nil }
                return .browser(command: .clickAt(x: x, y: y), sessionId: id)
            case "fill":
                guard let field = dict["field"] as? String,
                      !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let text = dict["text"] as? String else { return nil }
                return .browser(command: .fill(field: field, text: text), sessionId: id)
            case "fill-id":
                guard let elementId = dict["id"] as? String,
                      !elementId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let text = dict["text"] as? String else { return nil }
                return .browser(command: .fillId(id: elementId, text: text), sessionId: id)
            case "clear":
                return .browser(command: .clear(field: optionalString(dict["field"])), sessionId: id)
            case "type":
                guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
                return .browser(command: .type(text: text), sessionId: id)
            case "paste":
                guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
                return .browser(command: .paste(text: text), sessionId: id)
            case "press":
                guard let key = dict["key"] as? String,
                      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .browser(command: .press(key: key), sessionId: id)
            case "hotkey":
                guard let key = dict["key"] as? String,
                      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .browser(command: .hotkey(combo: key), sessionId: id)
            case "scroll":
                let direction = dict["direction"] as? String ?? "down"
                let amount = (dict["amount"] as? String).flatMap(Double.init)
                return .browser(command: .scroll(direction: direction, amount: amount), sessionId: id)
            case "hover":
                guard let elementId = dict["id"] as? String,
                      !elementId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .browser(command: .hover(id: elementId), sessionId: id)
            case "wait":
                guard let text = dict["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let timeout = (dict["timeout"] as? String).flatMap(Int.init) ?? 5_000
                return .browser(command: .wait(text: text, timeoutMilliseconds: timeout), sessionId: id)
            case "wait-url":
                guard let text = dict["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let timeout = (dict["timeout"] as? String).flatMap(Int.init) ?? 5_000
                return .browser(command: .waitURL(text: text, timeoutMilliseconds: timeout), sessionId: id)
            case "wait-title":
                guard let text = dict["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let timeout = (dict["timeout"] as? String).flatMap(Int.init) ?? 5_000
                return .browser(command: .waitTitle(text: text, timeoutMilliseconds: timeout), sessionId: id)
            case "back":
                return .browser(command: .back, sessionId: id)
            case "forward":
                return .browser(command: .forward, sessionId: id)
            case "reload":
                return .browser(command: .reload, sessionId: id)
            case "stop":
                return .browser(command: .stop, sessionId: id)
            case "close":
                return .browser(command: .close, sessionId: id)
            default:
                return nil
            }
        }

        if dict["kind"] as? String == "tool" {
            guard
                let agentSlug = dict["agent"] as? String,
                let agent = AgentTemplate.from(hookSlug: agentSlug),
                let toolName = dict["tool_name"] as? String, !toolName.isEmpty,
                let identifier = dict["identifier"] as? String,
                let eventRaw = dict["event"] as? String,
                let event = HookToolEvent(rawValue: eventRaw)
            else { return nil }

            // success ships as a literal "true" / "false" string on .post;
            // .pre omits it. Strict equality with "true" — any other value
            // ("TRUE", "1", "yes", "") coerces to false. KookyHookKit owns
            // the wire shape and ships exactly "true" / "false", so the
            // strict check is a wire-protocol contract not a parse heuristic.
            // Missing field on .post leaves success nil — the consumer
            // (WorkspaceStore.applyToolCallEvent) treats nil as success
            // (rather than guess-fail an unparseable response).
            var success: Bool? = nil
            if event == .post, let s = dict["success"] as? String {
                success = (s == "true")
            }

            // tool_use_id ships only when Claude includes it (recent CLI);
            // nil-tolerant on the consumer side so old payloads still work.
            let toolUseId = (dict["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            return .toolCall(
                agent: agent,
                toolName: toolName,
                identifier: identifier,
                event: event,
                success: success,
                toolUseId: toolUseId,
                sessionId: id
            )
        }

        guard
            let agentSlug = dict["agent"] as? String,
            let eventName = dict["event"] as? String,
            let agent = AgentTemplate.from(hookSlug: agentSlug),
            let event = HookEvent(rawValue: eventName)
        else { return nil }
        return .agent(agent: agent, event: event, sessionId: id)
    }
}
