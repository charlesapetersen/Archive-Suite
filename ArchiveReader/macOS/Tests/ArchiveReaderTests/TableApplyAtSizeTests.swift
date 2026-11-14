import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-scope-exit-main: what in the table's `showRows` grows with the row count. At 115,999 rows a new
/// list cost 364 ms on the main thread at -O in every scope change (`ReaderChainAtSizeTests` §2b). This times each
/// step of `showRows`/`applySnapshot` (the `table.…` stages) as a list goes from All Files to a third of it and
/// back, and to every row moved, at several sizes, in a table set up as the chain lane's `ViewEmulation` is.
///
/// **Env-gated**: `TEST_RUNNER_READER_TABLE_APPLY_SIZES=10000,50000,116000 xcodebuild test
/// -only-testing:ArchiveReaderTests/TableApplyAtSizeTests` (add `SWIFT_OPTIMIZATION_LEVEL=-O` for shipped
/// figures). Rows are made in memory under a path that does not exist; nothing is read or written.
@MainActor
final class TableApplyAtSizeTests: XCTestCase {

    private func rows(_ count: Int) -> [ArchiveFile] {
        // About as long as the corpus's paths: root, box, folder, file.
        let root = "/Users/archivist/Desktop/Google Drive/Archival Photos/W40-table-apply-\(UUID().uuidString)"
        return (0..<count).map { i in
            let url = URL(fileURLWithPath: "\(root)/Box \(i / 2_000)/Folder \(i / 40 % 50)/IMG_\(100_000 + i).pdf")
            let entry = CorpusEntry(url: url, tagNames: ["Read"], labelNumber: nil,
                                    contentModified: Date(timeIntervalSince1970: 1_000),
                                    contentTypeIdentifier: "com.adobe.pdf", isDataless: false)
            return ArchiveLibrary.row(entry, tagNames: ["Read"], labelNumber: nil)
        }
    }

    private func makeCoordinator(_ navigation: NavigationModel) -> (AppKitTableView.Coordinator, NSScrollView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        let tableView = NSTableView(frame: scrollView.bounds)
        scrollView.documentView = tableView
        // As the app's table; READER_TABLE_APPLY_FIXED_HEIGHTS=1 turns it off, to see what the row-height pass costs.
        tableView.usesAutomaticRowHeights = ProcessInfo.processInfo.environment["READER_TABLE_APPLY_FIXED_HEIGHTS"] != "1"
        tableView.rowHeight = max(20, 13 * 1.8)
        for column in AppKitTableView.columnDefinitions {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tc.width = column.width
            tableView.addTableColumn(tc)
        }
        let coordinator = AppKitTableView.Coordinator(AppKitTableView(
            model: navigation, selection: .constant([]), fontSize: 13, scrollRequest: 0, scrollTargetID: nil,
            onDoubleClick: {}, buildContextMenu: { _ in nil }))
        coordinator.tableView = tableView
        let dataSource = SortableDiffableDataSource(tableView: tableView) { tv, column, _, itemID in
            ReaderStages.measure("table.makeCell") { coordinator.makeCell(tableView: tv, column: column, itemID: itemID) }
        }
        coordinator.dataSource = dataSource
        tableView.delegate = coordinator
        return (coordinator, scrollView)
    }

    private func ms(_ nanoseconds: UInt64) -> String { String(format: "%.1f ms", Double(nanoseconds) / 1e6) }

    /// Show `files`, and print the whole call and each `table.` stage inside it.
    private func show(_ files: [ArchiveFile], _ label: String, size: Int, on coordinator: AppKitTableView.Coordinator) {
        ReaderStages.recorder.reset(recording: true)
        let start = DispatchTime.now().uptimeNanoseconds
        let changed = coordinator.showRows(files)
        let total = DispatchTime.now().uptimeNanoseconds - start
        let stages = ReaderStages.recorder.snapshot().totals
        ReaderStages.recorder.reset(recording: false)
        XCTAssertTrue(changed, "\(label): the rows changed")
        let parts = stages.filter { $0.key.stage.hasPrefix("table.") }
            .sorted { $0.value.nanoseconds > $1.value.nanoseconds }
            .map { "\($0.key.stage) \(ms($0.value.nanoseconds))\($0.value.count > 1 ? " ×\($0.value.count)" : "")" }
        print("TA n=\(size) \(label) → \(files.count) rows: showRows \(ms(total)) | " + parts.joined(separator: " | "))
    }

    func testWhatGrowsWithTheRowCount() throws {
        guard let spec = ProcessInfo.processInfo.environment["READER_TABLE_APPLY_SIZES"] else {
            throw XCTSkip("set TEST_RUNNER_READER_TABLE_APPLY_SIZES to measure")
        }
        let sizes = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let navigation = NavigationModel(defaults: fixtureDefaults())
        for size in sizes {
            let all = rows(size)
            let third = all.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
            let (coordinator, scrollView) = makeCoordinator(navigation)
            show(all, "first", size: size, on: coordinator)
            for run in 1...3 {
                show(third, "enter (run \(run))", size: size, on: coordinator)
                show(all, "exit (run \(run))", size: size, on: coordinator)
            }
            show(Array(all.reversed()), "every row moves", size: size, on: coordinator)
            withExtendedLifetime(scrollView) {}
        }
    }
}
