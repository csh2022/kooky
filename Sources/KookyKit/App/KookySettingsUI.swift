import AppKit
import SwiftUI

/// `@Observable` mirror of the typed slice of `~/.kooky/settings.json` we
/// expose in the Settings UI. Loads on init, debounces writes back to disk
/// so rapid `Stepper` taps don't thrash the file. Only knows about keys that
/// have working bindings in libghostty today — kooky-specific keys
/// (`agent.*`, `sidebar.*`, …) live in settings.json but aren't surfaced in
/// the UI yet, because their behavior isn't wired and shipping a hollow
/// toggle is worse than no toggle.
@Observable
@MainActor
final class KookySettingsModel {
    /// Singleton so non-Settings UI surfaces (TabBarView's `+` menu, etc.)
    /// observe the same instance and react to user edits without a reload.
    static let shared = KookySettingsModel()

    var fontFamily: String = ""
    /// `nil` = not overridden — let libghostty fall back to ghostty's own
    /// config (or its default). Writing a default 13 unconditionally would
    /// silently shadow the user's `~/.config/ghostty/config` font-size.
    var fontSize: Int? = nil
    var cursorStyle: String = "block"

    /// User-customised order for the `+` menu agent list (Terminal stays
    /// pinned first regardless). Empty = use `AgentTemplate.all` order.
    /// Unknown ids are dropped on load; ids absent from this array but
    /// present in `AgentTemplate.all` are appended after, so a new agent
    /// shipped in a future kooky still shows up.
    var agentOrder: [String] = []
    var hiddenAgents: Set<String> = []
    /// Per-agent CLI options appended after the binary name when launching.
    /// E.g. `agentOptions["claude-code"] = "--model opus"` → KOOKY_AGENT
    /// becomes `claude --model opus`. The wrapper rc's `eval` splits on
    /// whitespace, so users handle their own quoting for spaces.
    var agentOptions: [String: String] = [:]
    /// `id` of the template that `+` / `⌘T` should open without prompting.
    /// `nil` (or pointing to a now-hidden / unknown agent) means "ask each
    /// time" — the popover stays. Terminal is always a valid choice.
    var defaultAgentId: String? = nil
    /// User-defined agent entries (`agents.custom` in settings.json). Each
    /// becomes a runtime `AgentTemplate` via `AgentTemplate.fromCustom`,
    /// joins the `+` menu / Settings list alongside the builtin agents,
    /// and supports the same visibility / order / options machinery.
    var customAgents: [CustomAgentData] = []
    /// When true, kooky launches Claude tabs with `--resume <id>` using the
    /// conversation id persisted on each tab (captured via Claude's hook
    /// payload). When false, every Claude tab starts fresh — but the
    /// persisted conversation id stays on disk so turning the toggle back
    /// on resumes from where the user left off.
    var resumeConversations: Bool = true

    private var saveWork: DispatchWorkItem?

    init() { load() }

    func load() {
        let parsed = KookySettings.loadParsed() ?? [:]
        let terminal = parsed["terminal"] as? [String: Any] ?? [:]
        fontFamily = (terminal["font-family"] as? String) ?? ""
        fontSize = nil
        if let n = terminal["font-size"] as? Int {
            fontSize = n
        } else if let d = terminal["font-size"] as? Double {
            fontSize = Int(d)
        }
        cursorStyle = (terminal["cursor-style"] as? String) ?? "block"

        let agents = parsed["agents"] as? [String: Any] ?? [:]
        agentOrder = (agents["order"] as? [String]) ?? []
        hiddenAgents = Set((agents["hidden"] as? [String]) ?? [])
        agentOptions = (agents["options"] as? [String: String]) ?? [:]
        defaultAgentId = agents["default"] as? String
        resumeConversations = (agents["resumeConversations"] as? Bool) ?? true

        let rawCustom = (agents["custom"] as? [[String: Any]]) ?? []
        let builtinIds = Set(AgentTemplate.builtin.map(\.id))
        var seen: Set<String> = []
        customAgents = rawCustom.compactMap { dict -> CustomAgentData? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            // Drop hand-edited collisions with builtin agents, and the
            // second occurrence of a duplicated id, so the live `all` list
            // is guaranteed-unique downstream.
            if builtinIds.contains(id) { return nil }
            if !seen.insert(id).inserted { return nil }
            return CustomAgentData(
                id: id,
                title: (dict["title"] as? String) ?? "",
                command: (dict["command"] as? String) ?? "",
                baseAgentId: (dict["baseAgentId"] as? String) ?? "",
                iconAsset: (dict["iconAsset"] as? String) ?? "",
                symbol: (dict["symbol"] as? String) ?? "",
                tintHex: (dict["tintHex"] as? String) ?? "",
                env: (dict["env"] as? String) ?? ""
            )
        }
    }

