import XCTest
import SwiftUI
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class TagInspectorRenderTests: XCTestCase {
    func testInspectorRendersAtItsMinimumColumnWidth() throws {
        let model = NavigationModel(defaults: fixtureDefaults(), thumbnailer: nil)
        let files = [
            ArchiveFile(url: URL(fileURLWithPath: "/scratch/example.pdf"), name: "Example archival letter.pdf", fileType: "PDF",
                        tags: DocumentTags.parse(raw: ["Unread", "1984", "03 March", "Day 12", "Q2", "Blue", "History", "Letters"], labelNumber: nil), contentModified: nil),
            ArchiveFile(url: URL(fileURLWithPath: "/scratch/other.pdf"), name: "Other letter.pdf", fileType: "PDF",
                        tags: DocumentTags.parse(raw: ["Read", "1962", "History", "Other subject"], labelNumber: nil), contentModified: nil),
            // W40.fix-reader-date-fields: a document with a Sent-with date shows that section open.
            ArchiveFile(url: URL(fileURLWithPath: "/scratch/enclosure.pdf"), name: "Enclosure.pdf", fileType: "PDF",
                        tags: DocumentTags.parse(raw: ["1958", "Sent With 1958-03-12", "Sent With Date Uncertain"], labelNumber: nil), contentModified: nil)
        ]
        model.library.replaceFilesForTesting(files)
        for scheme in [ColorScheme.light, .dark] {
            for (name, paths) in [("empty", [String]()), ("single", [files[0].path]), ("group", [files[0].path, files[1].path]),
                                ("sent-with", [files[2].path])] {
                let view = NSHostingView(rootView: TagInspectorView(model: model, paths: paths, onClose: {}).environment(\.colorScheme, scheme))
                let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: view, size: CGSize(width: 340, height: 700)))
                writeRenderArtifact(png, named: "tag-inspector-\(name)-\(scheme).png")
                assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "Edit Info \(name)")
            }
        }
    }
}
