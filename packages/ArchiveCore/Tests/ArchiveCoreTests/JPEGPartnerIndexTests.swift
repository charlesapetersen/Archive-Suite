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

    @Test("W49.adoption-nbsp-pairing: U+00A0 and ASCII space pair in mirrored and stem tiers while real ambiguity stays ambiguous")
    func nbspMatchesSpaceAndKeepsAmbiguity() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        // 1. Mirrored tier: PDF with NBSP matches JPEG with plain space (Greene Papers pattern),
        //    and plain-space PDF matches NBSP JPEG.
        let greenePDF = tree.main.appendingPathComponent("Greene Papers/00001 —\u{00A0}Greene.pdf")
        let greeneJPG = tree.jpegs.appendingPathComponent("Greene Papers/00001 — Greene.JPG")
        let reversePDF = tree.main.appendingPathComponent("Greene Papers/00002 — Greene.pdf")
        let reverseJPG = tree.jpegs.appendingPathComponent("Greene Papers/00002 —\u{00A0}Greene.JPG")
        // Mirrored folder name differing only by NBSP also pairs as mirrored.
        let folderPDF = tree.main.appendingPathComponent("Box\u{00A0}1/note.pdf")
        let folderJPG = tree.jpegs.appendingPathComponent("Box 1/note.jpg")
        // 2. Stem tier: relocated folder with NBSP vs plain space in stem.
        let relocatedPDF = tree.main.appendingPathComponent("New Folder/00003 —\u{00A0}Relocated.pdf")
        let relocatedJPG = tree.jpegs.appendingPathComponent("Old Folder/00003 — Relocated.jpeg")
        // 3. Real ambiguity on mirrored tier: both plain-space and NBSP JPEGs exist beside each other.
        let ambigMirrorPDF = tree.main.appendingPathComponent("Ambig/00004 —\u{00A0}Dual.pdf")
        let ambigMirrorSpace = tree.jpegs.appendingPathComponent("Ambig/00004 — Dual.jpg")
        let ambigMirrorNBSP = tree.jpegs.appendingPathComponent("Ambig/00004 —\u{00A0}Dual.jpg")
        // 4. Real ambiguity on stem tier: two different folders hold space and NBSP variants.
        let ambigStemPDF = tree.main.appendingPathComponent("Other/00005 —\u{00A0}Split.pdf")
        let ambigStemA = tree.jpegs.appendingPathComponent("Col A/00005 — Split.jpg")
        let ambigStemB = tree.jpegs.appendingPathComponent("Col B/00005 —\u{00A0}Split.jpg")

        for url in [greenePDF, greeneJPG, reversePDF, reverseJPG, folderPDF, folderJPG,
                    relocatedPDF, relocatedJPG, ambigMirrorPDF, ambigMirrorSpace, ambigMirrorNBSP,
                    ambigStemPDF, ambigStemA, ambigStemB] {
            try makeFile(url)
        }

        let partnerIndex = index(tree.jpegs)
        func discovered(_ suffix: String) throws -> URL {
            URL(fileURLWithPath: try #require(partnerIndex.candidates.first { $0.path.hasSuffix(suffix) }?.path))
        }

        #expect(partnerIndex.resolve(pdfURL: greenePDF, mainRoot: tree.main)
                == .match(try discovered("Greene Papers/00001 — Greene.JPG")))
        #expect(partnerIndex.resolve(pdfURL: reversePDF, mainRoot: tree.main)
                == .match(try discovered("Greene Papers/00002 —\u{00A0}Greene.JPG")))
        #expect(partnerIndex.resolve(pdfURL: folderPDF, mainRoot: tree.main)
                == .match(try discovered("Box 1/note.jpg")))
        #expect(partnerIndex.resolve(pdfURL: relocatedPDF, mainRoot: tree.main)
                == .match(try discovered("Old Folder/00003 — Relocated.jpeg")))

        if case .ambiguous(let urls) = partnerIndex.resolve(pdfURL: ambigMirrorPDF, mainRoot: tree.main) {
            #expect(urls.count == 2)
        } else {
            Issue.record("expected mirrored ambiguity when both plain-space and NBSP originals exist")
        }
        if case .ambiguous(let urls) = partnerIndex.resolve(pdfURL: ambigStemPDF, mainRoot: tree.main) {
            #expect(urls.count == 2)
        } else {
            Issue.record("expected stem ambiguity when plain-space and NBSP originals exist in different folders")
        }
        // Collection context with NBSP still narrows an ambiguous stem.
        #expect(partnerIndex.resolve(pdfURL: ambigStemPDF, mainRoot: tree.main, collectionContext: "Col\u{00A0}B")
                == .match(try discovered("Col B/00005 —\u{00A0}Split.jpg")))
        // Exact-path lookup stays byte-exact (never swaps U+00A0 for ASCII space).
        let exactGreenePath = try discovered("Greene Papers/00001 — Greene.JPG").path
        #expect(partnerIndex.candidate(atPath: exactGreenePath) != nil)
        #expect(partnerIndex.candidate(atPath: exactGreenePath.replacingOccurrences(of: "— ", with: "—\u{00A0}")) == nil)
    }
}
