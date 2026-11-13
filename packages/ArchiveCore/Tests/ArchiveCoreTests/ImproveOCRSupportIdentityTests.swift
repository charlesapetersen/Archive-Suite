// ImproveOCRSupportIdentityTests.swift — the shared support folder's identity (W44.reocr-processor)
import Testing
import Foundation
@testable import ArchiveCore

@Suite("ImproveOCRSupportIdentity")
struct ImproveOCRSupportIdentityTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func madeOnceThenRead() throws {
        let s = try folder()
        #expect(try ImproveOCRSupportIdentity.identity(of: s, create: false) == nil)
        let id = try #require(try ImproveOCRSupportIdentity.identity(of: s, create: true))
        #expect(try ImproveOCRSupportIdentity.identity(of: s, create: true) == id)
        #expect(try ImproveOCRSupportIdentity.identity(of: s, create: false) == id)
        // A different folder is a different store.
        #expect(try ImproveOCRSupportIdentity.identity(of: try folder(), create: true) != id)
    }

    @Test func twoAppsCreatingAtOnceAgree() throws {
        let s = try folder()
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var ids: [UUID?] = []
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let id = try? ImproveOCRSupportIdentity.identity(of: s, create: true)
            results.lock.withLock { results.ids.append(id) }
        }
        #expect(results.ids.count == 8 && results.ids.allSatisfy { $0 != nil } && Set(results.ids.compactMap { $0 }).count == 1)
    }

    @Test func aFolderInsideAnArchiveIsRefused() throws {
        let s = try folder()
        try Data("{}".utf8).write(to: s.appendingPathComponent(RootMarker.filename))
        #expect(throws: (any Error).self) { _ = try ImproveOCRSupportIdentity.identity(of: s, create: true) }
    }
}
