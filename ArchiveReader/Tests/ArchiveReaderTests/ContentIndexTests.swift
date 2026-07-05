import XCTest
@testable import ArchiveReader

final class ContentIndexTests: XCTestCase {

    private func makeIndex() -> (ContentIndex, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ci-\(UUID().uuidString).sqlite3")
        return (ContentIndex(url: url), url)
    }

    func testUpsertAndSearch() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a.pdf",
                             classification: "Document Start", body: "Senator Chafee discussed the Cold War budget.")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b.pdf",
                             classification: "Continuation", body: "Economic policy and taxes in California.")
        let cold = await idx.search("Cold War")
        XCTAssertEqual(cold, ["/a.pdf"])
        let taxes = await idx.search("taxes")
        XCTAssertEqual(taxes, ["/b.pdf"])
        let none = await idx.search("nonexistentterm")
        XCTAssertTrue(none.isEmpty)
        await idx.close()
    }

    func testNeedsIndexIncremental() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let unindexed = await idx.needsIndex(path: "/a.pdf", mtime: 100)
        XCTAssertTrue(unindexed)
        try await idx.upsert(path: "/a.pdf", mtime: 100, name: "a", classification: nil, body: "hello world")
        let same = await idx.needsIndex(path: "/a.pdf", mtime: 100)
        XCTAssertFalse(same)
        let changed = await idx.needsIndex(path: "/a.pdf", mtime: 200)
        XCTAssertTrue(changed)
        await idx.close()
    }

    func testReindexReplacesOldBody() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "apples")
        try await idx.upsert(path: "/a.pdf", mtime: 2, name: "a", classification: nil, body: "oranges")
        let apples = await idx.search("apples")
        XCTAssertTrue(apples.isEmpty)                      // old body gone
        let oranges = await idx.search("oranges")
        XCTAssertEqual(oranges, ["/a.pdf"])
        let count = await idx.indexedCount()
        XCTAssertEqual(count, 1)                            // still a single file
        await idx.close()
    }

    func testMultiTermSearchIsAnd() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "cold war budget")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b", classification: nil, body: "cold weather report")
        let both = await idx.search("cold war")
        XCTAssertEqual(both, ["/a.pdf"])                                    // AND of terms
        let cold = await idx.search("cold")
        XCTAssertEqual(Set(cold), ["/a.pdf", "/b.pdf"])
        await idx.close()
    }

    func testArbitraryQueryDoesNotCrashFTS() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "hello")
        // Punctuation that would be invalid raw FTS5 syntax must be handled safely.
        _ = await idx.search("\"unbalanced ( quote * AND")
        await idx.close()
    }

    func testClassificationParsing() {
        let page2 = "Extracted text.\n00023 IMG — Brown.jpg\nGemini · Gemini 2.5 · 19 June 2026\nClassification: Document Start\nINTRODUCTION"
        XCTAssertEqual(PDFTextExtractor.parseClassification(from: page2), "Document Start")
        XCTAssertEqual(PDFTextExtractor.parseClassification(from: "Classification: Box"), "Box")
        XCTAssertNil(PDFTextExtractor.parseClassification(from: "no classification line here"))
    }
}