    /// Schedules a debounced write. UI bindings call this on every change;
    /// the 300ms timer collapses a burst of edits (Stepper, typing, etc.)
    /// into one write.
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Cancels the pending debounce and writes synchronously. Called from
    /// the Restart flow so the new instance is guaranteed to see the user's
    /// latest edits.
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        save()
    }

    private func save() {
        var parsed = KookySettings.loadParsed() ?? [:]
        var terminal = parsed["terminal"] as? [String: Any] ?? [:]
        // Sentinel values (empty string / nil / "block") drop the key so
        // libghostty falls back to ghostty's own config or its own default.
        terminal["font-family"] = fontFamily.isEmpty ? nil : fontFamily
        terminal["font-size"] = fontSize
        terminal["cursor-style"] = cursorStyle == "block" ? nil : cursorStyle
        parsed["terminal"] = terminal

        let nonEmptyOptions = agentOptions.filter { !$0.value.isEmpty }
        let serialisedCustom: [[String: Any]] = customAgents.compactMap { c in
            guard !c.id.isEmpty else { return nil }
            var dict: [String: Any] = ["id": c.id]
            if !c.title.isEmpty { dict["title"] = c.title }
            if !c.command.isEmpty { dict["command"] = c.command }
            if !c.baseAgentId.isEmpty { dict["baseAgentId"] = c.baseAgentId }
            if !c.iconAsset.isEmpty { dict["iconAsset"] = c.iconAsset }
            if !c.symbol.isEmpty { dict["symbol"] = c.symbol }
            if !c.tintHex.isEmpty { dict["tintHex"] = c.tintHex }
            if !c.env.isEmpty { dict["env"] = c.env }
            return dict
        }
        let allDefaults = agentOrder.isEmpty
            && hiddenAgents.isEmpty
            && nonEmptyOptions.isEmpty
            && defaultAgentId == nil
            && serialisedCustom.isEmpty
            && resumeConversations  // default-true is the no-op case
        if allDefaults {
            parsed.removeValue(forKey: "agents")
        } else {
            var agents = parsed["agents"] as? [String: Any] ?? [:]
            agents["order"] = agentOrder.isEmpty ? nil : agentOrder
            agents["hidden"] = hiddenAgents.isEmpty ? nil : Array(hiddenAgents).sorted()
            agents["options"] = nonEmptyOptions.isEmpty ? nil : nonEmptyOptions
            agents["default"] = defaultAgentId
            agents["custom"] = serialisedCustom.isEmpty ? nil : serialisedCustom
            // Only serialise when non-default to keep settings.json lean.
            agents["resumeConversations"] = resumeConversations ? nil : false
            parsed["agents"] = agents
        }

        KookySettings.write(parsed)
        KookyShellIntegration.refreshClaudeCustomSettings(customAgents: customAgents)
    }

    func resetAgentCustomisation() {
        agentOrder = []
        hiddenAgents = []
        agentOptions = [:]
        defaultAgentId = nil
        customAgents = []
        scheduleSave()
    }

    /// Appends a new blank custom agent. The id is `custom-N`, the title is
    /// empty (user fills it inline) — `AgentTemplate.fromCustom` falls back
    /// to showing the id as title until the user edits it.
    func addCustomAgent() {
        let usedIds = Set(AgentTemplate.builtin.map(\.id) + customAgents.map(\.id))
        var n = customAgents.count + 1
        var candidate = "custom-\(n)"
        while usedIds.contains(candidate) { n += 1; candidate = "custom-\(n)" }
        customAgents.append(CustomAgentData(id: candidate))
        scheduleSave()
    }

    func deleteCustomAgent(id: String) {
        customAgents.removeAll { $0.id == id }
        agentOrder.removeAll { $0 == id }
        hiddenAgents.remove(id)
        agentOptions.removeValue(forKey: id)
        if defaultAgentId == id { defaultAgentId = nil }
        scheduleSave()
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case terminal, codingAgents, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .codingAgents: return "Agents"
        case .advanced: return "Advanced"
        }
    }
}

