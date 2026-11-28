import AppKit
import ArchiveCore
import ArchiveCoreUI
import SwiftUI
import Testing

@Suite("CloudDriveWarning and PanelDividerView")
struct CloudDriveWarningAndDividerTests {

    @Test @MainActor
    func localFolderWithCloudNamesIsNotClassifiedAsCloudStorage() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CDW-\(UUID().uuidString)", isDirectory: true)
        let nested = folder.appendingPathComponent("Library/CloudStorage/Dropbox/iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let selected = await CloudDriveWarning.firstCloudSelection(in: [nested])
        #expect(selected == nil)
    }

    @Test @MainActor
    func nonFileURLsAreIgnored() async {
        let web = URL(string: "https://example.com/archive")!
        let selected = await CloudDriveWarning.firstCloudSelection(in: [web])
        #expect(selected == nil)
    }

#if DEBUG
    @Test @MainActor
    func testPathEnvironmentFlagsExactAndDescendantPaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CDW-Flagged-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("MyLibrary.archivenotes", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = ProcessInfo.processInfo.environment["ARCHIVE_CLOUD_WARNING_TEST_PATH"]
        setenv("ARCHIVE_CLOUD_WARNING_TEST_PATH", root.resolvingSymlinksInPath().path, 1)
        defer {
            if let saved { setenv("ARCHIVE_CLOUD_WARNING_TEST_PATH", saved, 1) }
            else { unsetenv("ARCHIVE_CLOUD_WARNING_TEST_PATH") }
        }

        let exact = await CloudDriveWarning.firstCloudSelection(in: [root])
        let nested = await CloudDriveWarning.firstCloudSelection(in: [child])
        #expect(exact == root)
        #expect(nested == child)
    }
#endif

    @Test @MainActor
    func panelDividerClampsVoiceOverSizeAndSwitchesOrientation() {
        var size = 500.0
        let divider = PanelDividerView()
        divider.size = Binding(get: { size }, set: { size = $0 })
        divider.range = 140...350

        // Out-of-range remembered size reports clamped value and steps from it.
        #expect(divider.accessibilityRole() == .splitter)
        #expect(divider.accessibilityOrientation() == .vertical)
        #expect(divider.accessibilityValue() as? Double == 350)
        #expect(divider.accessibilityPerformDecrement())
        #expect(size == 340)

        // Switching to vertical axis (stacked layout) switches AX orientation to horizontal.
        divider.axis = .vertical
        #expect(divider.accessibilityOrientation() == .horizontal)
        divider.setAccessibilityValue(Double.nan)
        #expect(size == 340)
    }
}
