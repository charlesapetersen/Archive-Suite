import Testing
import Foundation
@testable import ArchiveNotes

// W23.h2 — same-item edit transactions must never lose an update.
//
// Every note edit used to be a load-whole-item → mutate → save-whole-item pair of SEPARATE
// `NoteStore` calls. The actor serializes each individual call but not the read-modify-write
// *transaction*, and `NotesModel` is `@MainActor` yet reentrant at every `await` — so two tasks
// could both load the same old item, apply different edits, and save in either order. The later
// whole-item save silently dropped the other's body, metadata or source blocks.
//
// Measured against the pre-fix code, the raw pattern lost 23 of 24 concurrent same-item appends.
// `NoteStore.withItem` closes it by making the transaction the unit of serialization: load, mutate
// and save run in ONE actor-isolated call with no suspension point between the read and the write.
//
// Everything here runs against a scratch `mktemp` store — never the owner's real Notes store
// (Prime Directive #1).

@Suite("W23.h2 — same-item edit transactions never lose an update")
struct NotesItemTransactionTests {

    // MARK: - Scratch fixtures

    private static func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-w23h2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func blankItem(id: UUID = UUID(),
                                  kind: Item.Kind = .note,
                                  title: String = "Note",
                                  body: String? = nil,
                                  blocks: [Block] = []) -> Item {
        Item(id: id, kind: kind, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: blocks,
             unknownFrontMatter: [], trailingBodyRaw: body)
    }

    // MARK: - The primitive: contention on ONE item

    @Test("24 concurrent withItem transactions on one item ALL survive")
    func concurrentTransactionsNeverLoseAnUpdate() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, body: ""))

        let n = 24
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    _ = try? await store.withItem(id) { item in
                        item.trailingBodyRaw = (item.trailingBodyRaw ?? "") + "\(i);"
                    }
                }
            }
        }

        let final = try await store.load(id)
        let landed = Set((final.trailingBodyRaw ?? "").split(separator: ";").map(String.init))
        #expect(landed.count == n)
        for i in 0..<n { #expect(landed.contains("\(i)")) }
    }

    @Test("concurrent transactions on DIFFERENT fields of one item all compose")
    func concurrentFieldEditsCompose() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, body: "body"))

        async let a: ItemTransaction? = try? store.withItem(id) { $0.quality = 4 }
        async let b: ItemTransaction? = try? store.withItem(id) { $0.date = "1968"; $0.datePrecision = .year }
        async let c: ItemTransaction? = try? store.withItem(id) { $0.dateUncertain = true }
        _ = await (a, b, c)

        let r = try await store.load(id)
        #expect(r.quality == 4)
        #expect(r.date == "1968")
        #expect(r.datePrecision == .year)
        #expect(r.dateUncertain)
        #expect(r.trailingBodyRaw == "body")
    }

    // MARK: - The primitive: what it returns, and how it fails

    @Test("withItem returns the item exactly as written, with a fresh ref")
    func returnsWrittenItemAndRef() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, title: "Before", body: "old"))

        let tx = try await store.withItem(id) { $0.title = "After"; $0.trailingBodyRaw = "new" }
        #expect(tx.item.title == "After")
        #expect(tx.item.trailingBodyRaw == "new")
        #expect(tx.ref.id == id)
        // The title is a projection of the filename, so the rename landed too.
        #expect(tx.ref.url.lastPathComponent == "After.md")
        let onDisk = try await store.load(id)
        #expect(onDisk.title == tx.item.title)
        #expect(onDisk.trailingBodyRaw == tx.item.trailingBodyRaw)
    }

    @Test("withItem on a missing item throws notFound and writes nothing")
    func missingItemThrows() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let ghost = UUID()

        await #expect(throws: (any Error).self) {
            _ = try await store.withItem(ghost) { $0.quality = 1 }
        }
        let dir = NoteStore.itemDir(root: store.rootURL, id: ghost)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("a throwing mutate aborts the transaction and leaves the .md untouched")
    func throwingMutateLeavesDiskUntouched() async throws {
        struct Boom: Error {}
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.create(Self.blankItem(id: id, title: "Keep", body: "pristine"))

        await #expect(throws: Boom.self) {
            _ = try await store.withItem(id) { item in
                item.trailingBodyRaw = "clobbered"
                throw Boom()
            }
        }
        let r = try await store.load(id)
        #expect(r.trailingBodyRaw == "pristine")
        #expect(r.title == "Keep")
    }

    @Test("withTemplate is atomic over the Templates container too")
    func templateTransactionsAreAtomic() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let id = UUID()
        _ = try await store.createTemplate(Self.blankItem(id: id, title: "T", body: ""))

        let n = 12
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    _ = try? await store.withTemplate(id) { item in
                        item.trailingBodyRaw = (item.trailingBodyRaw ?? "") + "\(i);"
                    }
                }
            }
        }

        let final = try await store.loadTemplate(id)
        let landed = Set((final.trailingBodyRaw ?? "").split(separator: ";").map(String.init))
        #expect(landed.count == n)
    }
}
