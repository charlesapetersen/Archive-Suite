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

    /// W40.fix-reader-viewer-switch: the lookups are dictionaries, so they must give exactly what a scan of
    /// every candidate gives — the mirrored path, the leaf stem in table order, and an exact path.
    @Test("the dictionary lookups agree with a scan of every candidate, and stay cheap at size")
    func lookupsAgreeWithAScan() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        var pdfs: [URL] = []
        for c in 0..<20 {
            for k in 0..<100 {
                let name = "c\(c)/scan-\(k % 60)"   // stems repeat across collections and within names
                try makeFile(tree.jpegs.appendingPathComponent(name + (k % 3 == 0 ? ".JPG" : ".jpeg")))
                if k < 3 { pdfs.append(tree.main.appendingPathComponent(name + ".pdf")) }
            }
        }
        pdfs.append(tree.main.appendingPathComponent("elsewhere/scan-7.pdf"))
        pdfs.append(tree.main.appendingPathComponent("elsewhere/missing.pdf"))
        for pdf in pdfs { try makeFile(pdf) }
        let partnerIndex = index(tree.jpegs)
        #expect(partnerIndex.candidates.count == 1_200)   // 20 folders × 60 names (k and k + 60 write one file)

        let jpegRoot = try #require(CorpusWalker.discoveredPathPrefix(for: tree.jpegs))
        let mainRoot = try #require(CorpusWalker.discoveredPathPrefix(for: tree.main))
        for pdf in pdfs {
            let canonical = mainRoot + "/" + pdf.path.dropFirst(tree.main.path.count + 1)
            let pdfStem = ((String(canonical.dropFirst(mainRoot.count + 1))) as NSString).deletingPathExtension
            let exact = partnerIndex.candidates.filter {
                ($0.path.dropFirst(jpegRoot.count + 1) as NSString).deletingPathExtension == pdfStem
            }
            let byStem = partnerIndex.candidates.filter { $0.stem == (pdfStem as NSString).lastPathComponent }
            let url = { (p: String) in URL(fileURLWithPath: p) }
            let expected: JPEGPartnerResolution = exact.count == 1 ? .match(url(exact[0].path))
                : exact.count > 1 ? .ambiguous(exact.map { url($0.path) })
                : byStem.isEmpty ? .none : byStem.count == 1 ? .match(url(byStem[0].path))
                : .ambiguous(byStem.map { url($0.path) })
            #expect(partnerIndex.resolve(pdfURL: pdf, mainRoot: tree.main) == expected, "\(pdf.lastPathComponent)")
        }
        for candidate in partnerIndex.candidates.prefix(50) {
            #expect(partnerIndex.candidate(atPath: candidate.path) == candidate)
        }
        #expect(partnerIndex.candidate(atPath: jpegRoot + "/nowhere.jpg") == nil)

        // A persisted table rebuilt from its rows answers the same, and equals the scanned one.
        let reloaded = JPEGPartnerIndex(jpegRootPath: partnerIndex.jpegRootPath, candidates: partnerIndex.candidates,
                                        isClean: true, filesSeen: partnerIndex.filesSeen)
        #expect(reloaded == partnerIndex)
        let start = Date()
        for pdf in pdfs { _ = reloaded.resolve(pdfURL: pdf, mainRoot: tree.main) }
        // Loose on purpose (a guard against a return to per-candidate filesystem work, not a benchmark).
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}
