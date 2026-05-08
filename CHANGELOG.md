# Changelog

Notable changes per release. Tagged commits use `vX.Y` shortform.

## v0.3 — 2026-05-08

- **Agent activity state in the sidebar.** Each workspace row shows a small status dot in the close-button slot — blue while an agent is processing, amber when it's waiting on user input, hidden when idle. Aggregated across the workspace's tabs (`attention` > `running` > `idle`).
- **Real Claude Code integration.** App ships a `KookyHook` CLI helper next to the main binary plus a generated wrapper at `~/Library/Application Support/kooky/bin/claude`. Inside a kooky session (`$KOOKY_SURFACE_ID` set) the wrapper invokes the real `claude` with `--settings <hooks.json>`; Claude Code's `UserPromptSubmit` / `Stop` / `Notification` / `SessionEnd` hooks `exec` the `KookyHook` helper, which opens the unix socket the app listens on (`~/Library/Application Support/kooky/socket`), writes one JSON line, and exits. App routes the event to the matching session's `activityState`.
- **Env injection for new sessions.** `KOOKY_SURFACE_ID`, `KOOKY_HOOKS_PATH`, `KOOKY_BIN_DIR` injected at spawn; wrapper rc files (`.zshrc` / `.bashrc`) re-prepend `KOOKY_BIN_DIR` to `PATH` after sourcing the user's rc so the `claude` wrapper resolves first regardless of what the user's shell config does to `PATH`.
- **Codex / Gemini / OpenCode / Amp** still use the inline-launch path from v0.1 but don't yet drive `activityState` — their wrappers + per-agent hook protocols are the next slice.

## v0.2 — 2026-05-08

- **Keyboard shortcuts.** `⌘T` new tab, `⌘N` new workspace, `⌘W` close tab, `⌘⇧W` close workspace, `⌘1`-`⌘9` switch tab in active workspace, plus standard `⌘C` / `⌘V` / `⌘X` / `⌘A` routed through first-responder selectors so libghostty handles them inside the surface. Wired via `NSMenu` so keyEquivalents fire even with libghostty's `keyDown` intercept.
- **Persistence.** Workspaces, tabs, agent type, per-tab and per-workspace cwd survive relaunch. JSON snapshot under `~/Library/Application Support/kooky/state.json`, debounced 1s on mutation and flushed on `applicationWillTerminate`. PTY state itself doesn't persist — restored tabs spawn fresh sessions in the saved cwd; cwd that no longer exists falls back to `$HOME`. `WorkspaceStore.engineFactory` + the new `Persistence` protocol both inject through the initializer for tests.
- **Hidden title bar.** Full-content window with the traffic lights overlaid on the sidebar; the tab bar sits directly at the window top edge. Sidebar header reserves 32pt for the traffic lights.
- **Sidebar leading icon.** First non-terminal agent's brand icon + `+N` capsule when more agents are running, falling back to the terminal SF symbol for plain shells. Sidebar row title weight is regular for both active and inactive — selection is distinguished by background fill alone, no weight shift.
- **SwiftTerm dropped.** libghostty has carried every active session since M2; the fallback's `onPwdChange` was a stub anyway. `TerminalEngine` protocol stays so future engine swaps don't touch the UI layer; `TestEngine` continues to validate the seam.
- **Tests.** Three new persistence cases (restore from disk, restore spawns engines with saved cwd, flushPersistence writes snapshot). 20 total.

## v0.1 — 2026-05-08

First public release. Native macOS terminal with vertical-tab workspaces and one-click AI agent sessions.

- **Terminal engine.** libghostty, Metal-accelerated, full ANSI/UTF-8/scrollback. `TerminalEngine` protocol abstracts the engine for tests and future swaps.
- **Session model.** Workspaces → Tabs. Sidebar lists workspaces; top tab bar lists each workspace's sessions. Closing the last tab closes the workspace; closing the last workspace closes the window.
- **Agent launcher.** Claude Code, Codex, Gemini CLI, OpenCode, Amp. The shell starts under a generated wrapper rc (zsh `ZDOTDIR` or bash `--rcfile` via a launcher script that re-execs as non-login) which `exec`s the agent inline before any prompt prints. No shell prompt or command echo before the agent UI.
- **Working-directory tracking.** OSC 7 `chpwd`/`PROMPT_COMMAND` hooks installed by the same wrappers; `GHOSTTY_ACTION_PWD` syncs `Session.currentDirectory`. The active tab's `cd` updates the workspace, new tabs and new workspaces inherit.
- **Chrome.** Onest (display) + JetBrains Mono (mono) registered at launch via `CTFontManager`. Brand PNG icons from lobe-icons. Sidebar leading icon shows the first non-terminal agent + a `+N` capsule for multi-agent workspaces; falls back to the terminal SF symbol for plain shells. Tab pill, sidebar row, and popover share one `hoverableRowBackground` modifier.
- **Tests.** 17 XCTest cases covering `AgentTemplate` (terminal vs agent shell selection, `KOOKY_AGENT` env wiring) and `WorkspaceStore` (initial state, add/close cascading, OSC 7 cwd inheritance). `WorkspaceStore.engineFactory` lets tests inject a no-op `TestEngine`.
