// RootMarkerDurabilityTests.swift — a root's identity is either DURABLE or an error (W23.m6/W23.l3).
//
// The Codable/round-trip and happy-path disk tests live in `DurableLinkTests`. These cover the
// failure surface only: what `read`/`ensure` must do when the marker cannot be read, cannot be
// written, or is being created by two callers at once. Every case here used to hand back a marker
// the disk did not agree with — and a marker is only ever used to mint links that must still
// resolve after a relaunch.

import Testing
import Foundation
@testable import ArchiveCore

@Suite("RootMarkerDurability")
struct RootMarkerDurabilityTests {

    // MARK: - Helpers

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RootMarkerDurability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Write a valid marker straight to disk (no coordination) and return it.
    @discardableResult
    private func plantMarker(in dir: URL, guid: UUID = UUID()) throws -> RootMarker {
        let marker = RootMarker(guid: guid, name: "Archive", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: dir.appendingPathComponent(RootMarker.filename))
        return marker
    }

    private func thrownError(_ body: () throws -> Void) -> RootMarkerError? {
        do { try body(); return nil } catch { return error as? RootMarkerError }
    }

    // MARK: - read: unreadable is not absence (W23.m6)

    /// `read` used to funnel *every* non-ENOENT, non-decoding failure into "no marker here" — the
    /// one answer that licenses minting a replacement GUID.
    @Test(.enabled(if: getuid() != 0))
    func readReportsAnUnreadableMarkerInsteadOfCallingItAbsent() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try plantMarker(in: dir)
        let fileURL = dir.appendingPathComponent(RootMarker.filename)
        try chmod(fileURL, 0o000)
        defer { try? chmod(fileURL, 0o644) }

        let error = thrownError { _ = try RootMarker.read(at: dir) }
        guard case .unreadable = error else {
            Issue.record("expected .unreadable, got \(String(describing: error))")
            return
        }
    }

    @Test func readStillReportsGenuineAbsenceAsNil() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try RootMarker.read(at: dir) == nil)
    }

    // MARK: - ensure: never mint over an identity you merely failed to read (W23.m6)

    /// The data-loss path: a transient read error on an EXISTING marker was read as absence, so
    /// `ensure` minted and wrote a new GUID over it — every link already copied from this root then
    /// pointed at an archive that no longer existed.
    @Test(.enabled(if: getuid() != 0))
    func ensureRefusesToMintOverAnUnreadableMarker() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try plantMarker(in: dir)
        let fileURL = dir.appendingPathComponent(RootMarker.filename)
        let originalBytes = try Data(contentsOf: fileURL)
        try chmod(fileURL, 0o000)

        let error = thrownError { _ = try RootMarker.ensure(at: dir, kind: .reader, name: "Archive") }

        try chmod(fileURL, 0o644)   // restore before inspecting, so the check itself can read
        guard case .unreadable = error else {
            Issue.record("expected .unreadable, got \(String(describing: error))")
            return
        }
        #expect(try Data(contentsOf: fileURL) == originalBytes, "the existing marker must be untouched")
        #expect(try RootMarker.read(at: dir)?.guid == original.guid, "…so the root keeps its identity")
    }

    /// A marker that only exists in memory is not an identity: it is a different GUID after the next
    /// launch, so every link minted from it is born broken. `ensure` must refuse rather than hand it
    /// back looking like a normal marker — the provisional value rides along on the error instead.
    @Test(.enabled(if: getuid() != 0))
    func ensureRefusesToReturnAMarkerItCouldNotWrite() throws {
        let dir = try scratchDir()
        try chmod(dir, 0o500)   // r-x: readable, not writable
        defer {
            try? chmod(dir, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }

        let error = thrownError { _ = try RootMarker.ensure(at: dir, kind: .reader, name: "Archive") }
        guard case .readOnly(_, let provisional, _) = error else {
            Issue.record("expected .readOnly, got \(String(describing: error))")
            return
        }
        #expect(provisional.kind == .reader, "the lost identity is reported, not returned as durable")
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(RootMarker.filename).path
        ), "nothing was written")
    }

    // MARK: - ensure: first-time creation is a race (W23.l3)

    /// Two callers that both saw absence must not both mint a GUID. The check-then-write ordering
    /// let one of them return a marker the disk had already replaced with the other's — links copied
    /// in that window name a root that no longer identifies as itself.
    @Test func concurrentFirstTimeEnsureAgreesWithWhatLandedOnDisk() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let box = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            box.record(Result { try RootMarker.ensure(at: dir, kind: .reader, name: "Archive") })
        }

        #expect(box.errors.isEmpty, "no caller should fail: \(box.errors)")
        #expect(box.markers.count == 8)
        let onDisk = try #require(try RootMarker.read(at: dir))
        #expect(Set(box.markers.map(\.guid)) == [onDisk.guid],
                "every caller must be handed the GUID the root actually ended up with")
    }

    /// Thread-safe collector for the concurrent-`ensure` fixture.
    private final class ConcurrentResults: @unchecked Sendable {
        private let lock = NSLock()
        private var _markers: [RootMarker] = []
        private var _errors: [Error] = []

        var markers: [RootMarker] { lock.lock(); defer { lock.unlock() }; return _markers }
        var errors: [Error] { lock.lock(); defer { lock.unlock() }; return _errors }

        func record(_ result: Result<RootMarker, Error>) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let marker): _markers.append(marker)
            case .failure(let error): _errors.append(error)
            }
        }
    }
}
