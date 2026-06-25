import XCTest
@testable import KookyKit

final class RecentWorkspaceMenuTests: XCTestCase {
    func testRecentWorkspaceMenuTitleShowsFullFolderPath() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("csh/repos/inner_repos/bytesmith", isDirectory: true)

        XCTAssertEqual(
            recentWorkspaceMenuTitle(for: url),
            "bytesmith (~/csh/repos/inner_repos/bytesmith)"
        )
    }
}
