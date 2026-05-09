# kooky

> **A terminal built for the coding experience.**
> 专为 coding 体验优化的 terminal。

An open-source macOS terminal with first-class vertical tabs and one-click AI agent sessions.

Built on **[libghostty](https://github.com/ghostty-org/ghostty)** for GPU-accelerated rendering. Native macOS UI via SwiftUI + AppKit.

## Status

**v0.7.6** — App icon + macOS 14 minimum. The cyber-minimalist `[ - · ]` mark on a charcoal squircle now lives in the Dock / Finder / About panel, generated at build time from `branding/AppIcon.png` into a full Apple `.iconset`. macOS minimum dropped to 14 (Sonoma) — `@Observable` is the floor. Building on **v0.7.5**'s first `.app` bundle: `scripts/build-app.sh` produces `dist/Kooky.app` (drag-to-`/Applications` ready) with adhoc codesign; `scripts/build-dmg.sh` packages a drag-to-Applications `Kooky-vX.Y.Z.dmg` for GitHub Releases. Bundle ID `com.iamcorey.kooky`. Custom bundle resolver replaces SPM's auto-generated `Bundle.module` so resources still load when shipped inside `.app/Contents/Resources/` (the SPM accessor only checks `Bundle.main.bundleURL` and `fatalError`s otherwise). v0.7.4: per-workspace command-failure dot — any tab's non-zero exit lights up the sidebar row red, with attention > failure > running > idle precedence. v0.7.3: OSC 133 / FinalTerm command status — small red dot per tab pill on non-zero exit, hover for `exit N · 12.4s`, `⌘↑` / `⌘↓` jump prev/next prompt. ZDOTDIR wrapper installs the OSC 133 hooks without touching `~/.zshrc`. v0.7.2: right-click → *Rename…* on tabs and workspaces (empty input clears back to cwd). v0.7.1: URL ⌘+click in any terminal opens default browser; mouse shape follows libghostty (URL → pointing-hand, vim split → resize); `⌘=` / `⌘-` / `⌘0` font size; `⌘K` Clear Pane; sidebar mode (full / compact / hidden) persists across launches. v0.7: three-state sidebar (`⌘⌃S` cycles), 32pt top chrome strip with explicit `WindowDragHandle`, View menu as navigation hub, Help + Debug menus, custom About panel from `KookyApp` constants. v0.6: drag-reorder workspaces and tabs, cross-pane tab move preserves session state, `+` doubles as drop-at-end, double-click tab bar = Zoom, right-click menu shortcut hints, declarative menu DSL. v0.5:  splits — recursive `PaneNode` tree, per-pane tab bars, `⌘D` / `⌘⇧D` split, drag-resize divider, click-to-focus. Earlier still: Codex hooks via `notify`, Claude Code full hooks, IME (中日韩 / 越南文 / etc.) via `NSTextInputClient`, keyboard shortcuts, workspace + tab persistence, agent launcher (Claude Code / Codex / Gemini CLI / OpenCode / Amp) with inline auto-launch, OSC 7 cwd tracking, Onest + JetBrains Mono chrome, brand icons from [lobe-icons](https://github.com/lobehub/lobe-icons). 31-test XCTest suite. Up next: Gemini / OpenCode / Amp activity-dot wrappers, Settings UI, then Apple Developer ID + notarization for unfettered distribution.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the roadmap and design notes.

## Goals

- **Better vertical tabs.** Stable, fast, keyboard-driven, with persistent state.
- **One-click agent sessions.** Spin up Claude Code, Codex, Gemini CLI, or any other agent without typing the command.
- **macOS-native.** Feels like a Mac app, not a web view.
- **Zero cloud.** Fully local, no telemetry, no accounts.

## Install

Download the latest `Kooky-vX.Y.Z.dmg` from [Releases](https://github.com/iAmCorey/kooky/releases), open it, drag `Kooky.app` to `Applications`.

**First launch will be blocked by Gatekeeper** because the build is adhoc-signed (no paid Apple Developer ID yet — public-distribution signing + notarization land when the project has real users). You'll see *"Kooky cannot be opened because Apple cannot check it for malicious software"* or *"Kooky is damaged and cannot be opened"*. One of these two paths gets you through:

**Path A (GUI) — System Settings**

1. Double-click `Kooky.app` once. macOS blocks it and shows the warning dialog. Dismiss the dialog.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the **Security** section. You'll see "Kooky was blocked to protect your Mac" with an **Open Anyway** button. Click it. Enter your password.
4. Double-click `Kooky.app` again. The dialog now offers **Open** — click it. Done.

**Path B (Terminal) — strip quarantine**

```sh
xattr -d com.apple.quarantine /Applications/Kooky.app
```

**Path C — when "Open Anyway" doesn't appear at all**

Newer macOS sometimes hides the **Open Anyway** button entirely for adhoc-signed apps. If that happens, run once to re-enable the legacy "Anywhere" option, then redo Path A:

```sh
sudo spctl --global-disable      # macOS 15+ (Sequoia); older systems use --master-disable
# Open System Settings → Privacy & Security → set "Allow applications from" to Anywhere
# Open Kooky.app → it now launches
sudo spctl --global-enable       # turn Gatekeeper back on once kooky is whitelisted
```

This is **system-wide** — while disabled, macOS will run any unsigned app. Re-enable as soon as kooky launches once (the per-app whitelist persists after re-enabling).

Either way, macOS only blocks the first launch. After that you launch normally from Spotlight / Dock / Finder.

## Building from source

Requires Xcode 26+ and macOS 14+ (Sonoma — `@Observable` is the floor).

```sh
# One-time: download the prebuilt GhosttyKit xcframework into Vendor/.
./scripts/setup-libghostty.sh

swift build
swift run
swift test          # 31 unit tests covering AgentTemplate + WorkspaceStore (incl. persistence + splits + cross-pane move + OSC 133 command status)

# Produce a real macOS .app bundle (writes dist/Kooky.app):
./scripts/build-app.sh

# Package as DMG for distribution (writes dist/Kooky-vX.Y.Z.dmg):
./scripts/build-dmg.sh --build
```

`Vendor/` and `dist/` are gitignored. The libghostty setup script is idempotent and skips the download when the pinned SHA already matches.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party assets retain their upstream licenses; see [NOTICE.md](NOTICE.md).
