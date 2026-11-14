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
///   1. The rule (`TextLayerRule`): print kinds are placed, handwritten and mixed pages get the text page alone (the
///      hand placer is not in the app yet), an unknown kind is placed only when the reading aligns, and a reading in
///      a right-to-left script or in CJK or Thai gets no layer.
///   2. Each output still has its two pages, the text page first line `Extracted text.`, and the image page's text,
///      read back through PDFKit, holds the reading: a selection over each drawn line returns that line's words, in
///      order (the strict line pass, `05-placement.md` §3), on the JPEG fast path, the re-encoded path and a turned page.
///   3. A page the rule gives no layer, and a page written without one, have no text on the image page.
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
    }

    private static func improveChecks(dir: URL, jpeg: URL, reading: String) async {
        guard let original = try? Data(contentsOf: dir.appendingPathComponent("jpeg.pdf")),
              case .success(let pairs) = ReOCRPairs.validate(original), let pair = pairs.first else {
            check("5 the layered output is an Improve OCR pair", false); return
        }
        let source = (try? Data(contentsOf: jpeg)) ?? Data()
        let model = LLMModel.appleVisionModels[0]
        let newText = reading.replacingOccurrences(of: "MEMORANDUM", with: "MEMORANDA")
        let newReading = OCRResult(text: newText, classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil)
        guard let remade = await ReOCRJob.remadeImagePage(original, pair: pair, reading: newReading, kind: .typewritten) else {
            check("5 the image page is remade beside a re-read", false); return
        }
        let layer = PDFDocument(data: remade)?.page(at: 0)?.string ?? ""
        check("5 the remade layer holds the new reading", layer.contains("MEMORANDA") && !layer.contains("MEMORANDUM"),
              String(layer.prefix(40)))
        check("5 the remade page embeds the same JPEG bytes", ReOCRJob.embeddedJPEG(remade, pageIndex: 0) == source)
        do {
            let text = try ReOCRPairs.replacementPage(for: pair, result: newReading, model: model, kind: .typewritten)
            let candidate = try ReOCRIncrementalWriter.candidate(original: original,
                                                                 replacements: [pair.imageIndex: remade, pair.textIndex: text])
            let doc = PDFDocument(data: candidate)
            // Kept for test-text-layer.sh's veraPDF run: a revision with both pages replaced is still PDF/A-2b.
            if let keep = ProcessInfo.processInfo.environment["TEXTLAYER_TEST_KEEP"] {
                try? candidate.write(to: URL(fileURLWithPath: keep).appendingPathComponent("revised.pdf"))
            }
            check("5 the incremental revision takes both pages and keeps the original as its prefix",
                  candidate.starts(with: original) && doc?.pageCount == 2
                  && doc?.page(at: 0)?.string?.contains("MEMORANDA") == true)
        } catch { check("5 the incremental revision takes both pages", false, "\(error)") }
        let hand = await ReOCRJob.remadeImagePage(original, pair: pair, reading: newReading, kind: .handwritten)
        let handText = hand.flatMap { PDFDocument(data: $0)?.page(at: 0)?.string ?? "" }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("5 a re-read that gets no layer drops the old one", handText?.isEmpty == true, String(describing: handText))
        if let doc = PDFDocument(data: original), let first = doc.page(at: 0) {
            first.setBounds(CGRect(x: 20, y: 20, width: 500, height: 700), for: .cropBox)
            if let cropped = doc.dataRepresentation(), case .success(let cp) = ReOCRPairs.validate(cropped), let c = cp.first {
                let kept = await ReOCRJob.remadeImagePage(cropped, pair: c, reading: newReading, kind: .typewritten)
                check("5 an image page with its own crop box is kept (a remade page would show more)", kept == nil)
            } else { check("5 a cropped original for Improve OCR", false) }
        }
        let plainURL = dir.appendingPathComponent("plain-improve.pdf")
        if await write(jpeg, reading: reading, kind: .typewritten, rotation: 0, to: plainURL, options: nil) != nil,
           let plain = try? Data(contentsOf: plainURL), case .success(let plainPairs) = ReOCRPairs.validate(plain),
           let p = plainPairs.first {
            let left = await ReOCRJob.remadeImagePage(plain, pair: p, reading: newReading, kind: .handwritten)
            check("5 a page with no layer that gets none is left as it is", left == nil)
        } else { check("5 a plain output for Improve OCR", false) }
    }

    private static func ruleChecks() {
        func d(_ k: PageKindName?, _ r: String? = "a letter", hand: Bool = true) -> TextLayerRule.Decision {
            TextLayerRule.decide(kind: k, reading: r, placeHandOnImage: hand)
        }
        check("1 registers: text page", d(.registers) == .textPage(TextLayerRule.handwritingReason))
        for k in [PageKindName.typewritten, .printed, .forms, .newspapers, .clippings] {
            check("1 \(k.rawValue) placed", d(k) == .place(requireAligned: false))
        }
        check("1 handwritten: text page", d(.handwritten) == .textPage(TextLayerRule.handwritingReason))
        check("1 mixed: text page", d(.mixed) == .textPage(TextLayerRule.handwritingReason))
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
              let catalog = doc.catalog else { check("6 \(name) opens", false); return }
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

    static func drawPage(_ text: [String], to url: URL, type: String, skew: Double = 0) -> URL? {
        guard let ctx = CGContext(data: nil, width: pageW, height: pageH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Courier" as CFString, 34, nil)
        // A positive skew makes the lines fall to the right, as ReadingCopy measures it (y down): clockwise on paper.
        ctx.translateBy(x: CGFloat(pageW) / 2, y: CGFloat(pageH) / 2)
        ctx.rotate(by: CGFloat(-skew * .pi / 180))
        ctx.translateBy(x: -CGFloat(pageW) / 2, y: -CGFloat(pageH) / 2)
        for (i, line) in text.enumerated() {
            let s = CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font] as CFDictionary)!
            ctx.textPosition = CGPoint(x: 90, y: CGFloat(baselineY(i))); CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
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
