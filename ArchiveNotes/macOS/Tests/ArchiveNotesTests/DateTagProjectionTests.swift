import Testing
import Foundation
@testable import ArchiveNotes
import ArchiveCore

/// W19.date — front-matter date remains authoritative, while the Notes-owned scratch `.md` mirrors
/// only the existing ArchiveCore Year/Month/Day/Decade facets. Never a corpus file.
@Suite("DateTagProjection — front-matter authority + existing date facets")
@MainActor
struct DateTagProjectionTests {
    struct Env { let model: NotesModel; let store: NoteStore; let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-dateprojection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        return Env(model: NotesModel(organization: org, index: index, noteStore: store),
                   store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func makeNote(_ env: Env, tags: [String] = []) async throws -> UUID {
        let item = Item(id: UUID(), kind: .note, title: "Date note", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: tags, zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        return item.id
    }

    private func finderTags(_ env: Env, _ id: UUID) async throws -> [String] {
        let url = try await env.store.mdURL(for: id)
        return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    @Test("date precision maps to existing facets and removes only the previous mirrored date")
    func projectsDateFacetsLosslessly() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, tags: ["1984"])
        let url = try await env.store.mdURL(for: id)
        try (url as NSURL).setResourceValue(["1984", "Do Not Sync"], forKey: .tagNamesKey)

        await env.model.setDate("1960", precision: .decade, for: id)
        #expect(Set(try await finderTags(env, id)) == ["1984", "1960s", "Do Not Sync"])

        await env.model.setDate("1968", precision: .year, for: id)
        #expect(Set(try await finderTags(env, id)) == ["1984", "1968", "Do Not Sync"])

        await env.model.setDate("1968-03", precision: .month, for: id)
        #expect(Set(try await finderTags(env, id)) == ["1984", "1968", "03 March", "Do Not Sync"])

        await env.model.setDate("1968-03-05", precision: .day, for: id)
        let datedTags = try await finderTags(env, id)
        #expect(Set(datedTags) == ["1984", "1968", "03 March", "Day 5", "Do Not Sync"])
        let parsed = DocumentTags.parse(raw: datedTags, labelNumber: nil)
        #expect(parsed.year == 1968 && parsed.month?.number == 3 && parsed.day == 5,
                "the appended authoritative facets must win over the subject token 1984")

        await env.model.setDate(nil, precision: nil, for: id)
        #expect(Set(try await finderTags(env, id)) == ["1984", "Do Not Sync"],
                "clearing the date removes only the previous date tokens")
    }

    @Test("date and Quality facets coexist without a new vocabulary or a label write")
    func coexistsWithQuality() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, tags: ["1984"])
        let url = try await env.store.mdURL(for: id)
        try (url as NSURL).setResourceValue(["1984", "Do Not Sync"], forKey: .tagNamesKey)
        try (url as NSURL).setResourceValue(6, forKey: .labelNumberKey)

        await env.model.setDate("1971-04", precision: .month, for: id)
        await env.model.setQuality(3, for: id)
        let tags = try await finderTags(env, id)
        #expect(Set(tags) == ["1984", "1971", "04 April", "Q3", "Do Not Sync"])
        let parsed = DocumentTags.parse(raw: tags, labelNumber: nil)
        #expect(parsed.year == 1971 && parsed.month?.number == 4 && parsed.quality == 3)
        #expect(try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber == 6,
                "date projection must preserve the Finder label")
    }

    @Test("malformed or unsupported-width front-matter dates invent no tag")
    func malformedDateProjectsNothing() {
        let invalidDates: [(String, Item.DatePrecision)] = [
            ("1968-13", .month), ("10", .year), ("10000", .year), ("10", .decade), ("10000", .decade)
        ]
        for (date, precision) in invalidDates {
            let item = Item(id: UUID(), kind: .note, title: "Malformed", authors: [], date: date,
                            datePrecision: precision, dateUncertain: false, quality: nil, tags: [], zotero: [],
                            roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                            unknownFrontMatter: [], trailingBodyRaw: nil)
            #expect(NotesTagVocabulary.dateFacetTokens(for: item).isEmpty, "\(date) / \(precision)")
        }
    }

    @Test("a body save that overtakes date projection carries exact date-facet ownership")
    func bodySaveOvertakingDateCarriesFacetOwnership() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let id = try await makeNote(env, tags: ["1984"])
        await env.model.setDate("1960", precision: .decade, for: id)

        let dateTx = try await env.store.withItem(id) { item in
            item.date = "1968"
            item.datePrecision = .year
            item.modified = Date()
        }
        let bodyTx = try await env.store.withItem(id) { item in
            item.trailingBodyRaw = "overtook the date save"
            item.modified = Date()
        }
        #expect(dateTx.ownedDateFacetTokens == ["1960s"])
        #expect(bodyTx.ownedDateFacetTokens == ["1960s"],
                "the later body save must carry the preempted date's exact on-disk ownership")

        let projected = try await env.store.performIfCurrent(bodyTx.ref) { ref in
            _ = try NotesTagProjector.project(
                NotesTagVocabulary.facetProjectionTokens(for: bodyTx.item),
                previouslyManaged: bodyTx.ownedDateFacetTokens.union(NotesTagVocabulary.qualityTokens),
                to: ref.url,
                itemDir: ref.url.deletingLastPathComponent(),
                orderedFacetTokens: NotesTagVocabulary.dateFacetTokens(for: bodyTx.item),
                expectedIdentity: ref.identity)
        }
        #expect(projected)
        #expect(Set(try await finderTags(env, id)) == ["1984", "1968"],
                "the old Notes-owned 1960s facet must not survive a preempted date projection")
    }

    @Test("a matching third-party date token is not adopted or removed")
    func externalMatchingDateTokenSurvivesClear() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let item = Item(id: UUID(), kind: .note, title: "External date", authors: [], date: "1968",
                        datePrecision: .year, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.create(item)
        let url = try await env.store.mdURL(for: item.id)
        try (url as NSURL).setResourceValue(["1968", "Do Not Sync"], forKey: .tagNamesKey)
        #expect(NotesTagProjector.recoverPreviouslyManaged(for: item, from: url).isEmpty,
                "date ownership comes only from the item ledger, never an equal Finder tag")

        await env.model.setDate(nil, precision: nil, for: item.id)
        #expect(Set(try await finderTags(env, item.id)) == ["1968", "Do Not Sync"],
                "a date-like tag that Notes did not introduce remains external")
    }

    @Test("template-derived dates project when the item is created")
    func templateDerivedDateProjectsOnCreation() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let template = Item(id: UUID(), kind: .note, title: "Dated template", authors: [], date: "1971-04-05",
                            datePrecision: .day, dateUncertain: false, quality: nil, tags: [], zotero: [],
                            roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                            unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await env.store.createTemplate(template)

        let id = try #require(await env.model.newItem(kind: .note, in: nil, from: template.id))
        #expect(Set(try await finderTags(env, id)) == ["1971", "04 April", "Day 5"])
    }
}
