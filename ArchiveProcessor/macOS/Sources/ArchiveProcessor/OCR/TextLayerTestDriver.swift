#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import ArchiveCore
import CoreText
import Foundation
import PDFKit
import VisionOCRKit

/// Headless, $0 self-test of the image page's searchable layer (W42.int-s5), gated by `TEXTLAYER_TEST=1` (does nothing
/// in normal use). Run by `scripts/test-text-layer.sh`. Pages are drawn here, in a scratch folder; never the corpus.
///
/// What has to be true:
///   1. The rule (`TextLayerRule`): print kinds are placed, handwritten and mixed pages go to the hand placer once it
///      is downloaded (the text page alone before, with the switch off, or when the reading reflows), an unknown kind is
///      placed only when the reading aligns, and a reading in
///      a right-to-left script or in CJK or Thai gets no layer.
///   2. Each output still has its two pages, the text page first line `Extracted text.`, and the image page's text,
///      read back through PDFKit, holds the reading: a selection over each drawn line returns that line's words, in
///      order (the strict line pass, `05-placement.md` §3), on the JPEG fast path, the re-encoded path and a turned page.
///   3. A page the rule gives no layer, and a page written without one, have no text on the image page.
///   7. The searchable form (W42.int-s5-searchable): one page, its header in the XMP and read back through Core, an
///      unplaced layer where the words cannot be placed, a pair where the form cannot hold the page, merges that mix
///      the two forms, the date-evidence line rewritten in the XMP, and Improve OCR refusing it.
@MainActor
enum TextLayerTestDriver {
    nonisolated static let envKey = "TEXTLAYER_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { @MainActor in await run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    static let memo = ["MEMORANDUM", "To: The Secretary of the Treasury", "From: Budget Office, Room 214",
                       "Subject: Fiscal year 1958 estimates", "The attached tables show the revised figures",
                       "for the second quarter, as agreed on March 3."]

    static func run() async {
        defer { finish() }
        ruleChecks()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("text-layer-test-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        guard let jpeg = drawPage(memo, to: dir.appendingPathComponent("memo.jpg"), type: "public.jpeg"),
              let png = drawPage(memo, to: dir.appendingPathComponent("memo.png"), type: "public.png") else {
            check("0 smoke pages drawn", false); return
        }
        let reading = memo.joined(separator: "\n")
        await childProcessChecks(dir, jpeg: jpeg)

        // 2. Placed print, three ways onto the page.
        for (name, url, turn) in [("jpeg", jpeg, 0), ("png", png, 0), ("turned", png, 90)] {
            let out = dir.appendingPathComponent("\(name).pdf")
            guard let o = await write(url, reading: reading, kind: .typewritten, rotation: turn, to: out) else {
                check("2 \(name) written", false); continue
            }
            check("2 \(name) placed", o.layer.route != .textPage, "\(o.layer)")
            check("2 \(name) the reading aligned", o.layer.route == .visionLinesAligned, "\(o.layer.route)")
            check("2 \(name) every line placed", o.layer.unplaced == 0 && o.layer.lines >= memo.count, "\(o.layer)")
            check("2 \(name) a level page is not turned", o.straightenedDegrees == nil, "\(String(describing: o.straightenedDegrees))")
            guard let doc = PDFDocument(url: out), doc.pageCount == 2, let image = doc.page(at: 0), let text = doc.page(at: 1)
            else { check("2 \(name) two pages", false); continue }
            check("2 \(name) the text page is page 2",
                  text.string?.hasPrefix("Extracted text.") == true, String(text.string?.prefix(40) ?? ""))
            let layer = image.string ?? ""
            let missing = memo.flatMap { $0.split(separator: " ") }.filter { !layer.contains($0) }
            check("2 \(name) the image page holds every word", missing.isEmpty, "missing \(missing)")
            if name == "jpeg" {
                let source = (try? Data(contentsOf: url)) ?? Data()
                let embedded = jpegStreams(image)
                check("2 jpeg the scan is embedded as it was (the source JPEG's bytes)",
                      embedded.contains(source), "streams \(embedded.map(\.count)) against \(source.count)")
                check("2 jpeg Improve OCR reads the scan's own bytes, not a rendering",
                      (try? Data(contentsOf: out)).flatMap { ReOCRJob.embeddedJPEG($0, pageIndex: 0) } == source)
            }
            if turn == 0 {
                let passed = linePass(image, lines: memo, imageURL: url)
                check("2 \(name) a selection over each line returns it", passed == memo.count, "\(passed)/\(memo.count)")
            }
            lines.append("SIZE \(name) layered \(size(out)) bytes")
            if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
                try? FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: keep).appendingPathComponent(out.lastPathComponent))
            }
        }

        // 4. Straightening (`straightenReadingCopy`, 01-reading-copy.md §3).
        let level = await Task.detached { ReadingCopy.lineAngle(of: decode(jpeg)!) }.value
        check("4 a level page measures level", level.map { abs($0) < 0.5 } == true, "\(String(describing: level))")
        if let skewed = drawPage(memo, to: dir.appendingPathComponent("skewed.jpg"), type: "public.jpeg", skew: 3),
           let slight = drawPage(memo, to: dir.appendingPathComponent("slight.jpg"), type: "public.jpeg", skew: 0.5) {
            let measured = await Task.detached { ReadingCopy.lineAngle(of: decode(skewed)!) }.value
            check("4 a page drawn 3 degrees off level measures about 3", measured.map { abs($0 - 3) < 0.5 } == true,
                  "\(String(describing: measured))")
            let out = dir.appendingPathComponent("skewed.pdf")
            let o = await write(skewed, reading: reading, kind: .typewritten, rotation: 0, to: out)
            check("4 it is turned level", o?.straightenedDegrees.map { abs($0 - 3) < 0.5 } == true,
                  "\(String(describing: o?.straightenedDegrees))")
            if let doc = PDFDocument(url: out), let page = doc.page(at: 0), let jpg = jpegStreams(page).first,
               let cg = CGImageSourceCreateWithData(jpg as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
                check("4 on a canvas that holds all of it (nothing cropped)", cg.width > pageW && cg.height > pageH,
                      "\(cg.width)x\(cg.height)")
                let after = await Task.detached { ReadingCopy.lineAngle(of: cg) }.value
                check("4 the page shown is level", after.map { abs($0) < 0.5 } == true, "\(String(describing: after))")
                let layer = page.string ?? ""
                let missing = memo.flatMap { $0.split(separator: " ") }.filter { !layer.contains($0) }
                check("4 its layer holds every word", missing.isEmpty, "missing \(missing)")
                check("4 its layer was placed", o?.layer.route == .visionLinesAligned, "\(String(describing: o?.layer))")
            } else { check("4 the straightened page is readable", false) }
            let off = dir.appendingPathComponent("skewed-off.pdf")
            let o2 = await write(skewed, reading: reading, kind: .typewritten, rotation: 0, to: off,
                                 options: PDFGenerator.TextLayerOptions(straighten: false))
            let source = (try? Data(contentsOf: skewed)) ?? Data()
            check("4 switched off, the page is left as photographed", o2?.straightenedDegrees == nil
                  && PDFDocument(url: off)?.page(at: 0).map(jpegStreams)?.contains(source) == true)
            let o3 = await write(slight, reading: reading, kind: .typewritten, rotation: 0,
                                 to: dir.appendingPathComponent("slight.pdf"))
            check("4 a page under 1 degree is left as it is", o3 != nil && o3?.straightenedDegrees == nil,
                  "\(String(describing: o3?.straightenedDegrees))")
            let o4 = await write(skewed, reading: reading, kind: .handwritten, rotation: 0,
                                 to: dir.appendingPathComponent("skewed-hand.pdf"))
            check("4 a page with no layer is straightened too", o4?.straightenedDegrees != nil && o4?.layer.route == .textPage)
        } else { check("4 skewed pages drawn", false) }
        check("4 no settings: both switches on", PDFGenerator.TextLayerOptions.from([:]) == .standard)
        let offValues = [SettingsKey.straightenReadingCopy.rawValue: ResolvedSetting(value: .bool(false), layer: .collection)]
        check("4 a collection's straighten off is read", PDFGenerator.TextLayerOptions.from(offValues).straighten == false
              && PDFGenerator.TextLayerOptions.from(offValues).placeHandOnImage)
        check("4 straightening is no longer pending on the sheet", !SettingsSheetModel.switchPending.contains(.straightenReadingCopy))

        // 3. No layer: the rule says so, or none was asked for.
        let cases: [(String, OCRPageKind?, String, PDFGenerator.TextLayerOptions?)] = [
            ("handwritten", .handwritten, reading, .standard),
            ("handwritten, switch off", .handwritten, reading, PDFGenerator.TextLayerOptions(placeHandOnImage: false)),
            ("unknown kind, unrelated reading", nil, "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do", .standard),
            ("Hebrew reading", .printed, "שלום עולם זה מכתב ארוך מאוד על התקציב", .standard),
            ("no layer asked for", .typewritten, reading, nil),
        ]
        for (name, kind, text, options) in cases {
            let out = dir.appendingPathComponent("none-\(UUID().uuidString).pdf")
            guard let o = await write(jpeg, reading: text, kind: kind, rotation: 0, to: out, options: options),
                  let doc = PDFDocument(url: out), doc.pageCount == 2 else { check("3 \(name) written", false); continue }
            check("3 \(name): the text page alone", o.layer.route == .textPage, "\(o.layer)")
            let s = (doc.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            check("3 \(name): no text on the image page", s.isEmpty, String(s.prefix(60)))
            if options == nil {
                lines.append("SIZE jpeg plain \(size(out)) bytes")
                if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
                    try? FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: keep).appendingPathComponent("plain.pdf"))
                }
                let source = (try? Data(contentsOf: jpeg)) ?? Data()
                check("6 the plain output embeds the source JPEG's bytes", doc.page(at: 0).map(jpegStreams)?.contains(source) == true)
                archivalChecks("plain output", out)
            }
        }
        // 6. PDF/A-2b (step 4): every output, merged documents too. veraPDF itself runs in test-text-layer.sh.
        let layered = dir.appendingPathComponent("jpeg.pdf")
        archivalChecks("layered output", layered)
        let merged = dir.appendingPathComponent("merged.pdf")
        do {
            try PDFGenerator().mergeDocumentPDFs(sourcePDFs: [layered, layered], outputURL: merged)
            check("6 the merged document has every page", PDFDocument(url: merged)?.pageCount == 4)
            archivalChecks("merged document", merged)
            if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
                try? FileManager.default.copyItem(at: merged, to: URL(fileURLWithPath: keep).appendingPathComponent("merged.pdf"))
            }
        } catch { check("6 the merged document is written", false, "\(error)") }
        // 5. Improve OCR: the image page's layer follows the new reading (step 3b).
        await improveChecks(dir: dir, jpeg: jpeg, reading: reading)

        // An unknown kind whose reading aligns is placed.
        let unknown = dir.appendingPathComponent("unknown.pdf")
        let u = await write(jpeg, reading: reading, kind: nil, rotation: 0, to: unknown)
        check("3 unknown kind, aligned reading: placed", u?.layer.route == .visionLinesAligned, "\(String(describing: u?.layer))")

        await searchableChecks(dir: dir, jpeg: jpeg, reading: reading)
    }

    private static func searchableChecks(dir: URL, jpeg: URL, reading: String) async {
        check("7 a matching pair picks the searchable form",
              OutputForm.form(format: "jpeg", kind: .typewritten, searchableFor: ["*/typewritten"]) == .searchable)
        check("7 a format alone picks it for any kind, an unknown one too",
              OutputForm.form(format: "pdf", kind: nil, searchableFor: ["pdf/*"]) == .searchable)
        check("7 an unknown kind is not matched by a named kind",
              OutputForm.form(format: "jpeg", kind: nil, searchableFor: ["*/printed"]) == .imageAndText)
        check("7 no setting: image-plus-text", OutputForm.form(format: "jpeg", kind: .printed, searchableFor: []) == .imageAndText)
        check("7 a word the writer joins across a line-end hyphen is held",
              OutputForm.holds("the document is here", every: "the docu-\nment is here"))
        check("7 a missing word is named", OutputForm.missingWords("a b", "a b c c") == ["c", "c"])
        check("7 extensions name formats", OutputForm.format(ofExtension: "JPG") == "jpeg" && OutputForm.format(ofExtension: "tif") == "tiff")
        let values = [SettingsKey.searchableFor.rawValue:
                        ResolvedSetting(value: .strings(["jpeg/typewritten"]), layer: .collection)]
        check("7 the setting is read from a run's settings",
              PDFGenerator.TextLayerOptions.from(values).searchableFor == ["jpeg/typewritten"])
        let options = PDFGenerator.TextLayerOptions(searchableFor: ["jpeg/typewritten", "jpeg/handwritten", "jpeg/printed"])
        let model = LLMModel.appleVisionModels[0]
        func write(_ text: String, kind: OCRPageKind?, name: String, to out: URL,
                   classification: DocumentClassification? = nil) async -> PDFGenerator.Output? {
            let result = OCRResult(text: text, classification: classification, rotationDegrees: 0, errorMessage: nil, errorCode: nil)
            return await Task.detached {
                try? PDFGenerator().generateOutput(imageURL: jpeg, result: result, model: model, outputURL: out,
                                                   originalFileName: name, pageKind: kind, textLayer: options)
            }.value
        }
        let words = memo.flatMap { $0.split(separator: " ") }

        // Placed print, with a name XML has to escape and a classification.
        let typed = dir.appendingPathComponent("searchable.pdf")
        let name = "memo & <copy>.jpg"
        let o = await write(reading, kind: .typewritten, name: name, to: typed, classification: .documentStart)
        check("7 print: the searchable form", o?.form == .searchable && o?.formFallback == nil, "\(String(describing: o))")
        check("7 print: placed on Vision's lines", o?.layer.route == .visionLinesAligned, "\(String(describing: o?.layer))")
        // W42.int-s5-compress: compressed as Vision OCR compresses where its tools are found, else said why.
        let tools = CompressedPage.missingTools.isEmpty
        func compressed(_ url: URL) -> Bool {
            (try? Data(contentsOf: url))?.range(of: Data("/JBIG2Decode".utf8)) != nil
        }
        check("7 print: compressed (JBIG2) where jbig2 and qpdf are found, else said why",
              tools ? o?.compression == nil && compressed(typed) : o?.compression?.hasSuffix("not found") == true,
              "\(String(describing: o?.compression))")
        if let doc = PDFDocument(url: typed), let content = PDFHeaderParser.extract(typed) {
            check("7 print: one page, no text page", doc.pageCount == 1, "\(doc.pageCount)")
            let layer = doc.page(at: 0)?.string ?? ""
            check("7 print: the page holds every word", words.allSatisfy { layer.contains($0) })
            check("7 print: Core reads one searchable page", content.pageRoles == [.searchable], "\(content.pageRoles)")
            let header = content.textPages.first?.header
            check("7 print: the header is read from the XMP", content.textPages.map(\.pageIndex) == [0]
                  && header?.kind == .typewritten && header?.provenance?.provider == "Apple Vision"
                  && header?.originalFilename == name && header?.diagnostics.isEmpty == true, "\(String(describing: header))")
            check("7 print: its classification", content.classification == "Document Start", "\(String(describing: content.classification))")
            check("7 print: the body is the page's text", content.strippedBody.contains("MEMORANDUM")
                  && !content.strippedBody.contains("Extracted text."), String(content.strippedBody.prefix(60)))
            check("7 print: the full text holds the header too", content.fullBody.contains("Extracted text.")
                  && content.fullBody.contains("Kind: typewritten"))
            let processor = PDFTextExtractor.extract(from: typed)
            check("7 print: the Processor's extractor maps it", processor.classification == .documentStart && processor.text != nil)
            archivalChecks("searchable output", typed)
        } else { check("7 print: written and read back", false) }

        // W42.stroke-weight-processor: a camera's page is compressed as the engine compresses a camera's photo, which
        // keeps the photo's stroke weight (no pale-ink re-cut). The same pale page as a phone's file, as an untagged
        // file the caller names a camera (a live capture), and as an untagged one, a scan.
        // A full page of type, as the engine's own check draws it (VisionOCRKit's suite, the same section).
        let prose = (0..<20).map { "The quick brown fox jumps over the dog \($0)" }
        if tools, let camera = drawPage(prose, to: dir.appendingPathComponent("camera.jpg"), type: "public.jpeg",
                                        pale: true, camera: true),
           let plain = drawPage(prose, to: dir.appendingPathComponent("plain.jpg"), type: "public.jpeg", pale: true) {
            check("7 camera: a phone's tags read as a camera's photo, an untagged file's do not",
                  CompressedPage.isCameraPhoto(camera) && !CompressedPage.isCameraPhoto(plain))
            let result = OCRResult(text: prose.joined(separator: "\n"), classification: nil, rotationDegrees: 0,
                                   errorMessage: nil, errorCode: nil)
            func drawn(_ image: URL, photographed: Bool?, _ name: String) async -> [UInt8]? {
                let out = dir.appendingPathComponent(name)
                let o = await Task.detached {
                    try? PDFGenerator().generateOutput(imageURL: image, result: result, model: model, outputURL: out,
                                                       pageKind: .typewritten, textLayer: options,
                                                       photographed: photographed)
                }.value
                if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
                    try? FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: keep).appendingPathComponent(name))
                }
                guard o?.form == .searchable, o?.compression == nil, let page = PDFDocument(url: out)?.page(at: 0)?.pageRef
                else { return nil }
                let box = page.getBoxRect(.mediaBox)
                let w = Int(box.width * 2), h = Int(box.height * 2)
                guard let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
                g.setFillColor(gray: 1, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
                g.scaleBy(x: 2, y: 2); g.drawPDFPage(page)
                return Array(UnsafeBufferPointer(start: g.data!.bindMemory(to: UInt8.self, capacity: w * h), count: w * h))
            }
            let tagged = await drawn(camera, photographed: nil, "camera.pdf")
            let named = await drawn(plain, photographed: true, "named.pdf")
            let scan = await drawn(plain, photographed: nil, "scan.pdf")
            func differing(_ a: [UInt8]?, _ b: [UInt8]?) -> Int {
                guard let a, let b, a.count == b.count else { return -1 }
                return zip(a, b).filter { abs(Int($0) - Int($1)) > 2 }.count
            }
            let same = differing(tagged, named), apart = differing(tagged, scan), total = tagged?.count ?? 0
            check("7 camera: a page named a camera draws as a camera-tagged file does",
                  same >= 0 && same * 1000 < total, "\(same) of \(total) pixels differ")
            check("7 camera: …and an untagged page takes the scan's stencil, not the camera's",
                  apart * 100 > total / 10, "\(apart) of \(total) pixels differ")
        }

        // Handwriting (owner, 2026-11-17): chosen for the searchable form, still a pair, since every handwritten page
        // keeps its text page; the placed layer only beside it, at the 0.9 gate.
        let hand = dir.appendingPathComponent("searchable-hand.pdf")
        let h = await write(reading, kind: .handwritten, name: "hand.jpg", to: hand)
        check("7 hand: written as a pair, and says why", h?.form == .imageAndText
              && h?.formFallback == OutputForm.handKeepsTextPage && h?.compression == nil, "\(String(describing: h))")
        check("7 hand: the layer only from the hand placer (none until it is downloaded)",
              HandPlacer.isInstalled() ? [.handBllaCtc, .textPage].contains(h?.layer.route)
                  : h?.layer == .textPage(TextLayerRule.notDownloadedReason), "\(String(describing: h?.layer))")
        if let doc = PDFDocument(url: hand), let content = PDFHeaderParser.extract(hand) {
            let handText = doc.page(at: 1)?.string ?? ""
            check("7 hand: two pages, the text page holding every word", doc.pageCount == 2
                  && words.allSatisfy { handText.contains($0) } && handText.contains("Extracted text."), "\(doc.pageCount)")
            check("7 hand: Core reads an image and its text page", content.pageRoles == [.image, .text], "\(content.pageRoles)")
        } else { check("7 hand: written and read back", false) }
        let plain = OCRResult(text: reading, classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil)
        var handClipping = plain
        handClipping.pageReader = PageReaderRecord(kind: PageKindName.clippings.rawValue, confidence: 0.9, reason: .kind,
                                                   provider: "Gemini", model: "m", readingKind: .handwritten)
        check("7 every hand kind, and a page read as handwriting, keeps its text page; other kinds may go without",
              [PageKindName.handwritten, .mixed, .registers].allSatisfy { TextLayerRule.isHand(TextLayerRule.placementKind($0, result: plain)) }
              && TextLayerRule.placementKind(.clippings, result: handClipping) == .handwritten
              && ([nil] + [PageKindName.typewritten, .printed, .forms, .newspapers, .clippings]).allSatisfy {
                  !TextLayerRule.isHand(TextLayerRule.placementKind($0, result: plain)) }
              && OutputForm.searchableRefusal(reading: reading, handwritten: true) == OutputForm.handKeepsTextPage
              && OutputForm.searchableRefusal(reading: reading, handwritten: false) == nil)
        check("7 the sheet offers no hand kind for the searchable form",
              Set(SettingsSheetModel.FormsRow.kinds) == Set(PageKindName.allCases).subtracting([.handwritten, .mixed, .registers]))

        // Every page also matches an unknown page. Simulate an image too faint for the pixel classifier to
        // identify the writing but whose OCR reader recovered a transcription.
        let unknownInput = dir.appendingPathComponent("unknown-input.jpg")
        let unknownOutput = dir.appendingPathComponent("searchable-unknown-faint.pdf")
        if let image = drawPage([], to: unknownInput, type: "public.jpeg") {
            let kept = await Self.write(image, reading: reading, kind: nil, rotation: 0, to: unknownOutput,
                                        options: .init(searchableFor: ["*/*"]))
            let doc = PDFDocument(url: unknownOutput)
            check("7 Every page: an inconclusive handwriting check keeps the full text page",
                  kept?.form == .imageAndText && kept?.formFallback == OutputForm.unknownKeepsTextPage
                  && doc?.pageCount == 2 && (doc?.page(at: 1)?.string?.contains("MEMORANDUM") ?? false),
                  "\(String(describing: kept))")
        } else { check("7 Every page: inconclusive handwriting fixture prepared", false) }

        let wildcardPrint = dir.appendingPathComponent("searchable-printed-wildcard.pdf")
        let checkedPrint = await Self.write(jpeg, reading: reading, kind: .typewritten, rotation: 0, to: wildcardPrint,
                                            options: .init(searchableFor: ["*/*"]))
        check("7 Every page: a page already identified as typewritten still writes as one searchable page",
              checkedPrint?.form == .searchable && PDFDocument(url: wildcardPrint)?.pageCount == 1,
              "\(String(describing: checkedPrint))")

        // Words Vision never found (a note it missed): the placed layer would lose them, so the reading goes unplaced.
        let extra = dir.appendingPathComponent("searchable-extra.pdf")
        let fuller = reading + "\nApproved in the margin by Hollister"
        let e = await write(fuller, kind: .typewritten, name: "extra.jpg", to: extra)
        let extraText = PDFDocument(url: extra)?.page(at: 0)?.string ?? ""
        check("7 a reading Vision lacks words of: unplaced, every word kept", e?.form == .searchable
              && e?.layer.route == .unplaced && OutputForm.holds(extraText, every: fuller), "\(String(describing: e?.layer))")

        check("7 unplaced output has a log note", e?.layerLogNotes.contains {
            $0.contains("not placed on the words")
        } == true)

        // Pages the form cannot hold are written as pairs, and say why.
        for (label, text, kind) in [("Hebrew", "שלום עולם זה מכתב ארוך מאוד על התקציב", OCRPageKind.printed),
                                    ("no reading", "", .typewritten), ("a kind not chosen", reading, .forms)] {
            let out = dir.appendingPathComponent("fallback-\(UUID().uuidString).pdf")
            let f = await write(text, kind: kind, name: "x.jpg", to: out)
            let chosen = kind != .forms
            check("7 \(label): written as a pair", f?.form == .imageAndText && PDFDocument(url: out)?.pageCount == 2
                  && (f?.formFallback != nil) == chosen, "\(String(describing: f))")
            check("7 \(label): the log notes a fallback only when the searchable form was chosen",
                  f?.layerLogNotes.contains { $0.hasPrefix("written with a text page instead:") } == chosen)
        }

        // A merge mixing the forms keeps every page's header where it belongs.
        let pair = dir.appendingPathComponent("jpeg.pdf")
        let mixed = dir.appendingPathComponent("merged-mixed.pdf")
        do {
            try PDFGenerator().mergeDocumentPDFs(sourcePDFs: [typed, pair, hand], outputURL: mixed)
            let content = PDFHeaderParser.extract(mixed)
            // The hand source is a pair (every handwritten page keeps its text page), the typed one searchable.
            check("7 merge: pages in order", content?.pageRoles == [.searchable, .image, .text, .image, .text],
                  "\(String(describing: content?.pageRoles))")
            check("7 merge: a header for each source page", content?.textPages.map(\.pageIndex) == [0, 2, 4]
                  && content?.textPages.map { $0.header?.kind } == [.typewritten, .typewritten, .handwritten],
                  "\(String(describing: content?.textPages))")
            check("7 merge: the Reader's summary reads every header",
                  PDFDocument(url: mixed).map { PDFHeaderParser.textPageHeaders($0).map { $0?.kind } }
                  == [.typewritten, .typewritten, .handwritten])
            archivalChecks("mixed merged document", mixed)
            check("7 merge: the searchable pages stay compressed, not redrawn", !tools || (compressed(mixed)
                  && size(mixed) <= size(typed) + size(pair) + size(hand) + 16_384),
                  "\(size(mixed)) bytes of \(size(typed)) + \(size(pair)) + \(size(hand))")
        } catch { check("7 merge: written", false, "\(error)") }
        // A source that ends on an image with no text page, before a searchable one, would shift the pairing: refused.
        let lone = dir.appendingPathComponent("lone.pdf")
        let loneDoc = PDFDocument()
        loneDoc.insert(PDFPage(), at: 0)
        try? loneDoc.dataRepresentation()?.write(to: lone)
        let refused = (try? PDFGenerator().mergeDocumentPDFs(sourcePDFs: [lone, typed],
                                                             outputURL: dir.appendingPathComponent("refused.pdf"))) == nil
        check("7 merge: a lone image before a searchable page is refused", refused)

        // Process Files adds the source dates and evidence to the XMP while keeping the page.
        let dates = PDFSourceDates(documentDate: "1957", sentWith: "Mar 12, 1958", dateEvidence: "image; page 1")
        if let data = try? Data(contentsOf: typed),
           case .rewrite(let new) = PDFGenerator().taggedHeaderRewrite(of: data, sourceName: name, fields: dates, body: reading,
                                                                     textColumns: 1) {
            let out = dir.appendingPathComponent("searchable-dated.pdf")
            try? new.write(to: out)
            let content = PDFHeaderParser.extract(out)
            let header = content?.textPages.first?.header
            check("7 source dates and evidence: read back from the XMP", header?.dateEvidence == dates.dateEvidence
                  && header?.documentDate == dates.documentDate && header?.sentWith == dates.sentWith
                  && header?.kind == .typewritten && header?.originalFilename == name, "\(String(describing: header))")
            check("7 date evidence: the page is kept", PDFDocument(url: out)?.page(at: 0)?.string == PDFDocument(url: typed)?.page(at: 0)?.string)
            archivalChecks("dated searchable output", out)
            check("7 date evidence: still compressed, not redrawn", !tools || (compressed(out)
                  && abs(size(out) - size(typed)) < 4_096), "\(size(out)) bytes against \(size(typed))")
            if case .unchanged = PDFGenerator().taggedHeaderRewrite(of: new, sourceName: name, fields: dates, body: reading, textColumns: 1) {
                check("7 date evidence: the same line again is no change", true)
            } else { check("7 date evidence: the same line again is no change", false) }
        } else { check("7 date evidence: rewritten", false) }

        // This fixture exercises the actual compressed form when the bundled tools are available.
        if let data = try? Data(contentsOf: typed), case .success(let pages) = ReOCRPairs.validate(data),
           let page = pages.first, pages.count == 1, page.isSearchable {
            do {
                let newReading = reading.replacingOccurrences(of: "MEMORANDUM", with: "MEMORANDA")
                guard let layer = try await ReOCRLayer.make(from: data, pageIndex: 0, reading: newReading,
                                                            required: true, scratch: dir) else {
                    check("7 Improve OCR makes a searchable replacement layer", false); return
                }
                let updated = try ReOCRIncrementalWriter.candidate(original: data, replacements: [:], layers: [0: layer])
                let doc = PDFDocument(data: updated.bytes)
                let text = doc?.page(at: 0)?.string ?? ""
                check("7 Improve OCR replaces the single searchable layer", updated.layerPages == [0]
                      && doc?.pageCount == 1 && text.contains("MEMORANDA") && !text.contains("MEMORANDUM"))
                if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
                    try updated.bytes.write(to: URL(fileURLWithPath: keep).appendingPathComponent("searchable-revised.pdf"))
                }
            } catch { check("7 Improve OCR replaces the single searchable layer", false, "\(error)") }
        } else { check("7 Improve OCR accepts a single suite searchable page", false) }

        if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
            for url in [typed, hand, mixed, dir.appendingPathComponent("searchable-dated.pdf")] {
                try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: keep).appendingPathComponent(url.lastPathComponent))
            }
        }
        lines.append("SIZE searchable \(size(typed)) bytes, unplaced \(size(hand)) bytes")
    }

    private static func childProcessChecks(_ dir: URL, jpeg: URL) async {
        let fm = FileManager.default
        let timed = await PDFGenerator.runWorker {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Ignore TERM so the test exercises escalation. The regular files exercise the same capture as qpdf.
            process.arguments = ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"]
            let start = DispatchTime.now()
            do {
                _ = try PDFChildBudget(seconds: 0.3).capture(process)
                return false
            } catch {
                return error.localizedDescription.contains("limit") && !process.isRunning
                    && process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
                    && DispatchTime.now() < start + 5
            }
        }
        check("8 compression timeout kills and reaps a child ignoring TERM", timed)

        // A tiny stand-in uses exactly the placer's real command, slot, cancellation and scratch paths.
        let hands = dir.appendingPathComponent("Hands")
        let interpreter = hands.appendingPathComponent("bin/python3")
        let model = hands.appendingPathComponent("models/McCATMuS_nfd_nofix_V1.mlmodel")
        let script = dir.appendingPathComponent("place.py"), started = dir.appendingPathComponent("place.py.started")
        let fake = """
            #!/bin/sh
            trap '' TERM
            printf '%s\\n%s\\n' "$$" "$3" > "$2.started"
            while :; do /bin/sleep 1; done
            """
        do {
            for url in [interpreter, model] {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data(fake.utf8).write(to: interpreter)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
            try Data().write(to: model)
            try Data().write(to: script)
        } catch { check("8 test hand placer prepared", false, error.localizedDescription); return }
        let environment = ["VISIONOCR_MODEL_HOME": dir.path, "VISIONOCR_HANDS_SCRIPT": script.path]

        @Sendable func place() async -> Bool {
            await PDFGenerator.runWorker {
                guard let image = decode(jpeg) else { return false }
                do {
                    _ = try HandPlacer.place(image: image, reading: "ONE LINE", environment: environment,
                                             isCancelled: { Task.isCancelled })
                    return false
                } catch { return error is CancellationError }
            }
        }
        func ready(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(30))
            }
            return false
        }

        let active = Task { await place() }
        let didStart = await ready { (try? String(contentsOf: started, encoding: .utf8).split(separator: "\n").count) == 2 }
        let start = DispatchTime.now()
        active.cancel()
        let stopped = await active.value
        let info = (try? String(contentsOf: started, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        if didStart, info.count == 2, let pid = Int32(info[0]), pid > 0 {
            check("8 Stop reaps a running hand placer and removes its scratch",
                  stopped && kill(pid, 0) == -1 && errno == ESRCH
                    && !fm.fileExists(atPath: URL(fileURLWithPath: info[1]).deletingLastPathComponent().path)
                    && DispatchTime.now() < start + 5)
        } else { check("8 test hand placer started", false) }

        let reflowing = """
            #!/bin/sh
            cat > "$5" <<'JSON'
            {"lines":[{"text":"ONE LINE","box":[0.1,0.1,0.8,0.1]}],"confidence":0.99,"span":8,"detected":10,"reading_lines":1,"peak_rss":0}
            JSON
            """
        do {
            try Data(reflowing.utf8).write(to: interpreter)
            let refusal = await PDFGenerator.runWorker {
                guard let image = decode(jpeg),
                      let placed = try? HandPlacer.place(image: image, reading: "ONE LINE", environment: environment)
                else { return nil as String? }
                return TextLayerRule.handPlacementRefusal(placed, reading: "ONE LINE")
            }
            check("8 a high-confidence hand placement is still refused when its reader joined the lines",
                  refusal == TextLayerRule.reflowReason)
        } catch { check("8 the reflowing hand placement fixture could not be written", false, error.localizedDescription) }

        // test-text-layer.sh gives this driver its own temporary root, and hence its own reader lock.
        let scratch = fm.temporaryDirectory
        let fd = open(scratch.appendingPathComponent("visionocr-model-reader.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { check("8 test slot opened", false); return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { check("8 test slot held", false); return }
        try? fm.removeItem(at: started)
        let queue = scratch.appendingPathComponent("visionocr-model-reader.queue")
        let waiting = Task { await place() }
        let queued = await ready { ((try? fm.contentsOfDirectory(atPath: queue.path)) ?? []).count == 1 }
        let stoppedWaitingAt = DispatchTime.now()
        waiting.cancel()
        let stoppedWaiting = await waiting.value
        check("8 Stop withdraws a queued hand placer without starting it",
              queued && stoppedWaiting && !fm.fileExists(atPath: started.path)
                && ((try? fm.contentsOfDirectory(atPath: queue.path)) ?? []).isEmpty
                && ((try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []).allSatisfy { !$0.hasPrefix("visionocr-hands-") }
                && DispatchTime.now() < stoppedWaitingAt + 3)
    }

    private static func improveChecks(dir: URL, jpeg: URL, reading: String) async {
        guard let original = try? Data(contentsOf: dir.appendingPathComponent("jpeg.pdf")),
              case .success(let pairs) = ReOCRPairs.validate(original), let pair = pairs.first else {
            check("5 the layered output is an Improve OCR pair", false); return
        }
        let model = LLMModel.appleVisionModels[0]
        let newText = reading.replacingOccurrences(of: "MEMORANDUM", with: "MEMORANDA")
        let newReading = OCRResult(text: newText, classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil)
        do {
            guard let layer = try await ReOCRLayer.make(from: original, pageIndex: pair.imageIndex, reading: newText,
                                                        required: true, scratch: dir) else {
                check("5 a replacement layer is made", false); return
            }
            let text = try ReOCRPairs.replacementPage(for: pair, result: newReading, model: model, kind: .typewritten)
            let updated = try ReOCRIncrementalWriter.candidate(original: original, replacements: [pair.textIndex: text],
                                                                layers: [pair.imageIndex: layer])
            let doc = PDFDocument(data: updated.bytes)
            let reading = doc?.page(at: 0)?.string ?? ""
            check("5 the new layer replaces the old reading", reading.contains("MEMORANDA") && !reading.contains("MEMORANDUM"),
                  String(reading.prefix(40)))
            check("5 the incremental revision takes both readings and keeps the original as its prefix",
                  updated.bytes.starts(with: original) && updated.layerPages == [0] && doc?.pageCount == 2
                  && doc?.page(at: 1)?.string?.contains("MEMORANDA") == true)
            // Kept for test-text-layer.sh's veraPDF run.
            if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
                try? updated.bytes.write(to: URL(fileURLWithPath: keep).appendingPathComponent("revised.pdf"))
            }
        } catch { check("5 the incremental revision takes both readings", false, "\(error)") }
        let plainURL = dir.appendingPathComponent("plain-improve.pdf")
        if await write(jpeg, reading: reading, kind: .typewritten, rotation: 0, to: plainURL, options: nil) != nil,
           let plain = try? Data(contentsOf: plainURL), case .success(let plainPairs) = ReOCRPairs.validate(plain),
           let p = plainPairs.first {
            do {
                let layer = try await ReOCRLayer.make(from: plain, pageIndex: p.imageIndex, reading: "Unrelated reading",
                                                      required: false, scratch: dir)
                check("5 a scan with no layer and no aligned reading is kept", layer == nil)
            } catch { check("5 a scan with no layer is kept", false, "\(error)") }
        } else { check("5 a plain output for Improve OCR", false) }
    }

    private static func ruleChecks() {
        func d(_ k: PageKindName?, _ r: String? = "a letter", hand: Bool = true,
               installed: Bool = false) -> TextLayerRule.Decision {
            TextLayerRule.decide(kind: k, reading: r, placeHandOnImage: hand, handPlacerInstalled: installed)
        }
        check("1 registers, placer not downloaded: text page", d(.registers) == .textPage(TextLayerRule.notDownloadedReason))
        for k in [PageKindName.handwritten, .mixed, .registers] {
            check("1 \(k.rawValue), placer downloaded: the hand placer", d(k, installed: true) == .placeHands)
        }
        check("1 reflow compares this reading's lines with the detected lines",
              TextLayerRule.reflows(readingLines: 6, detectedLines: 10)
              && TextLayerRule.reflows(readingLines: 1, detectedLines: 12)
              && !TextLayerRule.reflows(readingLines: 7, detectedLines: 10)
              && !TextLayerRule.reflows(readingLines: 1, detectedLines: 1)
              && !TextLayerRule.reflows(readingLines: 1, detectedLines: 0))
        check("1 ordered coverage accepts reading markup and detects swapped or skipped lines",
              TextLayerRule.preservesReadingOrder("**First** line\n<mark>Second line [illegible]", placed: "First line Second line")
              && !TextLayerRule.preservesReadingOrder("First line\nSecond line", placed: "Second line First line")
              && !TextLayerRule.preservesReadingOrder("First line\nSecond line", placed: "Second line"))
        func handCall(_ scores: [Double], lines: Int = 3) -> Bool? {
            let classes = ["handwritten", "typewritten", "printed"]
            let features = ["harmonic", "periodic", "conf", "text_px", "lines", "print0"]
            let hand = PageKindModel.Regression(classes: classes, features: features,
                                                mean: Array(repeating: 0, count: 6), sd: Array(repeating: 1, count: 6),
                                                W: Array(repeating: [0, 0, 0], count: 6), b: scores)
            let model = PageKindModel(measured: "fixture", hand: hand, form: hand)
            return PageKindClassifier.handwritingForPlacement(PageKindSignals(lines: lines, print: [0]), model: model)
        }
        check("1 unknown kind: the hand check only uses a confident writing classification with measured text",
              handCall([10, 0, 0]) == true && handCall([0, 10, 0]) == false && handCall([0, 0, 10]) == false
              && handCall([1, 0, 0]) == nil && handCall([10, 0, 0], lines: 1) == nil)
        check("1 handwritten with no reading: text page", d(.handwritten, nil, installed: true) == .textPage(TextLayerRule.noReadingReason))
        check("1 handwritten, switch off, placer downloaded: text page",
              d(.handwritten, hand: false, installed: true) == .textPage(TextLayerRule.switchOffReason))
        check("1 the gate is 0.9 (owner, 2026-11-17) and names the confidence", HandPlacer.gate == 0.9
              && TextLayerRule.gateReason(0.872).contains("0.87") && TextLayerRule.gateReason(0.872).contains("0.90"))
        check("1 the hand kinds", Set(PageKindName.allCases.filter(TextLayerRule.isHand)) == [.handwritten, .mixed, .registers]
              && !TextLayerRule.isHand(nil))
        check("1 hand placement is no longer pending on the sheet", !SettingsSheetModel.switchPending.contains(.placeHandOnImage))
        for k in [PageKindName.typewritten, .printed, .forms, .newspapers, .clippings] {
            check("1 \(k.rawValue) placed", d(k) == .place(requireAligned: false))
        }
        check("1 handwritten, placer not downloaded: text page", d(.handwritten) == .textPage(TextLayerRule.notDownloadedReason))
        check("1 mixed, placer not downloaded: text page", d(.mixed) == .textPage(TextLayerRule.notDownloadedReason))
        check("1 handwritten, switch off: text page", d(.handwritten, hand: false) == .textPage(TextLayerRule.switchOffReason))
        check("1 unknown kind: placed only when aligned", d(nil) == .place(requireAligned: true))
        check("1 Arabic: text page", { if case .textPage = d(.printed, "مرحبا بالعالم هذه رسالة") { return true }; return false }())
        check("1 Chinese: text page", { if case .textPage = d(.printed, "这是一封很长的信关于预算") { return true }; return false }())
        check("1 a stray Hebrew word in English: placed",
              d(.printed, "The word שלום is Hebrew for peace and is printed in this letter here") == .place(requireAligned: false))
        check("1 no reading: placed (Vision's own words)", d(.printed, nil) == .place(requireAligned: false))
        let r = OCRResult(text: "x", classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil)
        check("1 the person's kind first", TextLayerRule.kind(explicit: .forms, result: r) == .forms)
        check("1 no kind: unknown", TextLayerRule.kind(explicit: nil, result: r) == nil)
    }

    private static func write(_ image: URL, reading: String, kind: OCRPageKind?, rotation: Int, to out: URL,
                              options: PDFGenerator.TextLayerOptions? = .standard) async -> PDFGenerator.Output? {
        let result = OCRResult(text: reading, classification: nil, rotationDegrees: rotation, errorMessage: nil, errorCode: nil)
        let model = LLMModel.appleVisionModels[0]
        return await Task.detached {
            try? PDFGenerator().generateOutput(imageURL: image, result: result, model: model, outputURL: out,
                                               originalFileName: image.lastPathComponent, pageKind: kind, textLayer: options)
        }.value
    }

    /// Lines whose selection, a band across the page at the line's drawn height, reads back as exactly the line.
    private static func linePass(_ page: PDFPage, lines: [String], imageURL: URL) -> Int {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(bounds.width / CGFloat(pageW), bounds.height / CGFloat(pageH))
        let (dx, dy) = ((bounds.width - CGFloat(pageW) * scale) / 2, (bounds.height - CGFloat(pageH) * scale) / 2)
        var passed = 0
        for (i, line) in lines.enumerated() {
            let baseline = CGFloat(baselineY(i))
            let band = CGRect(x: dx, y: dy + (baseline - 8) * scale, width: CGFloat(pageW) * scale, height: 36 * scale)
            let got = (page.selection(for: band)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if got == line { passed += 1 } else { self.lines.append("NOTE line \(i) read \"\(got)\"") }
        }
        return passed
    }

    /// The raw bytes of every DCT-encoded image on `page`, its form XObjects' included.
    /// What `PDFGenerator.writeArchival` and `ArchivalFinish` promise of a written file, read from its bytes.
    private static func archivalChecks(_ name: String, _ url: URL) {
        guard let data = try? Data(contentsOf: url), let doc = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
              doc.numberOfPages > 0, let catalog = doc.catalog else { check("6 \(name) opens", false); return }
        var stream: CGPDFStreamRef?, intents: CGPDFArrayRef?
        var xmp = ""
        var unfiltered = false
        if CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream {
            var format = CGPDFDataFormat.raw
            xmp = (CGPDFStreamCopyData(stream, &format) as Data?).map { String(decoding: $0, as: UTF8.self) } ?? ""
            var filter: CGPDFObjectRef?
            unfiltered = CGPDFStreamGetDictionary(stream).map { !CGPDFDictionaryGetObject($0, "Filter", &filter) } ?? false
        }
        check("6 \(name) declares PDF/A-2b", xmp.contains("<pdfaid:part>2</pdfaid:part>")
              && xmp.contains("<pdfaid:conformance>B</pdfaid:conformance>")
              && CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents), String(xmp.prefix(80)))
        check("6 \(name) keeps its XMP unfiltered (PDFium's revision rewrites it)", unfiltered)
        let text = String(decoding: data, as: UTF8.self)
        check("6 \(name) interpolates no image", !text.contains("/Interpolate"))
        check("6 \(name) lists no unwritten object", !text.contains("0000000000 00000 n"))
        // A readable layer and valid PDF/A do not prove the JBIG2/MRC image drew. Render the finished pages,
        // including the mixed merge and date rewrite, through CoreGraphics with no window or model involved.
        for index in 1...doc.numberOfPages {
            guard let page = doc.page(at: index) else {
                check("6 \(name) page \(index) renders", false); continue
            }
            var pixels = [UInt8](repeating: 255, count: 300 * 400 * 4)
            let ink: Int? = pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 300, height: 400, bitsPerComponent: 8,
                                          bytesPerRow: 300 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                let rect = CGRect(x: 0, y: 0, width: 300, height: 400)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(rect)
                context.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(page)
                let bytes = buffer.bindMemory(to: UInt8.self)
                return stride(from: 0, to: bytes.count, by: 4).filter {
                    min(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) < 220
                }.count
            }
            check("6 \(name) page \(index) renders nonblank", ink.map { $0 > 100 } ?? false,
                  "\(ink.map(String.init) ?? "no render") dark pixels")
        }
    }

    private static func jpegStreams(_ page: PDFPage) -> [Data] {
        guard let dict = page.pageRef?.dictionary else { return [] }
        var out: [Data] = []
        func walk(_ resources: CGPDFDictionaryRef, depth: Int) {
            var xobjects: CGPDFDictionaryRef?
            guard depth < 4, CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            CGPDFDictionaryApplyBlock(xobjects, { _, value, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(value, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream)
                else { return true }
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded { out.append(data as Data) }
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(sd, "Resources", &inner), let inner { walk(inner, depth: depth + 1) }
                return true
            }, nil)
        }
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources { walk(resources, depth: 0) }
        return out
    }

    static let pageW = 1200, pageH = 1550
    static func baselineY(_ i: Int) -> Int { pageH - 140 - i * 70 }

    /// `pale`: dark grey type on grey paper, as a phone's photo of a page arrives; `camera`: a phone's tags on the file
    /// (W42.stroke-weight-processor).
    static func drawPage(_ text: [String], to url: URL, type: String, skew: Double = 0,
                         pale: Bool = false, camera: Bool = false) -> URL? {
        guard let ctx = CGContext(data: nil, width: pageW, height: pageH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let paper: CGFloat = pale ? 158 / 255 : 1, ink: CGFloat = pale ? 64 / 255 : 0
        ctx.setFillColor(CGColor(red: paper, green: paper, blue: paper, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        ctx.setFillColor(CGColor(red: ink, green: ink, blue: ink, alpha: 1))
        let font = pale ? CTFontCreateWithName("Times-Roman" as CFString, 36, nil)
                        : CTFontCreateWithName("Courier" as CFString, 34, nil)
        // A positive skew makes the lines fall to the right, as ReadingCopy measures it (y down): clockwise on paper.
        ctx.translateBy(x: CGFloat(pageW) / 2, y: CGFloat(pageH) / 2)
        ctx.rotate(by: CGFloat(-skew * .pi / 180))
        ctx.translateBy(x: -CGFloat(pageW) / 2, y: -CGFloat(pageH) / 2)
        for (i, line) in text.enumerated() {
            // The context's fill colour, which CTLineDraw ignores without this (the type would be black).
            let s = CFAttributedStringCreate(nil, line as CFString,
                                             [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
                                                as CFDictionary)!
            ctx.textPosition = CGPoint(x: 90, y: CGFloat(baselineY(i))); CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        // A pale page (Times 36, grey type on grey paper) is blurred (3x3) and noised (up to 12 either way, a fixed
        // seed), as a camera's strokes are, and saved at the JPEG's full quality, which the page embeds as it is, so the
        // noise survives: it then reads as pale ink (the engine's C54), as the owner's phone photos do.
        if pale, let data = ctx.data {
            let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * pageH), row = ctx.bytesPerRow
            let grey = (0..<(pageW * pageH)).map { px[($0 / pageW) * row + ($0 % pageW) * 4] }
            var seed: UInt64 = 0x5eed_c0de
            for y in 0..<pageH {
                for x in 0..<pageW {
                    var v = Int(grey[y * pageW + x])
                    if x > 0, y > 0, x < pageW - 1, y < pageH - 1 {
                        v = 0
                        for dy in -1...1 { for dx in -1...1 { v += Int(grey[(y + dy) * pageW + x + dx]) } }
                        v /= 9
                    }
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let out = UInt8(clamping: v + Int((seed >> 33) % 25) - 12)
                    for c in 0..<3 { px[y * row + x * 4 + c] = out }
                }
            }
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: pale ? 1.0 : 0.9]
        if camera {
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Google", kCGImagePropertyTIFFModel: "Pixel 6"]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifFNumber: 1.85]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
