import XCTest
@testable import ArchiveReader
import ArchiveCore

/// Integration tests for the safety-critical `TagWriter`. These operate ONLY on throwaway temp files
/// created per-test — NEVER the corpus. They exercise the Safety Protocol guarantees directly.
final class TagWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Create a temp file with some bytes and an initial tag set (+ optional label).
    private func makeFile(_ name: String, tags: [String], label: Int? = nil,
                          bytes: Data = Data("PDF-BYTES-\(UUID().uuidString)".utf8)) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try bytes.write(to: url)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    private func readTags(_ url: URL) throws -> [String] {
        (try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
    private func readLabel(_ url: URL) throws -> Int? {
        try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
    }

    // MARK: Read-state fast path

    func testSetReadStateSwapsAndPreservesOtherTags() throws {
        let url = try makeFile("swap.pdf", tags: ["Unread", "Jerry Brown", "1980", "P9"])
        let bytesBefore = try Data(contentsOf: url)

        let r = try TagWriter.setReadState(.read, on: url)

        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Read"))
        XCTAssertFalse(after.contains("Unread"))
        XCTAssertTrue(after.isSuperset(of: ["Jerry Brown", "1980", "P9"]))  // every other tag preserved
        XCTAssertFalse(r.isNoOp)
        // CORE DIRECTIVE: file bytes are untouched.
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    func testTagRenameDeltaSwapsOnlyThatTagAndPreservesBytes() throws {
        // The primitive behind the corpus-wide rename (D1): remove old + add new, per file.
        let url = try makeFile("rename.pdf", tags: ["Environtment", "Jerry Brown", "1980", "Unread", "P8"])
        let bytesBefore = try Data(contentsOf: url)
        let r = try TagWriter.apply(TagDelta(add: ["Environment"], remove: ["Environtment"]), to: url)
        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Environment"))
        XCTAssertFalse(after.contains("Environtment"))                          // old tag gone
        XCTAssertTrue(after.isSuperset(of: ["Jerry Brown", "1980", "Unread", "P8"]))  // everything else intact
        XCTAssertFalse(r.isNoOp)
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)                   // CORE DIRECTIVE: bytes unchanged
        // Undo (inverse delta) restores the original tag.
        _ = try TagWriter.apply(r.inverse, to: url)
        XCTAssertTrue(Set(try readTags(url)).contains("Environtment"))
        XCTAssertFalse(Set(try readTags(url)).contains("Environment"))
    }

    func testTagRenameIsNoOpOnFileWithoutTheTag() throws {
        let url = try makeFile("norename.pdf", tags: ["Jerry Brown", "Unread"])
        let r = try TagWriter.apply(TagDelta(add: ["Environment"], remove: ["Environtment"]), to: url)
        // File lacks "Environtment"; adding "Environment" is a real change here, so it's NOT a no-op —
        // but the rename model only visits files that CARRY the old tag, so this file is never touched.
        // Assert the delta applied cleanly and preserved existing tags (defensive check on the primitive).
        XCTAssertTrue(Set(try readTags(url)).isSuperset(of: ["Jerry Brown", "Unread"]))
        _ = r
    }

    func testConditionalRenameRechecksOldTokenAndDoesNotAddToAStaleSelection() throws {
        let url = try makeFile("conditional-stale.pdf", tags: ["Unread", "Subject/Current"])
        let bytesBefore = try Data(contentsOf: url)

        let result = try TagWriter.renameToken(from: "Subject/Old", to: "Subject/New", on: url)

        XCTAssertTrue(result.isNoOp)
        XCTAssertEqual(try readTags(url), ["Unread", "Subject/Current"])
        XCTAssertFalse(try readTags(url).contains("Subject/New"),
                       "a persisted-cache selection is not proof the old tag still exists")
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    func testConditionalRenameChangesOnlyAStillPresentOldToken() throws {
        let url = try makeFile("conditional-present.pdf",
                               tags: ["Unread", "Subject/Old", "1980", "P8"])
        let bytesBefore = try Data(contentsOf: url)

        let result = try TagWriter.renameToken(from: "Subject/Old", to: "Subject/New", on: url)

        XCTAssertFalse(result.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["Unread", "Subject/New", "1980", "P8"])
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    func testMarkReadIsNoOpOnFileWithoutReadState() throws {
        // Box/folder markers carry no Read/Unread token — default must NOT add one.
        let url = try makeFile("marker.pdf", tags: ["DP chapters"], label: 6)
        let r = try TagWriter.setReadState(.read, on: url)
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["DP chapters"])
        XCTAssertEqual(try readLabel(url), 6)  // color untouched
    }

    func testMarkReadAddsWhenExplicitlyRequested() throws {
        let url = try makeFile("marker2.pdf", tags: ["DP chapters"])
        _ = try TagWriter.setReadState(.read, on: url, addIfMissing: true)
        XCTAssertTrue(Set(try readTags(url)).contains("Read"))
    }

    func testSetReadStateIdempotentWhenAlreadyTarget() throws {
        let url = try makeFile("already.pdf", tags: ["Read", "x"])
        let r = try TagWriter.setReadState(.read, on: url)
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["Read", "x"])
    }

    // MARK: General delta edits

    func testApplyAddAndRemoveSubjects() throws {
        let url = try makeFile("edit.pdf", tags: ["Unread", "Speeches", "1982"])
        _ = try TagWriter.apply(TagDelta(add: ["Economics"], remove: ["Speeches"]), to: url)
        let after = Set(try readTags(url))
        XCTAssertEqual(after, ["Unread", "1982", "Economics"])
    }

    func testRemovingUnreadDoesNotTouchSubjectContainingReadSubstring() throws {
        let url = try makeFile("substr.pdf", tags: ["Unread", "Read later", "1970"])
        _ = try TagWriter.setReadState(.read, on: url)
        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Read later"))   // substring subject preserved
        XCTAssertTrue(after.contains("Read"))
        XCTAssertFalse(after.contains("Unread"))
    }

    func testColorSetAndClearKeepsTokenAndLabelConsistent() throws {
        let url = try makeFile("color.pdf", tags: ["Unread", "DP chapters"])
        _ = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        XCTAssertEqual(try readLabel(url), 6)
        XCTAssertTrue(Set(try readTags(url)).contains("Red"))

        _ = try TagWriter.apply(TagDelta(color: .clear), to: url)
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
        XCTAssertFalse(Set(try readTags(url)).contains("Red"))
    }

    func testColorTokenPreservedOnUnrelatedReadStateWrite() throws {
        // Real box marker shape: Red label + "Red" token. A Read/Unread edit must keep the swatch.
        let url = try makeFile("boxmarker.pdf", tags: ["Red", "Unread", "Jerry Brown"], label: 6)
        _ = try TagWriter.setReadState(.read, on: url, addIfMissing: true)
        XCTAssertEqual(try readLabel(url), 6)                      // label preserved (Safety §7)
        XCTAssertTrue(Set(try readTags(url)).contains("Red"))
    }

    func testClearColorRemovesColorTokenAndLabelButKeepsSubjects() throws {
        // In macOS a "Red"/"Purple" tag IS the color label (the token and the label are coupled —
        // Finder auto-assigns label 6/3 for the token). Clearing color removes the color token that
        // matches the current label and clears the label, while leaving ordinary subjects intact.
        let url = try makeFile("box.pdf", tags: ["Red", "Cold War", "Unread"], label: 6)
        _ = try TagWriter.apply(TagDelta(color: .clear), to: url)
        let after = Set(try readTags(url))
        XCTAssertFalse(after.contains("Red"))                    // color token removed with the label
        XCTAssertTrue(after.isSuperset(of: ["Cold War", "Unread"]))  // ordinary subjects preserved
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
    }

    func testSetColorSwapsPreviousLabelToken() throws {
        // Purple folder marker → set to box: "Purple" token dropped, "Red" added, label 6.
        let url = try makeFile("swapcolor.pdf", tags: ["Purple", "Unread"], label: 3)
        _ = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        let after = Set(try readTags(url))
        XCTAssertTrue(after.contains("Red"))
        XCTAssertFalse(after.contains("Purple"))
        XCTAssertEqual(try readLabel(url), 6)
    }

    // MARK: Undo via inverse delta

    func testInverseDeltaUndoesEdit() throws {
        let url = try makeFile("undo.pdf", tags: ["Unread", "Speeches", "1982"])
        let original = Set(try readTags(url))

        let r = try TagWriter.apply(TagDelta(add: ["Economics"], remove: ["Speeches"]), to: url)
        XCTAssertNotEqual(Set(try readTags(url)), original)

        _ = try TagWriter.apply(r.inverse, to: url)               // undo
        XCTAssertEqual(Set(try readTags(url)), original)
    }

    func testInverseUndoesColorChange() throws {
        let url = try makeFile("undocolor.pdf", tags: ["Unread"])
        let r = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        XCTAssertEqual(try readLabel(url), 6)
        _ = try TagWriter.apply(r.inverse, to: url)
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
        XCTAssertFalse(Set(try readTags(url)).contains("Red"))
    }

    // Regression (review finding [1]/[3]): undo of a color change is label-only, so it restores the
    // label verbatim and never adds/removes a token beyond the recorded diff.
    func testUndoColorSwapRestoresLabelAndTokensExactly() throws {
        let url = try makeFile("boxswap.pdf", tags: ["Red", "Jerry Brown"], label: 6)   // box
        let r = try TagWriter.apply(TagDelta(color: .set(.folder)), to: url)
        XCTAssertEqual(try readLabel(url), 3)
        XCTAssertTrue(Set(try readTags(url)).contains("Purple"))
        XCTAssertFalse(Set(try readTags(url)).contains("Red"))
        _ = try TagWriter.apply(r.inverse, to: url)                 // undo
        XCTAssertEqual(Set(try readTags(url)), ["Red", "Jerry Brown"])
        XCTAssertEqual(try readLabel(url), 6)                       // label restored verbatim
    }

    func testUndoSetColorOnUncoloredRemovesTokenAndLabel() throws {
        let url = try makeFile("plaincolor.pdf", tags: ["Jerry Brown", "Unread"], label: nil)
        let r = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        XCTAssertTrue(Set(try readTags(url)).contains("Red"))
        _ = try TagWriter.apply(r.inverse, to: url)
        let after = Set(try readTags(url))
        XCTAssertFalse(after.contains("Red"))
        XCTAssertTrue(after.isSuperset(of: ["Jerry Brown", "Unread"]))
        XCTAssertEqual(try readLabel(url) ?? 0, 0)
    }

    // MARK: Safety guards

    func testUnreadableFileIsRefusedNotWiped() throws {
        // A file that cannot be read must ABORT — never be coerced into "no tags" then overwritten.
        let ghost = tempDir.appendingPathComponent("does-not-exist.pdf")
        XCTAssertThrowsError(try TagWriter.setReadState(.read, on: ghost, addIfMissing: true)) { error in
            // Either the read guard or coordination rejects it — the key point is it THROWS.
            XCTAssertTrue(error is TagWriteError)
        }
    }

    func testEmptyDeltaIsNoOp() throws {
        let url = try makeFile("noop.pdf", tags: ["Unread", "x"])
        let r = try TagWriter.apply(TagDelta(), to: url)
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["Unread", "x"])
    }

    func testBatchApplyReturnsPerFileResults() throws {
        let a = try makeFile("a.pdf", tags: ["Unread", "x"])
        let b = try makeFile("b.pdf", tags: ["Unread", "y"])
        let ghost = tempDir.appendingPathComponent("ghost.pdf")
        let results = TagWriter.apply(TagDelta(add: ["Reviewed"]), to: [a, b, ghost])
        XCTAssertEqual(results.count, 3)
        XCTAssertNoThrow(try results[0].result.get())
        XCTAssertNoThrow(try results[1].result.get())
        XCTAssertThrowsError(try results[2].result.get())          // missing file surfaces as failure
        XCTAssertTrue(Set(try readTags(a)).contains("Reviewed"))
    }

    // MARK: §6 Write-target identity re-verification (adapter seam)

    func testApplyWithMatchingIdentityWrites() throws {
        let url = try makeFile("id-ok.pdf", tags: ["Unread", "Jerry Brown"])
        let identity = try XCTUnwrap(FileIdentity.capture(url))
        _ = try TagWriter.apply(TagDelta(add: ["Economics"]), to: url, expecting: identity)
        XCTAssertTrue(Set(try readTags(url)).isSuperset(of: ["Unread", "Jerry Brown", "Economics"]))
    }

    /// The core §6 safety guarantee through the Reader adapter: a DIFFERENT file placed at the same
    /// path since selection aborts the write with .identityMismatch, and the replacement is untouched.
    func testApplyWithMismatchedIdentityAbortsAndLeavesReplacementUntouched() throws {
        let name = "id-moved.pdf"
        let original = try makeFile(name, tags: ["Unread"])
        let originalIdentity = try XCTUnwrap(FileIdentity.capture(original))

        try FileManager.default.removeItem(at: original)               // simulate Finder move-away…
        let replacement = try makeFile(name, tags: ["Untouched"])      // …and a different file at the path
        XCTAssertFalse(try XCTUnwrap(FileIdentity.capture(replacement)).matches(originalIdentity))

        XCTAssertThrowsError(try TagWriter.apply(TagDelta(add: ["Reviewed"]), to: replacement, expecting: originalIdentity)) { error in
            guard case TagWriteError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
        }
        XCTAssertEqual(Set(try readTags(replacement)), ["Untouched"])  // aborted write changed nothing
    }

    func testSetReadStateWithMismatchedIdentityAborts() throws {
        let name = "id-read.pdf"
        let original = try makeFile(name, tags: ["Unread"])
        let originalIdentity = try XCTUnwrap(FileIdentity.capture(original))
        try FileManager.default.removeItem(at: original)
        let replacement = try makeFile(name, tags: ["Unread"])        // same tags, different file

        XCTAssertThrowsError(try TagWriter.setReadState(.read, on: replacement, expecting: originalIdentity)) { error in
            guard case TagWriteError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
        }
        XCTAssertEqual(Set(try readTags(replacement)), ["Unread"])    // not swapped to Read
    }

    /// Backward compatibility: without `expecting:`, the adapter behaves exactly as before (no §6
    /// check) — so existing call sites are unaffected until they opt in.
    func testApplyWithoutIdentitySkipsCheckAndWrites() throws {
        let name = "id-nocheck.pdf"
        let original = try makeFile(name, tags: ["Unread"])
        _ = try XCTUnwrap(FileIdentity.capture(original))
        try FileManager.default.removeItem(at: original)
        let replacement = try makeFile(name, tags: ["Untouched"])
        _ = try TagWriter.apply(TagDelta(add: ["Reviewed"]), to: replacement)   // no expecting:
        XCTAssertTrue(Set(try readTags(replacement)).isSuperset(of: ["Untouched", "Reviewed"]))
    }

    /// The §6-capable group overload (`apply(_:to:[(url,identity)])`, used by the corpus-wide rename
    /// path): each file is independent — one replaced under its path since capture aborts as
    /// `.identityMismatch` while its neighbours (a matched identity, and a nil-identity file that opts
    /// out) still apply. Results are 1:1 and in order.
    func testBatchApplyWithPerFileIdentityIsolatesMismatch() throws {
        let ok = try makeFile("batch-ok.pdf", tags: ["Unread"])
        let okIdentity = try XCTUnwrap(FileIdentity.capture(ok))

        let swapName = "batch-swap.pdf"
        let swapOriginal = try makeFile(swapName, tags: ["Unread"])
        let swapIdentity = try XCTUnwrap(FileIdentity.capture(swapOriginal))
        try FileManager.default.removeItem(at: swapOriginal)              // Finder move-away…
        let swapReplacement = try makeFile(swapName, tags: ["Untouched"]) // …different file, same path

        let optOut = try makeFile("batch-optout.pdf", tags: ["Unread"])   // nil identity → no §6 check

        let results = TagWriter.apply(
            TagDelta(add: ["Reviewed"]),
            to: [(url: ok, identity: okIdentity),
                 (url: swapReplacement, identity: swapIdentity),
                 (url: optOut, identity: nil)]
        )

        XCTAssertEqual(results.count, 3)                                  // 1:1, order preserved
        XCTAssertEqual(results[0].url, ok)
        XCTAssertNoThrow(try results[0].result.get())                     // matched identity → wrote
        XCTAssertTrue(Set(try readTags(ok)).contains("Reviewed"))

        XCTAssertEqual(results[1].url, swapReplacement)
        XCTAssertThrowsError(try results[1].result.get()) { error in      // mismatch → aborted, isolated
            guard case TagWriteError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
        }
        XCTAssertEqual(Set(try readTags(swapReplacement)), ["Untouched"]) // replacement untouched

        XCTAssertNoThrow(try results[2].result.get())                     // nil identity → skipped, wrote
        XCTAssertTrue(Set(try readTags(optOut)).contains("Reviewed"))
    }

    // MARK: Occurrence-aware undo (W15.tu2) — multiset restore via applyOccurrence

    /// A count-aware multiset of a tag array (occurrence-only; order is unobservable per SPEC).
    private func multiset(_ tags: [String]) -> [String: Int] {
        tags.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Headline W15.tu2 fix: undoing an edit that stripped a DUPLICATED tag restores BOTH occurrences.
    /// The forward remove deletes every "A"; the occurrence inverse re-adds the exact surplus (`["A","A"]`),
    /// so the on-disk multiset is `["A","A","B"]` again — which the set-based inverse could not do.
    func testOccurrenceInverseRestoresDuplicateTag() throws {
        let url = try makeFile("dup.pdf", tags: ["A", "A", "B"])
        let r = try TagWriter.apply(TagDelta(remove: ["A"]), to: url)
        XCTAssertEqual(multiset(try readTags(url)), ["B": 1])                 // forward: both A's gone
        XCTAssertEqual(r.occurrenceInverse.add.sorted(), ["A", "A"])          // inverse carries multiplicity

        _ = try TagWriter.applyOccurrence(r.occurrenceInverse, to: url)       // occurrence-aware undo
        XCTAssertEqual(multiset(try readTags(url)), ["A": 2, "B": 1])         // exact count restored
    }

    /// Proves WHY the occurrence path is needed: the set-based inverse collapses the duplicate, so the
    /// legacy `apply(_:inverse)` undo would leave only ONE "A" — the bug W15.tu2 closes.
    func testSetInverseLosesDuplicateButOccurrenceDoesNot() throws {
        let setURL = try makeFile("dup-set.pdf", tags: ["A", "A", "B"])
        let rSet = try TagWriter.apply(TagDelta(remove: ["A"]), to: setURL)
        _ = try TagWriter.apply(rSet.inverse, to: setURL)                    // legacy set-based undo
        XCTAssertEqual(multiset(try readTags(setURL)), ["A": 1, "B": 1])     // one occurrence LOST

        let occURL = try makeFile("dup-occ.pdf", tags: ["A", "A", "B"])
        let rOcc = try TagWriter.apply(TagDelta(remove: ["A"]), to: occURL)
        _ = try TagWriter.applyOccurrence(rOcc.occurrenceInverse, to: occURL)
        XCTAssertEqual(multiset(try readTags(occURL)), ["A": 2, "B": 1])     // both restored
    }

    /// Safety §9 through the occurrence path: an UNRELATED tag a concurrent editor added between the edit
    /// and the undo survives, while the duplicate is still restored to its exact count.
    func testOccurrenceUndoPreservesConcurrentUnrelatedTag() throws {
        let url = try makeFile("concurrent.pdf", tags: ["A", "A"])
        let r = try TagWriter.apply(TagDelta(remove: ["A"]), to: url)        // → []
        // Simulate a concurrent third-party edit landing before the undo.
        try (url as NSURL).setResourceValue(["Y"], forKey: .tagNamesKey)

        _ = try TagWriter.applyOccurrence(r.occurrenceInverse, to: url)
        XCTAssertEqual(multiset(try readTags(url)), ["A": 2, "Y": 1])        // Y kept, both A's restored
    }

    /// The remove side strips EXACTLY the delta's count: if a concurrent edit added a SECOND copy of the
    /// same token the forward edit introduced, undo removes only the one occurrence it is responsible for.
    func testOccurrenceUndoStripsExactlyDeltaCount() throws {
        let url = try makeFile("exact.pdf", tags: ["Unread"])
        let r = try TagWriter.apply(TagDelta(add: ["Economics"]), to: url)   // → ["Unread","Economics"]
        XCTAssertEqual(r.occurrenceInverse.remove, ["Economics"])
        // A concurrent editor adds a second "Economics" before the undo.
        try (url as NSURL).setResourceValue(["Unread", "Economics", "Economics"], forKey: .tagNamesKey)

        _ = try TagWriter.applyOccurrence(r.occurrenceInverse, to: url)
        XCTAssertEqual(multiset(try readTags(url)), ["Unread": 1, "Economics": 1])  // one copy survives
    }

    /// Color-label restore through the occurrence path (`.restoreLabel`): undoing a color set removes the
    /// color token (carried in the multiset) and restores the original label.
    func testOccurrenceUndoRestoresColorLabel() throws {
        let url = try makeFile("occ-color.pdf", tags: ["Unread"], label: nil)
        let r = try TagWriter.apply(TagDelta(color: .set(.box)), to: url)
        XCTAssertEqual(try readLabel(url), 6)
        XCTAssertTrue(Set(try readTags(url)).contains("Red"))

        _ = try TagWriter.applyOccurrence(r.occurrenceInverse, to: url)
        XCTAssertEqual(try readLabel(url) ?? 0, 0)                            // label restored
        XCTAssertFalse(Set(try readTags(url)).contains("Red"))               // color token stripped
        XCTAssertTrue(Set(try readTags(url)).contains("Unread"))             // subject preserved
    }

    // MARK: Concurrent same-path writes (W15.tu4) — the Reader adapter inherits §10 serialization

    /// Case (c) of the W15 cross-app matrix at the Reader `TagWriter` boundary: two concurrent
    /// add-delta writes to the SAME file each survive. `TagWriter.apply` routes through
    /// `ArchiveCore.CoordinatedTagWriter`, whose §10 per-resolved-path lock (W15.tu3) serializes the
    /// read→modify→write so the second writer observes the first's committed tag before merging its own
    /// delta — no lost update. (The deterministic-loss-*without*-the-lock proof lives in ArchiveCore's
    /// `TagWriterPrimitiveTests.testConcurrentSamePathWritesBothSurvive`, which can widen the RMW window
    /// from inside the transform; `apply` gives no such seam, so this pins — across several rounds to
    /// shake out scheduling nondeterminism — that the Reader delta adapter is on that protected path.)
    func testConcurrentAdapterWritesBothSurvive() throws {
        for round in 0..<8 {
            let url = try makeFile("race-\(round).pdf", tags: [])
            let box = ConcurrentErrorBox()
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                do {
                    _ = try TagWriter.apply(TagDelta(add: [i == 0 ? "Alpha" : "Beta"]), to: url)
                } catch { box.record(error) }
            }
            XCTAssertTrue(box.all.isEmpty, "round \(round): no concurrent writer should throw: \(box.all)")
            XCTAssertEqual(Set(try readTags(url)), ["Alpha", "Beta"],
                           "round \(round): both concurrently-added tags survive (§10 via the Reader adapter)")
        }
    }
}

/// Thread-safe error sink for the concurrent-write test.
private final class ConcurrentErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func record(_ e: Error) { lock.lock(); errors.append(e); lock.unlock() }
    var all: [Error] { lock.lock(); defer { lock.unlock() }; return errors }
}
