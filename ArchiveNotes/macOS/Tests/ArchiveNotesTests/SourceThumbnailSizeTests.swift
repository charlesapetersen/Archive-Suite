import Testing
import AppKit
@testable import ArchiveNotes

/// W40.fix-notes-small-fixes (owner, notes-1 row 19): a source block's page thumbnail is drawn smaller than the
/// preview popover; other inline images keep their larger cap.
@Suite("Source thumbnails are drawn small")
@MainActor
struct SourceThumbnailSizeTests {

    private func page(width: CGFloat, height: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: width, height: height))
    }

    @Test("Only the names importThumbnail writes count as source thumbnails")
    func thumbnailNames() {
        for path in ["assets/p1-thumb.png", "assets/p12-thumb.png", "assets/doc-thumb.png",
                     "assets/p3-thumb-1.png", "assets/doc-thumb-12.png"] {
            #expect(SourceBlockPaster.isThumbnailAsset(path), "\(path)")
        }
        for path in ["assets/pasted-2026-11-05.png", "assets/photo.png", "p1-thumb.png", "assets/p-thumb.png",
                     "assets/p1-thumb.jpg", "assets/sub/p1-thumb.png", "assets/xp1-thumb.png", "assets/p1-thumb-.png"] {
            #expect(!SourceBlockPaster.isThumbnailAsset(path), "\(path)")
        }
    }

    @Test("A page thumbnail fits the source cap, keeping its shape")
    func thumbnailIsSmall() {
        // Reader's thumbnails are about 440 × 570 (EditorTextView's probe note).
        let a = InlineImageAttachment(relativePath: "assets/p3-thumb.png", thumbnail: page(width: 440, height: 570))
        let cap = InlineImageAttachment.maxSourceThumbnailSize
        #expect(a.bounds.height == cap.height)
        #expect(a.bounds.width <= cap.width)
        #expect(abs(a.bounds.width / a.bounds.height - 440.0 / 570.0) < 0.01)
        // Well under the 400 × 500 preview popover in both directions.
        #expect(a.bounds.width < 400 / 2 && a.bounds.height < 500 / 2)
    }

    @Test("A pasted image keeps the larger cap")
    func pastedImageIsUnchanged() {
        let a = InlineImageAttachment(relativePath: "assets/pasted-2026-11-05.png", thumbnail: page(width: 800, height: 600))
        #expect(a.bounds.size == InlineImageAttachment.maxImageSize)
        let small = InlineImageAttachment(relativePath: "assets/p1-thumb.png", thumbnail: page(width: 60, height: 80))
        #expect(small.bounds.size == CGSize(width: 60, height: 80))   // never enlarged
    }
}
