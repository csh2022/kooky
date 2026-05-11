# kooky

> *A minimal modern terminal for AI coding.*

🇬🇧 English  ·  🇨🇳 [中文](README_CN.md)

![kooky — sidebar with three workspaces, two panes running Claude Code and Codex side by side, the `+` menu showing the five built-in agent templates](screenshot.png)

A minimal modern terminal built for AI coding. Sidebar workspaces; horizontal / vertical split panes; one-click agent launch; per-agent activity readout; live workspace state with one-click Node and branch switching. Open-source, MIT-licensed. No accounts, no telemetry; app state stays local. GPU rendering via [libghostty](https://github.com/ghostty-org/ghostty).

**[Download latest](https://github.com/iAmCorey/kooky/releases/latest)**  ·  [Changelog](CHANGELOG.md)

---

## Features

**Vertical tabs & split panes.** Sidebar workspaces with three-state collapse (`⌘⌃S`). Each pane owns its own tab strip and active tab. Drag tabs to reorder, or across panes to move sessions whole. State persists across launches.

**One-click AI agent sessions.** Claude Code · Codex · Gemini CLI · OpenCode · Amp. Pick one from the `+` menu; the agent boots before your first prompt prints.

**Agent activity readout.** Sidebar dot tracks each agent in real time — running (blue), waiting on you (amber), idle (none). Tab + workspace dots also turn red when the last command exited non-zero; hover for `exit N · 12.4s`.

**Live workspace state.** Pane status bar shows git branch + diff (`N files +X −Y`), Python venv, Node version, and active proxy (`https_proxy` / `http_proxy` / `all_proxy`). Auto-refreshes when an agent's Bash tool or another terminal switches branches. Click the Node or branch pill to switch versions / branches without typing; click the proxy pill to see and copy the full `name=value`.

**SwiftUI-native, minimal chrome.** Onest + JetBrains Mono. Custom About panel, native menus with shortcut hints, full IME support.

**Local by default.** No accounts, no telemetry, no cloud sync. Kooky keeps its own state on your device.

**libghostty-powered.** GPU-accelerated cell rendering, same engine as ghostty. Fast.

## Install

Download the latest `.dmg` from [Releases](https://github.com/iAmCorey/kooky/releases). Open it and drag `Kooky.app` to `Applications`.

**First launch is blocked by Gatekeeper** because the build is adhoc-signed (no Apple Developer ID yet — public-distribution signing and notarization will come when there are real users). You'll see *"Kooky cannot be opened because Apple cannot check it for malicious software"* or *"is damaged and cannot be opened"*. Pick whichever bypass works for you:

<details>
<summary><b>Path A — System Settings <i>(recommended)</i></b></summary>

1. Double-click `Kooky.app`. If shows the warning. Dismiss it.
2. **System Settings → Privacy & Security**, scroll to **Security**.
3. Click **Open Anyway** next to *"Kooky was blocked to protect your Mac"*. Enter your password.
4. Double-click `Kooky.app` again → click **Open**. Done.
</details>

<details>
<summary><b>Path B — Terminal (one-liner)</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/Kooky.app
```
</details>

<details>
<summary><b>Path C — when "Open Anyway" doesn't appear at all</b></summary>

Sequoia sometimes hides the Open Anyway button entirely for adhoc-signed apps. Re-enable the legacy "Anywhere" option, then redo Path A:

```sh
sudo spctl --global-disable      # macOS 15+; older systems use --master-disable
# System Settings → Privacy & Security → "Allow applications from" → Anywhere
# Open Kooky.app → it now launches
sudo spctl --global-enable       # turn Gatekeeper back on
```

This is **system-wide** while disabled. Re-enable as soon as kooky launches once (the per-app whitelist persists).
</details>

macOS only blocks the first launch. After that, Spotlight / Dock / Finder all work normally.

## Build from source

Requires Xcode 26+ and macOS 14+ (Sonoma — `@Observable` is the floor).

```sh
./scripts/setup-libghostty.sh        # one-time: fetch the libghostty xcframework
swift build
swift run                            # dev mode
swift test                           # 86 unit tests

./scripts/build-app.sh               # writes dist/Kooky.app
./scripts/build-dmg.sh --build       # writes dist/Kooky-vX.Y.Z.dmg
```

`Vendor/` and `dist/` are gitignored. The libghostty setup script is idempotent.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party assets retain their upstream licenses; see [NOTICE.md](NOTICE.md).
