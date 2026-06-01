# kooky

[![License](https://img.shields.io/github/license/iAmCorey/kooky?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-007AFF?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/iAmCorey/kooky/total?style=flat-square)](https://github.com/iAmCorey/kooky/releases)
[![Stars](https://img.shields.io/github/stars/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/stargazers)

> *AI コーディングのためのミニマルでモダンな macOS ターミナル。*

🇯🇵 日本語  ·  🇬🇧 [English](README.md)  ·  🇨🇳 [中文](README_CN.md)

![kooky のスクリーンショット](screenshot.png)

AI コーディングのために作られた、ミニマルでモダンな macOS ターミナルです。サイドバーで workspace を管理、水平 / 垂直の split pane、ワンクリックで agent を起動、agent のステータスをリアルタイム表示、pane 下部で Git・Node・Python など作業環境の状態が一目で確認できます。オープンソース、MIT ライセンス。アカウント不要、テレメトリなし、アプリの状態は端末内にのみ保存。GPU レンダリングは [libghostty](https://github.com/ghostty-org/ghostty) ベース。

**[最新版をダウンロード](https://github.com/iAmCorey/kooky/releases/latest)**  ·  [変更履歴](CHANGELOG.md)

---

## 機能

**垂直 tab、split pane、複数ウィンドウ。** サイドバーで全ての workspace を管理、3 段階の幅切り替え (`⌘⌃S`)。各 pane が独自の tab バーとアクティブ tab を持ちます。`⌘⇧N` で新しいウィンドウを開きます。tab はドラッグで並び替え、pane 間の移動、別ウィンドウへの移動が可能 —— セッションが scrollback と実行中のプロセスごとまるごと移動します。アプリ再起動後も状態は復元され、開いていた全ウィンドウが復元されます。任意のフォルダを新しい workspace として開く方法：Finder からサイドバーにドロップするか、⌘O。`⌘⇧E` でアクティブな pane を最大化、もう一度押すと元に戻ります —— 他の pane は画面外にスライドしますが、プロセスは走り続けています。

**ワンクリックで AI agent セッション。** Claude Code · Codex · Gemini CLI · OpenCode · Amp · Cursor CLI · Copilot CLI · Grok Build · Antigravity CLI · Kimi Code · Pi。`+` メニューから選ぶだけで、最初の prompt を打つ前に agent が起動します。Claude の会話は kooky の再起動を跨いで自動で resume されるので、tab を閉じて再度開いても直前の続きから再開できます。

**Git worktree。** 任意の git workspace を右クリック → "Create Worktree…" で新しい branch (または既存 branch の checkout) に対する worktree を作成します。worktree はサイドバーで元のリポジトリの下にネストして表示され、独自の tab + agent を持ちます —— main で何かが走っている最中でも、Claude を feature branch で並行して動かせます。コマンドラインで `git worktree add` した worktree も、次回 kooky 起動時に自動でサイドバーに現れます。

**選択範囲を右クリック → "Ask <agent>"。** ターミナル内でエラー / ログ / ファイルパスを選択して右クリック、好きな agent を選ぶと、新しい tab が開いた時点で選択範囲が最初の prompt として送信済みの状態になります。⌘C / ⌘V の往復なしで "これは何？" から答えに直行。

**クイックオープン (⌘P)。** 全ウィンドウの workspaces、tabs、agents、Terminal preset を 1 つのフローティングパネルから fuzzy 検索。文字を打って絞り込み、↑↓ で選択、Enter でジャンプまたは起動。⌘P または上部 chrome の検索 pill から呼び出せます。

**ストレスのない入力。** zsh の prompt 上のどこをクリックしても shell カーソルがそこに移動します (modifier 不要、ghostty.app と同じ操作感)。Finder からファイル / フォルダを pane にドラッグすると、エスケープ済みの絶対パスがカーソル位置に挿入されます。

**Agent ステータスをリアルタイム表示。** サイドバーのドットが各 agent の状態を示します —— 実行中 (青)、ユーザー待ち (琥珀)、アイドル (なし)。直前のコマンドが非ゼロ終了したときは tab と workspace のドットが赤くなり、ホバーで `exit N · 12.4s` が確認できます。Claude Code と Pi のセッションでは pane 下部のステータスバーに agent が今走らせているツール (Bash / Edit / Read など) と経過時間も表示されます —— pill をクリックすればセッション全体の履歴を確認でき、失敗したツール呼び出しはすぐに赤くなります。pill は Settings → Status Bar で agent ごとに表示/非表示を切り替えられます。

**作業環境の状態が一目で見える。** pane 下部のステータスバーに Git branch + diff (`N files +X −Y`)、Python venv、Node バージョン、有効中の proxy (`https_proxy` / `http_proxy` / `all_proxy`) を表示。agent の Bash ツールや別ターミナルで branch を切り替えても自動で更新されます。Node バージョンや Git branch の pill をクリックすればコマンドを打たずに切り替え可能、proxy pill をクリックすると完全な `name=value` を表示してコピーできます。

**SwiftUI ネイティブ、ミニマルな chrome。** Onest + JetBrains Mono。カスタム About パネル、ショートカットヒント付きのネイティブメニュー、日本語 IME を完全サポート。

**設定可能。** Settings (`⌘,`) からテーマ、フォント、カーソル、デフォルトの新規 tab 挙動、Terminal preset、agents、pane ステータスバーを調整できます。テーマ変更はウィンドウ全体に即時反映されます。

**ローカルファースト。** アカウント不要、テレメトリなし、クラウド同期なし。kooky の状態はすべて端末内に保存されます。

**libghostty 駆動。** ghostty と同じ GPU 加速セルレンダリングエンジン。高速。

## インストール

[Releases](https://github.com/iAmCorey/kooky/releases) から最新の `.dmg` をダウンロード、開いて `Kooky.app` を `Applications` フォルダにドラッグしてください。

**初回起動は Gatekeeper にブロックされます**。現在のビルドは adhoc 署名 (Apple Developer ID 未取得 —— 公開配布署名と公証は実際のユーザーが増えてから対応予定) なので、*"Kooky cannot be opened because Apple cannot check it for malicious software"* または *"is damaged and cannot be opened"* というエラーが出ます。下記の 3 通りからどれか一つを実行してください：

<details>
<summary><b>方法 A —— システム設定から <i>(推奨)</i></b></summary>

1. まず `Kooky.app` をダブルクリック。macOS が警告を出すのでダイアログを閉じます。
2. **システム設定 → プライバシーとセキュリティ** を開き、**セキュリティ** セクションまでスクロール。
3. *"Kooky was blocked to protect your Mac"* の隣に表示される **Open Anyway** をクリックし、パスワードを入力。
4. もう一度 `Kooky.app` をダブルクリック、今度は **Open** ボタンが表示されるのでクリックして完了。
</details>

<details>
<summary><b>方法 B —— ターミナル 1 行</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/Kooky.app
```
</details>

<details>
<summary><b>方法 C —— "Open Anyway" ボタンすら表示されない場合</b></summary>

Sequoia 以降では adhoc 署名アプリに対して "Open Anyway" ボタンが完全に隠れることがあります。その場合は旧版の "Anywhere" オプションを一旦有効化してから方法 A をやり直します：

```sh
sudo spctl --global-disable      # macOS 15+；古いシステムは --master-disable
# システム設定 → プライバシーとセキュリティ → "Allow applications from" で Anywhere を選択
# Kooky.app をダブルクリック → 起動できるはず
sudo spctl --global-enable       # Kooky が一度起動したら、すぐに Gatekeeper を戻す
```

注意：これは **システム全体の設定** です。無効の間はあらゆる未署名アプリの起動を許可してしまいます。Kooky が一度起動したら必ず元に戻してください。Kooky 自体は個別に信頼済みとして記憶されるので、以後ブロックされません。
</details>

macOS は **初回起動のみブロック** します。それ以降は Spotlight / Dock / Finder から通常のアプリと同じように起動できます。

## ソースからビルド

Xcode 26+ と macOS 14+ (Sonoma —— `@Observable` の最低システム要件) が必要です。

```sh
./scripts/setup-libghostty.sh        # 初回のみ：プリビルドの libghostty xcframework を Vendor/ にダウンロード
swift build
swift run                            # 開発モードで直接起動
swift test                           # 380 個のユニットテスト

./scripts/build-app.sh               # dist/Kooky.app を出力
./scripts/build-dmg.sh --build       # dist/Kooky-vX.Y.Z.dmg を出力
```

`Vendor/` と `dist/` は `.gitignore` 済みです。libghostty の setup スクリプトは冪等で、SHA に変更がなければスキップされます。

## ライセンス

MIT —— [LICENSE](LICENSE) を参照。同梱されているサードパーティ製アセットはそれぞれのライセンスに従います。詳細は [NOTICE.md](NOTICE.md) を参照。
