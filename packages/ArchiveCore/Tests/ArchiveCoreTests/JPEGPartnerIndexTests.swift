import Foundation
import Testing
@testable import ArchiveCore

@Suite("JPEG partner stem index — scratch trees only")
struct JPEGPartnerIndexTests {
    private func makeTree() throws -> (root: URL, main: URL, jpegs: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JPEGPartnerIndexTests-\(UUID().uuidString)", isDirectory: true)
        let main = root.appendingPathComponent("MAIN", isDirectory: true)
        let jpegs = root.appendingPathComponent("JPEGS", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        return (root, main, jpegs)
    }

    private func makeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("scratch".utf8).write(to: url)
    }

    private func index(_ jpegs: URL) -> JPEGPartnerIndex {
        JPEGPartnerIndex(jpegRoot: jpegs,
                         scan: CorpusWalker.scanFingerprints(root: jpegs))
    }

    @Test("exact mirrored relative path wins before a duplicate stem elsewhere")
    func mirroredPathWins() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let pdf = tree.main.appendingPathComponent("Cambridge/Young/scan.pdf")
        let mirrored = tree.jpegs.appendingPathComponent("Cambridge/Young/scan.JPG")
        let duplicate = tree.jpegs.appendingPathComponent("Other Collection/scan.jpeg")
        try makeFile(pdf)
        try makeFile(mirrored)
        try makeFile(duplicate)

        let partnerIndex = index(tree.jpegs)
        let result = partnerIndex.resolve(pdfURL: pdf, mainRoot: tree.main)
        let discoveredMirror = URL(fileURLWithPath: try #require(
            partnerIndex.candidates.first(where: { $0.stem == "scan" })?.path))
        #expect(result == .match(discoveredMirror))
    }

    @Test("a relocated unique stem resolves across renamed collection folders")
    func relocatedUniqueStemResolves() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let pdf = tree.main.appendingPathComponent("Young, Michael/box-17.pdf")
        let jpeg = tree.jpegs.appendingPathComponent("Michael Young Archive/box-17.HEIC")
        try makeFile(pdf)
        try makeFile(jpeg)

        let partnerIndex = index(tree.jpegs)
        #expect(partnerIndex.candidates.first?.collectionContext == "Michael Young Archive")
        let discoveredJPEG = URL(fileURLWithPath: try #require(partnerIndex.candidates.first?.path))
        #expect(partnerIndex.resolve(pdfURL: pdf, mainRoot: tree.main) == .match(discoveredJPEG))
    }

    @Test("a clean empty pass means no partner; an incomplete pass means unknown")
    func absenceRequiresCleanPass() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let pdf = tree.main.appendingPathComponent("Only PDF/scan.pdf")
        try makeFile(pdf)

        let clean = index(tree.jpegs)
        #expect(clean.isClean)
        #expect(clean.resolve(pdfURL: pdf, mainRoot: tree.main) == .none)

        let failed = CorpusFingerprintScanResult(
            entries: clean.candidates.map {
                CorpusFingerprintEntry(url: URL(fileURLWithPath: $0.path), fingerprint: $0.fingerprint)
            },
            unreadable: [],
            directoryErrors: [CorpusReadFailure(url: tree.jpegs, reason: "scratch denial")],
            filesSeen: clean.filesSeen,
            vanishedMidScan: 0,
            rootUnreadable: false,
            cancelled: false
        )
        #expect(JPEGPartnerIndex(jpegRoot: tree.jpegs, scan: failed)
            .resolve(pdfURL: pdf, mainRoot: tree.main) == .unknown)
    }

    @Test("a clean scan from a different subtree cannot certify no partner")
    func mismatchedScanRootStaysUnknown() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let otherRoot = tree.root.appendingPathComponent("Other JPEGS", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let pdf = tree.main.appendingPathComponent("Collection/scan.pdf")
        try makeFile(pdf)

        let wrongScan = CorpusWalker.scanFingerprints(root: otherRoot)
        #expect(wrongScan.isClean)
        let mismatched = JPEGPartnerIndex(jpegRoot: tree.jpegs, scan: wrongScan)
        #expect(!mismatched.isClean)
        #expect(mismatched.resolve(pdfURL: pdf, mainRoot: tree.main) == .unknown)
    }

    @Test("duplicate stems stay ambiguous unless collection context selects one")
    func duplicateStemUsesContextOrRefuses() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let pdf = tree.main.appendingPathComponent("Source/same.pdf")
        let first = tree.jpegs.appendingPathComponent("Collection A/same.jpg")
        let second = tree.jpegs.appendingPathComponent("Collection B/same.jpeg")
        try makeFile(pdf)
        try makeFile(first)
        try makeFile(second)

        let partnerIndex = index(tree.jpegs)
        let discoveredFirst = URL(fileURLWithPath: try #require(
            partnerIndex.candidates.first(where: { $0.collectionContext == "Collection A" })?.path))
        let discoveredSecond = URL(fileURLWithPath: try #require(
            partnerIndex.candidates.first(where: { $0.collectionContext == "Collection B" })?.path))
        #expect(partnerIndex.resolve(pdfURL: pdf, mainRoot: tree.main)
                == .ambiguous([discoveredFirst, discoveredSecond]))
        #expect(partnerIndex.resolve(pdfURL: pdf, mainRoot: tree.main,
                                     collectionContext: "Collection B") == .match(discoveredSecond))
    }
}
