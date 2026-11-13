// ImproveOCRReceiptTests.swift — the Processor's content-revision receipt for the Reader (W44.reocr-processor)
import Testing
import Foundation
import Darwin
@testable import ArchiveCore

@Suite("ImproveOCRReceipt")
struct ImproveOCRReceiptTests {
    private func support() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("receipts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func receipt(_ op: UUID, after: String = "bb") -> ImproveOCRReceipt {
        ImproveOCRReceipt(operationID: op, key: .init(rootGUID: UUID(uuidString: "7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e")!,
                                                      relativePath: "Box 3/letter.pdf"),
                          textPages: [5, 1], beforeSHA256: "aa", afterSHA256: after, outcome: .published)
    }

    @Test func writesOnceAndReadsBack() throws {
        let s = try support(), op = UUID(), r = receipt(op)
        try r.write(to: s)
        let url = ImproveOCRReceipt.url(for: op, in: s)
        #expect(try ImproveOCRReceipt.read(url) == r)
        #expect(r.textPages == [1, 5])
        try r.write(to: s)   // the same receipt again: a no-op
        // Rebuilt later (a retry, recovery): another date, the same revision.
        try ImproveOCRReceipt(operationID: op, key: .init(rootGUID: r.rootGUID, relativePath: r.relativePath), textPages: [1, 5],
                              beforeSHA256: "aa", afterSHA256: "bb", outcome: .published,
                              date: Date().addingTimeInterval(90)).write(to: s)
        #expect(throws: (any Error).self) { try receipt(op, after: "cc").write(to: s) }
        var st = stat(); lstat(url.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        let all = try FileManager.default.contentsOfDirectory(atPath: s.appendingPathComponent("Receipts").path)
        #expect(all == ["\(op.uuidString).json"], "\(all)")
    }

    @Test func carriesNoTextOrAbsolutePath() throws {
        let s = try support(), op = UUID()
        try receipt(op).write(to: s)
        let json = try String(contentsOf: ImproveOCRReceipt.url(for: op, in: s), encoding: .utf8)
        #expect(!json.contains(s.path) && json.contains("Box 3"))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        #expect(Set(object.keys)
                == ["operationID", "rootGUID", "relativePath", "textPages", "beforeSHA256", "afterSHA256", "outcome", "date"])
    }
}
