import XCTest
import ArchiveCoreUI
@testable import ArchiveReader

@MainActor
final class CloudDriveWarningTests: XCTestCase {
    func testLocalFolderWithCloudNamesIsNotClassifiedAsCloudStorage() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = folder.appendingPathComponent("Library/CloudStorage/Dropbox/iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let selected = await CloudDriveWarning.firstCloudSelection(in: [nested])
        XCTAssertNil(selected)
    }
}
