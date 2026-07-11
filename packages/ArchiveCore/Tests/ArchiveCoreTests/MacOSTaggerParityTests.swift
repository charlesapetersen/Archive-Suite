// W0-S5 Tier-2: scratch-corpus write-parity test for the MacOSTagger→CoordinatedTagWriter migration.
// Exercises the exact transform logic on real temp files. Asserts multiset(tags) + labelNumber.
// This file is committed as a permanent regression gate (the transforms are part of ArchiveCore's contract).
import XCTest
@testable import ArchiveCore

final class MacOSTaggerParityTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("w0s5-parity-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mkf(_ name: String) -> URL {
        let u = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: Data("t".utf8))
        return u
    }
    private func readBack(_ url: URL) -> (tags: [String], label: Int) {
        let rv = try! url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
        return (rv.tagNames ?? [], rv.labelNumber ?? 0)
    }
    private func msEq(_ a: [String], _ b: [String]) -> Bool { a.sorted() == b.sorted() }
    private func fLabel(_ c: String) -> Int { c == "Red" ? 6 : c == "Purple" ? 3 : -1 }

    /// The real-tagging transform extracted from MacOSTagger.applyTags (stampUnread=true).
    private func realTransform(
        tags: [String], appColor: String?, authColor: Bool,
        _ cur: [String], _ lbl: Int?
    ) -> ([String], Int?)? {
        var inc = tags; inc.removeAll { $0.caseInsensitiveCompare("Unread") == .orderedSame }
        let filt = inc.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let cName: String?; let text: [String]
        if authColor {
            cName = (appColor == "Red" || appColor == "Purple") ? appColor : nil
            if let c = cName, let i = filt.firstIndex(of: c) { var t = filt; t.remove(at: i); text = t }
            else { text = filt }
        } else {
            let det = filt.first { ["Red","Purple"].contains($0) }; cName = det
            text = filt.filter { $0 != det }
        }
        var all = text; if let c = cName { all.insert(c, at: 0) }; all.append("Unread")
        let tl = (cName != nil && fLabel(cName!) >= 0) ? fLabel(cName!) : 0
        return (all, tl)
    }

    /// Copy-source transform (stampUnread=false).
    private func copyTransform(_ tags: [String], _ cur: [String], _ lbl: Int?) -> ([String], Int?)? {
        let v = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !v.isEmpty else { return nil }
        return (v, lbl)
    }

    // (a) dated+subjects with box color
    func testBoxTagging() throws {
        let u = mkf("a_box.pdf")
        _ = try CoordinatedTagWriter.write(u) { c,l in self.realTransform(tags:["1962","Red","Corr","Tax"],appColor:nil,authColor:false,c,l) }
        let (t,l) = readBack(u)
        XCTAssert(msEq(t, ["Red","Corr","Tax","1962","Unread"]), "box tags: \(t.sorted())")
        XCTAssertEqual(l, 6, "box label")
    }

    // (a) folder color
    func testFolderTagging() throws {
        let u = mkf("a_fld.pdf")
        _ = try CoordinatedTagWriter.write(u) { c,l in self.realTransform(tags:["Purple","Rcpt","1974"],appColor:nil,authColor:false,c,l) }
        let (t,l) = readBack(u)
        XCTAssert(msEq(t, ["Purple","Rcpt","1974","Unread"]), "folder tags: \(t.sorted())")
        XCTAssertEqual(l, 3, "folder label")
    }

    // (a) no-color (OCR failed)
    func testNoColorTagging() throws {
        let u = mkf("a_nc.pdf")
        _ = try CoordinatedTagWriter.write(u) { c,l in self.realTransform(tags:["OCR Failed","1999"],appColor:nil,authColor:false,c,l) }
        let (t,l) = readBack(u)
        XCTAssert(msEq(t, ["OCR Failed","1999","Unread"]), "nc tags: \(t.sorted())")
        XCTAssertEqual(l, 0, "nc label")
    }

    // (b) retag an already-tagged file
    func testRetagOverwrite() throws {
        let u = mkf("b_ret.pdf")
        try (u as NSURL).setResourceValue(["OldTag","Unread"], forKey: .tagNamesKey)
        try (u as NSURL).setResourceValue(6, forKey: .labelNumberKey)
        _ = try CoordinatedTagWriter.write(u) { c,l in self.realTransform(tags:["Purple","New"],appColor:nil,authColor:false,c,l) }
        let (t,l) = readBack(u)
        XCTAssert(msEq(t, ["Purple","New","Unread"]), "retag tags: \(t.sorted())")
        XCTAssertEqual(l, 3, "retag label")
    }

    // (c) copy-source with empty array → no-op
    func testCopySourceEmpty() throws {
        let u = mkf("c_emp.pdf")
        try (u as NSURL).setResourceValue(["Pre"], forKey: .tagNamesKey)
        let r = try CoordinatedTagWriter.write(u) { c,l in self.copyTransform([], c, l) }
        let (t,_) = readBack(u)
        XCTAssert(msEq(t, ["Pre"]), "empty copy preserved: \(t)")
        XCTAssert(r.isNoOp, "should be no-op")
    }

    // (c2) copy-source verbatim, label untouched
    func testCopySourceVerbatim() throws {
        let u = mkf("c2.pdf")
        try (u as NSURL).setResourceValue(3, forKey: .labelNumberKey)
        _ = try CoordinatedTagWriter.write(u) { c,l in self.copyTransform(["Red","Tag","Blue"], c, l) }
        let (t,l) = readBack(u)
        XCTAssert(msEq(t, ["Red","Tag","Blue"]), "copy verbatim: \(t.sorted())")
        XCTAssertEqual(l, 3, "label preserved")
    }

    // (d) incoming Unread deduplicated, one trailing
    func testUnreadDedup() throws {
        let u = mkf("d.pdf")
        _ = try CoordinatedTagWriter.write(u) { c,l in self.realTransform(tags:["S1","Unread","unread","UNREAD","Red"],appColor:nil,authColor:false,c,l) }
        let (t,l) = readBack(u)
        let uc = t.filter { $0.caseInsensitiveCompare("Unread") == .orderedSame }.count
        XCTAssertEqual(uc, 1, "exactly 1 Unread")
        XCTAssertEqual(t.last, "Unread", "Unread is last")
        XCTAssertEqual(l, 6, "Red label")
    }

    // (e) unreadable target → abort (never write to a nonexistent file)
    func testUnreadableAbort() throws {
        let bad = dir.appendingPathComponent("e_nonexistent.pdf")
        XCTAssertThrowsError(try CoordinatedTagWriter.write(bad) { _,_ in (["X"],0) })
    }

    // (f) "Red" as subject with colorIsAuthoritative=true, appColor=nil
    func testRedAsSubject() throws {
        let u = mkf("f.pdf")
        _ = try CoordinatedTagWriter.write(u) { c,l in self.realTransform(tags:["Red","Comm","1955"],appColor:nil,authColor:true,c,l) }
        let (t,l) = readBack(u)
        XCTAssert(t.contains("Red"), "Red kept as text: \(t)")
        XCTAssertEqual(l, 0, "no color label")
        XCTAssertEqual(t.last, "Unread")
    }

    // (f2) "Purple" as subject alongside appColor=Red
    func testPurpleSubjectRedColor() throws {
        let u = mkf("f2.pdf")
        _ = try CoordinatedTagWriter.write(u) { c,l in self.realTransform(tags:["Red","Purple","CW","1962"],appColor:"Red",authColor:true,c,l) }
        let (t,l) = readBack(u)
        XCTAssert(t.contains("Purple"), "Purple kept as text: \(t)")
        XCTAssertEqual(l, 6, "Red label from appColor")
    }
}