/// Settings panel. Brutalist-minimal:
///   - sidebar list reads like a config-key index: mono font, `▸` prefix on
///     the selected row, no pill highlights, no icons
///   - detail surface is unboxed — rows are hairline-separated, labels are
///     kebab-case config keys in mono, headers use Onest display for the
///     single human-readable hook
///   - all separators are 1pt hairlines, all corners are sharp
/// The goal is to feel like polishing a `.toml` in a clean GUI, not a SaaS
/// settings panel.
struct KookySettingsView: View {
    @Bindable var model: KookySettingsModel
    let onOpenInTab: () -> Void
    @State private var selected: SettingsCategory = .terminal

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.chromeHairline).frame(width: 1)
            ScrollView { detail }
                .frame(maxWidth: .infinity)
        }
        .background(Theme.chromeBackground)
        .preferredColorScheme(.dark)
        .onChange(of: model.fontFamily) { _, _ in model.scheduleSave() }
        .onChange(of: model.fontSize) { _, _ in model.scheduleSave() }
        .onChange(of: model.cursorStyle) { _, _ in model.scheduleSave() }
        .onChange(of: model.agentOrder) { _, _ in model.scheduleSave() }
        .onChange(of: model.hiddenAgents) { _, _ in model.scheduleSave() }
        .onChange(of: model.agentOptions) { _, _ in model.scheduleSave() }
        .onChange(of: model.defaultAgentId) { _, _ in model.scheduleSave() }
        .onChange(of: model.customAgents) { _, _ in model.scheduleSave() }
        .onChange(of: model.resumeConversations) { _, _ in model.scheduleSave() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS")
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 18)
            ForEach(SettingsCategory.allCases) { category in
                sidebarRow(category)
            }
            Spacer()
        }
        .frame(width: 168, alignment: .topLeading)
        .background(Theme.chromeFaint.opacity(0.08))
    }

    private func sidebarRow(_ category: SettingsCategory) -> some View {
        let isSelected = selected == category
        return HStack(spacing: 0) {
            Text(isSelected ? "▸" : " ")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.chromeForeground : Color.clear)
                .frame(width: 14, alignment: .leading)
            Text(category.title)
                .font(Theme.mono(12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.chromeForeground : Theme.chromeMuted)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { selected = category }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selected.title)
                .font(Theme.display(22, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 22)
            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            switch selected {
            case .terminal: terminalDetail
            case .codingAgents: codingAgentsDetail
            case .advanced: advancedDetail
            }
            Spacer(minLength: 28)
        }
    }

    private var terminalDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "font-family") {
                Picker("", selection: $model.fontFamily) {
                    Text("Default").tag("")
                    Divider()
                    ForEach(Self.monospaceFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180)
            }
            SettingsHairline()
            SettingsRow(label: "font-size") {
                HStack(spacing: 8) {
                    Text("\(model.fontSize ?? Self.defaultFontSize)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.chromeForeground)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                    Stepper("", value: fontSizeBinding, in: 8...32)
                        .labelsHidden()
                }
            }
            SettingsHairline()
            SettingsRow(label: "cursor-style") {
                Picker("", selection: $model.cursorStyle) {
                    Text("Block").tag("block")
                    Text("Underline").tag("underline")
                    Text("Bar").tag("bar")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180)
            }
            terminalRestartCallout
        }
    }

    private var codingAgentsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "default") {
                Picker("", selection: $model.defaultAgentId) {
                    Text("Ask each time").tag(String?.none)
                    Divider()
                    ForEach(AgentTemplate.visibleOrdered(model: model)) { template in
                        Text(template.title).tag(String?.some(template.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180)
            }
            SettingsHairline()
            AgentReorderList(model: model)
            SettingsHairline()
            SettingsRow(label: "resume-conversation-when-reopen") {
                Toggle("", isOn: $model.resumeConversations)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var advancedDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "~/.kooky/settings.json") {
                BracketButton("open in new tab", action: onOpenInTab)
            }
            Text("Edit the raw JSON for any key not exposed above. Comments (`//`, `/* */`) are accepted.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.horizontal, 28)
                .padding(.top, 16)
        }
    }

    private var terminalRestartCallout: some View {
        HStack(spacing: 12) {
            Text("Terminal settings apply on restart.")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeMuted)
            Spacer()
            BracketButton("restart kooky", action: restartApp)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
    }

    private func restartApp() {
        // Naively `openApplication` + `terminate` races: the new instance
        // boots while the old one still holds `~/Library/Application
        // Support/kooky/socket` and the persisted workspace file. The new
        // instance reads stale state and binds to the socket that the old
        // `applicationWillTerminate` is about to delete, leaving KookyHook
        // unable to reach anyone.
        //
        // Fix: sync-flush settings, detach a bash helper that waits for the
        // current PID to fully exit, then `open` a fresh instance. The
        // helper inherits PID 1 once kooky dies, so it keeps running after
        // our terminate.
        model.flushSave()
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = KookyShellIntegration.quote(Bundle.main.bundlePath)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.3; open -n \(bundle)"
        ]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Falls back to 13 when the user hasn't explicitly chosen a size —
    /// matches libghostty's own default so the Stepper display doesn't lie.
    private static let defaultFontSize = 13

    /// Bridges `model.fontSize: Int?` to `Stepper`'s required `Binding<Int>`.
    /// Reading the Stepper always shows a concrete number; writing sets the
    /// optional, which `save()` then writes only when non-nil.
    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { model.fontSize ?? Self.defaultFontSize },
            set: { model.fontSize = $0 }
        )
    }

    private static let monospaceFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .compactMap { family -> String? in
                guard let font = NSFont(name: family, size: 12), font.isFixedPitch else { return nil }
                return family
            }
            .sorted()
    }()

}

