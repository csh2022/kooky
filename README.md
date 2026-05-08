# kooky

> **A terminal built for the coding experience.**
> 专为 coding 体验优化的 terminal。

An open-source macOS terminal with first-class vertical tabs and one-click AI agent sessions.

Built on **[libghostty](https://github.com/ghostty-org/ghostty)** for GPU-accelerated rendering. Native macOS UI via SwiftUI + AppKit.

## Status

v0.5 — Splits, . Each workspace is a recursive pane tree; ⌘D / ⌘⇧D slice the whole pane region (tab strip + content together) so two halves each get their own independent tab bar. ⌘W closes the focused tab and collapses an empty pane up into its sibling; ⌘[ / ⌘] cycle pane focus; clicking into any pane's terminal updates focus + cwd tracking via libghostty's first-responder hook. Right-click context menus (tab + sidebar workspace rows) styled to match the chrome instead of system NSMenu — ⌘W / ⌘D / ⌘⇧D / ⌘⇧W shortcut hints render in SF Pro next to each item. Persistence schema upgrades with backward compat for v0.4 flat tabs. Earlier: Codex hook coverage via `notify` + wrapper bracketing, Claude Code full hooks, IME (中日韩 / 越南文 / etc.) via `NSTextInputClient`, keyboard shortcuts, workspace + tab persistence, hidden title bar, agent launcher (Claude Code / Codex / Gemini CLI / OpenCode / Amp) with inline auto-launch, OSC 7 cwd tracking, Onest + JetBrains Mono chrome, brand icons from [lobe-icons](https://github.com/lobehub/lobe-icons). 26-test XCTest suite. Up next: Gemini / OpenCode / Amp wrappers, then `.app` bundle + Settings UI.

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
swift test          # 26 unit tests covering AgentTemplate + WorkspaceStore (incl. persistence + splits)
```

`Vendor/` is gitignored; the setup script is idempotent and skips the download when the pinned SHA already matches.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party assets retain their upstream licenses; see [NOTICE.md](NOTICE.md).
