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
    var fontFamily: String = ""
    /// `nil` = not overridden — let libghostty fall back to ghostty's own
    /// config (or its default). Writing a default 13 unconditionally would
    /// silently shadow the user's `~/.config/ghostty/config` font-size.
    var fontSize: Int? = nil
    var cursorStyle: String = "block"

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
        KookySettings.write(parsed)
    }
}

/// Settings panel — mirrors the main-window chrome (dark bg, Onest labels,
/// 1pt hairlines, no rounded grouped form). v1 surface area: 4 ghostty-routed
/// keys plus an "open raw JSON" escape hatch.
struct KookySettingsView: View {
    @Bindable var model: KookySettingsModel
    let onOpenInTab: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    SettingsSection(title: "Terminal") {
                        SettingsRow(label: "Font Family") {
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
                        SettingsRow(label: "Font Size") {
                            HStack(spacing: 6) {
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
                        SettingsRow(label: "Cursor Style") {
                            Picker("", selection: $model.cursorStyle) {
                                Text("Block").tag("block")
                                Text("Underline").tag("underline")
                                Text("Bar").tag("bar")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(minWidth: 180)
                        }
                    }
                    SettingsSection(title: "Advanced") {
                        SettingsRow(label: "settings.json") {
                            Button(action: onOpenInTab) {
                                Text("Open in New Tab")
                                    .font(Theme.display(12, weight: .regular))
                                    .foregroundStyle(Theme.chromeForeground)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Theme.chromeFaint.opacity(0.5))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    } caption: {
                        Text("For options not surfaced here, edit `~/.kooky/settings.json` directly.")
                    }
                }
                .padding(.vertical, 16)
            }
            footerHint
        }
        .background(Theme.chromeBackground)
        .preferredColorScheme(.dark)
        .onChange(of: model.fontFamily) { _, _ in model.scheduleSave() }
        .onChange(of: model.fontSize) { _, _ in model.scheduleSave() }
        .onChange(of: model.cursorStyle) { _, _ in model.scheduleSave() }
    }

    private var footerHint: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            HStack(spacing: 12) {
                Text("Changes apply when you restart kooky.")
                    .font(Theme.display(11.5, weight: .regular))
                    .foregroundStyle(Theme.chromeMuted)
                Spacer()
                Button {
                    restartApp()
                } label: {
                    Text("Restart")
                        .font(Theme.display(12, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.chromeFaint.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Theme.chromeHairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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

/// Section header + content block. Header uses Onest small-caps tracking
/// to match the rest of the sidebar / status chrome aesthetic.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    let caption: AnyView?

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
        self.caption = nil
    }

    init<Caption: View>(
        title: String,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder caption: () -> Caption
    ) {
        self.title = title
        self.content = content
        self.caption = AnyView(caption())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.display(10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Theme.chromeMuted)
                .padding(.horizontal, 20)
                .padding(.top, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.chromeFaint.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.chromeHairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            if let caption {
                caption
                    .font(Theme.display(11.5, weight: .regular))
                    .foregroundStyle(Theme.chromeMuted)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
        }
        .padding(.bottom, 18)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.display(12.5, weight: .regular))
                .foregroundStyle(Theme.chromeForeground)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(Theme.chromeHairline).frame(height: 1)
    }
}

/// Singleton NSWindowController so reopening Settings reuses the same window
/// (preserves position, doesn't stack). `show(store:)` is the only entry
/// point; the store reference powers the "Open in New Tab" action that
/// spawns an editor session for `settings.json` inside kooky itself.
@MainActor
final class KookySettingsWindowController: NSWindowController {
    static let shared = KookySettingsWindowController()
    private let model = KookySettingsModel()
    private weak var store: WorkspaceStore?
    private var host: NSHostingController<KookySettingsView>?

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(store: WorkspaceStore) {
        let controller = shared
        controller.store = store
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
        window.setContentSize(NSSize(width: 480, height: 420))
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
        guard let store, let workspace = store.active else {
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
