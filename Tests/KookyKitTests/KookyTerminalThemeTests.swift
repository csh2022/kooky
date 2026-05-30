import XCTest
@testable import KookyKit

@MainActor
final class KookyTerminalThemeTests: XCTestCase {
    func testPresetLookupAcceptsStableId() {
        let theme = KookyTerminalTheme.preset(for: "solarized-light")
        XCTAssertEqual(theme?.title, "Solarized Light")
    }

    func testPresetLookupAcceptsLegacyDisplayName() {
        let theme = KookyTerminalTheme.preset(for: "Solarized Light")
        XCTAssertEqual(theme?.id, "solarized-light")
    }

    func testPresetExpandsToConcreteGhosttyColors() {
        let theme = KookyTerminalTheme.preset(for: "dracula")
        XCTAssertEqual(theme?.lines.first, "background = #282A36")
        XCTAssertEqual(theme?.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testSettingsThemeSelectionPreservesUnknownRawTheme() {
        let state = KookySettingsModel.themeSelection(for: "/Users/me/.config/ghostty/themes/custom")
        XCTAssertEqual(state.selection, KookySettingsModel.customThemeSelection)
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: state.customRawValue
            ),
            "/Users/me/.config/ghostty/themes/custom"
        )
    }

    func testSettingsDefaultThemeSelectionClearsRawThemeWhenChosen() {
        let defaultSelection = KookySettingsModel.themeSelection(for: nil).selection
        XCTAssertNil(
            KookySettingsModel.persistedThemeValue(
                selection: defaultSelection,
                customRawValue: "/Users/me/.config/ghostty/themes/custom"
            )
        )
    }

    func testSettingsPresetThemeSelectionPersistsStableId() {
        let state = KookySettingsModel.themeSelection(for: "Solarized Light")
        XCTAssertEqual(state.selection, "solarized-light")
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil
            ),
            "solarized-light"
        )
    }

    func testUserThemesLoadsGhosttyThemeDirectoryFiles() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let themeURL = dir.appendingPathComponent("My Custom Theme")
        try """
        # comments are ignored
        background = #101820
        foreground = "F2AA4C"
        palette = 0=#101820
        """.write(to: themeURL, atomically: true, encoding: .utf8)

        let themes = KookyTerminalTheme.userThemes(in: dir)
        XCTAssertEqual(themes.map(\.title), ["My Custom Theme"])
        XCTAssertEqual(themes.first?.storedValue, "My Custom Theme")
        XCTAssertEqual(themes.first?.backgroundHex, "#101820")
        XCTAssertEqual(themes.first?.foregroundHex, "F2AA4C")
    }

    func testSettingsThemeSelectionAcceptsUserThemeByFileName() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Issue 17")
        try "background = #000000\nforeground = #ffffff\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let custom = KookyTerminalTheme.userThemes(in: dir)
        let state = KookySettingsModel.themeSelection(for: "Issue 17", in: KookyTerminalTheme.presets + custom)
        XCTAssertEqual(state.selection, "ghostty-user:Issue 17")
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil,
                in: KookyTerminalTheme.presets + custom
            ),
            "Issue 17"
        )
    }

    func testGhosttyUserThemesDirectoryHonorsXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let xdg = KookyTerminalTheme.ghosttyUserThemesDirectory(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: home
        )
        XCTAssertEqual(xdg.path, "/tmp/xdg/ghostty/themes")

        let fallback = KookyTerminalTheme.ghosttyUserThemesDirectory(
            environment: [:],
            homeDirectory: home
        )
        XCTAssertEqual(fallback.path, "/Users/example/.config/ghostty/themes")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
