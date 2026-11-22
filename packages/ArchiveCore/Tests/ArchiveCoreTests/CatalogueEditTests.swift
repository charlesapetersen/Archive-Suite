import Foundation
import Testing
@testable import ArchiveCore

@Suite("Catalogue field edits")
struct CatalogueEditTests {
    private let file = UUID()
    private let document = UUID()
    private let baseRevision = UUID()
    private let fieldRevision = UUID()

    @Test func editPreservesEvidenceAndUnfamiliarWireValues() throws {
        let base = try record()
        let date = CatalogueEdit.Target.document(document, .documentDate)
        let edit = CatalogueEdit(date, .set(.date(.init(date: try #require(ArchiveDate(year: 1957)), uncertain: true))))
        let saved = try CatalogueEditPatch(edits: [edit]).applying(to: base)
        let field = try #require(saved.document(id: document)?.fields?.documentDate)
        #expect(saved.parents == [baseRevision])
        #expect(saved.contentRevision == base.contentRevision)
        #expect(field.origin == "user")
        #expect(field.fieldRevision != fieldRevision && !field.isChecked)
        #expect(field.evidence.first?.supportsRevision == fieldRevision)
        let wire = String(decoding: saved.originalJSON, as: UTF8.self)
        #expect(wire.contains(#""futureRoot":{"large":1e999999}"#))
        #expect(wire.contains(#""futureField":[1e999999, "preserve spacing"]"#))
        #expect(wire.contains(#""futureDate":{"n":1e999999}"#))
        #expect(wire.contains(#""futureEvidence":1e999999"#))
        #expect(throws: CatalogueEdit.Invalid.unsupportedFieldData(date)) {
            try CatalogueEditPatch(edits: [.init(date, .clear)]).applying(to: saved)
        }
    }

    @Test func changedChecksConflictButOtherFieldsAndIntentionalClearsSurvive() throws {
        let base = try record()
        let date = CatalogueEdit.Target.document(document, .documentDate)
        let title = CatalogueEdit.Target.document(document, .title)
        let uncheck = CatalogueEditPatch(edits: [.init(date, .check(false))])
        let unverified = try uncheck.applying(to: base)
        let field = try #require(unverified.document(id: document)?.fields?.documentDate)
        #expect(field.fieldRevision == fieldRevision && !field.isChecked)
        #expect(try uncheck.conflicts(base: base, current: unverified) == [date])
        let clear = CatalogueEditPatch(edits: [.init(title, .clear)])
        #expect(try clear.conflicts(base: base, current: unverified).isEmpty)
        let both = try clear.applying(to: unverified)
        guard case .cleared? = both.document(id: document)?.fields?.title?.current else {
            Issue.record("Explicit clear was lost")
            return
        }
        #expect(try clear.applying(to: both).originalJSON == both.originalJSON)
        #expect(try uncheck.applying(to: both).revision == both.revision)
        #expect(throws: CatalogueEdit.Invalid.repeatedTarget(title)) {
            try CatalogueEditPatch(edits: [.init(title, .clear), .init(title, .check(false))]).applying(to: base)
        }
    }

    @Test func patchRejectsForeignDocumentsAndInvalidValues() throws {
        let foreign = try record(owned: false)
        let title = CatalogueEdit.Target.document(document, .title)
        #expect(throws: CatalogueEdit.Invalid.unavailableTarget(title)) {
            try CatalogueEditPatch(edits: [.init(title, .clear)]).applying(to: foreign)
        }
        #expect(throws: CatalogueEdit.Invalid.incompatibleValue(.file(.quality))) {
            try CatalogueEditPatch(edits: [.init(.file(.quality), .set(.rating(4)))]).applying(to: foreign)
        }
    }

    private func record(owned: Bool = true) throws -> CatalogueRecord {
        let owner = owned ? file : UUID()
        let fields = owned ? """
        ,"fields":{"documentDate":{"state":"value","value":{"date":"1958","uncertain":false,"futureDate":{"n":1e999999}},
             "fieldRevision":"\(fieldRevision)","origin":"imported","checkedRevision":"\(fieldRevision)",
             "evidence":[{"source":"scan","supportsRevision":"\(fieldRevision)","futureEvidence":1e999999}],
             "futureField":[1e999999, "preserve spacing"]}}
        """ : ""
        return try CatalogueRecord(json: Data("""
        {"schema":1,"fileID":"\(file)","contentRevision":"\(UUID())","revision":"\(baseRevision)","parents":[],
         "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
         "documents":[{"id":"\(document)","ownerFileID":"\(owner)"\(fields)}],
         "fileFields":{},"futureRoot":{"large":1e999999}}
        """.utf8))
    }
}
