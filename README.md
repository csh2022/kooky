# kooky

> **A terminal built for the coding experience.**
> 专为 coding 体验优化的 terminal。

An open-source macOS terminal with first-class vertical tabs and one-click AI agent sessions.

Built on **[libghostty](https://github.com/ghostty-org/ghostty)** for GPU-accelerated rendering. Native macOS UI via SwiftUI + AppKit.

## Status

v0.7 — Three-state collapsible sidebar (full / 52pt icon-only / hidden, ⌘⌃S cycles), 32pt top chrome strip with traffic-light clearance + sidebar toggle + explicit `WindowDragHandle` (`window.isMovable = false` globally so tab DnD always beats AppKit's implicit title-bar drag). View menu becomes the navigation hub: Tab `⌘1`-`⌘9`, Workspace `⌥⌘1`-`⌥⌘9`, Split, Focus Pane, Toggle Sidebar, Enter Full Screen. New Help menu (Report Issue / View on GitHub) and DEBUG-only Debug menu. Custom About panel sourced from `KookyApp` constants with a clickable repo link. Earlier (v0.6): drag-reorder workspaces and tabs, cross-pane tab move that preserves session state (same engine / scrollback / agent), `+` doubles as drop-at-end target, double-click tab bar = Zoom, right-click menu shortcut hints, declarative menu DSL. v0.5:  splits — recursive `PaneNode` tree, per-pane tab bars, ⌘D / ⌘⇧D split, drag-resize divider, click-to-focus via libghostty's first-responder hook. Earlier still: Codex hooks via `notify` + wrapper bracketing, Claude Code full hooks, IME (中日韩 / 越南文 / etc.) via `NSTextInputClient`, keyboard shortcuts, workspace + tab persistence, hidden title bar, agent launcher (Claude Code / Codex / Gemini CLI / OpenCode / Amp) with inline auto-launch, OSC 7 cwd tracking, Onest + JetBrains Mono chrome, brand icons from [lobe-icons](https://github.com/lobehub/lobe-icons). 28-test XCTest suite. Up next: Gemini / OpenCode / Amp wrappers, then `.app` bundle + Settings UI.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the roadmap and design notes.

## Goals

- **Better vertical tabs.** Stable, fast, keyboard-driven, with persistent state.
- **One-click agent sessions.** Spin up Claude Code, Codex, Gemini CLI, or any other agent without typing the command.
- **macOS-native.** Feels like a Mac app, not a web view.
- **Zero cloud.** Fully local, no telemetry, no accounts.

## Building

Requires Xcode 26+ and macOS 15+.

```sh
# One-time: download the prebuilt GhosttyKit xcframework into Vendor/.
./scripts/setup-libghostty.sh

swift build
swift run
swift test          # 28 unit tests covering AgentTemplate + WorkspaceStore (incl. persistence + splits + cross-pane move)
```

`Vendor/` is gitignored; the setup script is idempotent and skips the download when the pinned SHA already matches.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party assets retain their upstream licenses; see [NOTICE.md](NOTICE.md).
