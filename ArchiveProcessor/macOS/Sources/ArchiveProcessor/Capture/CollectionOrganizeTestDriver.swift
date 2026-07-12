import Foundation

/// Headless, $0 self-test of `CollectionSegmenter.organizeOutput`, gated by `COLLECTIONORGANIZE_TEST=1`
/// (inert in normal use). No OCR, no network, no cost, no GUI — synthetic files in a temp dir.
///
/// Proves KNOWN_ISSUES #2 (B3) is fixed: with dual (image) output + document merge + collection
/// organization, a merged multi-page document's per-page exported images (`page1.jpg`, `page2.jpg`, …)
/// are NUMBERED and MOVED into the collection folder (mirroring the Live Capture merged branch) instead
/// of being left loose/unrenamed in the output root, and the merged PDF takes the first page's number.
/// Also guards the regression surfaces: non-merged dual output still pairs image↔PDF by base name, the
/// no-export path is untouched, and no source file is ever overwritten or deleted.
///
/// Writes a PASS/FAIL report to `COLLECTIONORGANIZE_TEST_OUT` (or a temp file) + NSLog. Test scaffolding.
@MainActor
enum CollectionOrganizeTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["COLLECTIONORGANIZE_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("ORGANIZETEST \(ok ? "PASS" : "FAIL"): \(name)")
        }
        func writeFile(_ url: URL, _ s: String) { try? Data(s.utf8).write(to: url) }

        let seg = CollectionSegmenter()

        // ============================================================================================
        // Case 1 — THE BUG: merged 2-page document + dual output. Per-page images page1.jpg/page2.jpg
        // exist; merge collapsed page1.pdf+page2.pdf into page1_merged.pdf and repointed BOTH source URLs
        // at it. Expect: both images filed + numbered in the folder, merged PDF at 00001, output root
        // left with NO loose page images.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-merged-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let src1 = out.appendingPathComponent("page1.jpg")   // stand-in for source URLs (any URL works as a key)
            let src2 = out.appendingPathComponent("page2.jpg")
            let img1 = out.appendingPathComponent("page1.jpg")   // exported per-page images (pre-merge naming)
            let img2 = out.appendingPathComponent("page2.jpg")
            let merged = out.appendingPathComponent("page1_merged.pdf")
            writeFile(img1, "img1"); writeFile(img2, "img2"); writeFile(merged, "MERGEDPDF")
            writeFile(out.appendingPathComponent("page1_merged.json"), "{}")

            let coll = CollectionSegment(collectionName: "Test Coll", fileURLs: [src1, src2])
            do {
                try seg.organizeOutput(
                    collections: [coll],
                    outputDirectory: out,
                    outputURLMap: [src1: merged, src2: merged],
                    moveSiblingImages: true,
                    exportedImageMap: [src1: img1, src2: img2])
            } catch { check("merged: organizeOutput threw \(error)", false) }

            let folder = out.appendingPathComponent("Test Coll")
            let jpg1 = folder.appendingPathComponent("00001 Test Coll.jpg")
            let jpg2 = folder.appendingPathComponent("00002 Test Coll.jpg")
            let pdf = folder.appendingPathComponent("00001 Test Coll.pdf")
            let json = folder.appendingPathComponent("JSON Output/00001 Test Coll.json")
            check("merged: page-1 image filed as 00001 (numbered, in collection folder)", fm.fileExists(atPath: jpg1.path))
            check("merged: page-2 image filed as 00002 (numbered, in collection folder)", fm.fileExists(atPath: jpg2.path))
            check("merged: merged PDF filed at the first image's number (00001)", fm.fileExists(atPath: pdf.path))
            check("merged: JSON sidecar filed", fm.fileExists(atPath: json.path))
            // The bug's signature: page images left loose in the output ROOT. Must be gone (moved).
            check("merged: NO loose page image left in the output root", !fm.fileExists(atPath: img1.path) && !fm.fileExists(atPath: img2.path))
            check("merged: merged PDF no longer loose in the output root", !fm.fileExists(atPath: merged.path))
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 5 — safety: a JSON-only collision is invisible to highestLeadingNumber (which scans the
        // collection root). It must advance the whole artifact set instead of deleting the existing JSON.
        // The exported image uses a collision-renamed source path to prove exportedImageMap is authoritative.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-jsoncollision-\(UUID().uuidString)", isDirectory: true)
            let folder = out.appendingPathComponent("JC")
            let jsonFolder = folder.appendingPathComponent("JSON Output")
            try? fm.createDirectory(at: jsonFolder, withIntermediateDirectories: true)
            let existingJSON = jsonFolder.appendingPathComponent("00001 JC.json")
            writeFile(existingJSON, "KEEP")
            let source = out.appendingPathComponent("source.jpg")
            let pdf = out.appendingPathComponent("source.pdf")
            let json = out.appendingPathComponent("source.json")
            let collisionRenamedImage = out.appendingPathComponent("source (2).jpg")
            writeFile(pdf, "PDF"); writeFile(json, "NEWJSON"); writeFile(collisionRenamedImage, "IMAGE")
            let coll = CollectionSegment(collectionName: "JC", fileURLs: [source])
            do {
                try seg.organizeOutput(
                    collections: [coll], outputDirectory: out,
                    outputURLMap: [source: pdf], moveSiblingImages: true,
                    exportedImageMap: [source: collisionRenamedImage])
            } catch { check("JSON collision: organizeOutput threw \(error)", false) }
            let preserved = (try? String(contentsOf: existingJSON, encoding: .utf8)) == "KEEP"
            check("JSON collision: existing 00001 sidecar preserved", preserved)
            check("JSON collision: new PDF/JSON/image advanced together to 00002",
                  fm.fileExists(atPath: folder.appendingPathComponent("00002 JC.pdf").path)
                  && fm.fileExists(atPath: jsonFolder.appendingPathComponent("00002 JC.json").path)
                  && fm.fileExists(atPath: folder.appendingPathComponent("00002 JC.jpg").path))
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 2 — regression: NON-merged dual output (one PDF per page). Each page's image shares its
        // PDF's base name; organizeOutput pairs them by base name and numbers each page independently.
        // Must be unchanged by the fix (merged branch must NOT fire when each source has its own PDF).
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-nonmerged-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let s1 = out.appendingPathComponent("a.src"); let s2 = out.appendingPathComponent("b.src")
            let p1 = out.appendingPathComponent("a.pdf"); let p2 = out.appendingPathComponent("b.pdf")
            let i1 = out.appendingPathComponent("a.jpg"); let i2 = out.appendingPathComponent("b.jpg")
            writeFile(p1, "P1"); writeFile(p2, "P2"); writeFile(i1, "I1"); writeFile(i2, "I2")
            let coll = CollectionSegment(collectionName: "NM", fileURLs: [s1, s2])
            try? seg.organizeOutput(
                collections: [coll], outputDirectory: out,
                outputURLMap: [s1: p1, s2: p2], moveSiblingImages: true,
                exportedImageMap: [s1: i1, s2: i2])   // present but each source has its OWN pdf → sibling-by-name path
            let folder = out.appendingPathComponent("NM")
            let ok = fm.fileExists(atPath: folder.appendingPathComponent("00001 NM.pdf").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("00001 NM.jpg").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("00002 NM.pdf").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("00002 NM.jpg").path)
            check("non-merged dual output: each page filed as its own numbered PDF + image (unchanged)", ok)
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 3 — regression: merged doc but NO export (moveSiblingImages=false). Existing behavior:
        // move the merged PDF once, no image handling. Merged branch must NOT fire.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-noexport-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let s1 = out.appendingPathComponent("x.src"); let s2 = out.appendingPathComponent("y.src")
            let merged = out.appendingPathComponent("x_merged.pdf"); writeFile(merged, "M")
            let coll = CollectionSegment(collectionName: "NE", fileURLs: [s1, s2])
            try? seg.organizeOutput(
                collections: [coll], outputDirectory: out,
                outputURLMap: [s1: merged, s2: merged], moveSiblingImages: false)
            let folder = out.appendingPathComponent("NE")
            check("no-export merged: merged PDF filed once at 00001 (unchanged)",
                  fm.fileExists(atPath: folder.appendingPathComponent("00001 NE.pdf").path)
                  && !fm.fileExists(atPath: merged.path))
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 4 — safety: never overwrite. Pre-populate the collection folder with an existing 00001
        // file; the merged run must continue numbering (00002/00003) and leave the existing file intact.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-nooverwrite-\(UUID().uuidString)", isDirectory: true)
            let folder = out.appendingPathComponent("OW")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = folder.appendingPathComponent("00001 OW.pdf"); writeFile(existing, "EXISTING")
            let s1 = out.appendingPathComponent("m1.src"); let s2 = out.appendingPathComponent("m2.src")
            let i1 = out.appendingPathComponent("m1.jpg"); let i2 = out.appendingPathComponent("m2.jpg")
            let merged = out.appendingPathComponent("m1_merged.pdf")
            writeFile(i1, "I1"); writeFile(i2, "I2"); writeFile(merged, "M")
            let coll = CollectionSegment(collectionName: "OW", fileURLs: [s1, s2])
            try? seg.organizeOutput(
                collections: [coll], outputDirectory: out,
                outputURLMap: [s1: merged, s2: merged], moveSiblingImages: true,
                exportedImageMap: [s1: i1, s2: i2])
            let preserved = (try? String(contentsOf: existing, encoding: .utf8)) == "EXISTING"
            let newImg = fm.fileExists(atPath: folder.appendingPathComponent("00002 OW.jpg").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("00003 OW.jpg").path)
            let newPdf = fm.fileExists(atPath: folder.appendingPathComponent("00002 OW.pdf").path)
            check("no-overwrite: existing 00001 file preserved (not overwritten/deleted)", preserved)
            check("no-overwrite: merged run continued numbering at 00002/00003", newImg && newPdf)
            try? fm.removeItem(at: out)
        }

        // Merged JSON-only collision: reserve the entire image/PDF/JSON set at the next free range.
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-merged-jsoncollision-\(UUID().uuidString)", isDirectory: true)
            let folder = out.appendingPathComponent("MJ")
            let jsonFolder = folder.appendingPathComponent("JSON Output")
            try? fm.createDirectory(at: jsonFolder, withIntermediateDirectories: true)
            let existingJSON = jsonFolder.appendingPathComponent("00001 MJ.json")
            writeFile(existingJSON, "KEEP")
            let s1 = out.appendingPathComponent("p1.src"); let s2 = out.appendingPathComponent("p2.src")
            let i1 = out.appendingPathComponent("p1.jpg"); let i2 = out.appendingPathComponent("p2.jpg")
            let merged = out.appendingPathComponent("p1_merged.pdf")
            let mergedJSON = out.appendingPathComponent("p1_merged.json")
            writeFile(i1, "I1"); writeFile(i2, "I2"); writeFile(merged, "PDF"); writeFile(mergedJSON, "JSON")
            let coll = CollectionSegment(collectionName: "MJ", fileURLs: [s1, s2])
            do {
                try seg.organizeOutput(
                    collections: [coll], outputDirectory: out,
                    outputURLMap: [s1: merged, s2: merged], moveSiblingImages: true,
                    exportedImageMap: [s1: i1, s2: i2])
            } catch { check("merged JSON collision: organizeOutput threw \(error)", false) }
            check("merged JSON collision: existing 00001 JSON preserved",
                  (try? String(contentsOf: existingJSON, encoding: .utf8)) == "KEEP")
            check("merged JSON collision: new set advanced together to 00002/00003",
                  fm.fileExists(atPath: folder.appendingPathComponent("00002 MJ.jpg").path)
                  && fm.fileExists(atPath: folder.appendingPathComponent("00003 MJ.jpg").path)
                  && fm.fileExists(atPath: folder.appendingPathComponent("00002 MJ.pdf").path)
                  && fm.fileExists(atPath: jsonFolder.appendingPathComponent("00002 MJ.json").path))
            try? fm.removeItem(at: out)
        }

        // Failed collision-renamed export: never fall back to and move the unrelated preferred-name image.
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-missing-export-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let source = out.appendingPathComponent("page.src")
            let pdf = out.appendingPathComponent("page.pdf")
            let unrelatedPreferred = out.appendingPathComponent("page.jpg")
            let missingTracked = out.appendingPathComponent("page (2).jpg")
            writeFile(pdf, "PDF"); writeFile(unrelatedPreferred, "USER")
            let coll = CollectionSegment(collectionName: "ME", fileURLs: [source])
            var didThrow = false
            do {
                try seg.organizeOutput(
                    collections: [coll], outputDirectory: out,
                    outputURLMap: [source: pdf], moveSiblingImages: true,
                    exportedImageMap: [source: missingTracked])
            } catch { didThrow = true }
            check("missing tracked export: organization stops safely", didThrow)
            check("missing tracked export: unrelated preferred image remains untouched",
                  (try? String(contentsOf: unrelatedPreferred, encoding: .utf8)) == "USER")
            check("missing tracked export: PDF source remains retryable", fm.fileExists(atPath: pdf.path))
            try? fm.removeItem(at: out)
        }

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["COLLECTIONORGANIZE_TEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APOrganizeTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        NSLog("ORGANIZETEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
