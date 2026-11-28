#if DEBUG // W40.a5: a test contract, compiled out of Release
import ArchiveCore
import CoreGraphics
import Foundation
import PDFKit

/// Key-free, no-network contract for `OutputFileSafety` (W49.proc-output-safety-script).
/// Covers file identity, safe removal, unique reservation (including companion files and dangling symlinks),
/// atomic multi-artifact relocation with partial-copy and destination-race rollback, and `isUnfiledWorkingPDF` /
/// `isFiledCatalogue` guards for Process Files `catalogue-work-<UUID>` folders vs filed catalogues.
///
/// Run via `scripts/test-output-file-safety.sh`.
@MainActor
enum OutputFileSafetyContract {
    nonisolated static let envKey = "OUTPUT_FILE_SAFETY_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("APOutputSafety-\(UUID().uuidString)", isDirectory: true)
        let root = work.appendingPathComponent("files", isDirectory: true)
        var results: [String] = []
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            results.append("\(condition ? "PASS" : "FAIL"): \(label)\(condition || detail.isEmpty ? "" : " — \(detail)")")
        }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            // 1. Identity and removal guards.
            let original = root.appendingPathComponent("Original.PDF")
            let alias = root.appendingPathComponent("original.pdf")
            let distinct = root.appendingPathComponent("generated.pdf")
            let symlink = root.appendingPathComponent("linked.pdf")
            let sourceJSON = root.appendingPathComponent("Original.json")
            let generatedJSON = root.appendingPathComponent("generated.json")
            let occupiedPDF = root.appendingPathComponent("report.pdf")
            let occupiedPDF2 = root.appendingPathComponent("report (2).pdf")

            try Data("original".utf8).write(to: original)
            try Data("generated".utf8).write(to: distinct)
            try Data("source metadata".utf8).write(to: sourceJSON)
            try Data("generated metadata".utf8).write(to: generatedJSON)
            try Data("old report".utf8).write(to: occupiedPDF)
            try fm.createSymbolicLink(at: symlink, withDestinationURL: original)

            check("identical URL is the same file", OutputFileSafety.isSameFile(original, original))
            let caseSensitiveVolume = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames) ?? false
            if !caseSensitiveVolume {
                check("case-only alias is preserved conservatively", OutputFileSafety.isSameFile(original, alias))
            } else {
                check("distinct case on case-sensitive volume is not aliased", !OutputFileSafety.isSameFile(original, alias))
            }
            check("symlink alias is the same file", OutputFileSafety.isSameFile(original, symlink))
            check("generated output is distinct", !OutputFileSafety.isSameFile(original, distinct))

            try OutputFileSafety.removeGeneratedOutput(original, for: original)
            check("source-as-output PDF is preserved", fm.fileExists(atPath: original.path))
            check("source-as-output JSON is preserved", fm.fileExists(atPath: sourceJSON.path))

            try OutputFileSafety.removeGeneratedOutput(distinct, for: original)
            check("distinct generated PDF is removed", !fm.fileExists(atPath: distinct.path))
            check("unproven same-basename JSON is preserved", fm.fileExists(atPath: generatedJSON.path))

            // 2. Destination reservation (existing, reserved, companion, dangling symlink, allowedExisting).
            var reserved = Set<String>()
            let uniquePDF = OutputFileSafety.reserveUniqueDestination(preferred: occupiedPDF, reservedPaths: &reserved)
            check("existing destination receives a numbered name", uniquePDF == occupiedPDF2)
            let nextPDF = OutputFileSafety.reserveUniqueDestination(preferred: occupiedPDF, reservedPaths: &reserved)
            check("reserved destination is not reused", nextPDF.lastPathComponent == "report (3).pdf")

            let orphan = root.appendingPathComponent("orphan.json")
            let orphanPDF = root.appendingPathComponent("orphan.pdf")
            try Data("unrelated metadata".utf8).write(to: orphan)
            try fm.createSymbolicLink(at: root.appendingPathComponent("orphan (2).json"),
                                      withDestinationURL: root.appendingPathComponent("missing.json"))
            var pairReservations = Set<String>()
            let paired = OutputFileSafety.reserveUniqueDestination(preferred: orphanPDF, reservedPaths: &pairReservations,
                                                                   companionExtension: "json")
            check("paired output skips existing JSON and dangling JSON links", paired.lastPathComponent == "orphan (3).pdf")
            let preservedOrphan = try Data(contentsOf: orphan)
            check("paired reservation preserves older metadata", preservedOrphan == Data("unrelated metadata".utf8))

            var imageReservations = Set<String>()
            let reusedSource = OutputFileSafety.reserveUniqueDestination(
                preferred: original, allowedExisting: original, reservedPaths: &imageReservations)
            check("intentional source-as-image destination is reused", reusedSource == original)

            // 3. Transactional artifact relocation: partial copy rollback, destination race, and clean commit.
            let txSource1 = root.appendingPathComponent("tx-1.bin")
            let txSource2 = root.appendingPathComponent("tx-2.bin")
            let txDest1 = root.appendingPathComponent("filed/tx-1.bin")
            let txDest2 = root.appendingPathComponent("filed/tx-2.bin")
            try Data("one".utf8).write(to: txSource1)
            try Data("two".utf8).write(to: txSource2)

            var copyCount = 0
            do {
                try OutputFileSafety.relocateArtifactSet([
                    .init(source: txSource1, destination: txDest1),
                    .init(source: txSource2, destination: txDest2),
                ], copyItem: { source, destination in
                    copyCount += 1
                    if copyCount == 2 {
                        try Data("partial".utf8).write(to: destination)
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try fm.copyItem(at: source, to: destination)
                })
                check("injected partial-copy failure throws", false)
            } catch {
                check("partial-copy rollback preserves every source",
                      fm.fileExists(atPath: txSource1.path) && fm.fileExists(atPath: txSource2.path))
                check("partial-copy rollback removes created destinations",
                      !fm.fileExists(atPath: txDest1.path) && !fm.fileExists(atPath: txDest2.path))
            }

            do {
                try OutputFileSafety.relocateArtifactSet([
                    .init(source: txSource1, destination: txDest1),
                    .init(source: txSource2, destination: txDest2),
                ], copyItem: { source, temporary in
                    try fm.copyItem(at: source, to: temporary)
                    if source == txSource1 {
                        try Data("external owner".utf8).write(to: txDest2)
                    }
                })
                check("destination race aborts the transaction", false)
            } catch {
                check("destination race preserves every source",
                      fm.fileExists(atPath: txSource1.path) && fm.fileExists(atPath: txSource2.path))
                check("destination race rolls back only this transaction's installed file",
                      !fm.fileExists(atPath: txDest1.path))
                check("destination race preserves the other actor's file",
                      (try? String(contentsOf: txDest2, encoding: .utf8)) == "external owner")
            }
            try fm.removeItem(at: txDest2)

            try OutputFileSafety.relocateArtifactSet([
                .init(source: txSource1, destination: txDest1),
                .init(source: txSource2, destination: txDest2),
            ])
            check("successful artifact transaction verifies destinations",
                  fm.fileExists(atPath: txDest1.path) && fm.fileExists(atPath: txDest2.path))
            check("successful artifact transaction cleans sources only after verification",
                  !fm.fileExists(atPath: txSource1.path) && !fm.fileExists(atPath: txSource2.path))

            // 4. W49.proc-identity-at-write / W49.proc-output-safety-script:
            //    `isUnfiledWorkingPDF` and `isFiledCatalogue` across state-dir working folders vs filed/look-alike folders.
            let stateRoot = work.appendingPathComponent("state", isDirectory: true)
            try fm.createDirectory(at: stateRoot, withIntermediateDirectories: true)
            let saved = ["BATCHRESUME_TEST", "ARCHIVEPROC_TEST_STATE_ROOT"].map {
                ($0, ProcessInfo.processInfo.environment[$0])
            }
            setenv("BATCHRESUME_TEST", "1", 1)
            setenv("ARCHIVEPROC_TEST_STATE_ROOT", stateRoot.path, 1)
            defer {
                for (key, value) in saved {
                    if let value { setenv(key, value, 1) } else { unsetenv(key) }
                }
            }
            check("state root redirects pendingCatalogueURL into scratch",
                  OCRProcessor.pendingCatalogueURL.deletingLastPathComponent().standardizedFileURL
                    == stateRoot.standardizedFileURL)

            let dummySource = root.appendingPathComponent("scan.jpg")
            try Data("scan".utf8).write(to: dummySource)

            // 4a. Working folder's PDF (no companion): identified, unfiled working -> rewrite/removal allowed.
            let workingDir = stateRoot.appendingPathComponent("catalogue-work-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: workingDir, withIntermediateDirectories: true)
            let workingPDF = workingDir.appendingPathComponent("working.pdf")
            try writeIdentifiedPDF(at: workingPDF)
            check("working folder PDF has catalogue identity", OutputFileSafety.hasCatalogueIdentity(at: workingPDF))
            check("working folder PDF without companion is unfiled working PDF",
                  OutputFileSafety.isUnfiledWorkingPDF(workingPDF))
            check("working folder PDF with resolved symlink path (/private/var vs /var) is still unfiled working PDF",
                  OutputFileSafety.isUnfiledWorkingPDF(workingPDF.resolvingSymlinksInPath())
                    && !OutputFileSafety.isFiledCatalogue(at: workingPDF.resolvingSymlinksInPath()))
            check("working folder PDF without companion is not a filed catalogue",
                  !OutputFileSafety.isFiledCatalogue(at: workingPDF))
            try OutputFileSafety.replaceGeneratedOutput(workingPDF, for: dummySource, with: try Data(contentsOf: workingPDF))
            check("replaceGeneratedOutput succeeds on an unfiled working PDF", fm.fileExists(atPath: workingPDF.path))

            // 4b. Working folder's PDF WITH a catalogue companion beside it -> filed, protected.
            let workingWithRecord = workingDir.appendingPathComponent("paired.pdf")
            try writeIdentifiedPDF(at: workingWithRecord)
            try Data("{}".utf8).write(to: workingWithRecord.appendingPathExtension("archivesuite.json"))
            check("working PDF with companion record is not unfiled working PDF",
                  !OutputFileSafety.isUnfiledWorkingPDF(workingWithRecord))
            check("working PDF with companion record counts as filed catalogue",
                  OutputFileSafety.isFiledCatalogue(at: workingWithRecord))
            var threwFiledReplace = false
            do {
                try OutputFileSafety.replaceGeneratedOutput(workingWithRecord, for: dummySource, with: Data("x".utf8))
            } catch OutputFileSafety.ReplaceError.cataloguePDF {
                threwFiledReplace = true
            }
            check("replaceGeneratedOutput refuses a working PDF with a companion record", threwFiledReplace)

            // 4c. Working folder's PDF with a dangling companion symlink -> conservatively filed.
            let workingDangling = workingDir.appendingPathComponent("dangling.pdf")
            try writeIdentifiedPDF(at: workingDangling)
            try fm.createSymbolicLink(at: workingDangling.appendingPathExtension("archivesuite.json"),
                                      withDestinationURL: workingDir.appendingPathComponent("missing.json"))
            check("working PDF with dangling companion symlink is treated as filed",
                  !OutputFileSafety.isUnfiledWorkingPDF(workingDangling)
                    && OutputFileSafety.isFiledCatalogue(at: workingDangling))

            // 4d. Non-UUID `catalogue-work-` folder inside state dir -> NOT unfiled working.
            let badPrefixDir = stateRoot.appendingPathComponent("catalogue-work-not-a-uuid", isDirectory: true)
            try fm.createDirectory(at: badPrefixDir, withIntermediateDirectories: true)
            let badPrefixPDF = badPrefixDir.appendingPathComponent("doc.pdf")
            try writeIdentifiedPDF(at: badPrefixPDF)
            check("non-UUID catalogue-work folder inside state dir is not unfiled working PDF",
                  !OutputFileSafety.isUnfiledWorkingPDF(badPrefixPDF)
                    && OutputFileSafety.isFiledCatalogue(at: badPrefixPDF))

            // 4e. Look-alike `catalogue-work-<UUID>` folder OUTSIDE the state directory -> filed, protected.
            let lookalikeDir = work.appendingPathComponent("outside/catalogue-work-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: lookalikeDir, withIntermediateDirectories: true)
            let lookalikePDF = lookalikeDir.appendingPathComponent("filed.pdf")
            try writeIdentifiedPDF(at: lookalikePDF)
            check("look-alike catalogue-work folder outside state dir is not unfiled working PDF",
                  !OutputFileSafety.isUnfiledWorkingPDF(lookalikePDF))
            check("look-alike catalogue-work folder outside state dir is treated as filed catalogue",
                  OutputFileSafety.isFiledCatalogue(at: lookalikePDF))
            var threwLookalikeRemove = false
            do {
                try OutputFileSafety.removeGeneratedOutput(lookalikePDF, for: dummySource)
            } catch OutputFileSafety.ReplaceError.cataloguePDF {
                threwLookalikeRemove = true
            }
            check("removeGeneratedOutput refuses a look-alike outside working PDF",
                  threwLookalikeRemove && fm.fileExists(atPath: lookalikePDF.path))

            // Clean removal still works on the unfiled working PDF.
            try OutputFileSafety.removeGeneratedOutput(workingPDF, for: dummySource)
            check("removeGeneratedOutput removes an unfiled working PDF", !fm.fileExists(atPath: workingPDF.path))
        } catch {
            check("unexpected error", false, error.localizedDescription)
        }

        try? fm.removeItem(at: work)
        finish(results)
    }

    private static func writeIdentifiedPDF(at url: URL) throws {
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil),
              let xmp = identity.adding(to: packet) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.addDocumentMetadata(xmp as CFData)
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func finish(_ results: [String]) {
        let passed = !results.isEmpty && !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["OUTPUT_FILE_SAFETY_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-output-safety.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}

#endif
