import Testing
import Foundation
@testable import ArchiveNotes

// W6-S6 — Templates. Three layers: the pure nearest-ancestor resolver (no I/O), the `NoteStore`
// template storage (scratch `mktemp` dir — never a real corpus, Prime Directive #1), and the
// `NotesModel` template actions (assign / resolve / dangling-cleanup / new-from-template / CRUD).

// MARK: - Pure resolver

@Suite("TemplateResolution — nearest-ancestor + dangling")
struct TemplateResolutionTests {

    private func folder(_ id: UUID, parent: UUID? = nil) -> VFolder {
        VFolder(id: id, name: id.uuidString, parentId: parent, sortOrder: 0, kind: .normal, queryJSON: nil)
    }

    @Test("direct assignment on the folder resolves")
    func directAssignment() {
        let f = UUID(), t = UUID()
        let r = TemplateResolution.resolve(
            folderId: f, folders: [folder(f)],
            assignments: [TemplateAssignment(folderId: f, templateId: t)],
            existingTemplateIDs: [t])
        #expect(r.templateId == t)
        #expect(r.dangling.isEmpty)
    }

    @Test("nearest ancestor's assignment resolves for a child with none")
    func nearestAncestor() {
        let parent = UUID(), child = UUID(), t = UUID()
        let r = TemplateResolution.resolve(
            folderId: child, folders: [folder(parent), folder(child, parent: parent)],
            assignments: [TemplateAssignment(folderId: parent, templateId: t)],
            existingTemplateIDs: [t])
        #expect(r.templateId == t)
    }

    @Test("self assignment wins over an ancestor's")
    func selfOverAncestor() {
        let parent = UUID(), child = UUID(), tParent = UUID(), tChild = UUID()
        let r = TemplateResolution.resolve(
            folderId: child, folders: [folder(parent), folder(child, parent: parent)],
            assignments: [TemplateAssignment(folderId: parent, templateId: tParent),
                          TemplateAssignment(folderId: child, templateId: tChild)],
            existingTemplateIDs: [tParent, tChild])
        #expect(r.templateId == tChild)
    }

    @Test("no assignment anywhere → Blank (nil)")
    func blankFallback() {
        let parent = UUID(), child = UUID()
        let r = TemplateResolution.resolve(
            folderId: child, folders: [folder(parent), folder(child, parent: parent)],
            assignments: [], existingTemplateIDs: [])
        #expect(r.templateId == nil)
        #expect(r.dangling.isEmpty)
    }

    @Test("assignment to a deleted template is dangling → nil + reported for cleanup")
    func danglingReported() {
        let f = UUID(), gone = UUID()
        let r = TemplateResolution.resolve(
            folderId: f, folders: [folder(f)],
            assignments: [TemplateAssignment(folderId: f, templateId: gone)],
            existingTemplateIDs: [])          // `gone` not present
        #expect(r.templateId == nil)
        #expect(r.dangling == [f])
    }

    @Test("dangling child falls through to a live ancestor, still reports the dangling folder")
    func danglingFallsThroughToLiveAncestor() {
        let parent = UUID(), child = UUID(), live = UUID(), gone = UUID()
        let r = TemplateResolution.resolve(
            folderId: child, folders: [folder(parent), folder(child, parent: parent)],
            assignments: [TemplateAssignment(folderId: parent, templateId: live),
                          TemplateAssignment(folderId: child, templateId: gone)],
            existingTemplateIDs: [live])      // only the parent's template exists
        #expect(r.templateId == live)
        #expect(r.dangling == [child])
    }

    @Test("nil folder → nil, no dangling")
    func nilFolder() {
        let r = TemplateResolution.resolve(
            folderId: nil, folders: [], assignments: [], existingTemplateIDs: [])
        #expect(r.templateId == nil)
        #expect(r.dangling.isEmpty)
    }

    @Test("a parent cycle terminates (visited-set guard)")
    func cycleTerminates() {
        let a = UUID(), b = UUID()
        // a.parent = b, b.parent = a — a corrupt cycle; must not spin.
        let r = TemplateResolution.resolve(
            folderId: a, folders: [folder(a, parent: b), folder(b, parent: a)],
            assignments: [], existingTemplateIDs: [])
        #expect(r.templateId == nil)
    }
}

// MARK: - NoteStore template storage (scratch)

@Suite("NoteStore — templates")
struct NoteStoreTemplateTests {

    private func makeStore() throws -> (NoteStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteStoreTpl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (NoteStore(root: tmp), tmp)
    }

    private func makeItem(_ title: String, kind: Item.Kind = .note, body: String? = nil) -> Item {
        Item(id: UUID(), kind: kind, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: body)
    }

    @Test("createTemplate then loadTemplate round-trips title/kind/body")
    func roundTrip() async throws {
        let (store, tmp) = try makeStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let t = makeItem("Meeting", kind: .note, body: "Agenda")
        _ = try await store.createTemplate(t)
        let loaded = try await store.loadTemplate(t.id)
        #expect(loaded.title == "Meeting")
        #expect(loaded.kind == .note)
        #expect(loaded.trailingBodyRaw == "Agenda")
    }

    @Test("allTemplates lists created templates, sorted by name")
    func listSorted() async throws {
        let (store, tmp) = try makeStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await store.createTemplate(makeItem("Zeta"))
        _ = try await store.createTemplate(makeItem("alpha", kind: .extract))
        let list = await store.allTemplates()
        #expect(list.map(\.name) == ["alpha", "Zeta"])
        #expect(list.first?.kind == .extract)
    }

