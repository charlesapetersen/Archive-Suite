import Foundation
import AppKit
import PDFKit
import ArchiveCore

/// Headless, $0 self-test of W37.dual-date in the Processor, gated by `DUAL_DATE_TEST=1` (does nothing in
/// normal use). Synthetic files in a fresh temp dir only — no OCR, no LLM call (every document segment is
/// Mac-tagged, which skips the tagger), no network, no GUI, and it never opens the corpus.
///
/// What has to be true:
///   1. The OCR header marker is read ONLY from the header, only on a `[document_start]`, and never leaks
///      into the transcription or hides the rotation tag.
///   2. `DocumentSegmenter` proposes a relation ONLY from that marker — never from adjacency alone, never
///      across a box/folder label, never from a `.none`/continuation page — and chains several enclosures
///      to the ONE covering letter; a continuation page adds nothing.
///   3. The proposal round-trips through `OCRResult` Codable (PendingRun recovery) and a legacy record
///      without the key decodes; a reclassification drops it, a rotation-only fix keeps it.
///   4. The enclosure's `Sent With` date is its cover's OWN final date (decade/year/month/day), the
///      uncertainty is the cover's, an undated cover gives none, and the cover never gets the enclosure's.
///   5. End to end through `performTaggingPhase`: Finder tags + JSON sidecars on scratch outputs.
///   6. The JSON sidecar is unchanged when there is no sent-with date, and `GeneratedTags` round-trips
///      the new fields (Live Capture's retained manifest).
///   7. A generated PDF's source-date header lines strip cleanly via the shared Core parser.
///
/// Writes a PASS/FAIL report to `DUAL_DATE_TEST_OUT` (or a temp file) + NSLog, then exits 0/1.
@MainActor
enum DualDateTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["DUAL_DATE_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("DUALDATE \(ok ? "PASS" : "FAIL"): \(name)")
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APDualDate-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        func tagsOf(_ u: URL) -> [String] {
            if case .success(let names, _) = TagReading.read(u) { return names }
            return []
        }
        func jsonOf(_ u: URL) -> [String: Any] {
            guard let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        func writeOnePagePDF(_ url: URL) {
            var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
        }

        // --- 1. OCR header marker parsing. ---
        let inline = "[document_start] [enclosure]\n[rotate_0]\nREPORT ON HARBOUR WORKS"
        check("inline [enclosure] on a document_start line is read", OCRPrompt.parseEnclosureFlag(inline))
        check("...and does not leak into the transcription",
              OCRPrompt.parseResponse(inline).text == "REPORT ON HARBOUR WORKS")
        let ownLine = "[document_start]\n[enclosure]\n[rotate_90]\nBody text"
        let parsedOwnLine = OCRPrompt.parseResponse(ownLine)
        check("a whole-line [enclosure] is read", OCRPrompt.parseEnclosureFlag(ownLine))
        check("...is stripped from the text and does not hide the rotation tag",
              parsedOwnLine.text == "Body text" && parsedOwnLine.rotationDegrees == 90
              && parsedOwnLine.classification == .documentStart)
        check("a marker on a continuation is ignored",
              !OCRPrompt.parseEnclosureFlag("[document_continuation] [enclosure]\n[rotate_0]\ntext"))
        check("[enclosure] in the BODY is not the marker",
              !OCRPrompt.parseEnclosureFlag("[document_start]\n[rotate_0]\nSee [enclosure] below."))
        check("no marker → no proposal", !OCRPrompt.parseEnclosureFlag("[document_start]\n[rotate_0]\nDear Sir"))
        let plain = OCRPrompt.parseResponse("[document_start]\n[rotate_180]\nDear Sir,\nThanks.")
        check("a response without the marker parses exactly as before",
              plain.classification == .documentStart && plain.rotationDegrees == 180 && plain.text == "Dear Sir,\nThanks.")

        // --- 2. Segmenter proposals. ---
        func u(_ n: String) -> URL { tmp.appendingPathComponent(n) }
        let names = ["L.jpg", "E1.jpg", "E1c.jpg", "E2.jpg", "B.jpg", "X.jpg", "U.jpg", "E3.jpg", "N.jpg"]
        let files = names.map(u)
        let classes: [DocumentClassification?] = [.documentStart, .documentStart, .documentContinuation,
                                                  .documentStart, .boxLabel, .documentStart,
                                                  .documentStart, .documentStart, .documentStart]
        let flags = [false, true, false, true, false, true, false, true, false]
        let segs = DocumentSegmenter().segment(files: files, classifications: classes,
                                               texts: names.map { "text of \($0)" }, enclosureFlags: flags)
        check("segment count is unchanged by the relation (L, E1+E1c, E2, Box, X, U, E3, N)", segs.count == 8)
        if segs.count == 8 {
            check("the covering letter has no relation", segs[0].enclosureOf == nil)
            check("a marked enclosure points at its letter", segs[1].enclosureOf == 0)
            check("its continuation page joins the enclosure and adds nothing", segs[1].pdfURLs.count == 2)
            check("a second consecutive enclosure points at the SAME letter, not the first enclosure",
                  segs[2].enclosureOf == 0)
            check("a marker right after a box label crosses no collection boundary", segs[4].enclosureOf == nil)
            check("an enclosure of an (undated) letter is still related", segs[6].enclosureOf == 5)
            check("adjacency alone (no marker) proposes nothing", segs[7].enclosureOf == nil)
        }
        let noFlags = DocumentSegmenter().segment(files: files, classifications: classes, texts: [])
        check("no flags supplied → no relation anywhere", noFlags.allSatisfy { $0.enclosureOf == nil })
        let unclassified = DocumentSegmenter().segment(files: [u("a"), u("b")], classifications: [.documentStart, nil],
                                                       texts: [], enclosureFlags: [false, true])
        check("an unclassified (.none) page never carries a relation", unclassified.last?.enclosureOf == nil)
        check("validCoverIndex rejects a relation into a box label",
              OCRProcessor.validCoverIndex(of: 1, in: [DocumentSegment(pdfURLs: [u("b")], isBox: true),
                                                       DocumentSegment(pdfURLs: [u("d")], enclosureOf: 0)]) == nil)

        // --- 3. OCRResult carries the proposal through recovery. ---
        let flagged = OCRResult(text: "t", classification: .documentStart, rotationDegrees: 0,
                                errorMessage: nil, errorCode: nil, enclosure: true)
        let decoded = (try? JSONEncoder().encode(flagged)).flatMap { try? JSONDecoder().decode(OCRResult.self, from: $0) }
        check("OCRResult round-trips the enclosure proposal", decoded?.enclosure == true)
        let legacy = #"{"text":"t","classification":"document_start","rotationDegrees":0}"#
        let legacyDecoded = try? JSONDecoder().decode(OCRResult.self, from: Data(legacy.utf8))
        check("a pre-W37 persisted result still decodes, with no proposal",
              legacyDecoded != nil && legacyDecoded?.enclosure == nil)
        check("a reclassification drops the proposal",
              flagged.with(classification: .documentContinuation, rotationDegrees: 0).enclosure == nil)
        check("a rotation-only fix keeps it", flagged.with(classification: .documentStart, rotationDegrees: 90).enclosure == true)
        check("a continuation can never be constructed with one",
              OCRResult(text: nil, classification: .documentContinuation, errorMessage: nil, errorCode: nil,
                        enclosure: true).enclosure == nil)

        // --- 4. Cover date → Sent With. ---
        func own(_ y: String?, _ m: String? = nil, _ d: String? = nil) -> ArchiveDate? {
            EnclosureDates.ownDate(of: GeneratedTags(year: y, month: m, day: d))
        }
        check("year/month/day cover", own("1958", "03 March", "Day 12")?.wireValue == "1958-03-12")
        check("year/month cover", own("1958", "03 March")?.wireValue == "1958-03")
        check("year-only cover", own("1958")?.wireValue == "1958")
        check("decade cover", own("1950s")?.wireValue == "1950s")
        check("undated cover → nil", own(nil) == nil)
        check("an impossible cover date is not truncated into a fake one", own("1958", "02 February", "Day 30") == nil)
        check("an unparseable cover month gives nil, not a year guess", own("1958", "Spring") == nil)
        check("a day without a month is ignored (as machineDate does)", own("1958", nil, "Day 4")?.wireValue == "1958")
        check("an OCR-failed cover has no date",
              EnclosureDates.ownDate(of: GeneratedTags(year: "1958", ocrFailed: true)) == nil)
        var enc = GeneratedTags(year: "1957", subjectTags: ["Harbours"])
        EnclosureDates.applySentWith(fromCover: GeneratedTags(year: "1958", month: "03 March", day: "Day 12",
                                                              dateUncertain: true), to: &enc)
        check("enclosure gets the cover's date and the cover's uncertainty",
              enc.sentWith?.wireValue == "1958-03-12" && enc.sentWithUncertain)
        check("its allTags carry Sent With + its flag after its own date",
              enc.allTags == ["1957", "Sent With 1958-03-12", "Sent With Date Uncertain", "Harbours"])
        EnclosureDates.applySentWith(fromCover: GeneratedTags(subjectTags: ["x"]), to: &enc)
        check("re-applying from an undated cover CLEARS it (never keeps a stale/neighbour date)",
              enc.sentWith == nil && !enc.sentWithUncertain && !enc.allTags.contains { $0.hasPrefix("Sent With") })
        var manual = GeneratedTags(year: "1957")
        EnclosureDates.resolveManual(entry: "1958-02-30", uncertain: true, cover: GeneratedTags(year: "1958"), into: &manual)
        check("an invalid manual entry writes nothing, even with a cover", manual.sentWith == nil && !manual.sentWithUncertain)
        EnclosureDates.resolveManual(entry: " 1950s ", uncertain: true, cover: GeneratedTags(year: "1958"), into: &manual)
        check("an explicit valid manual entry wins over the cover", manual.sentWith?.wireValue == "1950s" && manual.sentWithUncertain)
        EnclosureDates.resolveManual(entry: "", uncertain: false, cover: GeneratedTags(year: "1958", month: "3"), into: &manual)
        check("an empty entry takes the cover's date", manual.sentWith?.wireValue == "1958-03")
        EnclosureDates.resolveManual(entry: "", uncertain: true, cover: nil, into: &manual)
        check("an empty entry with no relation writes nothing", manual.sentWith == nil && !manual.sentWithUncertain)
        check("lower-case / garbage manual entries are invalid",
              EnclosureDates.parseManual("sent with 1958") == .invalid && EnclosureDates.parseManual("1958-3") == .invalid)

        // --- 5. End to end through performTaggingPhase (no LLM: every document is Mac-tagged). ---
        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let processor = OCRProcessor()
        processor.taggingMode = .automatic
        processor.jobs = files.enumerated().map { i, url in
            var job = OCRJob(sourceURL: url)
            job.result = OCRResult(text: "text of \(names[i])", classification: classes[i], rotationDegrees: 0,
                                   errorMessage: nil, errorCode: nil, enclosure: flags[i])
            job.classification = classes[i]
            return job
        }
        // L 1958-03 · E1 1957 · E2 1956 · X 1960 · U undated · E3 1955 · N 1961
        processor.preGroupedYears = [1958, 1957, nil, 1956, nil, 1960, nil, 1955, 1961]
        processor.preGroupedMonths = [3, nil, nil, nil, nil, nil, nil, nil, nil]
        processor.preGroupedSubjects = names.map { _ in ["Correspondence"] }
        var outputs: [URL: URL] = [:]
        for f in files {
            let pdf = outDir.appendingPathComponent(f.deletingPathExtension().lastPathComponent + ".pdf")
            writeOnePagePDF(pdf)
            outputs[f] = pdf
        }
        processor.outputURLMap = outputs
        processor.rebuildSegments(files: files)
        check("rebuildSegments threads the persisted proposals", processor.segments.count == 8
              && processor.segments[1].enclosureOf == 0 && processor.segments[2].enclosureOf == 0)
        let model = LLMModel(id: "test", displayName: "Test", provider: .anthropic, supportsThinking: false,
                             returnsMd: false, inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
        await processor.performTaggingPhase(provider: .anthropic, model: model, thinkingLevel: nil, apiKey: "",
                                            outputDirectory: outDir, enableSegmentJSON: true)
        func out(_ n: String) -> URL { outputs[u(n)]! }
        func json(_ n: String) -> [String: Any] { jsonOf(out(n).deletingPathExtension().appendingPathExtension("json")) }
        func sentWithTokens(_ url: URL) -> [String] { tagsOf(url).filter { $0.hasPrefix("Sent With") } }
        check("the covering letter keeps its own date and gets NO Sent With",
              tagsOf(out("L.jpg")).contains("1958") && sentWithTokens(out("L.jpg")).isEmpty)
        check("enclosure page 1: own date + the letter's date",
              tagsOf(out("E1.jpg")).contains("1957") && sentWithTokens(out("E1.jpg")) == ["Sent With 1958-03"])
        check("enclosure continuation page: the same tags as its first page, nothing extra",
              tagsOf(out("E1c.jpg")) == tagsOf(out("E1.jpg")))
        check("second enclosure: same letter date",
              tagsOf(out("E2.jpg")).contains("1956") && sentWithTokens(out("E2.jpg")) == ["Sent With 1958-03"])
        check("after a box label: no Sent With", sentWithTokens(out("X.jpg")).isEmpty)
        check("enclosure of an undated letter: no Sent With (no neighbour borrowed)",
              tagsOf(out("E3.jpg")).contains("1955") && sentWithTokens(out("E3.jpg")).isEmpty)
        check("an unmarked neighbour: no Sent With", sentWithTokens(out("N.jpg")).isEmpty)
        let e1 = json("E1.jpg")
        check("enclosure sidecar: sent_with + flag + relation",
              e1["sent_with"] as? String == "1958-03" && e1["sent_with_uncertain"] as? Bool == false
              && e1["enclosure_of"] as? String == "L.jpg" && e1["date"] as? String == "1957")
        let e3 = json("E3.jpg")
        check("undated-cover sidecar keeps the relation but no date",
              e3["enclosure_of"] as? String == "U.jpg" && e3["sent_with"] == nil)
        let l = json("L.jpg")
        check("letter sidecar has no W37 keys", l["sent_with"] == nil && l["enclosure_of"] == nil)

        // --- 5b. Review fixes: a POST-tagging reclassification strips/refreshes written Sent With. ---
        // (MED-3) E1 reclassified to a continuation of L: E1 is now part of the cover, so its pages lose
        // the token and its sidecar the relation; E2's cover pages (L, E1, E1c) are unchanged, so it keeps
        // its (refreshed) letter date.
        processor.updateClassification(at: 1, to: .documentContinuation)
        check("MED-3: a page that stopped being an enclosure loses its Sent With tokens",
              sentWithTokens(out("E1.jpg")).isEmpty && sentWithTokens(out("E1c.jpg")).isEmpty)
        check("MED-3: ...and its sidecar loses sent_with + enclosure_of",
              json("E1.jpg")["sent_with"] == nil && json("E1.jpg")["enclosure_of"] == nil)
        check("MED-3: an enclosure whose cover pages are unchanged keeps its letter date",
              sentWithTokens(out("E2.jpg")) == ["Sent With 1958-03"]
              && json("E2.jpg")["enclosure_of"] as? String == "L.jpg")
        // (MED-3) a folder label inserted between E2 and its cover.
        processor.updateClassification(at: 2, to: .folderLabel)
        check("MED-3: a label inserted before an enclosure strips its Sent With",
              sentWithTokens(out("E2.jpg")).isEmpty && json("E2.jpg")["sent_with"] == nil
              && json("E2.jpg")["enclosure_of"] == nil)
        check("MED-3: ...and the new label page carries none either", sentWithTokens(out("E1c.jpg")).isEmpty)
        check("MED-3: the covering letter is still untouched", sentWithTokens(out("L.jpg")).isEmpty
              && tagsOf(out("L.jpg")).contains("1958"))
        check("token replacement touches only valid sent-with tokens, never prose",
              OCRProcessor.replacingSentWithTokens(
                in: ["1957", "Sent With 1950s", "Sent With Date Uncertain", "Harbours", "Sent with love", "Sent With Love"],
                with: ["Sent With 1958-03"])
              == ["1957", "Sent With 1958-03", "Harbours", "Sent with love", "Sent With Love"])
        check("token insertion lands after the own-date run",
              OCRProcessor.replacingSentWithTokens(in: ["1957", "05 May", "Day 3", "Date Uncertain", "Harbours"],
                                                   with: ["Sent With 1958"])
              == ["1957", "05 May", "Day 3", "Date Uncertain", "Sent With 1958", "Harbours"])
        check("stripping with no replacement removes both tokens",
              OCRProcessor.replacingSentWithTokens(in: ["1957", "Sent With 1958", "Sent With Date Uncertain", "X"], with: [])
              == ["1957", "X"])

        // (MED-1 / MED-2) the proposal baseline: P0 letter X · P1 letter Y · P2 Y cont. · P3 enclosure of Y.
        func baselineProcessor() -> (OCRProcessor, [URL]) {
            let p = OCRProcessor()
            let pf = ["P0.jpg", "P1.jpg", "P2.jpg", "P3.jpg"].map(u)
            let pc: [DocumentClassification] = [.documentStart, .documentStart, .documentContinuation, .documentStart]
            p.jobs = pf.indices.map { i in
                var job = OCRJob(sourceURL: pf[i])
                job.result = OCRResult(text: "t", classification: pc[i], rotationDegrees: 0,
                                       errorMessage: nil, errorCode: nil, enclosure: i == 3)
                job.classification = pc[i]
                return job
            }
            return (p, pf)
        }
        func relationOfP3(_ p: OCRProcessor, _ pf: [URL]) -> [URL]? {
            let segs = p.currentSegments(files: pf)
            guard let i = segs.firstIndex(where: { $0.pdfURLs.first == pf[3] }), let c = segs[i].enclosureOf else { return nil }
            return segs[c].pdfURLs
        }
        do {
            let (p, pf) = baselineProcessor()
            check("baseline: P3 is proposed as an enclosure of Y (P1+P2)", relationOfP3(p, pf) == [pf[1], pf[2]])
            p.removedSourceURLs.insert(pf[1])
            check("MED-1: removing the cover's first page (P2 now joins X) drops the relation",
                  relationOfP3(p, pf) == nil)
        }
        do {
            let (p, pf) = baselineProcessor()
            p.jobs[2].result = p.jobs[2].result?.with(classification: .documentStart, rotationDegrees: 0)
            check("MED-2: splitting the cover (P2 → its own start) drops the relation", relationOfP3(p, pf) == nil)
        }
        do {
            let (p, pf) = baselineProcessor()
            p.jobs[1].result = p.jobs[1].result?.with(classification: .documentContinuation, rotationDegrees: 0)
            check("MED-2: merging the cover into X (P1 → continuation) drops the relation", relationOfP3(p, pf) == nil)
        }
        do {
            let (p, pf) = baselineProcessor()
            p.jobs[1].result = p.jobs[1].result?.with(classification: .documentStart, rotationDegrees: 90)
            check("a rotation-only fix on the cover keeps the relation", relationOfP3(p, pf) == [pf[1], pf[2]])
            check("the model's own classification survives a reclassification (the baseline frame)",
                  flagged.with(classification: .documentContinuation, rotationDegrees: 0).ocrClassification == .documentStart)
            check("an explicit rebuild carries the proposal + model classification (LOW-1 shape)",
                  OCRResult(text: "t", classification: .documentStart, rotationDegrees: 90, errorMessage: nil, errorCode: nil,
                            enclosure: flagged.enclosure, ocrClassification: .some(flagged.ocrClassification)).enclosure == true)
        }

        // --- 6. JSON stability + GeneratedTags Codable. ---
        let plainTags = GeneratedTags(year: "1968", subjectTags: ["taxes"])
        let a = SegmentJSONBuilder.buildData(fileURLs: [u("a.pdf")], texts: ["x"], tags: plainTags)
        let b = SegmentJSONBuilder.buildData(fileURLs: [u("a.pdf")], texts: ["x"], tags: plainTags, enclosureOf: nil)
        check("no sent-with date → sidecar bytes unchanged", a != nil && a == b
              && !(String(data: a ?? Data(), encoding: .utf8) ?? "").contains("sent_with"))
        var coded = GeneratedTags(year: "1957")
        coded.sentWith = ArchiveDate(decade: 1950)
        coded.sentWithUncertain = true
        let back = (try? JSONEncoder().encode(coded)).flatMap { try? JSONDecoder().decode(GeneratedTags.self, from: $0) }
        check("GeneratedTags round-trips sentWith + sentWithUncertain (Live retained manifest)",
              back?.sentWith == coded.sentWith && back?.sentWithUncertain == true)

        // --- 7. PDF header lines strip via the shared parser. ---
        let pdfURL = tmp.appendingPathComponent("header.pdf")
        let sourceDates = EnclosureDates.pdfSourceDates(for: enc.with(year: "1957", sentWith: ArchiveDate(year: 1958, month: 3, day: 12)))
        check("source-date lines use Core's display form",
              sourceDates?.headerLines == ["Document date: 1957", "Sent with: Mar 12, 1958"])
        check("no dates → no lines", EnclosureDates.pdfSourceDates(for: GeneratedTags(subjectTags: ["x"])) == nil)
        _ = try? PDFGenerator().generate(imageURL: tmp.appendingPathComponent("missing.jpg"),
                                         result: OCRResult(text: "Report on the harbour works.", classification: .documentStart,
                                                           errorMessage: nil, errorCode: nil),
                                         model: model, outputURL: pdfURL, originalFileName: "E1.jpg",
                                         sourceDates: sourceDates)
        let extracted = PDFHeaderParser.extract(pdfURL)
        check("generated header carries both lines", extracted?.fullBody.contains("Sent with: Mar 12, 1958") == true
              && extracted?.fullBody.contains("Document date: 1957") == true)
        check("...and the stripped body is exactly the OCR text", extracted?.strippedBody == "Report on the harbour works.")
        check("...and classification still parses", extracted?.classification == "Document Start")

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["DUAL_DATE_TEST_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("archiveprocessor-dualdate-result.txt")
        try? Data(report.utf8).write(to: outPath, options: .atomic)
        NSLog("DUALDATE DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath.path)")
        try? fm.removeItem(at: tmp)   // explicit: `exit` below would skip a `defer`
        exit(passed ? 0 : 1)
    }
}

private extension GeneratedTags {
    /// Test helper: a copy with the given own year and sent-with date.
    func with(year: String?, sentWith: ArchiveDate?) -> GeneratedTags {
        var t = self
        t.year = year; t.month = nil; t.day = nil
        t.sentWith = sentWith
        return t
    }
}
