import XCTest
@testable import ArchiveCore

/// A folder date confirmed in the Reader dates the documents already written (W47.ct-folder-date-reader): which
/// documents take it, the tag change, the evidence line and the record kept beside the files.
final class FolderDateDocumentsTests: XCTestCase {
    private func tags(_ raw: [String]) -> DocumentTags { DocumentTags.parse(raw: raw, labelNumber: nil) }
    private func folder(_ s: String, start: String = "0001.pdf") -> ContainerFolderDate {
        ContainerFolderDate.parse(s, start: start)!
    }

    func testWhichDocumentsTakeTheDate() {
        let f = folder("1965-1967")
        XCTAssertTrue(f.dates(tags(["Unread", "Civil rights"]), evidence: nil), "no date: takes it")
        XCTAssertTrue(f.dates(tags([]), evidence: nil), "no text and no tags: takes it")
        XCTAssertFalse(f.dates(tags(["1958"]), evidence: nil), "a date with no evidence line is the document's own")
        XCTAssertFalse(f.dates(tags(["1958"]), evidence: "image; page 1; top; \"1958\""))
        XCTAssertTrue(f.dates(tags(["1958", "Date Uncertain"]), evidence: "estimate; from 0003.pdf; line 2; \"x\""))
        XCTAssertTrue(f.dates(tags(["1958"]), evidence: "stamp; page 1; \"MAR 1958\""))
        XCTAssertTrue(f.dates(tags(["1960s", "Date Uncertain"]), evidence: "folder; from 0001.pdf; \"1960s\""),
                      "an earlier folder date gives way to the confirmed one")
        XCTAssertFalse(f.dates(tags(["1958", "Date Uncertain"]), evidence: "inherited; from 0002.pdf"))
        XCTAssertFalse(f.dates(tags(["1958", "Checked Date"]), evidence: "estimate; from x"), "checked is the user's")
        XCTAssertFalse(f.dates(tags(["1958", "1959"]), evidence: "estimate; from x"), "two years: unclear which")
        XCTAssertFalse(f.dates(tags(["1958"]), evidence: "something new; x"), "an unknown class stands")
        XCTAssertFalse(folder("1940-1970").dates(tags([]), evidence: nil), "20 years or more dates nothing")
    }

    func testACoversYearGivesWayOnlyToTheFoldersOwnSingleYear() {
        let cover = "inherited; from 0002.pdf"
        XCTAssertTrue(folder("Feb. 1966").dates(tags(["1966", "Date Uncertain"]), evidence: cover))
        XCTAssertFalse(folder("Feb. 1966").dates(tags(["1965", "Date Uncertain"]), evidence: cover))
        XCTAssertFalse(folder("1965-1967").dates(tags(["1966", "Date Uncertain"]), evidence: cover),
                       "a range's year is uncertain: the cover's stands")
    }

