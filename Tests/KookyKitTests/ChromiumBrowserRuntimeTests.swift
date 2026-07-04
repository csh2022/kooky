import Foundation
import XCTest
@testable import KookyKit

final class ChromiumBrowserRuntimeTests: XCTestCase {
    func testReportsMissingRuntimePieces() throws {
        let root = try temporaryBundleRoot()
        let runtime = ChromiumBrowserRuntime(bundleURL: root)

        guard case .unavailable(let missing) = runtime.status() else {
            return XCTFail("runtime should be unavailable without bundled CEF pieces")
        }

        XCTAssertEqual(missing, [
            "Chromium Embedded Framework.framework",
            "Kooky Helper.app",
            "Kooky Helper (GPU).app",
            "Kooky Helper (Plugin).app",
            "Kooky Helper (Renderer).app",
            "KookyCEFBridge.framework",
            "KookyCEFBridge",
            "Kooky Helper executable",
        ])
    }

    func testReportsAvailableWhenAllRuntimePiecesExist() throws {
        let root = try temporaryBundleRoot()
        let frameworks = root.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        for name in [
            "Chromium Embedded Framework.framework",
            "Kooky Helper.app",
            "Kooky Helper (GPU).app",
            "Kooky Helper (Plugin).app",
            "Kooky Helper (Renderer).app",
            "KookyCEFBridge.framework",
        ] {
            try FileManager.default.createDirectory(
                at: frameworks.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        FileManager.default.createFile(
            atPath: frameworks
                .appendingPathComponent("KookyCEFBridge.framework", isDirectory: true)
                .appendingPathComponent("KookyCEFBridge")
                .path,
            contents: Data()
        )
        try FileManager.default.createDirectory(
            at: frameworks
                .appendingPathComponent("Kooky Helper.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: frameworks
                .appendingPathComponent("Kooky Helper.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS/Kooky Helper")
                .path,
            contents: Data()
        )

        let runtime = ChromiumBrowserRuntime(bundleURL: root)

        XCTAssertEqual(runtime.status(), .available)
    }

    private func temporaryBundleRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-chromium-runtime-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Kooky.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents/Frameworks", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        return root
    }
}
