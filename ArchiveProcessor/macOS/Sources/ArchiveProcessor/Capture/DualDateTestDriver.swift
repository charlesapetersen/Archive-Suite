#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
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
///   5c. A window split that drops the proposal: the cover named in document review (owner call 33) gives
///      the enclosure that letter's date as Sent With; left blank, none. Never a cover after the enclosure,
///      never one that overrides a kept proposal.
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
        check("year/month/day cover", own("1958", "3 March", "Day 12")?.wireValue == "1958-03-12")
        check("year/month cover", own("1958", "3 March")?.wireValue == "1958-03")
        check("year-only cover", own("1958")?.wireValue == "1958")
        check("decade cover", own("1950s")?.wireValue == "1950s")
        check("undated cover → nil", own(nil) == nil)
        check("an impossible cover date is not truncated into a fake one", own("1958", "2 February", "Day 30") == nil)
        check("an unparseable cover month gives nil, not a year guess", own("1958", "Spring") == nil)
        check("a day without a month is ignored (as machineDate does)", own("1958", nil, "Day 4")?.wireValue == "1958")
        check("an OCR-failed cover has no date",
              EnclosureDates.ownDate(of: GeneratedTags(year: "1958", ocrFailed: true)) == nil)
        var enc = GeneratedTags(year: "1957", subjectTags: ["Harbours"])
        EnclosureDates.applySentWith(fromCover: GeneratedTags(year: "1958", month: "3 March", day: "Day 12",
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
            job.result = OCRResult(text: names[i] == "E1c.jpg" ? nil : "text of \(names[i])", classification: classes[i], rotationDegrees: 0,
                                   errorMessage: nil, errorCode: nil, enclosure: flags[i])
            job.classification = classes[i]
            return job
        }
        // L 1958-03 · E1 1957 · E2 1956 · X 1960 · U undated · E3 1955 · N 1961
        processor.preGroupedYears = [1958, 1957, nil, 1956, nil, 1960, nil, 1955, 1961]
        processor.preGroupedMonths = [3, nil, nil, nil, nil, nil, nil, nil, nil]
        processor.preGroupedSubjects = names.map { _ in ["Correspondence"] }
        let model = LLMModel(id: "test", displayName: "Test", provider: .anthropic, supportsThinking: false,
                             returnsMd: false, inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
        var outputs: [URL: URL] = [:]
        for job in processor.jobs {
            let f = job.sourceURL
            let pdf = outDir.appendingPathComponent(f.deletingPathExtension().lastPathComponent + ".pdf")
            if let result = job.result {
                _ = try? PDFGenerator().generate(imageURL: f, result: result, model: model, outputURL: pdf,
                                                 originalFileName: f.lastPathComponent)
            }
            outputs[f] = pdf
        }
        processor.outputURLMap = outputs
        processor.rebuildSegments(files: files)
        check("rebuildSegments threads the persisted proposals", processor.segments.count == 8
              && processor.segments[1].enclosureOf == 0 && processor.segments[2].enclosureOf == 0)
        await processor.performTaggingPhase(provider: .anthropic, model: model, apiKey: "",
                                            outputDirectory: outDir, enableSegmentJSON: true)
        func out(_ n: String) -> URL { outputs[u(n)]! }
        func content(_ n: String) -> ExtractedContent? { PDFHeaderParser.extract(out(n)) }
        func json(_ n: String) -> [String: Any] { jsonOf(out(n).deletingPathExtension().appendingPathExtension("json")) }
        func sentWithTokens(_ url: URL) -> [String] { tagsOf(url).filter { $0.hasPrefix("Sent With") } }
        check("the covering letter keeps its own date and gets NO Sent With",
              tagsOf(out("L.jpg")).contains("1958") && sentWithTokens(out("L.jpg")).isEmpty)
        check("enclosure page 1: own date + the letter's date",
              tagsOf(out("E1.jpg")).contains("1957") && sentWithTokens(out("E1.jpg")) == ["Sent With 1958-03"])
        check("enclosure continuation page: the same tags as its first page, nothing extra",
              tagsOf(out("E1c.jpg")) == tagsOf(out("E1.jpg")))
        // W49.storage-drop-dead-copies: the dates are catalogue facts (`rememberCatalogueFields` builds them from the
        // tags the processor holds for each page); page 2 carries no date lines.
        func filedDates(_ n: String) -> (date: String?, sentWith: String?) {
            let tags = processor.appliedGeneratedTags[u(n)]
            return (tags.flatMap { EnclosureDates.ownDate(of: $0)?.display }, tags?.sentWith?.display)
        }
        func noDateLines(_ n: String) -> Bool {
            guard let h = content(n)?.textPages.first?.header else { return false }
            return h.documentDate == nil && h.sentWith == nil && h.dateEvidence == nil
        }
        check("both enclosure pages file the same dates, and neither page 2 (one a placeholder) carries a date line",
              ["E1.jpg", "E1c.jpg"].allSatisfy { processor.appliedGeneratedTags[u($0)] != nil } &&
              ["E1.jpg", "E1c.jpg"].allSatisfy {
                  filedDates($0) == ("1957", "Mar 1958") && noDateLines($0)
              } && content("E1c.jpg")?.strippedBody == "No text returned by model.")
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
        check("review clears Sent with from both pages and preserves their recorded own date",
              ["E1.jpg", "E1c.jpg"].allSatisfy { filedDates($0) == ("1957", nil) && noDateLines($0) })
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
        processor.rebuildSegments(files: files)
        await processor.performTaggingPhase(provider: .anthropic, model: model, apiKey: "",
                                            outputDirectory: outDir, enableSegmentJSON: true)
        let labelHeader = content("E1c.jpg")?.textPages.first?.header
        check("redo clears a former document's date snapshot from a page now tagged as a folder label",
              labelHeader != nil && labelHeader?.documentDate == nil && labelHeader?.sentWith == nil)
        check("token replacement touches only valid sent-with tokens, never prose",
              OCRProcessor.replacingSentWithTokens(
                in: ["1957", "Sent With 1950s", "Sent With Date Uncertain", "Harbours", "Sent with love", "Sent With Love"],
                with: ["Sent With 1958-03"])
              == ["1957", "Sent With 1958-03", "Harbours", "Sent with love", "Sent With Love"])
        check("token insertion lands after the own-date run",
              OCRProcessor.replacingSentWithTokens(in: ["1957", "5 May", "Day 3", "Date Uncertain", "Harbours"],
                                                   with: ["Sent With 1958"])
              == ["1957", "5 May", "Day 3", "Date Uncertain", "Sent With 1958", "Harbours"])
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

        // --- 5c. W49.proc-s047-cover-select (owner call 33): the cover named in document review. ---
        // Q0 letter X 1950 · Q1 letter Y Mar 1958 · Q2 Y's second page, split off as its own document (1959) ·
        // Q3 Y's enclosure (1957). The split drops the OCR's proposal; a cover named in review restores a relation.
        do {
            let (p, pf) = baselineProcessor()
            p.jobs[2].result = p.jobs[2].result?.with(classification: .documentStart, rotationDegrees: 0)
            let segs = p.currentSegments(files: pf)
            check("a dropped proposal offers the documents before the enclosure, oldest first",
                  segs.count == 4 && segs[3].coverCandidates == [0, 1, 2] && segs[0].coverCandidates.isEmpty)
            p.setEnclosureCover(pf[1].path, for: pf[3].path)
            check("the named cover becomes the relation", relationOfP3(p, pf) == [pf[1]])
            p.setEnclosureCover("", for: pf[3].path)
            check("a blank choice leaves no relation", relationOfP3(p, pf) == nil)
            p.setEnclosureCover(pf[3].path, for: pf[3].path)
            check("the enclosure itself is never its own cover", relationOfP3(p, pf) == nil)
        }
        do {
            let (p, pf) = baselineProcessor()
            p.setEnclosureCover(pf[0].path, for: pf[3].path)
            check("a choice never overrides a proposal the baseline kept", relationOfP3(p, pf) == [pf[1], pf[2]]
                  && p.currentSegments(files: pf)[2].coverCandidates.isEmpty)
        }
        do {
            // Two enclosures of the split letter: the second is offered the documents, never the first enclosure.
            let (p, pf) = baselineProcessor()
            let p4 = u("P4.jpg")
            var job = OCRJob(sourceURL: p4)
            job.result = OCRResult(text: "t", classification: .documentStart, rotationDegrees: 0,
                                   errorMessage: nil, errorCode: nil, enclosure: true)
            job.classification = .documentStart
            p.jobs.append(job)
            let files5 = pf + [p4]
            check("baseline: both enclosures share the letter", p.currentSegments(files: files5)[3].enclosureOf == 1)
            p.jobs[2].result = p.jobs[2].result?.with(classification: .documentStart, rotationDegrees: 0)
            p.setEnclosureCover(pf[1].path, for: pf[3].path)
            let segs = p.currentSegments(files: files5)
            check("an enclosure is never offered as another enclosure's cover",
                  segs.count == 5 && segs[3].enclosureOf == 1 && segs[4].coverCandidates == [0, 1, 2])
            p.setEnclosureCover(pf[3].path, for: p4.path)
            check("...and a choice of it is ignored", p.currentSegments(files: files5)[4].enclosureOf == nil)
        }
        func coverChoiceRun(_ choice: String?) async -> (tokens: [String], json: [String: Any], ownDate: Bool, sheetCover: Int?,
                                                         afterEdit: [String]) {
            let dir = tmp.appendingPathComponent("cover-\(choice == nil ? "blank" : "chosen")", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let qn = ["Q0.jpg", "Q1.jpg", "Q2.jpg", "Q3.jpg"]
            let qf = qn.map(u)
            let qc: [DocumentClassification] = [.documentStart, .documentStart, .documentContinuation, .documentStart]
            let p = OCRProcessor()
            p.taggingMode = .automatic
            p.jobs = qf.indices.map { i in
                var job = OCRJob(sourceURL: qf[i])
                job.result = OCRResult(text: "text of \(qn[i])", classification: qc[i], rotationDegrees: 0,
                                       errorMessage: nil, errorCode: nil, enclosure: i == 3)
                job.classification = qc[i]
                return job
            }
            // The window split: Q2 starts its own document.
            p.jobs[2].classification = .documentStart
            p.jobs[2].result = p.jobs[2].result?.with(classification: .documentStart, rotationDegrees: 0)
            p.preGroupedYears = [1950, 1958, 1959, 1957]
            p.preGroupedMonths = [nil, 3, nil, nil]
            p.preGroupedSubjects = qn.map { _ in ["Correspondence"] }
            if let choice { p.setEnclosureCover(choice, for: qf[3].path) }
            var outs: [URL: URL] = [:]
            for job in p.jobs {
                let f = job.sourceURL
                let pdf = dir.appendingPathComponent(f.deletingPathExtension().lastPathComponent + ".pdf")
                if let result = job.result {
                    _ = try? PDFGenerator().generate(imageURL: f, result: result, model: model, outputURL: pdf,
                                                     originalFileName: f.lastPathComponent)
                }
                outs[f] = pdf
            }
            p.outputURLMap = outs
            p.rebuildSegments(files: qf)
            let sheetCover = OCRProcessor.validCoverIndex(of: 3, in: p.segments)
            await p.performTaggingPhase(provider: .anthropic, model: model, apiKey: "",
                                        outputDirectory: dir, enableSegmentJSON: true)
            let q3 = outs[qf[3]]!
            let tokens = sentWithTokens(q3), sidecar = jsonOf(q3.deletingPathExtension().appendingPathExtension("json"))
            // A later edit elsewhere re-derives every relation (MED-3 reconcile); the named cover stands.
            p.updateClassification(at: 0, to: .folderLabel)
            return (tokens, sidecar, tagsOf(q3).contains("1957"), sheetCover, sentWithTokens(q3))
        }
        let blank = await coverChoiceRun(nil)
        check("split cover left blank: the enclosure keeps its own date and gets no Sent With",
              blank.ownDate && blank.tokens.isEmpty && blank.json["sent_with"] == nil && blank.json["enclosure_of"] == nil)
        let chosen = await coverChoiceRun(u("Q1.jpg").path)
        check("split cover named in review (page 2): Sent With is that letter's date, own date kept",
              chosen.ownDate && chosen.tokens == ["Sent With 1958-03"]
              && chosen.json["sent_with"] as? String == "1958-03" && chosen.json["enclosure_of"] as? String == "Q1.jpg")
        check("the manual tag sheet is seeded with the named cover", chosen.sheetCover == 1 && blank.sheetCover == nil)
        check("an unrelated reclassification after tagging keeps the named cover's Sent With",
              chosen.afterEdit == ["Sent With 1958-03"] && blank.afterEdit.isEmpty)

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

        // --- 7. Historical header lines (an older file's, kept by Improve OCR) strip via the shared parser. ---
        // W49.storage-drop-dead-copies: new output carries its dates in the catalogue record, not these lines.
        let pdfURL = tmp.appendingPathComponent("header.pdf")
        let dated = enc.with(year: "1957", sentWith: ArchiveDate(year: 1958, month: 3, day: 12))
        let sourceDates = PDFSourceDates(documentDate: EnclosureDates.ownDate(of: dated)?.display,
                                         sentWith: dated.sentWith?.display)
        check("source-date lines use Core's display form",
              sourceDates.headerLines == ["Document date: 1957", "Sent with: Mar 12, 1958"])
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

        // W44.reocr-spec: new-output Kind/provenance, plus existing audited tag semantics on scratch.
        for kind in OCRPageKind.allCases {
            _ = try? PDFGenerator().generate(imageURL: tmp.appendingPathComponent("missing.jpg"),
                result: OCRResult(text: "Report.", classification: .documentStart, errorMessage: nil, errorCode: nil),
                model: model, outputURL: pdfURL, originalFileName: "Kind: filename.jpg", sourceDates: sourceDates,
                pageKind: kind)
            let parsed = PDFHeaderParser.extract(pdfURL)
            let h = parsed?.textPages.first?.header
            check("Kind \(kind.rawValue) round-trips with both source dates and actual provenance",
                  h?.kind == kind && h?.documentDate == "1957" && h?.sentWith == "Mar 12, 1958"
                  && h?.provenance?.model == model.displayName && h?.diagnostics.isEmpty == true
                  && parsed?.strippedBody == "Report.")
        }
        let gatewayLabel = "Kind: a very long custom gateway name " + String(repeating: "University ", count: 10) + "· Region\nWest"
        _ = try? PDFGenerator().generate(imageURL: tmp.appendingPathComponent("missing.jpg"),
            result: OCRResult(text: "Report.", classification: nil, errorMessage: nil, errorCode: nil),
            model: model, outputURL: pdfURL, gatewayDisplayName: gatewayLabel, pageKind: .printed)
        let gatewayHeader = PDFHeaderParser.extract(pdfURL)?.textPages.first?.header
        check("a long gateway label round-trips whole after separator/control sanitization: \(String(describing: gatewayHeader)) raw: \((PDFDocument(url: pdfURL)?.page(at: 1)?.string ?? "").debugDescription)",
              gatewayHeader?.provenance?.provider == ImportedReading.headerComponent(gatewayLabel)
              && gatewayHeader?.provenance?.model == model.displayName && gatewayHeader?.kind == .printed)
        for kind in ["mixed", "unknown", ""] {
            let imported = ImportedReading(source: "Atlas", model: "Qwen", preset: nil, precision: nil, job: nil, kind: kind)
            _ = try? PDFGenerator().generate(imageURL: tmp.appendingPathComponent("missing.jpg"),
                result: OCRResult(text: "Report.", classification: nil, errorMessage: nil, errorCode: nil, imported: imported),
                model: model, outputURL: pdfURL)
            let h = PDFHeaderParser.extract(pdfURL)?.textPages.first?.header
            check("unknown imported kind '\(kind)' remains absent", h?.kind == nil && h?.diagnostics.contains(.missingKind) == true)
        }
        let rawTags = ["oCr pOoR", "OCR Poor", "OCR Failed", "OCR Poorly", "Q3", "Unread", "History", "History"]
        do {
            let before = try Data(contentsOf: pdfURL)
            try MacOSTagger.applyTags(rawTags, to: pdfURL, stampUnread: false)
            let read = try MacOSTagger.readTags(from: pdfURL)
            check("Processor tag round-trip retains Poor as an ordinary Subject and every occurrence",
                  multisetEqual(read, rawTags) && DocumentTags.parse(raw: read, labelNumber: nil).hasPoorOCR)
            check("Processor tag writes leave PDF bytes intact", try Data(contentsOf: pdfURL) == before)
        } catch { check("Processor Poor tag contract", false) }

        // --- 8. The typed date fields (W40.processor-date-field): typed text → the same tags as before. ---
        func typed(_ text: String) -> ArchiveDate? {
            if case .date(let d, _) = DateFieldEntry.archiveDate(text) { return d }
            return nil
        }
        /// Typed text through the draft the cards bind (`SegmentTagData.ownDate`) to the tags it writes.
        func tagsTyped(_ text: String, sentWith: String = "") -> [String] {
            var draft = SegmentTagData()
            draft.ownDate = typed(text)
            draft.sentWith = typed(sentWith)?.wireValue ?? ""
            var g = GeneratedTags(year: draft.year.isEmpty ? nil : draft.year,
                                  month: draft.month.isEmpty ? nil : draft.month,
                                  day: draft.day.isEmpty ? nil : draft.day)
            EnclosureDates.resolveManual(entry: draft.sentWith, uncertain: false, cover: nil, into: &g)
            return g.allTags
        }
        check("typed 1968 → the Year tag", tagsTyped("1968") == ["1968"])
        check("typed 1960s → the decade tag", tagsTyped("1960s") == ["1960s"])
        check("typed March 1968 → Year + Month", tagsTyped("March 1968") == ["1968", "3 March"])
        check("typed 1968-03-12 → Year + Month + Day", tagsTyped("1968-03-12") == ["1968", "3 March", "Day 12"])
        check("typed 12 Mar 1968 → the same", tagsTyped("12 Mar 1968") == ["1968", "3 March", "Day 12"])
        check("an impossible typed day is dropped to its month", tagsTyped("31 February 1968") == ["1968", "2 February"])
        check("typed Sent with → its token after the own date",
              tagsTyped("1957", sentWith: "March 1958") == ["1957", "Sent With 1958-03"])
        check("typed Sent with a decade", tagsTyped("", sentWith: "1950s") == ["Sent With 1950s"])
        let typedParsed = DocumentTags.parse(raw: tagsTyped("12 March 1968", sentWith: "1958-03-12"), labelNumber: nil)
        check("the written tags read back as the SPEC's facets",
              typedParsed.year == 1968 && typedParsed.month?.number == 3 && typedParsed.day == 12
              && typedParsed.sentWith?.wireValue == "1958-03-12" && typedParsed.subjects.isEmpty)
        check("a typed decade reads back as the decade facet",
              DocumentTags.parse(raw: tagsTyped("1960s"), labelNumber: nil).decade == 1960)
        for wire in ["1958", "1950s", "1958-03", "1958-03-12"] {
            let d = ArchiveDate.parse(wireValue: wire)
            let c = TypedDateTags.components(d)
            check("\(wire): seed text → components → date round-trips",
                  typed(wire) == d && TypedDateTags.date(year: c.year, month: c.month, day: c.day) == d)
        }
        var cleared = SegmentTagData(year: "1968", month: "3 March", day: "Day 12")
        cleared.ownDate = nil
        check("an emptied field clears Year, Month and Day", cleared.dateComponents == TypedDateTags.Components())
        var decadeOver = SegmentTagData(year: "1968", month: "3 March", day: "Day 12")
        decadeOver.ownDate = typed("1960s")
        check("a coarser typed date drops the old month and day", decadeOver.dateComponents == .init(year: "1960s"))
        check("stored strings that name no date are shown, not hidden",
              TypedDateTags.date(year: "circa 1968", month: "", day: "") == nil
              && TypedDateTags.rawText(.init(year: "circa 1968", month: " ", day: "")) == "circa 1968")
        var reply = SegmentTagData()
        reply.setDate(fromReply: GeneratedTags(year: "1968", month: nil, day: "Day 12"))
        check("an auto-date reply is taken as the date it names (no unseen Day beside a year)",
              reply.dateComponents == .init(year: "1968"))
        reply.setDate(fromReply: GeneratedTags(year: "1968", month: "March", day: "12"))
        check("...and in the canonical tag strings", reply.dateComponents == .init(year: "1968", month: "3 March", day: "Day 12"))
        reply.setDate(fromReply: GeneratedTags(year: "circa 1968"))
        check("a reply that names no date is kept verbatim for the field to show",
              reply.dateComponents == .init(year: "circa 1968") && reply.ownDate == nil)
        var blocked = SegmentTagData()
        blocked.dateTextUnreadable = true
        var blockedSent = ManualTagSegment(segmentIndex: 0, images: [])
        blockedSent.sentWithTextUnreadable = true
        check("unreadable typed text blocks Save / Next", !blocked.datesAreValid && !blockedSent.datesAreValid
              && SegmentTagData().datesAreValid)
        if case .unreadable = DateFieldEntry.archiveDate("12/3/1968") {
            check("an ambiguous all-number date is refused", true)
        } else { check("an ambiguous all-number date is refused", false) }
        if case .unreadable = TypedDateTags.liveCaptureReading("1960s") {
            check("Live Capture refuses a decade (it keeps a year and month)", true)
        } else { check("Live Capture refuses a decade (it keeps a year and month)", false) }
        if case .date(let d, let note) = TypedDateTags.liveCaptureReading("12 March 1968") {
            check("Live Capture keeps the year and month of a typed day, and says so",
                  d.wireValue == "1968-03" && note?.contains("day is not kept") == true)
        } else { check("Live Capture keeps the year and month of a typed day, and says so", false) }
        if case .date(let d, nil) = TypedDateTags.liveCaptureReading("1968") {
            check("Live Capture takes a year", d.year == 1968 && d.month == nil)
        } else { check("Live Capture takes a year", false) }
        // The written tags on a scratch PDF (never the corpus), read back.
        let typedPDF = tmp.appendingPathComponent("typed.pdf")
        writeOnePagePDF(typedPDF)
        do {
            let written = tagsTyped("12 March 1968", sentWith: "1950s")
            try MacOSTagger.applyTags(written, to: typedPDF, stampUnread: false)
            check("typed-date tags land on a scratch PDF as written",
                  multisetEqual(try MacOSTagger.readTags(from: typedPDF), written))
        } catch { check("typed-date tags land on a scratch PDF as written", false) }

        // --- 5d. W49.proc-manual-repoint-relation: manual tag sheet re-points an enclosure at another letter. ---
        // Box (seg 0) · Letter A 1950 (seg 1, card 0) · Letter B 1958-03 (seg 2, card 1) ·
        // Enclosure E proposed->B (seg 3, card 2) · Standalone Doc D (seg 4, card 3).
        do {
            let dir = tmp.appendingPathComponent("manual-repoint", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let names = ["M0_Box.jpg", "M1_LetterA.jpg", "M2_LetterB.jpg", "M3_Encl.jpg", "M4_Doc.jpg"]
            let urls = names.map(u)
            let classes: [DocumentClassification] = [.boxLabel, .documentStart, .documentStart, .documentStart, .documentStart]
            let p = OCRProcessor()
            p.taggingMode = .human
            p.jobs = urls.indices.map { i in
                var job = OCRJob(sourceURL: urls[i])
                job.result = OCRResult(text: "text \(names[i])", classification: classes[i], rotationDegrees: 0,
                                       errorMessage: nil, errorCode: nil, enclosure: i == 3)
                job.classification = classes[i]
                return job
            }
            var outs: [URL: URL] = [:]
            for job in p.jobs {
                let pdf = dir.appendingPathComponent(job.sourceURL.deletingPathExtension().lastPathComponent + ".pdf")
                writeOnePagePDF(pdf)
                outs[job.sourceURL] = pdf
            }
            p.outputURLMap = outs
            p.rebuildSegments(files: urls)

            let task = Task { @MainActor in
                await p.performManualTaggingPhase(
                    mode: .human, provider: .anthropic, model: model, thinkingLevel: nil,
                    apiKey: "", outputDirectory: dir, enableSegmentJSON: true
                )
            }
            while !p.awaitingManualTagging { await Task.yield() }

            // Seed dates on Letter A (1950), Letter B (1958-03), Encl E (1957), Doc D (1956).
            p.manualTagSegments[0].ownDate = ArchiveDate(year: 1950)
            p.manualTagSegments[1].ownDate = ArchiveDate(year: 1958, month: 3)
            p.manualTagSegments[2].ownDate = ArchiveDate(year: 1957)
            p.manualTagSegments[3].ownDate = ArchiveDate(year: 1956)

            // Candidate list excludes box label (seg 0), self, later segments, and other enclosures (seg 3).
            let optsForEncl = p.manualCoverOptions(forCardAt: 2).map(\.segmentIndex)
            let optsForDoc = p.manualCoverOptions(forCardAt: 3).map(\.segmentIndex)
            check("W49.proc-manual-repoint-relation: cover options offer earlier non-label, non-enclosure letters only",
                  p.manualCoverOptions(forCardAt: 0).isEmpty && optsForEncl == [1, 2] && optsForDoc == [1, 2])
            check("W49.proc-manual-repoint-relation: proposed enclosure starts on Letter B",
                  p.manualTagSegments[2].enclosureOfSegmentIndex == 2
                  && p.manualTagSegments[2].proposedEnclosureOfSegmentIndex == 2)

            // Guard checks: self, forward, box label, and another enclosure are all rejected.
            p.setManualEnclosureCover(0, forCardAt: 2)   // box label
            check("W49.proc-manual-repoint-relation: box label rejected as cover",
                  p.manualTagSegments[2].enclosureOfSegmentIndex == nil)
            p.setManualEnclosureCover(3, forCardAt: 2)   // self
            check("W49.proc-manual-repoint-relation: self rejected as cover",
                  p.manualTagSegments[2].enclosureOfSegmentIndex == nil)
            p.setManualEnclosureCover(4, forCardAt: 2)   // later segment
            check("W49.proc-manual-repoint-relation: later document rejected as cover",
                  p.manualTagSegments[2].enclosureOfSegmentIndex == nil)

            // Re-point Enclosure E from Letter B (seg 2) to Letter A (seg 1).
            p.setManualEnclosureCover(1, forCardAt: 2)
            check("W49.proc-manual-repoint-relation: re-pointing updates cover index and name",
                  p.manualTagSegments[2].enclosureOfSegmentIndex == 1
                  && p.manualTagSegments[2].enclosureCoverName == "M1_LetterA.jpg")
            // Cannot chain: Doc D cannot pick Enclosure E (seg 3) while E is an enclosure.
            p.setManualEnclosureCover(3, forCardAt: 3)
            check("W49.proc-manual-repoint-relation: chained enclosure rejected as cover",
                  p.manualTagSegments[3].enclosureOfSegmentIndex == nil)
            // Point standalone Doc D at Letter B (seg 2), with an explicit typed Sent With override.
            p.setManualEnclosureCover(2, forCardAt: 3)
            p.manualTagSegments[3].sentWith = "1959-01"
            // If Letter B itself becomes an enclosure of Letter A, Doc D's pointer to Letter B is cleared (no chains).
            p.setManualEnclosureCover(1, forCardAt: 1)
            check("W49.proc-manual-repoint-relation: turning a cover into an enclosure clears downstream pointers",
                  p.manualTagSegments[1].enclosureOfSegmentIndex == 1
                  && p.manualTagSegments[3].enclosureOfSegmentIndex == nil)
            // Restore Letter B as standalone and point Doc D back at Letter B (keeping its explicit Sent With).
            p.setManualEnclosureCover(nil, forCardAt: 1)
            p.setManualEnclosureCover(2, forCardAt: 3)

            p.finishManualTagging()
            await task.value

            let enclPDF = outs[urls[3]]!
            let enclJSON = jsonOf(enclPDF.deletingPathExtension().appendingPathExtension("json"))
            let docPDF = outs[urls[4]]!
            let docJSON = jsonOf(docPDF.deletingPathExtension().appendingPathExtension("json"))

            check("W49.proc-manual-repoint-relation: re-pointed enclosure takes Letter A's Sent With + sidecar enclosure_of",
                  sentWithTokens(enclPDF) == ["Sent With 1950"]
                  && (enclJSON["enclosure_of"] as? String) == "M1_LetterA.jpg"
                  && p.effectiveCoverIndex(of: 3, in: p.segments) == 1)
            check("W49.proc-manual-repoint-relation: newly pointed doc keeps explicit Sent With while recording chosen cover",
                  sentWithTokens(docPDF) == ["Sent With 1959-01"]
                  && (docJSON["enclosure_of"] as? String) == "M2_LetterB.jpg"
                  && p.effectiveCoverIndex(of: 4, in: p.segments) == 2)
        }

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

#endif
