import XCTest
@testable import ArchiveCore

/// Tests for `CoordinatedTagWriter.write` — the shared coordinated-write primitive.
/// Exercises the Safety Protocol guarantees directly on throwaway temp files (never the corpus).
final class TagWriterPrimitiveTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeFile(_ name: String, tags: [String], label: Int? = nil) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("PDF-BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    /// Read-back helpers go through a NEW `URL`: a reused one answers from its resource-value cache and
    /// would never see a write made through another object (W40.fix-identity-url-cache).
    private func readTags(_ url: URL) throws -> [String] {
        (try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
    private func readLabel(_ url: URL) throws -> Int? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.labelNumberKey]).labelNumber
    }
    /// Fill `url`'s own resource-value cache with its tags, label and identity, as a discovery enumerator
    /// or an earlier read would have; the cache-sensitivity tests start from this state.
    private func prime(_ url: URL) throws {
        _ = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey, .fileResourceIdentifierKey])
    }

    // MARK: §3 Trustworthy-read guard — unreadable file ABORTS

    func testUnreadableFileAborts() throws {
        let ghost = tempDir.appendingPathComponent("does-not-exist.pdf")
        XCTAssertThrowsError(try CoordinatedTagWriter.write(ghost) { _, _ in (["x"], nil) }) { error in
            XCTAssertTrue(error is TagWriteError)
        }
    }

    // MARK: No-op transform returns no-op result

    func testNilTransformIsNoOp() throws {
        let url = try makeFile("noop.pdf", tags: ["Unread", "x"])
        let r = try CoordinatedTagWriter.write(url) { _, _ in nil }
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(Set(try readTags(url)), ["Unread", "x"])
    }

    // MARK: §8 Verify by re-read — multiset equality

    func testWriteAndVerifyRoundTrip() throws {
        let url = try makeFile("verify.pdf", tags: ["A", "B"])
        let r = try CoordinatedTagWriter.write(url) { current, label in
            (current + ["C"], label)
        }
        XCTAssertFalse(r.isNoOp)
        XCTAssertTrue(multisetEqual(r.after, ["A", "B", "C"]))
        XCTAssertTrue(multisetEqual(try readTags(url), ["A", "B", "C"]))
    }

    /// The tag verify must be seen to fire: macOS drops an empty tag name on write, so the re-read
    /// differs from the intended array and the write throws `.verificationFailed` (W40.e7 mutant C06).
    func testTagVerifyFailsWhenTheReReadDiffers() throws {
        let url = try makeFile("verify-tags.pdf", tags: ["A"])
        XCTAssertThrowsError(try CoordinatedTagWriter.write(url) { current, label in
            (current + [""], label)
        }) { error in
            guard case let TagWriteError.verificationFailed(why) = error else {
                return XCTFail("expected .verificationFailed, got \(error)")
            }
            XCTAssertTrue(why.hasPrefix("tag mismatch"), why)
        }
        XCTAssertEqual(try readTags(url), ["A"], "test premise: macOS dropped the empty name")
    }

    /// The label verify must be seen to fire: macOS stores an out-of-range label (9) as no label, so
    /// the re-read differs and the write throws `.verificationFailed` (W40.e7 mutant C07).
    func testLabelVerifyFailsWhenTheReReadDiffers() throws {
        let url = try makeFile("verify-label.pdf", tags: ["A"])
        XCTAssertThrowsError(try CoordinatedTagWriter.write(url) { current, _ in
            (current, 9)
        }) { error in
            guard case let TagWriteError.verificationFailed(why) = error else {
                return XCTFail("expected .verificationFailed, got \(error)")
            }
            XCTAssertTrue(why.hasPrefix("label mismatch"), why)
        }
        XCTAssertEqual(normalizedLabel(try readLabel(url)), 0, "test premise: macOS did not keep label 9")
    }

    /// Multiset equality counts duplicates: the verify must not accept a re-read that lost one
    /// occurrence of a duplicated tag (W40.e7 mutant C12).
    func testMultisetEqualCountsDuplicates() {
        XCTAssertFalse(multisetEqual(["A", "A"], ["A"]))
        XCTAssertFalse(multisetEqual(["A"], ["A", "A"]))
        XCTAssertTrue(multisetEqual(["B", "A", "A"], ["A", "B", "A"]))
    }

    // MARK: Removal matching — whole token, never substring

    /// Removing subject "Smith" leaves "Smithson" (the "never substring" promise in `shouldRemoveTag`'s
    /// doc comment; W40.e7 mutant C11), and through the write primitive as the apps call it.
    func testRemovingASubjectLeavesALongerOneSharingItsPrefix() throws {
        XCTAssertTrue(shouldRemoveTag("Smith", matching: "Smith"))
        XCTAssertFalse(shouldRemoveTag("Smithson", matching: "Smith"))
        XCTAssertFalse(shouldRemoveTag("Unread later", matching: "Unread"))

        let url = try makeFile("untag-prefix.pdf", tags: ["Smith", "Smithson"])
        _ = try CoordinatedTagWriter.write(url) { current, label in
            (current.filter { !shouldRemoveTag($0, matching: "Smith") }, label)
        }
        XCTAssertEqual(try readTags(url), ["Smithson"])
    }

    // MARK: Tag identity — case-insensitive, spelling kept (W40.fix-tags-case-insensitive)

    func testTagsThatDifferOnlyInCaseAreOneTag() {
        XCTAssertTrue(isSameTag("Lincoln", "lincoln"))
        XCTAssertTrue(isSameTag("LINCOLN", "Lincoln"))
        XCTAssertTrue(isSameTag("Straße", "STRASSE"), "full case folding, not lowercasing")
        XCTAssertTrue(isSameTag("Café", "Cafe\u{301}"), "canonically equivalent spellings stay one tag")
        XCTAssertFalse(isSameTag("Lincoln", "Lincolnshire"))
        XCTAssertFalse(isSameTag("Cafe", "Café"), "accents are not folded")
        XCTAssertEqual(tagKey("Lincoln"), tagKey("lINCOLN"))
        XCTAssertTrue(shouldRemoveTag("lincoln", matching: "Lincoln"))
        XCTAssertFalse(shouldRemoveTag("lincoln papers", matching: "Lincoln"))
        XCTAssertTrue(isSameTag("unread", "Unread"), "Read/Unread still match in any case")
        XCTAssertTrue(shouldRemoveTag("READ", matching: "Read"))
    }

    /// A facet the parser reads by its exact spelling keeps its case as its identity: the rating `Q2` and a
    /// fiscal-quarter subject `q2`, the box marker's `Red` and a subject `red`, are different tags, so a
    /// rating or colour edit never adds, skips or removes the other one (Tier-2 review finding).
    func testFacetShapedTokensKeepTheirExactCase() {
        for (facet, subject) in [("Q2", "q2"), ("P9", "p9 "), ("Red", "red"), ("Purple", "PURPLE"),
                                 ("03 March", "03 march"), ("Sent With 1958", "sent with 1958"),
                                 ("Date Uncertain", "date uncertain"), ("1970s", "1970S")] {
            XCTAssertFalse(isSameTag(facet, subject), "\(facet) / \(subject)")
            XCTAssertFalse(shouldRemoveTag(subject, matching: facet), "\(facet) / \(subject)")
            XCTAssertFalse(shouldRemoveTag(facet, matching: subject), "\(facet) / \(subject)")
            XCTAssertNotEqual(tagKey(subject), tagKey(facet), "\(facet) / \(subject)")
        }
        XCTAssertTrue(keepsExactCase("Q2") && keepsExactCase("Red") && keepsExactCase("1958"))
        XCTAssertFalse(keepsExactCase("Lincoln") || keepsExactCase("Red Scare") || keepsExactCase("Read"))
        XCTAssertTrue(isSameTag("Red Scare", "red scare"), "a subject merely starting with a colour folds")
    }

    func testTagCountsGroupCaseVariantsInTheMostUsedSpelling() {
        let files = [["Lincoln", "lincoln"], ["lincoln"], ["LINCOLN", "Grant"], ["Lincoln"], ["Lincoln"]]
        let counts = Dictionary(uniqueKeysWithValues: tagCounts(files).map { ($0.tag, $0.count) })
        XCTAssertEqual(counts, ["Lincoln": 5, "Grant": 1], "once per file, in the spelling most files use")
        // A tie goes to the spelling that sorts first, whatever the file order.
        XCTAssertEqual(tagCounts([["b"], ["B"]]).map(\.tag), ["B"])
        XCTAssertEqual(tagCounts([["B"], ["b"]]).map(\.tag), ["B"])
        XCTAssertEqual(tagCounts([["1958", "Lincoln"]], include: { $0 != "1958" }).map(\.tag), ["Lincoln"])
    }

    /// Through the write primitive, the remove-then-add the Reader's delta adapter makes: removing one
    /// spelling takes every case of it and leaves the rest of the file verbatim.
    func testRemovingATagTakesEveryCaseOfIt() throws {
        let url = try makeFile("untag-case.pdf", tags: ["Lincoln", "lincoln", "Grant", "Lincolnshire"])
        _ = try CoordinatedTagWriter.write(url) { current, label in
            (current.filter { !shouldRemoveTag($0, matching: "LINCOLN") }, label)
        }
        XCTAssertEqual(try readTags(url), ["Grant", "Lincolnshire"])
    }

    // MARK: §7 Label written only when changed; drift restored

    func testLabelPreservedWhenTransformDoesNotChangeIt() throws {
        let url = try makeFile("labeldrift.pdf", tags: ["Unread", "Red"], label: 6)
        _ = try CoordinatedTagWriter.write(url) { current, label in
            // Replace "Unread" with "Read" but keep label the same
            (current.map { $0 == "Unread" ? "Read" : $0 }, label)
        }
        XCTAssertEqual(try readLabel(url), 6)
    }

    func testLabelChangedWhenTransformSetsIt() throws {
        let url = try makeFile("labelchange.pdf", tags: ["A"], label: nil)
        _ = try CoordinatedTagWriter.write(url) { current, _ in
            (current + ["Red"], 6)
        }
        XCTAssertEqual(try readLabel(url), 6)
    }

    // MARK: §9 Inverse delta

    func testInverseDeltaIsCorrect() throws {
        let url = try makeFile("inverse.pdf", tags: ["A", "B"])
        let r = try CoordinatedTagWriter.write(url) { _, label in
            (["A", "C"], label)
        }
        // Inverse should add "B" (was removed) and remove "C" (was added)
        XCTAssertTrue(r.inverse.add.contains("B"))
        XCTAssertTrue(r.inverse.remove.contains("C"))
    }

    // MARK: File bytes untouched

    func testFileBytesPreserved() throws {
        let url = try makeFile("bytes.pdf", tags: ["Unread"])
        let bytesBefore = try Data(contentsOf: url)
        _ = try CoordinatedTagWriter.write(url) { _, label in
            (["Read"], label)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    // MARK: TagReading integration

    func testTagReadingReadSuccess() throws {
        let url = try makeFile("read.pdf", tags: ["Jerry Brown", "1980"], label: 6)
        let result = TagReading.read(url)
        guard case let .success(tagNames, labelNumber) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(Set(tagNames), ["Jerry Brown", "1980"])
        XCTAssertEqual(labelNumber, 6)
    }

    func testTagReadingReadFailure() {
        let ghost = tempDir.appendingPathComponent("ghost.pdf")
        let result = TagReading.read(ghost)
        XCTAssertNil(result.tagNames)
    }

    func testTagReadingReadTagsReturnsParsedFacets() throws {
        let url = try makeFile("facets.pdf", tags: ["1980", "P9", "Unread", "Jerry Brown"], label: 6)
        let tags = TagReading.readTags(url)
        XCTAssertNotNil(tags)
        XCTAssertEqual(tags?.year, 1980)
        XCTAssertEqual(tags?.quality, 2)
        XCTAssertEqual(tags?.readState, .unread)
        XCTAssertEqual(tags?.color, .box)
    }

    // MARK: §6 Write-target identity re-verification

    /// Matching identity → the write proceeds normally.
    func testIdentityMatchAllowsWrite() throws {
        let url = try makeFile("id-match.pdf", tags: ["Unread"])
        let identity = try XCTUnwrap(FileIdentity.capture(url))
        let r = try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
            (current + ["Read"], label)
        }
        XCTAssertFalse(r.isNoOp)
        XCTAssertTrue(multisetEqual(try readTags(url), ["Unread", "Read"]))
    }

    /// A DIFFERENT file was put at the same path since discovery → the write ABORTS with
    /// .identityMismatch and the replacement file is left untouched (never tag the wrong file).
    func testReplacedFileAbortsAndLeavesReplacementUntouched() throws {
        let name = "id-swap.pdf"
        let original = try makeFile(name, tags: ["Unread"])
        let originalIdentity = try XCTUnwrap(FileIdentity.capture(original))

        // Replace with a genuinely different file (delete → recreate ⇒ new inode ⇒ new identity).
        try FileManager.default.removeItem(at: original)
        let replacement = try makeFile(name, tags: ["Untouched"])
        // Precondition guards the test itself: the replacement must have a distinct identity.
        let replacementIdentity = try XCTUnwrap(FileIdentity.capture(replacement))
        XCTAssertFalse(replacementIdentity.matches(originalIdentity),
                       "test setup: delete+recreate should yield a distinct file identity")

        XCTAssertThrowsError(try CoordinatedTagWriter.write(replacement, expectedIdentity: originalIdentity) { current, label in
            (current + ["Reviewed"], label)
        }) { error in
            guard case TagWriteError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
        }
        // The aborted write changed nothing — the replacement's tags are exactly as created.
        XCTAssertEqual(Set(try readTags(replacement)), ["Untouched"])
    }

    /// Same replace scenario but WITHOUT passing an identity → the write proceeds. The §6 check is
    /// strictly opt-in; existing callers (nil identity) are unaffected (backward compatibility).
    func testNilIdentitySkipsCheckAndWrites() throws {
        let name = "id-nil.pdf"
        let original = try makeFile(name, tags: ["Unread"])
        _ = try XCTUnwrap(FileIdentity.capture(original))
        try FileManager.default.removeItem(at: original)
        let replacement = try makeFile(name, tags: ["Untouched"])

        let r = try CoordinatedTagWriter.write(replacement) { current, label in
            (current + ["Reviewed"], label)
        }
        XCTAssertFalse(r.isNoOp)
        XCTAssertTrue(multisetEqual(try readTags(replacement), ["Untouched", "Reviewed"]))
    }

    /// The captured file was DELETED since discovery (nothing at the path) → the §6 check finds no
    /// identity and aborts with `.identityMismatch`, before the tag read. Asserting the exact case is
    /// what kills W40.e7's mutant C02 (a nil capture falling back to the expected identity): with the
    /// check bypassed the write still fails, but later and as `.unreadable`. An earlier note here
    /// called this case nondeterministic; W40.fix-mut-tagwriter-tests measured it (20 deletions per
    /// run, every run) and the §6 check runs first, so the coordinator never reaches the path.
    func testDeletedTargetAbortsWithIdentityMismatch() throws {
        for i in 0..<20 {
            let url = try makeFile("id-gone-\(i).pdf", tags: ["Unread"])
            let identity = try XCTUnwrap(FileIdentity.capture(url))
            try FileManager.default.removeItem(at: url)

            XCTAssertThrowsError(try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
                (current + ["Reviewed"], label)
            }) { error in
                guard case TagWriteError.identityMismatch = error else {
                    return XCTFail("expected .identityMismatch, got \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the aborted write created nothing")
        }
    }

    /// FileIdentity.capture + matches semantics: same file matches itself (and is symmetric),
    /// distinct files differ, and a nonexistent file yields nil.
    func testFileIdentityCaptureAndMatches() throws {
        let a = try makeFile("id-a.pdf", tags: [])
        let b = try makeFile("id-b.pdf", tags: [])
        let a1 = try XCTUnwrap(FileIdentity.capture(a))
        let a2 = try XCTUnwrap(FileIdentity.capture(a))
        let bId = try XCTUnwrap(FileIdentity.capture(b))
        XCTAssertTrue(a1.matches(a2))     // same file, captured twice
        XCTAssertTrue(a2.matches(a1))     // symmetric
        XCTAssertFalse(a1.matches(bId))   // distinct files
        XCTAssertNil(FileIdentity.capture(tempDir.appendingPathComponent("nope.pdf")))
    }

    // MARK: W40.fix-identity-url-cache — reads see the disk, not the URL's resource-value cache

    /// The mechanism behind the S1: the SAME `URL` instance, captured before and after the file at its
    /// path is replaced. Before the fix the second capture answered from the first one's cache.
    func testFileIdentityCaptureThroughAReusedURLSeesASwap() throws {
        let url = try makeFile("id-reused.pdf", tags: ["Unread"])
        let before = try XCTUnwrap(FileIdentity.capture(url))

        try FileManager.default.removeItem(at: url)
        try Data("a different document".utf8).write(to: URL(fileURLWithPath: url.path))

        let fresh = try XCTUnwrap(FileIdentity.capture(URL(fileURLWithPath: url.path)))
        XCTAssertFalse(fresh.matches(before), "precondition: a fresh URL sees the replacement")
        let reused = try XCTUnwrap(FileIdentity.capture(url))
        XCTAssertFalse(reused.matches(before), "the same URL instance must see the replacement too")
    }

    /// The Reader's shape of the S1, at the writer: identity captured through a `URL`, the file swapped
    /// under its path, then a write through THAT SAME `URL` expecting the captured identity. §6 must refuse
    /// and the replacement must be left exactly as it was written.
    func testReplacedFileAbortsThroughTheSameURLItWasCapturedThrough() throws {
        let url = try makeFile("id-swap-same-url.pdf", tags: ["Unread"])
        let identity = try XCTUnwrap(FileIdentity.capture(url))
        try prime(url)   // the tag cache too, as a discovery enumerator's URL arrives

        try FileManager.default.removeItem(at: url)
        let replacement = URL(fileURLWithPath: url.path)
        try Data("a different document".utf8).write(to: replacement)
        try (replacement as NSURL).setResourceValue(["Untouched"], forKey: .tagNamesKey)

        XCTAssertThrowsError(try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
            (current + ["Reviewed"], label)
        }) { error in
            guard case TagWriteError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
        }
        XCTAssertEqual(try readTags(URL(fileURLWithPath: url.path)), ["Untouched"],
                       "§6: a file swapped under the path is never tagged")
    }

    /// §2 at the writer: the transform must receive the tags ON DISK, not the tags the caller's `URL` read
    /// last time. The coordinator hands the block the caller's own `NSURL`, so before the fix a write
    /// through a URL that had read its tags once computed from those stale tags and clobbered a change
    /// made since (here "Keep", added by another writer through a fresh URL).
    func testWriteReadsTheDiskNotTheCallersURLCache() throws {
        let url = try makeFile("stale-before.pdf", tags: ["Unread"])
        try prime(url)
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Unread", "Keep"], forKey: .tagNamesKey)

        var seen: [String] = []
        let r = try CoordinatedTagWriter.write(url) { current, label in
            seen = current
            return (current.filter { $0 != "Unread" } + ["Read"], label)
        }
        XCTAssertTrue(multisetEqual(seen, ["Unread", "Keep"]), "the transform saw the disk, got \(seen)")
        XCTAssertTrue(multisetEqual(r.before, ["Unread", "Keep"]))
        XCTAssertTrue(multisetEqual(try readTags(URL(fileURLWithPath: url.path)), ["Keep", "Read"]),
                      "the concurrent addition survived the write")
    }

    /// A write through a `URL` holding cached Finder info rebuilds the Finder-info block from the CACHE, so
    /// it reverts a hidden flag another writer set since (measured; the Reader's rows carry the enumerator's
    /// URLs, which arrive with Finder info cached). The writer must leave such bits alone: Tier-2 review of
    /// this item.
    func testWriteThroughACachedURLKeepsAnExternalHiddenFlag() throws {
        let url = try makeFile("hidden-kept.pdf", tags: ["Unread"])
        try prime(url)   // the label lives in Finder info, so this caches the Finder-info block
        let fresh = URL(fileURLWithPath: url.path)
        try (fresh as NSURL).setResourceValue(true, forKey: .isHiddenKey)
        XCTAssertEqual(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isHiddenKey]).isHidden, true,
                       "precondition: the hidden flag is set on disk")

        let r = try CoordinatedTagWriter.write(url) { current, label in (current + ["Read"], 6) }
        XCTAssertFalse(r.isNoOp)
        XCTAssertEqual(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isHiddenKey]).isHidden, true,
                       "a tag + label write must not write cached Finder info back over the hidden flag")
        XCTAssertTrue(multisetEqual(try readTags(URL(fileURLWithPath: url.path)), ["Unread", "Read"]))
        XCTAssertEqual(try readLabel(URL(fileURLWithPath: url.path)), 6)
    }

    /// `URL.uncached` names the same bytes, and never falls back to the working directory.
    func testUncachedURLKeepsTheNameBytesAndRefusesAnEmptyPath() throws {
        let composed = tempDir.appendingPathComponent("caf\u{E9}-\u{65}\u{301}.pdf")   // NFC é and NFD é side by side
        try Data("x".utf8).write(to: composed)
        var original: [CChar] = [], rebuilt: [CChar] = []
        composed.withUnsafeFileSystemRepresentation { p in original = Array(UnsafeBufferPointer(start: p, count: strlen(p!))) }
        composed.uncached.withUnsafeFileSystemRepresentation { p in rebuilt = Array(UnsafeBufferPointer(start: p, count: strlen(p!))) }
        XCTAssertEqual(original, rebuilt, "the file-system representation is carried over byte for byte")
        XCTAssertFalse((composed.uncached as NSURL) === (composed as NSURL), "and it is a new object")
        XCTAssertTrue(FileIdentity.capture(composed.uncached)!.matches(FileIdentity.capture(composed)!))

        let undecodable = try XCTUnwrap(URL(string: "file:///tmp/%FF"))
        XCTAssertEqual(undecodable.path, "", "precondition: Foundation decodes this to an empty path")
        XCTAssertEqual(undecodable.uncached, undecodable, "an empty path is returned as it is, never the working directory")
        let web = try XCTUnwrap(URL(string: "https://example.org/a.pdf"))
        XCTAssertEqual(web.uncached, web)
    }

    /// `TagReading.read` itself, the primitive every read in the suite goes through: a reused `URL` must
    /// report a change made since it last read.
    func testTagReadingReadThroughAReusedURLSeesAnExternalChange() throws {
        let url = try makeFile("stale-read.pdf", tags: ["Unread"])
        guard case let .success(first, _) = TagReading.read(url) else { return XCTFail("first read failed") }
        XCTAssertEqual(first, ["Unread"])
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Read"], forKey: .tagNamesKey)
        guard case let .success(second, _) = TagReading.read(url) else { return XCTFail("second read failed") }
        XCTAssertEqual(second, ["Read"], "the same URL instance reports the tags on disk now")
    }

    // MARK: §9 (W15.tu1) Occurrence-aware (multiset) inverse — never loses a duplicate

    /// The multiset-difference primitive underneath the occurrence-aware inverse.
    func testMultisetDifference() {
        XCTAssertEqual(multisetDifference(["A", "A", "B"], minus: ["A"]), ["A", "B"])  // one A cancels
        XCTAssertEqual(multisetDifference(["A", "A"], minus: []), ["A", "A"])          // both surplus
        XCTAssertEqual(multisetDifference(["A"], minus: ["A", "A"]), [])               // a has fewer → empty
        XCTAssertEqual(multisetDifference([], minus: ["A"]), [])
        XCTAssertEqual(multisetDifference(["A", "B"], minus: ["A", "C"]), ["B"])       // parity w/ set-diff (no dups)
    }

    /// The occurrence-aware inverse restores the exact COUNT of a duplicated token — the case the
    /// set-based `inverse` silently collapses.
    func testOccurrenceInversePreservesDuplicateCount() {
        let inv = tagOccurrenceInverse(before: ["A", "A"], after: [], beforeLabel: nil, afterLabel: nil)
        XCTAssertTrue(multisetEqual(inv.add, ["A", "A"]))  // BOTH occurrences re-added, not one
        XCTAssertTrue(inv.remove.isEmpty)
        XCTAssertNil(inv.color)
    }

    /// For ordinary (no-duplicate) edits the occurrence-aware inverse equals the set-based inverse.
    func testOccurrenceInverseMatchesSetInverseWhenNoDuplicates() {
        let before = ["A", "B"], after = ["A", "C"]
        let occ = tagOccurrenceInverse(before: before, after: after, beforeLabel: nil, afterLabel: nil)
        XCTAssertTrue(multisetEqual(occ.add, ["B"]))     // re-add what was removed
        XCTAssertTrue(multisetEqual(occ.remove, ["C"]))  // strip what was added
    }

    /// Color restore rides along unchanged (a label has no multiplicity).
    func testOccurrenceInverseColorRestore() {
        let occ = tagOccurrenceInverse(before: ["Red"], after: [], beforeLabel: 6, afterLabel: 0)
        guard case let .restoreLabel(lbl)? = occ.color else { return XCTFail("expected .restoreLabel") }
        XCTAssertEqual(lbl, 6)
        // No label change → no color inverse.
        let noChange = tagOccurrenceInverse(before: ["x"], after: ["x", "y"], beforeLabel: 6, afterLabel: 6)
        XCTAssertNil(noChange.color)
    }

    /// End-to-end through the write primitive: removing both copies of a duplicated tag yields an
    /// occurrence-aware inverse that re-adds BOTH, while the legacy set-based inverse collapses to one.
    func testWriteExposesOccurrenceAwareInverseForDuplicates() throws {
        let url = try makeFile("dup-inverse.pdf", tags: ["A", "A"])
        // Premise of the wave (W15.tu0): macOS persists duplicate tag strings. Skip if a volume dedups.
        try XCTSkipUnless(try readTags(url).filter { $0 == "A" }.count == 2,
                          "platform did not persist duplicate tags; occurrence-inverse test N/A")
        let r = try CoordinatedTagWriter.write(url) { _, label in ([], label) }  // remove both A's
        XCTAssertTrue(multisetEqual(r.after, []))
        XCTAssertTrue(multisetEqual(r.occurrenceInverse.add, ["A", "A"]), "got \(r.occurrenceInverse.add)")
        XCTAssertTrue(r.occurrenceInverse.remove.isEmpty)
        XCTAssertEqual(r.inverse.add, ["A"])  // the set-based collapse the occurrence inverse routes around
    }

    /// A no-op write carries an empty occurrence-aware inverse (default), same as the set-based one.
    func testOccurrenceInverseEmptyForNoOp() throws {
        let url = try makeFile("occ-noop.pdf", tags: ["A", "A", "B"])
        let r = try CoordinatedTagWriter.write(url) { _, _ in nil }
        XCTAssertTrue(r.isNoOp)
        XCTAssertEqual(r.occurrenceInverse, TagOccurrenceDelta())
    }

    // MARK: §10 In-process per-resolved-path serialization — no lost update on concurrent same-path writes

    /// Two concurrent writers to the SAME file, each appending a distinct tag, with the
    /// read→modify→write window deliberately widened (a sleep INSIDE the transform) to force the
    /// windows to overlap. Without §10 per-path serialization the later `setxattr` clobbers the
    /// earlier writer's tag (a lost update — exactly the race the Notes projector documented); with
    /// it, the second writer observes the first's committed state, so BOTH tags survive.
    /// (Verified non-vacuous: this fails deterministically when the §10 lock is removed.)
    func testConcurrentSamePathWritesBothSurvive() throws {
        let url = try makeFile("race-same.pdf", tags: [])
        let tags = ["Alpha", "Beta"]
        let errors = ErrorCollector()
        DispatchQueue.concurrentPerform(iterations: tags.count) { i in
            do {
                _ = try CoordinatedTagWriter.write(url) { current, label in
                    Thread.sleep(forTimeInterval: 0.15)   // widen the RMW window to force overlap
                    return (current + [tags[i]], label)
                }
            } catch { errors.record(error) }
        }
        XCTAssertTrue(errors.all.isEmpty, "no concurrent writer should throw: \(errors.all)")
        XCTAssertEqual(Set(try readTags(url)), Set(tags),
                       "both concurrently-added tags survive — the per-path lock closed the lost-update race")
    }

    /// The lock is PER PATH, not global: concurrent writes to DIFFERENT files each complete correctly
    /// (a global lock would still pass this — the point is it must not regress into serializing, and
    /// it proves distinct paths get distinct locks and both writes land).
    func testConcurrentDifferentPathWritesEachSucceed() throws {
        let count = 8
        let urls = try (0..<count).map { try makeFile("race-diff-\($0).pdf", tags: ["base"]) }
        let errors = ErrorCollector()
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do {
                _ = try CoordinatedTagWriter.write(urls[i]) { current, label in (current + ["T\(i)"], label) }
            } catch { errors.record(error) }
        }
        XCTAssertTrue(errors.all.isEmpty, "no writer should throw: \(errors.all)")
        for i in 0..<count {
            XCTAssertEqual(Set(try readTags(urls[i])), ["base", "T\(i)"], "file \(i) got exactly its own tag")
        }
    }
}

/// Thread-safe error sink for concurrent test iterations.
private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func record(_ e: Error) { lock.lock(); errors.append(e); lock.unlock() }
    var all: [Error] { lock.lock(); defer { lock.unlock() }; return errors }
}
