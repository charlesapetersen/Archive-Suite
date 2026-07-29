import XCTest

/// W15.tu0 — the platform premise the whole Wave-15 occurrence-aware undo/restore machinery rests on.
///
/// macOS Finder tags (`URLResourceKey.tagNamesKey`) preserve **duplicate strings verbatim** through a
/// write→read round-trip: `["A", "A", "B"]` reads back as two `A`s and one `B`, *not* the de-duplicated
/// `["A", "B"]`. Everything in Wave 15 (the occurrence-aware inverse `tagOccurrenceInverse`, the
/// multiplicity-aware apply/restore, the per-resolved-path write serializer) is only *necessary* — and
/// only *correct* — because this fact holds: if macOS silently collapsed duplicates there would be
/// nothing to preserve on undo, and a `Set`-based inverse would be sufficient.
///
/// This test PINS that fact authoritatively with a HARD assertion. The occurrence-aware *consumer*
/// tests (e.g. `TagWriterPrimitiveTests.testWriteExposesOccurrenceAwareInverseForDuplicates`)
/// `XCTSkipUnless`-guard the same premise so they degrade gracefully on a hypothetical
/// de-duplicating volume; this test is the single one that must hold. If a future platform/volume ever
/// collapses duplicate tag strings, this fails LOUDLY — the signal we want, since undo/restore
/// correctness silently depends on it. Recorded in `SPEC/tag-format.md` beside the multiset rule.
///
/// Pure Foundation round-trip on a throwaway temp file (the `TagWriterPrimitiveTests.makeFile` pattern:
/// temp dir + teardown) — never the corpus (Prime Directive #1).
final class DuplicateTagPremiseTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// `["A", "A", "B"]` written via `.tagNamesKey` survives a write→read round-trip as a multiset with
    /// TWO copies of `A` — macOS does not de-duplicate the tag array on write.
    func testDuplicateTagStringsSurviveTagNamesKeyRoundTrip() throws {
        let url = tempDir.appendingPathComponent("dup-premise.pdf")
        try Data("PDF-BYTES-\(UUID().uuidString)".utf8).write(to: url)

        let written = ["A", "A", "B"]
        try (url as NSURL).setResourceValue(written, forKey: .tagNamesKey)

        let readBack = (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []

        // Multiset equality (order is not guaranteed; macOS may reorder on write — SPEC §"Finder tag model").
        XCTAssertEqual(readBack.sorted(), written.sorted(),
                       "macOS must persist duplicate tag strings verbatim; got \(readBack)")
        XCTAssertEqual(readBack.filter { $0 == "A" }.count, 2,
                       "both copies of the duplicated tag 'A' survived the round-trip")
        XCTAssertEqual(readBack.count, 3, "no tag string was dropped or added")
    }
}