    private func apply(_ d: TagDelta?, to raw: [String]) -> Set<String> {
        guard let d else { return Set(raw) }
        var out = raw.filter { t in !d.remove.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        for a in d.add where !out.contains(a) { out.append(a) }
        return Set(out)
    }

    func testTheTagChange() {
        let range = folder("1965-1967")
        XCTAssertEqual(apply(range.delta(given: tags(["Unread"])), to: ["Unread"]), ["Unread", "1966", "Date Uncertain"])
        let estimated = ["Unread", "1958", "3 March", "Day 4", "Date Uncertain"]
        XCTAssertEqual(apply(range.delta(given: tags(estimated)), to: estimated), ["Unread", "1966", "Date Uncertain"],
                       "the month and day go with the old year")
        let single = folder("Feb. 1970")
        let had = ["1958", "Date Uncertain", "Checked Title"]
        XCTAssertEqual(apply(single.delta(given: tags(had)), to: had), ["1970", "2 February", "Checked Title"],
                       "a single year: its month, no Date Uncertain, and no check of the date")
        let decade = folder("1962-1975")
        XCTAssertEqual(apply(decade.delta(given: tags(["1958"])), to: ["1958"]), ["1960s", "Date Uncertain"])
        XCTAssertEqual(single.delta(given: tags(["1970", "2 February"])), TagDelta(), "already so: nothing to write")
        XCTAssertNil(folder("1900-1950").delta(given: tags([])))
    }

    func testTheEvidenceLineIsProcessFiles() {
        XCTAssertEqual(folder("1965-1967", start: "IMG_0101.pdf").evidence, "folder; from IMG_0101.pdf; \"1965-1967\"; gave 1966, Date Uncertain")
        XCTAssertEqual(folder("1960s", start: "").evidence, "folder; from the folder; \"1960s\"; gave 1960s, Date Uncertain")
        XCTAssertEqual(ContainerFolderDate.evidenceClass("folder; from x"), "folder")
        XCTAssertNil(ContainerFolderDate.evidenceClass(nil))
    }

    func testTheRecordHoldsOnlyWhileTheFileCarriesItsDate() throws {
        let record = try XCTUnwrap(folder("Feb. 1970").record)
        XCTAssertEqual(record, FolderDateRecord(date: "1970-02", uncertain: false, evidence: "folder; from 0001.pdf; \"Feb. 1970\"; gave 1970-02"))
        XCTAssertTrue(record.holds(for: tags(["1970", "2 February", "Unread"])))
        XCTAssertFalse(record.holds(for: tags(["1970", "2 February", "Date Uncertain"])), "undone to the estimate's")
        XCTAssertFalse(record.holds(for: tags(["1958"])))
        XCTAssertFalse(record.holds(for: tags([])))
        let page = "estimate; from 0003.pdf; gave 1958, Date Uncertain"
        XCTAssertEqual(FolderDateRecord.evidence(record, page: page, tags: tags(["1970", "2 February"])), record.evidence)
        XCTAssertEqual(FolderDateRecord.evidence(record, page: page, tags: tags(["1958", "Date Uncertain"])), page)
        let decade = try XCTUnwrap(folder("1962-1975").record)
        XCTAssertEqual(decade.date, "1960s")
        XCTAssertTrue(decade.holds(for: tags(["1960s", "Date Uncertain"])))
    }

    /// W49.reader-finder-year-stands, W49.reader-finder-month-stands: page 2's evidence speaks for the date only while
    /// the file still carries the date it gave, month, day and `Date Uncertain` included. A date changed in Finder (which
    /// records nothing) is the user's, so no folder date replaces it.
    func testPageEvidenceStandsOnlyForTheDateItGave() {
        let stamp = "stamp; page 1; top; \"RECEIVED MAR 1958\"; gave 1958-03"
        XCTAssertEqual(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1958", "3 March", "Unread"])), stamp)
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1961", "3 March"])), "year retyped in Finder")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1958", "4 April"])), "month changed")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1958"])), "month removed")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1958", "3 March", "Day 9"])), "day added")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1958", "3 March", "Date Uncertain"])),
                     "Date Uncertain added")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1958", "1959", "3 March"])),
                     "a second Year added: the date is ambiguous")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags(["1950s"])), "a decade is not the year")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: "stamp; page 1", tags: tags(["1958"])), "no date recorded")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: "stamp; page 1; year 1958", tags: tags(["1958"])),
                     "the year-only form speaks for nothing")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: "estimate; from a.pdf; \"x; gave 1958\"", tags: tags(["1958"])),
                     "a quote's text is not the recorded date")
        let day = "image; page 1; \"March 30, 1961\"; gave 1961-03-30"
        XCTAssertEqual(FolderDateRecord.evidence(nil, page: day, tags: tags(["1961", "3 March", "Day 30"])), day)
        XCTAssertNil(FolderDateRecord.evidence(nil, page: day, tags: tags(["1961", "3 March", "Day 31"])), "day changed")
        let uncertain = "estimate; from a.pdf; gave 1957, Date Uncertain"
        XCTAssertEqual(FolderDateRecord.evidence(nil, page: uncertain, tags: tags(["1957", "Date Uncertain"])), uncertain)
        XCTAssertNil(FolderDateRecord.evidence(nil, page: uncertain, tags: tags(["1957"])), "Date Uncertain removed")
        let decade = "folder; from 0001.pdf; \"1962-1975\"; gave 1960s, Date Uncertain"
        XCTAssertEqual(FolderDateRecord.evidence(nil, page: decade, tags: tags(["1960s", "Date Uncertain"])), decade)
        XCTAssertNil(FolderDateRecord.evidence(nil, page: decade, tags: tags(["1964", "Date Uncertain"])))
        let f = folder("1965-1967")
        for changed in [["1961", "3 March"], ["1958"], ["1958", "3 March", "Date Uncertain"]] {
            let t = tags(changed)
            XCTAssertFalse(f.dates(t, evidence: FolderDateRecord.evidence(nil, page: stamp, tags: t)),
                           "the user's \(changed) stands")
        }
        let kept = tags(["1958", "3 March"])
        XCTAssertTrue(f.dates(kept, evidence: FolderDateRecord.evidence(nil, page: stamp, tags: kept)))
        XCTAssertNil(FolderDateRecord.evidence(nil, page: stamp, tags: tags([])))
        XCTAssertTrue(f.dates(tags([]), evidence: nil), "an undated file still takes the folder's")
    }

    /// The last part is the parsed date's own form, so the Processor's tags and the Reader's read the same.
    func testTheGaveFormReadsTheTags() {
        XCTAssertEqual(ContainerFolderDate.evidenceGave(tags(["1958", "3 March", "Day 2", "Date Uncertain"])),
                       "gave 1958-03-02, Date Uncertain")
        XCTAssertEqual(ContainerFolderDate.evidenceGave(tags(["1958", "Day 2"])), "", "a day with no month names nothing")
        XCTAssertEqual(ContainerFolderDate.evidenceGave(tags(["1958", "1950s"])), "", "nor a decade beside a year")
        XCTAssertNil(FolderDateRecord.evidence(nil, page: "estimate; gave 1958", tags: tags(["1958", "Day 5"])),
                     "a Day added in Finder to a year-only date stands")
        XCTAssertEqual(ContainerFolderDate.evidenceGave(tags(["1960s"])), "gave 1960s")
        XCTAssertEqual(ContainerFolderDate.evidenceGave(tags(["Unread"])), "")
    }

    func testTheRecordsRoundTripInTheItemFieldsDocument() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderDateDocumentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = UserItemFields()
        f.set(.title, to: "A Report", for: "0002.pdf")
        f.setDateRecord(folder("1965-1967").record, for: "Re\u{0301}sume\u{0301}.pdf")
        XCTAssertNotNil(f.dateRecord(for: "Résumé.pdf"), "keyed composed")
        try ContainerFileStore.writeItemFields(f, directory: dir, expecting: nil)
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: dir).document, f)
        f.setDateRecord(nil, for: "Résumé.pdf")
        XCTAssertNil(f.dateRecord(for: "Résumé.pdf"))

        let target = ContainerFileStore.itemFieldsURL(in: dir)
        let body = #"{"schemaVersion":1,"files":{},"dates":{"a.pdf":{"date":"1966","uncertain":true,"evidence":"x","by":1}}}"#
        try Data(body.utf8).write(to: target)
        guard case .unreadable = ContainerFileStore.loadItemFields(directory: dir) else {
            return XCTFail("an unknown key in a record is read")
        }
    }

    /// W49.reader-folder-date-undo: which dates a folder gave, and how one is taken away when the folder no longer
    /// gives a date.
    func testTheDatesAFolderGaveAndTakingThemAway() {
        let reader = "folder; from 0001.pdf; \"Feb. 1966\"; gave 1966-02"
        XCTAssertTrue(ContainerFolderDate.folderGave(tags(["1966", "2 February"]), evidence: reader))
        XCTAssertTrue(ContainerFolderDate.folderGave(tags(["1960s", "Date Uncertain"]),
                                                     evidence: "folder; from 0001.pdf; \"1960s\""),
                      "Process Files' folder date, from page 2")
        XCTAssertFalse(ContainerFolderDate.folderGave(tags(["1966", "Checked Date"]), evidence: reader), "checked")
        XCTAssertFalse(ContainerFolderDate.folderGave(tags(["1966"]), evidence: nil), "the file's own")
        XCTAssertFalse(ContainerFolderDate.folderGave(tags(["1958"]), evidence: "stamp; page 1; gave 1958"))
        XCTAssertFalse(ContainerFolderDate.folderGave(tags(["1966", "1967"]), evidence: reader), "carried twice")
        XCTAssertFalse(ContainerFolderDate.folderGave(tags(["Unread"]), evidence: reader), "no date")

        let dated = ["Unread", "1966", "2 February", "Date Uncertain"]
        XCTAssertEqual(apply(ContainerFolderDate.undatingDelta(given: tags(dated), page: nil), to: dated), ["Unread"])
        XCTAssertEqual(apply(ContainerFolderDate.undatingDelta(given: tags(dated), page: reader), to: dated), ["Unread"],
                       "page 2 a folder's too: no date to go back to")
        XCTAssertEqual(apply(ContainerFolderDate.undatingDelta(
            given: tags(dated), page: "estimate; from 0002.pdf; gave 1958, Date Uncertain"), to: dated),
                       ["Unread", "1958", "Date Uncertain"], "back to the estimate the folder's replaced")
        let certain = ["Unread", "1966", "2 February"]
        XCTAssertEqual(apply(ContainerFolderDate.undatingDelta(
            given: tags(certain), page: "stamp; page 1; \"MAR 1958\"; gave 1958-03"), to: certain),
                       ["Unread", "1958", "3 March"])
        XCTAssertEqual(apply(ContainerFolderDate.undatingDelta(
            given: tags(certain), page: "stamp; page 1; \"MAR 1958\""), to: certain), ["Unread"],
                       "an evidence line that names no date: no date")
    }

    /// The review's cases: an image's date is never put back (a folder's never replaced one), a covering letter's year
    /// stands, and a date tag added in Finder that the form cannot name makes the record stop speaking for the file.
    func testUndatingLeavesTheFilesOwnDates() {
        let dated = ["Unread", "1966"]
        XCTAssertEqual(apply(ContainerFolderDate.undatingDelta(given: tags(dated), page: "image; page 1; gave 1962"),
                             to: dated), ["Unread"], "an image's date is not the folder's to put back")
        XCTAssertEqual(apply(ContainerFolderDate.undatingDelta(given: tags(dated), page: "inherited; from 0002.pdf; gave 1966"),
                             to: dated), ["Unread", "1966"], "the cover's year")
        let cover = ["Unread", "1966", "Sent With 1966-04-02"]
        XCTAssertTrue(ContainerFolderDate.undatingDelta(given: tags(cover), page: nil).isEmpty,
                      "a year the covering letter gives too stands")
        let record = FolderDateRecord(date: "1966", uncertain: false, evidence: "folder; from 0001.pdf; gave 1966")
        XCTAssertTrue(record.holds(for: tags(["1966"])))
        XCTAssertFalse(record.holds(for: tags(["1966", "Day 5"])), "a Day with no Month was added in Finder")
        let decade = FolderDateRecord(date: "1960s", uncertain: true, evidence: "folder; from 0001.pdf; gave 1960s")
        XCTAssertTrue(decade.holds(for: tags(["1960s", "Date Uncertain"])))
        XCTAssertFalse(decade.holds(for: tags(["1960s", "3 March", "Date Uncertain"])), "a Month beside the Decade")
        XCTAssertFalse(decade.holds(for: tags(["1960s", "1966", "Date Uncertain"])), "a Year beside the Decade")
    }
}
