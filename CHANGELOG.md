# Changelog

Notable changes per release. Tagged commits use `vX.Y.Z` shortform.

## v0.11.4 — 2026-05-18

- Fixed: Chinese / Japanese / Korean IME candidate window now appears right under the cursor where you'd expect, instead of flying out of kooky's window to the bottom-left of the screen. Pinyin, kana, hangul, anything — composes inline like every other macOS app.
- Under the hood: kooky now wires libghostty's `ghostty_surface_preedit` for the in-progress composition string, so libghostty renders the preedit glyphs on-surface and clears them cleanly on commit / cancel. `firstRect(forCharacterRange:)` calls `ghostty_surface_ime_point` instead of the v0.4 sentinel that pushed the rect off-window. Verified no ghost residue in Codex / Claude Code TUIs.

## v0.11.3 — 2026-05-16

- Drag a file or folder from Finder onto any kooky terminal pane → its absolute path drops in at the cursor as backslash-escaped text (`/Users/corey/My\ Folder/file.txt`), same shape Finder→Terminal.app / ghostty.app use. Multiple files at once → space-separated. Works in any shell, agent, or TUI — kooky just types the path; what you do with it is up to whatever's on the other side.
- Edge case handled: filenames containing a literal newline fall back to POSIX single-quote wrap (`'/tmp/foo<newline>bar.txt'`) so the shell doesn't eat the newline as line-continuation. Visible quotes are uglier than `\ ` but better than silently corrupting a legal macOS path.

## v0.11.2 — 2026-05-16

- Click anywhere on your zsh prompt to jump the shell cursor there — same UX as ghostty.app. Drag is still selection; click without drag moves the cursor. Works in zsh; bash and TUIs (Claude Code / vim) follow each app's own cursor model.
- Under the hood: kooky's shell-integration wrapper now emits the OSC 133 prompt marker in the exact format libghostty expects (`A;cl=line` with BEL terminator). Previous releases emitted a slightly different form that libghostty silently ignored, leaving cursor-click-to-move and jump-to-prompt dormant on kooky's wrapped zsh.
- Cursor-click-to-move is also force-enabled on the kooky side so users don't need to touch their ghostty config to get it.

## v0.11.1 — 2026-05-15

- Right-click menu now matches the rest of kooky's brutalist style — same `KookyMenuList` / `KookyMenuRow` as the tab pill and sidebar menus, anchored at the click position. Each "Ask <agent>" row shows the agent's brand icon; the default agent gets a leading `▸`.
- Fixed: right-clicking selections that start with `-` (e.g. `ls -la` output) would crash some agents' argparsers as "unexpected argument". Kooky now passes a POSIX `--` separator before positional prompts so anything that looks like a flag is treated as plain text.
- Fixed: Paste in the right-click menu now uses the same bracketed-paste path as ⌘V, so multi-line pastes into zsh / vim behave the same regardless of how you triggered them.
- Fixed: right-clicking inside an inactive split now activates that pane first, so "Ask <agent>" spawns the new tab in the split you actually clicked, and the keyboard cursor follows.

## v0.11.0 — 2026-05-15

- Right-click selection → "Ask <agent>". Select an error / log line / file path in any terminal, right-click → native menu lists every agent in your `+` menu (Claude / Codex / Gemini / Cursor / Copilot / OpenCode / Amp). Pick one → a new tab spawns with the selection already submitted as the first prompt, agent starts answering immediately. Zero ⌘C / ⌘V.
- Default agent (Settings → Agents → default) shows first with a `▸` glyph so the one-click path is obvious.
- Right-click on whitespace / no selection does nothing — the menu only opens when there's text to ask about. The menu sits above the existing Copy / Paste / Select All / Clear actions, separated by a divider.

## v0.10.8 — 2026-05-15

- Claude conversations now resume across kooky restarts. Quit kooky mid-conversation → next launch, the same tabs spawn with `claude --resume <id>` and pick up where they left off. Reopen Closed Tab (`⌘⇧T`) also restores the conversation.
- Settings → Agents → `resume-conversation-when-reopen` toggle (on by default) lets you turn it off; the persisted ids stay on disk so flipping it back on later still works.
- Multi-tab safe: each Claude tab has its own conversation id, so running three Claude tabs in parallel and restarting kooky resumes each thread independently.
- Other agents (Codex / Cursor / Gemini / OpenCode / Copilot / Amp) don't resume yet — only Claude exposes a hook payload kooky can capture the id from. Tracked for v2.

## v0.10.7 — 2026-05-15

- GitHub Copilot tabs now show the mid-run "attention" dot, joining Claude as the second agent with full lifecycle tracking. Sidebar dot turns yellow the moment Copilot finishes a turn and waits for your next prompt.

## v0.10.6 — 2026-05-15

