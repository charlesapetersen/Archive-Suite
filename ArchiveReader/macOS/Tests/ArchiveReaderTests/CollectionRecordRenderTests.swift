import XCTest
import SwiftUI
import ArchiveCore
import ArchiveCoreUI
@testable import ArchiveReader

/// W46.settings-reader-notes: the inspector's "What produced this collection" draws, from a record read off a
/// scratch collection folder, light and dark.
@MainActor
final class CollectionRecordRenderTests: XCTestCase {
    func testCollectionRecordRendersAtTheInspectorWidth() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ar-collrec-\(UUID())")
        let suite = folder.appendingPathComponent(".archivesuite/runs", isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = #"{"schemaVersion":1,"createdAt":"2026-11-04T09:59:00Z","projectName":"Correspondence","collection":{"id":"A","kind":"collection","name":"Letters 1952","entries":{"hours":{"source":{"setByUser":{"_0":"2026-11-04T10:00:00Z"}},"value":{"type":"double","value":8}}}}}"#
        try Data(doc.utf8).write(to: folder.appendingPathComponent(".archivesuite/collection-settings.json"))
        let run = #"{"schemaVersion":1,"id":"R1","kind":"processFiles","fileCount":12,"startedAt":"2026-11-05T10:00:00Z","settings":{"schemaVersion":1,"runID":"R1","resolvedAt":"2026-11-05T10:00:00Z","macMemoryGB":16,"processing":{"selectedProvider":{"type":"string","value":"Gemini"},"selectedModelId_Gemini":{"type":"string","value":"gemini-3.7-flash"}},"values":{"moneyHabit":{"value":{"type":"string","value":"none"}}}}}"#
        try Data(run.utf8).write(to: suite.appendingPathComponent("20261105-100000-R1.json"))
        try Data().write(to: folder.appendingPathComponent("letter.pdf"))

        let located = try XCTUnwrap(CollectionSettingsRecord.locate(from: folder.appendingPathComponent("letter.pdf")))
        let record = try XCTUnwrap(CollectionSettingsRecord.load(collectionFolder: located))
        XCTAssertEqual(record.latestRun?.reader, "Gemini, gemini-3.7-flash")
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: CollectionRecordContent(record: record, id: "ar.collectionRecord")
                .padding().frame(width: 340).background(.background).environment(\.colorScheme, scheme))
            let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: view, size: CGSize(width: 340, height: 260)))
            writeRenderArtifact(png, named: "collection-record-\(scheme).png")
            assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "collection record \(scheme)")
        }
    }
}