private struct SettingsRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.chromeForeground)
            Spacer(minLength: 14)
            trailing()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
    }
}

private struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chromeHairline.opacity(0.55))
            .frame(height: 1)
            .padding(.horizontal, 28)
    }
}

/// Reorderable list of non-terminal agent templates. The user's saved order
/// (`model.agentOrder`) is the source of truth; templates absent from it
/// (e.g. a fresh kooky install, or a new agent in a future version) are
/// appended in their default `AgentTemplate.all` position.
private struct AgentReorderList: View {
    @Bindable var model: KookySettingsModel
    @State private var draggingId: String?
    @State private var endTargeted: Bool = false
    @State private var expandedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, template in
                if index > 0 { SettingsHairline() }
                AgentRow(
                    template: template,
                    visible: !model.hiddenAgents.contains(template.id),
                    isDragging: draggingId == template.id,
                    isExpanded: expandedId == template.id,
                    isCustom: isCustomId(template.id),
                    options: Binding(
                        get: { model.agentOptions[template.id] ?? "" },
                        set: { model.agentOptions[template.id] = $0 }
                    ),
                    title: customBinding(id: template.id, \.title),
                    command: customBinding(id: template.id, \.command),
                    baseAgentId: customBinding(id: template.id, \.baseAgentId),
                    env: customBinding(id: template.id, \.env),
                    onToggleVisible: { toggle(template.id) },
                    onToggleExpanded: {
                        expandedId = expandedId == template.id ? nil : template.id
                    },
                    onBeginDrag: { draggingId = template.id },
                    onDrop: { droppedId in
                        defer { draggingId = nil }
                        return reorder(draggedId: droppedId, before: template.id)
                    },
                    onDelete: isCustomId(template.id) ? { model.deleteCustomAgent(id: template.id) } : nil
                )
            }
            // Trailing drop catcher — drag past the last row to send the
            // agent to the end of the list. Without this, the bottom-most
            // position is only reachable by dropping onto the second-to-last
            // row, which reads wrong.
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingId = nil }
                    guard let id = items.first else { return false }
                    return moveToEnd(id)
                } isTargeted: { endTargeted = $0 }
            HStack {
                Button {
                    let newId = model.customAgents.last?.id
                    model.addCustomAgent()
                    if let id = model.customAgents.last?.id, id != newId {
                        expandedId = id
                    }
                } label: {
                    Text("+ add custom agent")
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .bracketBorder()
                }
                .buttonStyle(.plain)
                Spacer()
                if hasCustomisation {
                    Button("reset to defaults") { model.resetAgentCustomisation() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .underline()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
        }
    }

    private func isCustomId(_ id: String) -> Bool {
        model.customAgents.contains(where: { $0.id == id })
    }

    /// Binding into a specific custom agent's field. Returns a no-op binding
    /// if the row is a built-in agent (`AgentRow` ignores these bindings
    /// when `isCustom == false`).
    private func customBinding(id: String, _ key: WritableKeyPath<CustomAgentData, String>) -> Binding<String> {
        Binding(
            get: { model.customAgents.first(where: { $0.id == id })?[keyPath: key] ?? "" },
            set: { newValue in
                guard let idx = model.customAgents.firstIndex(where: { $0.id == id }) else { return }
                model.customAgents[idx][keyPath: key] = newValue
            }
        )
    }

    /// All non-terminal templates in the user's chosen order — visible and
    /// hidden alike. Hidden agents render greyed out but stay wherever the
    /// user dragged them, so toggling visibility doesn't move them. The
    /// `+` menu's filter to visible-only lives in `AgentTemplate.visibleOrdered`.
    private var rows: [AgentTemplate] { AgentTemplate.ordered(model: model) }

    private var hasCustomisation: Bool {
        !model.agentOrder.isEmpty
            || !model.hiddenAgents.isEmpty
            || model.agentOptions.values.contains(where: { !$0.isEmpty })
            || model.defaultAgentId != nil
            || !model.customAgents.isEmpty
    }

    private func toggle(_ id: String) {
        if model.hiddenAgents.contains(id) {
            model.hiddenAgents.remove(id)
        } else {
            model.hiddenAgents.insert(id)
        }
    }

    private func reorder(draggedId: String, before targetId: String) -> Bool {
        var ids = rows.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              let targetIdx = ids.firstIndex(of: targetId),
              sourceIdx != targetIdx else { return false }
        let item = ids.remove(at: sourceIdx)
        // After remove, target index shifts left by 1 if source was earlier.
        let adjustedTarget = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx
        ids.insert(item, at: adjustedTarget)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.agentOrder = ids
        }
        return true
    }

    private func moveToEnd(_ draggedId: String) -> Bool {
        var ids = rows.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              sourceIdx != ids.count - 1 else { return false }
        let item = ids.remove(at: sourceIdx)
        ids.append(item)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.agentOrder = ids
        }
        return true
    }
}