    @Test("templates never leak into the note list")
    func noLeak() async throws {
        let (store, tmp) = try makeStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await store.createTemplate(makeItem("Tpl"))
        let ids = await store.allItemIDs()
        #expect(ids.isEmpty)
    }

    @Test("saveTemplate renames the file when the name changes")
    func renameOnSave() async throws {
        let (store, tmp) = try makeStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        var t = makeItem("Old Name")
        _ = try await store.createTemplate(t)
        t.title = "New Name"
        let ref = try await store.saveTemplate(t)
        #expect(ref.url.lastPathComponent == "New Name.md")
        let list = await store.allTemplates()
        #expect(list.map(\.name) == ["New Name"])
    }

    @Test("deleteTemplate removes it from the listing")
    func delete() async throws {
        let (store, tmp) = try makeStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let t = makeItem("Doomed")
        _ = try await store.createTemplate(t)
        try await store.deleteTemplate(t.id)
        let list = await store.allTemplates()
        #expect(list.isEmpty)
    }
}

// MARK: - NotesModel template actions (scratch)

@Suite("NotesModel — templates")
@MainActor
struct NotesModelTemplateTests {

    struct Env { let model: NotesModel; let org: OrganizationStore; let store: NoteStore
                 let index: NotesIndex; let root: URL }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-tpl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        return Env(model: model, org: org, store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func templateItem(_ title: String, kind: Item.Kind = .note, date: String? = nil,
                              quality: Int? = nil, tags: [String] = [], body: String? = nil) -> Item {
        Item(id: UUID(), kind: kind, title: title, authors: [], date: date,
             datePrecision: date == nil ? nil : .year, dateUncertain: false, quality: quality,
             tags: tags, zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
             blocks: [], unknownFrontMatter: [], trailingBodyRaw: body)
    }

    @Test("createTemplate then reload lists it; kind filtering offers only matching kinds")
    func createAndKindFilter() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        _ = await env.model.createTemplate(name: "Note Tpl", kind: .note)
        _ = await env.model.createTemplate(name: "Extract Tpl", kind: .extract)
        #expect(env.model.templates.count == 2)
        #expect(env.model.templates(matching: .note).map(\.name) == ["Note Tpl"])
        #expect(env.model.templates(matching: .extract).map(\.name) == ["Extract Tpl"])
    }

    @Test("assign + effectiveTemplate resolves through the nearest ancestor")
    func assignResolve() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let tid = try #require(await env.model.createTemplate(name: "T", kind: .note))
        let parent = try await env.org.createFolder(name: "Parent").id
        let child = try await env.org.createFolder(name: "Child", parent: parent).id
        await env.model.assignTemplate(tid, to: parent)
        #expect(env.model.effectiveTemplate(for: child)?.id == tid)
        #expect(env.model.effectiveTemplate(for: parent)?.id == tid)
    }

    @Test("effectiveTemplate returns nil for an assignment to a since-deleted template")
    func effectiveDangling() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let tid = try #require(await env.model.createTemplate(name: "T", kind: .note))
        let f = try await env.org.createFolder(name: "F").id
        await env.model.assignTemplate(tid, to: f)
        // Delete the template directly on disk (external), then refresh the list → dangling.
        try await env.store.deleteTemplate(tid)
        await env.model.reloadTemplates()
        #expect(env.model.effectiveTemplate(for: f) == nil)
    }

    @Test("deleteTemplate clears every folder assignment that pointed at it")
    func deleteClearsAssignments() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let tid = try #require(await env.model.createTemplate(name: "T", kind: .note))
        let a = try await env.org.createFolder(name: "A").id
        let b = try await env.org.createFolder(name: "B").id
        await env.model.assignTemplate(tid, to: a)
        await env.model.assignTemplate(tid, to: b)
        #expect(env.org.assignments.count == 2)
        await env.model.deleteTemplate(tid)
        #expect(env.org.assignments.isEmpty)
        #expect(env.model.templates.isEmpty)
    }

    @Test("new-from-template clones defaults + body into a fresh item and files it in the folder")
    func newFromTemplate() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        // A template carrying real defaults + a body (built directly for the assertion).
        let tpl = templateItem("Interview", date: "1990", quality: 3, tags: ["oral-history"], body: "Q: …")
        _ = try await env.store.createTemplate(tpl)
        await env.model.reloadTemplates()
        let folder = try await env.org.createFolder(name: "Project").id

        let newID = try #require(await env.model.newItem(kind: .note, in: folder, from: tpl.id))
        #expect(newID != tpl.id)
        let created = try await env.store.load(newID)
        #expect(created.title == "Interview")
        #expect(created.date == "1990")
        #expect(created.quality == 3)
        #expect(created.tags == ["oral-history"])
        #expect(created.trailingBodyRaw == "Q: …")
        #expect(env.org.foldersContaining(item: newID) == [folder])
    }

    @Test("blank new note is filed in Inbox; blank new extract in Extracts (§16.6)")
    func blankNewItemDefaultFolders() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let note = try #require(await env.model.newItem(kind: .note, in: nil, from: nil))
        let extract = try #require(await env.model.newItem(kind: .extract, in: nil, from: nil))
        #expect(env.org.foldersContaining(item: note) == [OrganizationStore.inboxFolderId])
        #expect(env.org.foldersContaining(item: extract) == [OrganizationStore.extractsFolderId])
    }
}
