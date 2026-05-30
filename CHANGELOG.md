# Changelog

Notable changes per release. Tagged commits use `vX.Y.Z` shortform.

## v0.20.0 — 2026-05-30

- **Kimi Code** — Moonshot AI's `kimi` CLI joins the agent launcher. Pick it from the `+` menu or set it as your default agent; the sidebar activity dot tracks when it's running.

## v0.19.3 — 2026-05-30

- **Custom Ghostty themes** — themes in your Ghostty themes folder now appear in Settings and recolor the terminal and whole window when selected. (Resolves #17.)

## v0.19.2 — 2026-05-29

- Fixed the layout breaking when you drag the window between displays with different scale factors (e.g. a Retina laptop screen and a 1x external monitor) — the terminal now re-flows to the new display's resolution instead of leaving a blank gutter on the right or letting input overflow the viewport. (Resolves #8.)

## v0.19.1 — 2026-05-29

- Fixed the terminal getting stuck mid-screen after a resize, fullscreen toggle, or the status bar appearing — when an agent like Claude Code is streaming output, the view now stays pinned to the latest output and the input box instead of stranding them below the fold. Scroll up to read history and it stays where you left it. (Resolves #7.)

## v0.19.0 — 2026-05-28

- Watch Claude Code work in real time — kooky now shows a pill in the bottom status bar with the tool Claude is running (Bash / Edit / Read / etc.), how long it's been running, and whether it succeeded or failed. Click the pill to see the full session history.
- Failed tool calls turn red immediately, not after a 60-second wait.
- Settings → Status Bar gets a Claude Code section with a toggle for the activity pill.

## v0.18.3 — 2026-05-28

- Worktree close is safe by default — closing a worktree now only removes it from the sidebar; the directory and branch stay on disk. Tick "also delete worktree directory and branch" in the confirm sheet for the v0.18.x destructive behaviour.
- Adopt existing worktrees — Create Worktree → "adopt" mode lists every `git worktree list` entry not already in the sidebar. Pick the ones you want kooky to manage.
- Kooky no longer auto-imports CLI-created worktrees at launch. Only worktrees you explicitly created or adopted show up in the sidebar.

## v0.18.2 — 2026-05-27

- Paste a file or image — copy a file in Finder (Cmd+C) and Cmd+V into kooky now pastes the full file path instead of just the filename, so Claude / Codex / Cursor can read it as an argument.
- Paste a screenshot — take a screenshot to the clipboard (Cmd+Ctrl+Shift+4), Cmd+V into kooky, and the image gets saved to `~/Library/Caches/kooky/pastes/` with its path pasted into the terminal. Drop a screenshot straight into a Claude prompt with no save-to-disk detour. (Resolves #15.)

## v0.18.1 — 2026-05-27

- Worktree sidebar polish — worktree rows now show a branch badge in their subtitle, source rows reveal a hover-only chevron for collapsing the worktree group, and the disclosure no longer steals a leading column from the (already narrow) sidebar.
- Right-click a worktree → "Go to Source Workspace" jumps back to the source repo. Right-click a source → "Refresh Worktrees" picks up worktrees you created in another terminal without restarting kooky.
- Closing a worktree now also cleans up its branch — `git branch -d` runs after `git worktree remove`. Merged branches go away (next worktree of the same name builds cleanly); unmerged branches stay (git itself refuses, no data loss). Reads the worktree's real current branch from git at delete time, so `git switch`ing inside the worktree no longer leaves the wrong branch behind.
- "Create Worktree…" sheet opens noticeably faster (git enumeration runs in parallel), and the existing-branch picker hides itself when every local branch is already checked out somewhere.
- Worktrees you created from the command line now spawn with your default agent (the one you picked in Settings → Agents) instead of a plain Terminal.

## v0.18.0 — 2026-05-26

- **Git worktrees** — right-click a git workspace → "Create Worktree…" to spin one up on a new branch (or check out an existing one). Each worktree gets its own sidebar entry nested under its source repo, its own tabs, and its own agent — work on a feature branch with Claude without touching what's running on main. Closing a worktree deletes the directory; closing a source repo removes its whole worktree group in one confirm. Worktrees you create from the command line show up automatically next launch.

## v0.17.0 — 2026-05-26

- **Theme picker** — choose a theme in Settings. Theme changes apply immediately across the terminal and the whole window.

## v0.16.3 — 2026-05-25

- **Pane zoom (⌘⇧E)** — expand the active pane to fill the workspace; the other panes slide off-screen but their processes keep running. Toggle from ⌘⇧E, the zoom button in each pane's bottom status bar, the View menu, or right-click → "Zoom Pane".

## v0.16.2 — 2026-05-25

- **Settings → Status Bar** — drag to reorder the pane bottom status bar's slots (Python venv / Node version / Proxy / Git branch / Git diff), toggle individual ones off, or hide the whole row. Reset to defaults if you change your mind.

## v0.16.1 — 2026-05-25

- Fixed the Quick Open search pill overlapping the sidebar toggle when the window was dragged narrow. The pill now stays in the drag-handle area and hides automatically when there isn't room for it — ⌘P and the File menu still open the palette.

## v0.16.0 — 2026-05-25

- **Quick Open (⌘P)** — fuzzy-search across every window's workspaces and tabs, plus every visible agent and Terminal preset. Type to filter, ↑↓ to navigate, Enter to jump; clicking a workspace or tab focuses its owning window, picking an agent or preset spawns a new tab with it. Triggers from ⌘P or the search pill in the top chrome.

## v0.15.0 — 2026-05-25

- **Terminal presets** — define "Terminal at <path>" entries that show up in the `+` menu, each opening a new tab at a fixed folder regardless of the active workspace. Configure under Settings → Terminals: name + path (with `~/foo` shorthand or a folder picker), drag to reorder, toggle visibility, delete. Handy when you keep jumping to the same project folders.
- Settings sidebar reorganized — first category renamed `General` (was `Terminal`) to make room for the new `Terminals` category in between. The `default-new-tab` picker moved to `General` since it now controls both presets and agents.

## v0.14.4 — 2026-05-24

- File → Open Folder… (⌘O) opens any folder as a new workspace.

## v0.14.3 — 2026-05-23

- Drag a folder from Finder onto the sidebar to open it as a new workspace.

## v0.14.2 — 2026-05-23

- Right-click any tab → "Move to New Window" sends it to its own new window — the terminal, scrollback, and any running process all come along.

## v0.14.1 — 2026-05-22

- Drag a tab from one window's tab bar onto another window's to move it across — the terminal, its scrollback, and any running process all come with it.

## v0.14.0 — 2026-05-22

- Multiple windows — press ⌘⇧N to open a new window. Each window keeps its own workspaces, tabs, and sidebar, and every open window is restored when you relaunch kooky.

## v0.13.0 — 2026-05-22

- Custom agents based on Claude Code can now carry their own environment variables — set `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` in a custom agent's new `env` field (Settings → Agents) to point it at a Claude-compatible mirror or proxy.

## v0.12.4 — 2026-05-21

- Fixed: arrow keys in `vim` (and other full-screen programs) now work over SSH to older remote machines.

## v0.12.3 — 2026-05-21

- The tab and sidebar name now follow the terminal title — `ssh` into a remote host and the tab shows its `user@host` instead of the local folder, then reverts when you exit.

## v0.12.2 — 2026-05-20

- Antigravity CLI joins the agent menu — Google's Go-based successor to Gemini CLI.
- Fixed: picking Antigravity from the `+` menu when only the IDE is installed now surfaces a clear CLI install hint instead of accidentally opening the IDE app.

## v0.12.1 — 2026-05-19

- Check for Updates in the Kooky menu — see what's new and download the latest DMG in one click.

## v0.12.0 — 2026-05-19

- Grok Build (xAI) joins the agent menu.

## v0.11.6 — 2026-05-18

- Fixed: shell history and Tab completion now survive kooky restarts.
- Fixed: environment variables in `~/.zshenv`, `~/.zprofile`, and `~/.bash_profile` now load in kooky terminals.

## v0.11.5 — 2026-05-18

- Fixed: long Chinese / Japanese / Korean inputs no longer leave a phantom space mid-line.
- Fixed: when a long input wraps to a second line, the first line no longer disappears.

## v0.11.4 — 2026-05-18

- Fixed: Chinese / Japanese / Korean IME candidate window now shows right under the cursor instead of flying off-screen.

## v0.11.3 — 2026-05-16

- Drag a file or folder from Finder onto any kooky terminal pane → its path drops in at the cursor. Multi-file drag = space-separated paths.

## v0.11.2 — 2026-05-16

- Click anywhere on your zsh prompt to jump the cursor there.

## v0.11.1 — 2026-05-15

- Right-click menu redesigned to match kooky's brutalist style.
- Fixed: right-clicking selections that start with `-` no longer crashes the agent.
- Fixed: paste in the right-click menu now matches ⌘V behavior in zsh / vim.
- Fixed: right-clicking inside an inactive split now activates that pane first.

## v0.11.0 — 2026-05-15

- Right-click selection → "Ask <agent>". Select any text in a terminal, right-click, pick an agent → a new tab spawns with the selection as the first prompt.

## v0.10.8 — 2026-05-15

- Claude conversations resume across kooky restarts. Quit mid-conversation → next launch picks up where you left off.
- Settings → Agents → `resume-conversation-when-reopen` toggle.

## v0.10.7 — 2026-05-15

- GitHub Copilot tabs now show the mid-run "attention" dot.

## v0.10.6 — 2026-05-15

- Custom agents can inherit from a builtin — pick **Claude Code** as the base and your custom (e.g. "Claude Opus") inherits the icon, brand tint, and lifecycle tracking.
- Fixed: custom-based-on-Claude tabs now revert to Terminal when the agent exits.

## v0.10.5 — 2026-05-15

- Define your own agent. Settings → Agents → `+ add custom agent` wires any CLI as a first-class kooky agent.

## v0.10.4 — 2026-05-15

- GitHub Copilot CLI joins the agent menu.

## v0.10.3 — 2026-05-15

- Default agent for `+` and `⌘T`. Pick any agent in Settings → Agents → default to skip the popover.

## v0.10.2 — 2026-05-14

- Per-agent launch options. Each agent row in Settings has a chevron to add options like `--model opus`.

## v0.10.1 — 2026-05-14

- Customise the `+` menu — hide agents you don't use, reorder the rest.
- Settings UI redesigned with a brutalist-minimal aesthetic.

## v0.10.0 — 2026-05-14

- Cursor CLI joins the agent menu.

## v0.9.12 — 2026-05-14

- Cleaner "agent not installed" message.
- Fixed: tab icon reverts to Terminal when the agent's CLI is missing.

## v0.9.11 — 2026-05-14

- Mac-style text editing shortcuts in the shell:
  - `Cmd+←` / `Cmd+→` — beginning / end of line
  - `Option+←` / `Option+→` (or `Ctrl+←` / `Ctrl+→`) — jump by word
  - `Cmd+Backspace` — delete to start of line
  - `Option+Backspace` — delete previous word

## v0.9.10 — 2026-05-14

- Friendlier "agent not installed" message.
- Fixed: `curl | bash` installers now write to your real `~/.zshrc`.

## v0.9.9 — 2026-05-13

- Non-focused panes fully dim, including terminal content.

## v0.9.8 — 2026-05-13

- Spot the focused pane at a glance — non-focused panes dim their chrome.

## v0.9.7 — 2026-05-12

- New Settings window (`⌘,`) backed by `~/.kooky/settings.json`. v1 surfaces Font Family / Font Size / Cursor Style.
- First-launch onboarding offers to import `~/.config/ghostty/config`.

## v0.9.6 — 2026-05-12

- Smoother sidebar-collapse animation.
- Per-row Unset button in the proxy popover.
- New app icon.

## v0.9.5 — 2026-05-11

- `Shift+Enter` inserts a newline. Plain Enter still submits.
- About panel polish.

## v0.9.4 — 2026-05-11

- Status bar git state auto-refreshes during agent sessions.
- Network proxy slot in the status bar.
- Tab icon promotes when you manually launch an agent.

## v0.9.3 — 2026-05-11

- Tab icon promotes when you manually launch an agent inside a Terminal tab.

## v0.9.2 — 2026-05-11

- `exit` / `logout` closes the tab automatically.
- Reveal in Finder — right-click any tab pill or workspace row.
- Reopen Closed Tab (`⌘⇧T`).
- `⌃⇥` / `⌃⇧⇥` for per-pane tab cycling.

## v0.9.1 — 2026-05-11

- Reveal in Finder for tabs and workspaces.
- Reopen Closed Tab (`⌘⇧T`) restores agent + cwd + custom title.
- `⌃⇥` / `⌃⇧⇥` per-pane tab cycling.

## v0.9.0 — 2026-05-10

- Pane status bar showing live working-tree state — Python venv, Node version, git branch, git diff.
- Click the Node version pill → switch between installed nvm versions. Click the git branch pill → switch branches.

## v0.8.0 — 2026-05-10

- Find in scrollback (`⌘F`) per-pane. `⌘G` / `⌘⇧G` for next / previous match.
- Gemini CLI activity dot.
- OpenCode activity dot.
- Amp activity dot.

## v0.7.6 — 2026-05-09

- App icon.
- macOS 14 minimum (was 15).

## v0.7.5 — 2026-05-09

- `.app` bundle. Drag `dist/Kooky.app` into `/Applications` and launch from Spotlight.

## v0.7.4 — 2026-05-09

- Workspace-level command-failure dot — red dot on the sidebar row when any tab has a non-zero last exit.

## v0.7.3 — 2026-05-09

- Per-tab last-command status — small red dot when the most recent command exited non-zero. Hover for `exit N · 12.4s`.
- `⌘↑` / `⌘↓` to jump between prompts.

## v0.7.2 — 2026-05-09

- Manual rename for tabs and workspaces. Right-click → *Rename…*. Persists.

## v0.7.1 — 2026-05-09

- URL `⌘+click` opens in your default browser.
- Mouse shape follows libghostty (pointing-hand on URLs, resize on TUI splits).
- Font size shortcuts: `⌘=` increase, `⌘-` decrease, `⌘0` reset.
- Clear Pane (`⌘K`).
- Sidebar mode persists across launches.

## v0.7.0 — 2026-05-09

- Three-state sidebar (`full` / `compact` / `hidden`), `⌘⌃S` cycles.
- Top chrome strip with dedicated drag handle, sidebar toggle, traffic-light clearance.
- View menu becomes the navigation hub — Tab `⌘1`-`⌘9`, Workspace `⌥⌘1`-`⌥⌘9`, splits, sidebar toggle. New Help menu.
- Custom About panel.

## v0.6.0 — 2026-05-09

- Drag-reorder workspaces and tabs with animated drop indicators.
- Cross-pane tab move via drag.
- View menu with `Tab 1`-`9` and `Workspace 1`-`9` switches.
- Double-click tab bar zooms the window.
- Right-click menus show keyboard shortcut hints.

## v0.5.0 — 2026-05-08

- Recursive splits — `⌘D` splits right, `⌘⇧D` splits down, `⌘[` / `⌘]` cycles focus, `⌘W` closes a tab and collapses an empty pane.
- Right-click context menus on tabs and sidebar rows.
- Click-to-focus across panes.

## v0.4.0 — 2026-05-08

- Codex integration — sidebar shows the Codex icon while it's running.
- Auto-promote agent on hook — plain Terminal tabs that report a Claude / Codex hook upgrade to the matching template.
- IME — Chinese / Japanese / Korean / Vietnamese compose properly.

## v0.3.0 — 2026-05-08

- Agent activity dot in the sidebar — blue when processing, amber when waiting on input, hidden when idle.
- Real Claude Code integration.

## v0.2.0 — 2026-05-08

- Keyboard shortcuts: `⌘T` new tab, `⌘N` new workspace, `⌘W` close tab, `⌘⇧W` close workspace, `⌘1`-`⌘9` switch tab.
- Persistence — workspaces, tabs, agent type, and cwd survive relaunch.
- Hidden title bar; tab bar sits at the window top edge.

## v0.1.0 — 2026-05-08

First public release. Native macOS terminal with vertical-tab workspaces and one-click AI agent sessions (Claude Code / Codex / Gemini CLI / OpenCode / Amp).