private struct AgentRow: View {
    let template: AgentTemplate
    let visible: Bool
    let isDragging: Bool
    let isExpanded: Bool
    let isCustom: Bool
    @Binding var options: String
    /// Title binding — only consulted when `isCustom` so the user can rename
    /// their custom agent inline. Bound to a no-op for builtin rows.
    @Binding var title: String
    /// Launch-command binding — same scoping rule as `title`.
    @Binding var command: String
    /// `baseAgentId` binding — same scoping rule as `title`/`command`. Empty
    /// string = no base (generic icon + no wrapper inheritance).
    @Binding var baseAgentId: String
    /// Env-block binding (`.env` syntax) — same scoping rule as `title`;
    /// additionally only shown for Claude-Code-based customs.
    @Binding var env: String
    let onToggleVisible: () -> Void
    let onToggleExpanded: () -> Void
    let onBeginDrag: () -> Void
    let onDrop: (String) -> Bool
    let onDelete: (() -> Void)?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                dragHandle
                AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 14)
                    .opacity(visible ? 1.0 : 0.35)
                Text(template.title)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
                Spacer(minLength: 14)
                disclosureButton
                Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(dropZone)
            if isExpanded { expandedForm }
        }
        .opacity(isDragging ? 0.35 : 1.0)
    }

    private var disclosureButton: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted.opacity(isExpanded ? 1.0 : 0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Indent the expansion sub-row so it visually hangs under the agent
    /// name. Approximates `row hpad + handle + spacing + icon` from the
    /// HStack above; a magic-but-named constant keeps the layout legible
    /// without reaching for `.alignmentGuide`.
    private static let optionsRowIndent: CGFloat = 56

    @ViewBuilder
    private var expandedForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCustom {
                basedOnRow
                editRow(label: "title", placeholder: "My Agent", text: $title)
                if baseAgentId.isEmpty {
                    editRow(label: "command", placeholder: "aichat --model gpt-4", text: $command)
                }
                if baseAgentId == AgentTemplate.claudeCodeID {
                    editRow(
                        label: "env",
                        placeholder: "ANTHROPIC_BASE_URL=https://...\nANTHROPIC_AUTH_TOKEN=sk-...",
                        text: $env,
                        axis: .vertical
                    )
                }
            }
            editRow(label: "options", placeholder: "--model opus", text: $options)
            if isCustom {
                HStack {
                    Spacer()
                    if let onDelete {
                        Button("delete agent", action: onDelete)
                            .buttonStyle(.plain)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.activityFailure.opacity(0.85))
                            .underline()
                    }
                }
                .padding(.leading, Self.optionsRowIndent)
                .padding(.trailing, 22)
                .padding(.top, 4)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 12)
        .id(template.id)
    }

    /// "based on" picker — inherits icon / tint / wrapper / launch binary
    /// from the chosen builtin. Empty = generic SF Symbol fallback,
    /// no wrapper-fired lifecycle, `command` field required.
    /// Switching to a non-empty base clears `command` so a stale override
    /// can't silently win over the base's binary.
    private var basedOnRow: some View {
        HStack(spacing: 10) {
            Text("based on")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
            Picker("", selection: $baseAgentId) {
                Text("(none)").tag("")
                Divider()
                ForEach(AgentTemplate.builtin.filter { $0.id != "terminal" }) { template in
                    Text(template.title).tag(template.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 160)
            .onChange(of: baseAgentId) { _, new in
                if !new.isEmpty { command = "" }
            }
        }
        .padding(.leading, Self.optionsRowIndent)
        .padding(.trailing, 22)
    }

    private func editRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        axis: Axis = .horizontal
    ) -> some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: 10) {
            Text(label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
                // drop the label to the multi-line field's first text line
                .padding(.top, axis == .vertical ? 6 : 0)
            Group {
                if axis == .vertical {
                    TextField(placeholder, text: text, axis: .vertical).lineLimit(3...12)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .bracketBorder()
        }
        .padding(.leading, Self.optionsRowIndent)
        .padding(.trailing, 22)
    }

    /// `.dropDestination` lives on a clear background layer so the row's
    /// foreground (Toggle in particular) keeps independent hit-testing.
    /// Earlier attempts attached the drop modifier to the row HStack with
    /// `.contentShape(Rectangle())`; SwiftUI then routed clicks via the
    /// row-wide content shape and toggles registered against the wrong row.
    private var dropZone: some View {
        Color.clear
            .contentShape(Rectangle())
            .dropIndicator(active: isTargeted && !isDragging, on: .top)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first, id != template.id else { return false }
                return onDrop(id)
            } isTargeted: { isTargeted = $0 }
            .allowsHitTesting(true)
    }

    /// Only the `≡` glyph is the drag source. Putting `.onDrag` on the whole
    /// row hijacked toggle taps when the user clicked near the switch edge.
    /// Scoping the gesture here also scopes the openHand cursor to the
    /// handle, which is the standard macOS reorder affordance.
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.chromeMuted.opacity(0.7))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDrag {
                onBeginDrag()
                return NSItemProvider(object: template.id as NSString)
            }
    }
}

