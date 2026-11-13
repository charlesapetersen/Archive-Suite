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
                let source = (try? Data(contentsOf: jpeg)) ?? Data()
                lines.append("NOTE plain output embeds the source JPEG's bytes: \(doc.page(at: 0).map(jpegStreams)?.contains(source) == true)")
            }
        }
        // An unknown kind whose reading aligns is placed.
        let unknown = dir.appendingPathComponent("unknown.pdf")
        let u = await write(jpeg, reading: reading, kind: nil, rotation: 0, to: unknown)
        check("3 unknown kind, aligned reading: placed", u?.layer.route == .visionLinesAligned, "\(String(describing: u?.layer))")
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

    private static func drawPage(_ text: [String], to url: URL, type: String) -> URL? {
        guard let ctx = CGContext(data: nil, width: pageW, height: pageH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Courier" as CFString, 34, nil)
        for (i, line) in text.enumerated() {
            let s = CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font] as CFDictionary)!
            ctx.textPosition = CGPoint(x: 90, y: CGFloat(baselineY(i))); CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
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
