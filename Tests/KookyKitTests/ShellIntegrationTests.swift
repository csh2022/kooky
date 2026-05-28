import AppKit
import XCTest
@testable import KookyKit

/// Verifies the *content* the integration generates. Tests do not invoke
/// `installAgentHooks()` because that writes to user-config dirs using a
/// hookCmd derived from the running binary (xctest's helpers under
/// `/Applications/Xcode.app/...`), which would pollute and corrupt
/// real user config files. Self-heals on next kooky launch but better
/// avoided: the writers are trivial, the content getters are the
/// load-bearing surface.
final class ShellIntegrationTests: XCTestCase {
    private static let stubHook = "/usr/local/bin/KookyHook"

    func testGeminiDefaultsExposesAllFourLifecycleEvents() throws {
        let object = KookyShellIntegration.geminiDefaultsObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        let expected: [String: String] = [
            "BeforeAgent": "running",
            "AfterAgent": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ]
        for (event, state) in expected {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["type"] as? String, "command")
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' gemini \(state)")
        }
    }

    func testClaudeHooksObjectStaysWiredAfterRefactor() throws {
        let object = KookyShellIntegration.claudeHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for (event, state) in [
            "UserPromptSubmit": "running",
            "Stop": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' claude \(state)")
        }
    }

    /// Tool-call lifecycle subscriptions added for the activity strip. These
    /// differ from lifecycle hooks: the third command argv preserves the raw
    /// event name (`PreToolUse` / `PostToolUse`) because `main.swift` reads
    /// stdin and routes through `KookyHookKit.parseToolEventPayload` for
    /// these — not a `HookEvent` rawValue.
    func testClaudeHooksObjectSubscribesToolCallEvents() throws {
        let object = KookyShellIntegration.claudeHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for event in ["PreToolUse", "PostToolUse"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["type"] as? String, "command")
            // argv[2] = raw Claude event name (not a HookEvent rawValue)
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' claude \(event)")
        }
    }

    /// Regression guard — Gemini wrapper doesn't expose tool-level hooks
    /// (per CLAUDE.md M5.x); its passthroughEvents stays empty. If we ever
    /// add tool events to Gemini, update this test deliberately.
    func testGeminiHooksObjectDoesNotSubscribeToolEvents() throws {
        let object = KookyShellIntegration.geminiDefaultsObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PostToolUse"])
    }

    func testBracketWrapperPassesThroughWhenSurfaceIdMissing() {
        let script = KookyShellIntegration.bracketWrapperScript(slug: "amp")

        XCTAssertTrue(script.contains("self_dir"), "must skip own dir on PATH walk")
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp running"))
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp ended"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testAntigravityWrapperGuardsAgainstIDEShim() {
        // Antigravity 2.0 IDE installs a launcher also called `agy` that
        // symlinks into `/Applications/Antigravity.app/...`. Without
        // detection, an IDE-only-installed user picking "Antigravity CLI"
        // from `+` would accidentally open the GUI app.
        let script = KookyShellIntegration.antigravityWrapperScript

        XCTAssertTrue(script.contains("readlink \"$real\""), "must resolve symlink one hop")
        XCTAssertTrue(script.contains("*/Antigravity.app/*"), "must match IDE launcher resolved path")
        XCTAssertTrue(script.contains("antigravity.google/cli/install.sh"), "must surface CLI install command")
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" agy ended"), "must revert tab icon on shim-detection bail")
        XCTAssertTrue(script.contains("exit 127"), "must mirror preamble's not-installed exit code")
    }

    func testAntigravityWrapperBracketsRunningAndEndedForRealCLI() {
        let script = KookyShellIntegration.antigravityWrapperScript

        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" agy running"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testOpencodePluginShellsOutToHookBinForBothEvents() {
        let body = KookyShellIntegration.opencodePluginScript

        XCTAssertTrue(body.contains("chat.message"), "plugin must subscribe to per-prompt event")
        XCTAssertTrue(body.contains("session.idle"), "plugin must subscribe to turn-end event")
        XCTAssertTrue(body.contains(#"ping("running")"#))
        XCTAssertTrue(body.contains(#"ping("attention")"#))
        XCTAssertTrue(body.contains("opencode"), "plugin must pass agent slug to KookyHook")
        XCTAssertTrue(body.contains("KOOKY_SURFACE_ID"))
        XCTAssertTrue(body.contains("kooky-managed-do-not-edit"), "plugin must carry the upgrade-safety marker")
    }

    func testEnvStatusBlockReportsLiveShellEnvironment() {
        let body = KookyShellIntegration.envStatusBlock

        XCTAssertTrue(body.contains("\"$KOOKY_HOOK_BIN\" env"))
        XCTAssertTrue(body.contains(#""${VIRTUAL_ENV:-}""#))
        XCTAssertTrue(body.contains(#""${CONDA_DEFAULT_ENV:-}""#))
        XCTAssertTrue(body.contains(#""${NVM_BIN:-}""#))
        XCTAssertTrue(body.contains(#""${NVM_DIR:-}""#))
        XCTAssertTrue(body.contains("--version"), "must invoke node --version")
        XCTAssertTrue(body.contains("_KOOKY_NODE_KEY_LAST"), "must memoize node version against path+NVM_BIN")
        XCTAssertTrue(body.contains("_KOOKY_ENV_LAST"), "must skip the kooky-hook IPC when env unchanged")
    }

    @MainActor
    func testHookServerParsesAgentPayload() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "agent": "claude",
            "event": "running",
            "surface": id.uuidString,
        ])

        guard case .agent(let agent, let event, let sessionId) = HookServer.parseMessage(data) else {
            return XCTFail("expected agent hook message")
        }
        XCTAssertEqual(agent, .claudeCode)
        XCTAssertEqual(event, .running)
        XCTAssertEqual(sessionId, id)
    }

    @MainActor
    func testHookServerParsesShellEnvironmentPayload() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "env",
            "surface": id.uuidString,
            "VIRTUAL_ENV": "/tmp/app/.venv",
            "CONDA_DEFAULT_ENV": "",
            "NVM_BIN": "/Users/corey/.nvm/versions/node/v20.1.0/bin",
            "NVM_DIR": "/Users/corey/.nvm",
            "KOOKY_NODE_VERSION": "v20.1.0",
        ])

        guard case .shellEnvironment(let env, let sessionId) = HookServer.parseMessage(data) else {
            return XCTFail("expected shell environment hook message")
        }
        XCTAssertEqual(sessionId, id)
        XCTAssertEqual(env["VIRTUAL_ENV"], "/tmp/app/.venv")
        XCTAssertEqual(env["NVM_BIN"], "/Users/corey/.nvm/versions/node/v20.1.0/bin")
        XCTAssertEqual(env["NVM_DIR"], "/Users/corey/.nvm")
        XCTAssertEqual(env["KOOKY_NODE_VERSION"], "v20.1.0")
    }

    func testBackslashEscapeLeavesPlainPathUntouched() {
        XCTAssertEqual(KookyShellIntegration.backslashEscape("/Users/corey/file.txt"), "/Users/corey/file.txt")
    }

    func testBackslashEscapeEscapesSpaceAndQuoteAndDollar() {
        XCTAssertEqual(
            KookyShellIntegration.backslashEscape("/Users/corey/My Folder/don't $cost"),
            #"/Users/corey/My\ Folder/don\'t\ \$cost"#
        )
    }

    func testBackslashEscapePassesThroughNonAscii() {
        // Chinese / emoji filenames are common on macOS; shells accept raw
        // UTF-8 so we don't escape them.
        XCTAssertEqual(KookyShellIntegration.backslashEscape("/tmp/项目/🚀.md"), "/tmp/项目/🚀.md")
    }

    func testClaudeCustomSettingsObjectCarriesHooksAndEnv() throws {
        let object = KookyShellIntegration.claudeCustomSettingsObject(
            env: ["ANTHROPIC_BASE_URL": "https://mirror.example.com"],
            hookCmd: Self.stubHook
        )
        // The env block Claude reads natively for the custom endpoint / key.
        let env = try XCTUnwrap(object["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://mirror.example.com")
        // Hooks must ride along — the per-agent file is the only settings
        // file passed to that session, so kooky's activity hooks have to be
        // in it too, not just the env block.
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' claude running")
    }

    func testBackslashEscapeFallsBackToQuoteOnNewlineToAvoidLineContinuation() {
        // POSIX: `\<newline>` is line continuation and gets dropped — so a
        // legitimate macOS filename containing `\n` would be silently
        // corrupted by the plain backslash-escape path. Codex P3 fix
        // (v0.11.3): fall back to single-quote wrap, which preserves the
        // literal newline.
        let escaped = KookyShellIntegration.backslashEscape("/tmp/multi\nline/file.txt")
        XCTAssertEqual(escaped, "'/tmp/multi\nline/file.txt'")
    }

    // MARK: - readTerminalPasteText / pasteboardHasTerminalPasteContent

    /// Create an isolated pasteboard so tests never touch `.general` or
    /// each other. `NSPasteboard(name:)` with a unique name returns a
    /// process-private board that AppKit cleans up on exit.
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let unique = "kooky-test-\(UUID().uuidString)"
        return NSPasteboard(name: NSPasteboard.Name(unique))
    }

    /// 1×1 transparent PNG — small valid PNG to exercise the image-spill path.
    private static let oneByOnePNG: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIA" +
        "AAoAAv/lxKUAAAAASUVORK5CYII="
    )!

    func testReadTerminalPasteTextReturnsRawStringForPlainText() {
        // String paste is the common case (Cmd+V on a shell command).
        // No backslash-escaping — `ls -la` must round-trip verbatim.
        let pb = makeIsolatedPasteboard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("ls -la", forType: .string)
        XCTAssertEqual(KookyShellIntegration.readTerminalPasteText(from: pb), "ls -la")
    }

    func testReadTerminalPasteTextReturnsEscapedPathForFileURL() {
        // Finder Copy on a file (including images) gives a fileURL on the
        // pasteboard. We backslash-escape the full disk path so the
        // shell / agent receives an addressable argument — not the bare
        // filename that `.string` would return.
        let pb = makeIsolatedPasteboard()
        let url = URL(fileURLWithPath: "/tmp/some folder/image one.png")
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        XCTAssertEqual(
            KookyShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/some\\ folder/image\\ one.png"
        )
    }

    func testReadTerminalPasteTextJoinsMultipleFileURLsWithSpace() {
        let pb = makeIsolatedPasteboard()
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])
        XCTAssertEqual(
            KookyShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/a.png /tmp/b.png"
        )
    }

    func testReadTerminalPasteTextSpillsPNGImageDataToCacheFile() throws {
        // Cmd+Ctrl+Shift+4 screenshots show up as raw PNG bytes with no
        // fileURL representation. Without spill-to-disk the agent has no
        // way to read the image — we cache it under
        // ~/Library/Caches/kooky/pastes/screenshot-*.png and paste the
        // escaped file path.
        let pb = makeIsolatedPasteboard()
        pb.declareTypes([.png], owner: nil)
        pb.setData(Self.oneByOnePNG, forType: .png)
        let pasted = try XCTUnwrap(KookyShellIntegration.readTerminalPasteText(from: pb))
        // Resolve the escape so we can `stat` the file.
        let rawPath = pasted.replacingOccurrences(of: "\\", with: "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawPath),
            "Expected pasted path to point at a real file on disk: \(rawPath)"
        )
        XCTAssertTrue(rawPath.contains("/kooky/pastes/screenshot-"))
        XCTAssertTrue(rawPath.hasSuffix(".png"))
        try? FileManager.default.removeItem(atPath: rawPath)
    }

    func testReadTerminalPasteTextSpillsTIFFImageDataAsPNG() throws {
        // Cmd+Shift+3 (full-screen-to-clipboard) and Preview "Copy" land
        // as TIFF on the pasteboard, not PNG — the TIFF→PNG re-encode
        // branch is the actual screenshot hot path. Without coverage
        // this can regress silently if someone tweaks the helper.
        let pb = makeIsolatedPasteboard()
        // Synthesise a 1×1 TIFF via NSBitmapImageRep so we exercise the
        // re-encode branch without bundling a binary fixture.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        )!
        let tiffData = try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))
        pb.declareTypes([.tiff], owner: nil)
        pb.setData(tiffData, forType: .tiff)
        let pasted = try XCTUnwrap(KookyShellIntegration.readTerminalPasteText(from: pb))
        let rawPath = pasted.replacingOccurrences(of: "\\", with: "")
        XCTAssertTrue(rawPath.hasSuffix(".png"))
        // Confirm we actually wrote PNG bytes (not TIFF with a .png suffix).
        let cached = try XCTUnwrap(FileManager.default.contents(atPath: rawPath))
        XCTAssertNotNil(NSBitmapImageRep(data: cached), "Cached file should parse as a bitmap image")
        let magic = cached.prefix(8)
        XCTAssertEqual(
            Array(magic),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "Cached file should have a PNG magic header, not TIFF"
        )
        try? FileManager.default.removeItem(atPath: rawPath)
    }

    func testReadTerminalPasteTextPrefersFileURLOverImageData() {
        // Finder Copy on an image populates both fileURL and TIFF/PNG.
        // fileURL must win — the user already has a real file on disk;
        // re-spilling the bytes to a cache file loses provenance + bloats
        // ~/Library/Caches.
        let pb = makeIsolatedPasteboard()
        let url = URL(fileURLWithPath: "/tmp/real-image.png")
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setData(Self.oneByOnePNG, forType: .png)
        XCTAssertEqual(
            KookyShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/real-image.png"
        )
    }

    func testReadTerminalPasteTextReturnsNilForEmptyPasteboard() {
        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        XCTAssertNil(KookyShellIntegration.readTerminalPasteText(from: pb))
    }

    func testPasteboardHasTerminalPasteContentMatchesReadability() {
        // Gate must agree with `readTerminalPasteText` so the right-click
        // Paste menu enables exactly when the action will produce input.
        let emptyPb = makeIsolatedPasteboard()
        emptyPb.clearContents()
        XCTAssertFalse(KookyShellIntegration.pasteboardHasTerminalPasteContent(emptyPb))

        let stringPb = makeIsolatedPasteboard()
        stringPb.declareTypes([.string], owner: nil)
        stringPb.setString("x", forType: .string)
        XCTAssertTrue(KookyShellIntegration.pasteboardHasTerminalPasteContent(stringPb))

        let filePb = makeIsolatedPasteboard()
        filePb.clearContents()
        filePb.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertTrue(KookyShellIntegration.pasteboardHasTerminalPasteContent(filePb))

        let imagePb = makeIsolatedPasteboard()
        imagePb.declareTypes([.png], owner: nil)
        imagePb.setData(Self.oneByOnePNG, forType: .png)
        XCTAssertTrue(KookyShellIntegration.pasteboardHasTerminalPasteContent(imagePb))
    }
}