- Custom agents can inherit from a builtin. Pick **Claude Code** as the base and your custom (e.g. "Claude Opus") gets Claude's icon, brand tint, launch binary, and lifecycle tracking automatically — you only set options like `--model opus`. Pick **(none)** to keep the fully custom behaviour.
- Fixed: custom-based-on-Claude tabs now properly revert to Terminal when the agent exits.

## v0.10.5 — 2026-05-15

- Define your own agent. Settings → Agents → `+ add custom agent` wires any CLI (`aichat`, `mistral-cli`, your own scripts) as a first-class kooky agent — shows up in the `+` menu alongside the builtins, drag-reorder, hide, set options, pick as default.

## v0.10.4 — 2026-05-15

- GitHub Copilot CLI joins the agent menu. Install with `brew install copilot-cli` or `npm install -g @github/copilot`.

## v0.10.3 — 2026-05-15

- Default agent for `+` and `⌘T`. Pick any visible agent (or Terminal) in Settings → Agents → default to skip the popover. Leave it on "Ask each time" to keep the picker.

## v0.10.2 — 2026-05-14

- Per-agent launch options. Each agent row in Settings has a chevron — expand to add options that get appended on launch (`claude --model opus`, `gemini --temp 0.7`, etc.).

## v0.10.1 — 2026-05-14

- Customise the `+` menu's agent list from Settings. Hide agents you don't use; reorder the rest. Terminal stays pinned first.
- Settings UI redesigned with a brutalist-minimal aesthetic — sidebar + detail layout, mono kebab-case row labels, 1pt hairlines, no rounded chrome.

## v0.10.0 — 2026-05-14

- Cursor CLI joins the agent menu. Install with `curl https://cursor.com/install -fsS | bash`.

## v0.9.12 — 2026-05-14

- Cleaner "agent not installed" message — dropped the `⚠` emoji for a plainer line.
- Fixed: tab icon no longer stays on the agent's icon when its CLI is missing — reverts to Terminal so you know what's actually running.

## v0.9.11 — 2026-05-14

- Mac-style text editing shortcuts now work in the shell:
  - `Cmd+←` / `Cmd+→` — beginning / end of line
  - `Option+←` / `Option+→` (or `Ctrl+←` / `Ctrl+→`) — jump by word
  - `Cmd+Backspace` — delete to start of line
  - `Option+Backspace` — delete previous word

## v0.9.10 — 2026-05-14

- Friendlier "agent not installed" message — yellow `⚠ X is not installed.` instead of the cryptic prior text.
- Fixed: `curl | bash` installers now write to your real `~/.zshrc` instead of vanishing into kooky's temp shell config.

## v0.9.9 — 2026-05-13

- Non-focused panes now fully dim, including the terminal content (the prior release dimmed only the chrome).

## v0.9.8 — 2026-05-13

- Spot the focused pane at a glance — non-focused panes dim their chrome to 50% opacity. Terminal content stays crisp.

## v0.9.7 — 2026-05-12

- New Settings window (`⌘,`) backed by `~/.kooky/settings.json`. v1 surfaces Font Family / Font Size / Cursor Style; advanced users edit the raw JSON via "Open in New Tab".
- First-launch onboarding offers to import `~/.config/ghostty/config` if you have it.
- Existing ghostty config still works — settings.json layers on top.

## v0.9.6 — 2026-05-12

- Status bar performs better — sidebar-collapse animation no longer stutters when the status bar is visible.
- Per-row Unset button in the proxy popover.
- New app icon.

## v0.9.5 — 2026-05-11

- `Shift+Enter` inserts a newline. Plain Enter still submits — works with Claude Code, Codex, and zsh's multi-line prompt.
- About panel polish: new tagline, refreshed credits, single GitHub link.

## v0.9.4 — 2026-05-11

- Status bar git state auto-refreshes during agent sessions — switching branches via the agent's shell tool (or any external terminal) now updates the bar within ~200ms.
- Network proxy slot in the status bar shows `host:port` when `https_proxy` / `http_proxy` / `all_proxy` are set; click to see all proxy vars in full.
- Tab icon promotes when you manually launch an agent. Type `claude` in a Terminal tab → tab + sidebar dot switch immediately.

## v0.9.3 — 2026-05-11

- Tab icon promotes when you manually launch an agent inside a Terminal tab.

## v0.9.2 — 2026-05-11

- `exit` / `logout` closes the tab automatically. Non-zero exits show "press any key to close" so you can read crash output before dismissing.
- Reveal in Finder — right-click any tab pill or workspace row.
- Reopen Closed Tab (`⌘⇧T`) — browser-style. LIFO history capped at 50.
- `⌃⇥` / `⌃⇧⇥` for per-pane tab cycling.

## v0.9.1 — 2026-05-11