/// Singleton NSWindowController so reopening Settings reuses the same window
/// (preserves position, doesn't stack). `show(storeProvider:)` is the only
/// entry point; the provider resolves the *current* active window's store
/// each time "Open in New Tab" runs — a captured store would dangle once
/// its window closed.
@MainActor
final class KookySettingsWindowController: NSWindowController {
    static let shared = KookySettingsWindowController()
    private let model = KookySettingsModel.shared
    private var storeProvider: (() -> WorkspaceStore?)?
    private var host: NSHostingController<KookySettingsView>?

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(storeProvider: @escaping () -> WorkspaceStore?) {
        let controller = shared
        controller.storeProvider = storeProvider
        controller.buildWindowIfNeeded()
        controller.model.load()
        if controller.window?.isVisible != true {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let view = KookySettingsView(model: model) { [weak self] in
            self?.openSettingsInNewTab()
        }
        let host = NSHostingController(rootView: view)
        self.host = host
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 680, height: 460))
        window.isReleasedWhenClosed = false
        // Match main-window chrome — forced dark so `Theme.chrome*` tokens
        // render readably regardless of system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        self.window = window
    }

    /// Opens `~/.kooky/settings.json` in a new kooky tab via `$EDITOR`
    /// (defaulting to `vi`). Falls back to the system default editor (via
    /// NSWorkspace) when no active workspace exists.
    private func openSettingsInNewTab() {
        // Ensure the file exists so the editor lands in a real document.
        if !FileManager.default.fileExists(atPath: KookySettings.url.path) {
            KookySettings.writeDefaultTemplate()
        }
        guard let store = storeProvider?(), let workspace = store.active else {
            NSWorkspace.shared.open(KookySettings.url)
            return
        }
        // KOOKY_AGENT is auto-evaluated by the wrapper rcfile; shell expands
        // `${EDITOR:-vi}` at runtime, so the user's chosen editor wins.
        let template = AgentTemplate(
            id: "kooky-settings-editor",
            title: "settings.json",
            symbol: "doc.text",
            iconAsset: nil,
            tintHex: nil,
            initialCommand: "${EDITOR:-vi} \(KookyShellIntegration.quote(KookySettings.url.path))"
        )
        let session = store.addTab(in: workspace, template: template)
        session.customTitle = "settings.json"
        window?.orderOut(nil)
    }
}
