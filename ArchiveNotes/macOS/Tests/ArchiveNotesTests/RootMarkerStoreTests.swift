import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

@Suite("RootMarkerStore — idempotent marker lifecycle")
struct RootMarkerStoreTests {

    private func makeScratchDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("ensureMarker creates a fresh marker when none exists")
    func createFresh() throws {
        let tmp = try makeScratchDir()
        defer { cleanup(tmp) }

        let marker = try RootMarkerStore.ensureMarker(at: tmp, kind: .notes)
        #expect(marker.kind == .notes)
        #expect(marker.name == tmp.lastPathComponent)

        let markerURL = tmp.appendingPathComponent(RootMarker.filename)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("ensureMarker returns same GUID on second call (idempotent)")
    func idempotent() throws {
        let tmp = try makeScratchDir()
        defer { cleanup(tmp) }

        let first = try RootMarkerStore.ensureMarker(at: tmp, kind: .notes)
        let second = try RootMarkerStore.ensureMarker(at: tmp, kind: .notes)

        #expect(first.guid == second.guid)
        // Compare to 1-second precision (ISO-8601 round-trip truncates sub-seconds).
        #expect(abs(first.createdAt.timeIntervalSince(second.createdAt)) < 1)
    }

    @Test("ensureMarker throws on corrupt (non-empty, invalid JSON) marker")
    func corruptThrows() throws {
        let tmp = try makeScratchDir()
        defer { cleanup(tmp) }

        let markerURL = tmp.appendingPathComponent(RootMarker.filename)
        try Data("not json at all".utf8).write(to: markerURL)

        #expect(throws: RootMarkerStore.MarkerError.self) {
            _ = try RootMarkerStore.ensureMarker(at: tmp, kind: .notes)
        }
    }

    @Test("ensureMarker writes fresh marker over empty file")
    func emptyFileWritesFresh() throws {
        let tmp = try makeScratchDir()
        defer { cleanup(tmp) }

        let markerURL = tmp.appendingPathComponent(RootMarker.filename)
        try Data().write(to: markerURL)

        let marker = try RootMarkerStore.ensureMarker(at: tmp, kind: .notes)
        #expect(marker.kind == .notes)
    }

    @Test("ensureMarker round-trips through JSON correctly")
    func jsonRoundTrip() throws {
        let tmp = try makeScratchDir()
        defer { cleanup(tmp) }

        let marker = try RootMarkerStore.ensureMarker(at: tmp, kind: .notes)

        let markerURL = tmp.appendingPathComponent(RootMarker.filename)
        let data = try Data(contentsOf: markerURL)
        let decoded = try JSONDecoder().decode(RootMarker.self, from: data)

        #expect(decoded.guid == marker.guid)
        #expect(decoded.kind == .notes)
    }
}
