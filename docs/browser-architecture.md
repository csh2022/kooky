# Built-in Browser Architecture

## Goal

Kooky needs a browser surface that agents can use without taking over the
user's primary Chrome window or desktop focus. The first implementation uses
Apple's `WKWebView` because it is the smallest native macOS integration, but
the product must keep a clean path to a Chromium-backed engine later.

## First Release Scope

- Add a browser leaf inside the existing workspace split tree. It should look
  and behave like a normal split region next to terminal panes, not like a
  detached utility sidebar.
- Support direct URL entry, search query entry, back, forward, reload, stop,
  and target-blank popup reuse in the same panel.
- Keep browser state runtime-local for the first release. Browser leaves are
  not persisted; saving collapses them out of the persisted pane tree.
- Add store-level APIs that an agent-facing CLI/MCP layer can call later:
  open/reuse an agent-owned browser split, navigate it, and close it only when
  it is still auto-owned.
- Make WebKit an implementation detail of `WebKitBrowserEngine`.

## Non-goals

- Do not embed the user's existing Google Chrome window.
- Do not promise Google account sign-in inside the embedded browser. Google can
  block OAuth flows in embedded user agents.
- Do not add full browser automation commands in this pass. Click/type/DOM/CDP
  tools should layer on top of the store/browser-engine boundary.

## Module Boundary

Browser code lives under `Sources/KookyKit/Browser/`.

- `BrowserEngine`: protocol owned by Kooky, not WebKit. UI uses this protocol
  for actions and state.
- `BrowserEngineSnapshot`: renderer-agnostic state for title, URL, loading,
  history availability, and transient error display.
- `BrowserLoadRequest`: normalizes address-bar text into a URL. This is pure
  logic and is tested without WebKit.
- `BrowserSurface`: observable state wrapper used by SwiftUI. It owns a
  `BrowserEngine` existential and mirrors snapshots into UI state.
- `BrowserHostView`: thin `NSViewRepresentable` that mounts `engine.view`.
- `WebKitBrowserEngine`: the only file that imports WebKit.
- `BrowserPane`: runtime model for one browser split leaf.
- `BrowserPaneView`: SwiftUI chrome for the browser split leaf.

Dependency direction:

`PaneTreeView -> BrowserPaneView -> BrowserSurface -> BrowserEngine`

Only `WebKitBrowserEngine` may depend on `WKWebView`. If a later CEF/Chrome
engine is added, it should implement `BrowserEngine` and expose its native
`NSView` through `view`.

## Future Chromium Replacement

A future Chromium implementation should add something like:

- `ChromiumBrowserEngine`
- optional Chromium process/profile manager
- optional DevTools/CDP bridge

It should not require changing `BrowserPaneView`, `BrowserSurface`, or
`ContentView` beyond construction/injection of the chosen engine.

If browser tabs become first-class pane tabs later, introduce a mixed tab model
around `BrowserSurface` and terminal `Session`; do not make terminal `Session`
own browser-specific state.

## Agent-Owned Browser Lifecycle

`WorkspaceStore` owns the orchestration:

- `openBrowserSplit(url:owner:)` finds an existing compatible browser leaf or
  splits the active terminal pane to the right.
- User-opened browser panes use `owner = .user`.
- Agent-opened browser panes use `owner = .agent(sessionId)`.
- `closeBrowserIfAutoOwned` closes only agent-owned browser panes that have not
  been pinned or marked user-touched.
- Manual address-bar submission marks the browser user-touched, which prevents
  automatic close.

The future CLI/MCP layer should call these store APIs rather than manipulating
SwiftUI views.

## Agent Discovery

Agents launched from Kooky learn about the built-in browser through
Kooky-owned process context, not by editing the user's global agent
configuration.

- Every Kooky session gets `KOOKY_BROWSER=1` and `KOOKY_HOOK_BIN`.
  `KOOKY_HOOK_BIN` points at the main `Kooky` executable. The same binary
  launches the GUI when run normally and acts as the short-lived hook CLI when
  invoked as `Kooky browser ...`, `Kooky env ...`, or `Kooky <agent> <event>`.
- The `codex` wrapper passes a per-invocation
  `-c developer_instructions=...` override only for interactive Codex
  processes running inside Kooky. Background pipe-driven Codex calls still pass
  through untouched.
- The injected instruction tells agents to run
  `"$KOOKY_HOOK_BIN" browser help` before browser-page tasks. Browser commands
  should be discoverable through that help text so future capabilities do not
  require hard-coding every command into agent instructions.
- Current command surface:
  - `browser open <url-or-query>`
  - `browser state`
  - `browser click <visible-text>`
  - `browser fill <field-label-or-placeholder> <text>`
  - `browser type <text>`
  - `browser press <key>`
  - `browser scroll <up|down|left|right> [amount]`
  - `browser back`, `browser forward`, `browser reload`, `browser stop`
  - `browser close`
- Browser commands can return a short response over the hook socket. Navigation
  and interaction commands return `ok` or state text so agents can confirm they
  used Kooky's browser path.
- Codex still reads the user's real `CODEX_HOME`, `config.toml`, and
  `AGENTS.md`. Kooky does not rewrite or shadow global Codex configuration.

## Hook Binary Shape

There is no separate `KookyHook` executable. Keeping hook mode inside the main
`Kooky` binary avoids app/helper version skew: the installed app, the hook CLI
entry point, and the bundled browser command surface are always built from the
same source revision.

## Persistence

The first release does not persist browser leaves. This keeps compatibility
with existing `state.json` files and avoids committing to a browser session
schema before the AI-control API is designed.

## Validation

- Unit test address normalization.
- Unit test right-sidebar content persistence backward compatibility.
- Run the full Swift test suite.
- Build and launch the app for a smoke check.
