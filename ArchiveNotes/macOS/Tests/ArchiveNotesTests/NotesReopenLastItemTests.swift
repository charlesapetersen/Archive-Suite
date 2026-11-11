import Testing
import Foundation
@testable import ArchiveNotes

/// W40.fix-notes-small-wins (owner, notes-2 row 6): at launch each window opens the note it had open when
/// Notes quit. A relaunch is a fresh `NotesNavigationModel` over the same defaults; every test uses a scratch
/// suite, never the app's own domain.
@MainActor
struct NotesReopenLastItemTests {

    private func makeModel() async throws -> (NotesModel, NotesIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-reopen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (NotesModel(organization: store), index, root)
    }
    private func cleanup(_ root: URL, _ index: NotesIndex) async {
        await index.close(); try? FileManager.default.removeItem(at: root)
    }
    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "com.archivenotes.tests.reopen.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    private func sum(_ title: String, kind: Item.Kind = .note, id: UUID = UUID()) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: id, title: title, kind: kind, date: nil, datePrecision: nil,
                           dateUncertain: false, authors: [], sortDate: nil, quality: nil,
                           created: t, modified: t, mtime: 0, managedTags: [])
    }
    private func window(_ model: NotesModel, _ defaults: UserDefaults?,
                        kind: ItemKindShell = .note) -> NotesNavigationModel {
        NotesNavigationModel(model: model, defaultKind: kind, rememberingLastOpenIn: defaults)
    }

    @Test func theNoteOpenAtQuitIsOpenAgainAtLaunch() async throws {
        let (model, index, root) = try await makeModel()
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite); Task { await cleanup(root, index) } }
        let a = sum("a"), b = sum("b")
        model.replaceItems([a, b])

        let first = window(model, defaults)
        #expect(first.selection.isEmpty, "nothing was open before")
        first.select(b.id)

        let relaunched = window(model, defaults)
        #expect(relaunched.selectedItemID == b.id)
    }

    @Test func theReopenWaitsForTheStoreToBeRead() async throws {
        let (model, index, root) = try await makeModel()
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite); Task { await cleanup(root, index) } }
        let a = sum("a")
        NotesAppSettings.setLastOpenItem(a.id, for: .note, into: defaults)

        let nav = window(model, defaults)   // the index has not answered yet
        #expect(nav.selection.isEmpty)
        model.replaceItems([sum("other"), a])
        #expect(nav.selectedItemID == a.id)
    }

    @Test func aChoiceMadeBeforeTheItemsArriveWins() async throws {
        let (model, index, root) = try await makeModel()
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite); Task { await cleanup(root, index) } }
        let a = sum("a"), b = sum("b")
        NotesAppSettings.setLastOpenItem(a.id, for: .note, into: defaults)

        let nav = window(model, defaults)
        nav.select(b.id)
        model.replaceItems([a, b])
        #expect(nav.selectedItemID == b.id)
        #expect(NotesAppSettings.lastOpenItem(for: .note, from: defaults) == b.id)
    }

    @Test func aNoteNoLongerInTheStoreOpensNothing() async throws {
        let (model, index, root) = try await makeModel()
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite); Task { await cleanup(root, index) } }
        NotesAppSettings.setLastOpenItem(UUID(), for: .note, into: defaults)
        let later = sum("later")

        let nav = window(model, defaults)
        model.replaceItems([sum("a")])
        #expect(nav.selection.isEmpty)
        // Only the first read of the store is a reopen: a later refresh never selects behind the user's back.
        NotesAppSettings.setLastOpenItem(later.id, for: .note, into: defaults)
        model.replaceItems([sum("a"), later])
        #expect(nav.selection.isEmpty)
    }

    @Test func closingTheNoteForgetsItAndAMultipleSelectionKeepsTheLastOne() async throws {
        let (model, index, root) = try await makeModel()
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite); Task { await cleanup(root, index) } }
        let a = sum("a"), b = sum("b")
        model.replaceItems([a, b])
        let nav = window(model, defaults)

        nav.select(a.id)
        nav.selection = [a.id, b.id]
        #expect(NotesAppSettings.lastOpenItem(for: .note, from: defaults) == a.id)
        nav.select(nil)
        #expect(NotesAppSettings.lastOpenItem(for: .note, from: defaults) == nil)
        #expect(window(model, defaults).selection.isEmpty)
    }

    @Test func eachWindowReopensItsOwnItem() async throws {
        let (model, index, root) = try await makeModel()
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite); Task { await cleanup(root, index) } }
        let note = sum("n"), extract = sum("e", kind: .extract)
        model.replaceItems([note, extract])

        window(model, defaults, kind: .note).select(note.id)
        window(model, defaults, kind: .extract).select(extract.id)

        #expect(window(model, defaults, kind: .note).selectedItemID == note.id)
        #expect(window(model, defaults, kind: .extract).selectedItemID == extract.id)
    }

    @Test func anItemOfAKindTheWindowDoesNotShowIsLeftClosed() async throws {
        let (model, index, root) = try await makeModel()
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite); Task { await cleanup(root, index) } }
        let extract = sum("e", kind: .extract)
        model.replaceItems([sum("n"), extract])
        // The Note window shows notes only, so an extract saved for it has no row there.
        NotesAppSettings.setLastOpenItem(extract.id, for: .note, into: defaults)
        #expect(window(model, defaults).selection.isEmpty)
    }

    @Test func noStoreReadsAndWritesNothing() async throws {
        let (model, index, root) = try await makeModel()
        defer { Task { await cleanup(root, index) } }
        let a = sum("a")
        model.replaceItems([a])
        window(model, nil).select(a.id)
        #expect(window(model, nil).selection.isEmpty)
    }
}
