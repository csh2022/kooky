# kooky

> *专为 AI coding 优化的极简 macOS 终端。*

🇨🇳 中文  ·  🇬🇧 [English](README.md)

![kooky 截图：侧边栏里有三个 workspace，两个 pane 并排运行 Claude Code 和 Codex，`+` 菜单展开了七种内置 agent](screenshot.png)

专为 AI coding 优化的极简 macOS 终端。支持侧边栏 workspace 管理、水平 / 垂直分屏、一键启动 agent、实时查看 agent 状态，也能在 pane 底部直接看到 Git、Node、Python 等工作区状态。开源，MIT 许可；不需要账号，不做遥测，应用状态都留在本机。GPU 渲染基于 [libghostty](https://github.com/ghostty-org/ghostty)。

**[下载最新版](https://github.com/iAmCorey/kooky/releases/latest)**  ·  [更新日志](CHANGELOG.md)

---

## 功能

**垂直 tab、分屏、多窗口。** 侧边栏管理所有 workspace，三档宽度可切换（`⌘⌃S`）。每个 pane 都有独立 tab 栏和当前 tab。`⌘⇧N` 打开新窗口。tab 可以拖动排序、跨 pane 移动，也能拖进另一个窗口 —— 实时会话整体带过去，scrollback 和正在跑的进程都在。重启后状态自动恢复，每个打开的窗口都会还原。把任意文件夹打开成新 workspace:从 Finder 拖到 sidebar,或者按 ⌘O。

**一键启动各种 agent。** Claude Code · Codex · Gemini CLI · OpenCode · Amp · Cursor CLI · Copilot CLI · Grok Build · Antigravity CLI。`+` 菜单里选一个,agent 会在第一个 prompt 出现前启动。Claude 对话还会跨 kooky 重启自动 resume,关掉 tab 再打开能从离开的地方接上。

**右键选中 → "Ask <agent>"。** 在 terminal 里选中一段 error / 日志 / 文件路径,右键挑任意 agent,新 tab 一打开,selection 已经作为第一条 prompt 发出去了,直接开始回答 —— 不用 ⌘C / ⌘V 来回切。

**快速打开(⌘P)。** 一个浮动面板模糊搜索所有 window 的 workspaces、tabs、agents、Terminal presets。输入关键字筛选,↑↓ 选,Enter 跳过去或者新开一个。⌘P 或顶部 chrome 上的 search pill 都能触发。

**输入顺手。** 在 zsh 提示行点哪儿光标就跳哪儿(不用按 modifier,跟 ghostty.app 一致)。从 Finder 把文件或文件夹拖到任意 pane,绝对路径会自动 escape 后插到光标位置。

**Agent 状态实时展示。** 侧边栏圆点显示每个 agent 的状态：运行中（蓝）、等待你处理（琥珀）、空闲（无色）。上一条命令非零退出时，tab 和 workspace 会同步显示红点；悬停可看到 `exit N · 12.4s`。

**工作区状态和环境一眼可见。** pane 底部状态栏显示 Git 分支 + diff（`N files +X −Y`）、Python venv、Node 版本，以及当前生效的代理（`https_proxy` / `http_proxy` / `all_proxy`）。Agent 用 Bash 切分支也好,你在别的终端改了 git 状态也好,这里都会自动刷新。Node 版本和 Git 分支点一下就能切,代理点开能看完整 `name=value` 并复制。

**SwiftUI 原生开发，简约风格。** Onest + JetBrains Mono 字体。自定义 About 面板、带快捷键提示的原生菜单,中日韩 IME 输入完整支持。

**可配置。** Settings 面板（`⌘,`）侧边栏布局：**General**（字体 / 光标 / 字号;挑一个 `+` 和 `⌘T` 默认开什么）、**Terminals**(配置多个「Terminal at /path」预设,每个固定到一个文件夹,出现在 `+` 菜单 —— 拖动排序、随时切换显隐)、**Agents**（拖动排序、切换显隐、给每个 agent 单独配启动参数比如 `--model opus`、定义自己的 custom agent —— 基于 Claude Code 的还能配自己的 endpoint / API key,指向镜像或代理站）、**Status Bar**(拖动排序 pane 底部状态栏的各项 —— Python venv / Node version / Proxy / Git branch / Git diff —— 也可以单独关掉)、**Advanced**（直接打开 raw JSON）。所有自定义都写到 `~/.kooky/settings.json` —— kooky 先读你的 `~/.config/ghostty/config`,再用 settings.json 覆盖;首次启动会问要不要导入现有 ghostty 配置。

**默认本地。** 不需要账号，不做遥测，没有云同步。kooky 的状态都留在本机。

**基于 libghostty。** 使用和 ghostty 同源的 GPU 终端渲染引擎。

## 安装

从 [Releases](https://github.com/iAmCorey/kooky/releases) 下载最新的 `.dmg`，打开后把 `Kooky.app` 拖进 `Applications` 文件夹。

**第一次启动会被 Gatekeeper 拦下来**，因为当前构建是 adhoc 签名（还没有 Apple Developer ID；公开分发签名和公证会等有真实用户后再做）。你会看到 *"Kooky cannot be opened because Apple cannot check it for malicious software"* 或者 *"is damaged and cannot be opened"* 这两类报错。下面三种方法任选一个即可：

<details>
<summary><b>方法 A —— 走系统设置 <i>(推荐)</i></b></summary>

1. 先双击一次 `Kooky.app`，macOS 会弹警告，把警告窗口关掉。
2. 打开 **系统设置 → 隐私与安全性**，往下翻到 **安全性** 这一段。
3. 看到 *"Kooky was blocked to protect your Mac"* 后，点旁边的 **Open Anyway**，输入密码。
4. 再双击一次 `Kooky.app`，这次会有 **Open** 按钮，点它即可。
</details>

<details>
<summary><b>方法 B —— 终端一行命令</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/Kooky.app
```
</details>

<details>
<summary><b>方法 C —— 连 "Open Anyway" 按钮都没有</b></summary>

新版 Sequoia 有时会对 adhoc 签名的 app 完全不显示 "Open Anyway" 按钮。这种情况下可以先把旧版的 "Anywhere" 选项打开，再回去走方法 A：

```sh
sudo spctl --global-disable      # macOS 15+；老系统用 --master-disable
# 系统设置 → 隐私与安全性 → "Allow applications from" 选 Anywhere
# 双击 Kooky.app，这次应该可以启动
sudo spctl --global-enable       # Kooky 跑过一次之后，立刻把 Gatekeeper 打开
```

注意：这是**系统级开关**。关着的时候，macOS 会允许任何未签名 app 启动。Kooky 跑过一次就把它重新打开；系统会单独记住已经信任过 Kooky，以后不会再拦。
</details>

macOS **只拦第一次启动**。之后从 Spotlight、Dock、Finder 启动都跟普通 app 一样。

## 从源码构建

需要 Xcode 26+ 和 macOS 14+（Sonoma，`@Observable` 的最低系统要求）。

```sh
./scripts/setup-libghostty.sh        # 一次性：把预编译的 libghostty xcframework 下到 Vendor/
swift build
swift run                            # 开发模式直接跑
swift test                           # 189 个单测

./scripts/build-app.sh               # 产出 dist/Kooky.app
./scripts/build-dmg.sh --build       # 产出 dist/Kooky-vX.Y.Z.dmg
```

`Vendor/` 和 `dist/` 都在 `.gitignore` 里。libghostty 的 setup 脚本可以反复跑；SHA 没变时会直接跳过。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。打包进来的第三方资源保留各自的许可证，详见 [NOTICE.md](NOTICE.md)。