- Reveal in Finder for tabs and workspaces via right-click.
- Reopen Closed Tab (`⌘⇧T`) restores agent + cwd + custom title.
- `⌃⇥` / `⌃⇧⇥` per-pane tab cycling.

## v0.9.0 — 2026-05-10

- Pane status bar showing live working-tree state — Python venv, Node version, git branch, git diff. Right-aligned, slots hide when empty.
- Click the Node version pill → switch between installed nvm versions. Click the git branch pill → switch branches.
- Status bar tracks live `nvm use` / `source activate` shell state via prompt hook.

## v0.8.0 — 2026-05-10

- Find in scrollback (`⌘F`) per-pane. `⌘G` / `⌘⇧G` for next / previous match.
- Gemini CLI activity dot.
- OpenCode activity dot via Bun plugin.
- Amp activity dot (bracket wrapper only — full mid-run state deferred).

## v0.7.6 — 2026-05-09

- App icon — `[ - · ]` mark on a charcoal squircle, sized into the full Apple iconset.
- macOS 14 minimum (was 15) — widens the audience to all Sonoma users.

## v0.7.5 — 2026-05-09

- `.app` bundle. `scripts/build-app.sh` produces `dist/Kooky.app` you can drag into `/Applications` and launch from Spotlight. Clipboard managers (Paste, Maccy) now see kooky's writes.

## v0.7.4 — 2026-05-09

- Workspace-level command-failure dot — red dot on the sidebar row when any tab in any pane has a non-zero last exit.

## v0.7.3 — 2026-05-09

- Per-tab last-command status (OSC 133) — small red dot when the most recent command exited non-zero. Hover for `exit N · 12.4s`.
- `⌘↑` / `⌘↓` to jump between prompts in the active pane's scrollback.

## v0.7.2 — 2026-05-09

- Manual rename for tabs and workspaces. Right-click → *Rename…*. Empty submission clears the override so the title resumes tracking the cwd. Persists.

## v0.7.1 — 2026-05-09

- URL `⌘+click` opens in your default browser.
- Mouse shape follows libghostty (pointing-hand on URLs, resize on TUI splits, etc.).
- Font size shortcuts: `⌘=` increase, `⌘-` decrease, `⌘0` reset.
- Clear Pane (`⌘K`).
- Sidebar mode (`full` / `compact` / `hidden`) persists across launches.

## v0.7.0 — 2026-05-09

- Window-drag rewrite — a dedicated drag handle replaces the implicit title-bar drag region, so tab DnD no longer races with window-move.
- Three-state sidebar (`full` / `compact 52pt` / `hidden`), `⌘⌃S` cycles.
- Top chrome strip with explicit drag handle, sidebar toggle, traffic-light clearance.
- View menu becomes the navigation hub — Tab `⌘1`-`⌘9`, Workspace `⌥⌘1`-`⌥⌘9`, splits, sidebar toggle all there. New Help menu.
- Custom About panel.

## v0.6.0 — 2026-05-09

- Drag-reorder workspaces and tabs. Direction-aware drop indicator. Animated.
- Cross-pane tab move via drag.
- View menu with `Tab 1`-`9` and `Workspace 1`-`9` switches.
- Double-click tab bar zooms the window.
- Right-click menus show keyboard shortcut hints.

## v0.5.0 — 2026-05-08

- Recursive splits — each workspace owns a pane tree, each pane has its own tab strip. `⌘D` splits right, `⌘⇧D` splits down, `⌘[` / `⌘]` cycles focus, `⌘W` closes a tab and collapses an empty pane.
- Right-click context menus on tabs and sidebar rows, styled to match the chrome.
- Click-to-focus across panes.

## v0.4.0 — 2026-05-08

- Codex integration — sidebar shows the Codex icon while it's running.
- Auto-promote agent on hook — plain Terminal tabs that report a Claude / Codex hook upgrade to the matching template.
- IME — Chinese / Japanese / Korean / Vietnamese compose properly.

## v0.3.0 — 2026-05-08

- Agent activity dot in the sidebar — blue when an agent is processing, amber when it's waiting on user input, hidden when idle.
- Real Claude Code integration via the kooky hook helper + Claude's hook system.

## v0.2.0 — 2026-05-08

- Keyboard shortcuts: `⌘T` new tab, `⌘N` new workspace, `⌘W` close tab, `⌘⇧W` close workspace, `⌘1`-`⌘9` switch tab.
- Persistence — workspaces, tabs, agent type, and cwd survive relaunch.
- Hidden title bar; tab bar sits at the window top edge.

## v0.1.0 — 2026-05-08

First public release. Native macOS terminal with vertical-tab workspaces and one-click AI agent sessions (Claude Code / Codex / Gemini CLI / OpenCode / Amp).
