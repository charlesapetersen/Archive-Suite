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
        XCTAssertEqual(folder("1965-1967", start: "IMG_0101.pdf").evidence, "folder; from IMG_0101.pdf; \"1965-1967\"")
        XCTAssertEqual(folder("1960s", start: "").evidence, "folder; from the folder; \"1960s\"")
        XCTAssertEqual(ContainerFolderDate.evidenceClass("folder; from x"), "folder")
        XCTAssertNil(ContainerFolderDate.evidenceClass(nil))
    }

    func testTheRecordHoldsOnlyWhileTheFileCarriesItsDate() throws {
        let record = try XCTUnwrap(folder("Feb. 1970").record)
        XCTAssertEqual(record, FolderDateRecord(date: "1970-02", uncertain: false, evidence: "folder; from 0001.pdf; \"Feb. 1970\""))
        XCTAssertTrue(record.holds(for: tags(["1970", "2 February", "Unread"])))
        XCTAssertFalse(record.holds(for: tags(["1970", "2 February", "Date Uncertain"])), "undone to the estimate's")
        XCTAssertFalse(record.holds(for: tags(["1958"])))
        XCTAssertFalse(record.holds(for: tags([])))
        let page = "estimate; from 0003.pdf"
        XCTAssertEqual(FolderDateRecord.evidence(record, page: page, tags: tags(["1970", "2 February"])), record.evidence)
        XCTAssertEqual(FolderDateRecord.evidence(record, page: page, tags: tags(["1958", "Date Uncertain"])), page)
        let decade = try XCTUnwrap(folder("1962-1975").record)
        XCTAssertEqual(decade.date, "1960s")
        XCTAssertTrue(decade.holds(for: tags(["1960s", "Date Uncertain"])))
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
}
