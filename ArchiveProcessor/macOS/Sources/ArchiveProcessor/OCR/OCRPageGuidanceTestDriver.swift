import AppKit
import SwiftUI

/// Headless, $0 self-test of the OCR picker's page-kind note (W41.app-ocr-hierarchy), gated by
/// `OCR_PAGE_GUIDANCE_TEST=1` (does nothing in normal use). No model call, no network, no Keychain read, no window: the
/// render guard draws offscreen with `ImageRenderer`. Run by `scripts/test-ocr-page-guidance.sh`, which also checks
/// every figure in the table against the bench result file it names.
///
/// What has to be true:
///   1. The bundled ocr-page-guidance.json decodes and has no problems: picks best first, NES in range, and every
///      `app_model` a built-in model id.
///   2. The lines read as the user should see them, including "(not in this list yet)" for a model the app lacks.
///   3. Render guard: the note draws non-blank pixels offscreen, one line per kind of page.
@MainActor
enum OCRPageGuidanceTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["OCR_PAGE_GUIDANCE_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    static func run() {
        defer { finish() }
        guard let g = OCRPageGuidance.loadBundled() else {
            check("1 bundled ocr-page-guidance.json decodes", false, "missing or undecodable")
            return
        }
        // 1. Fit to ship.
        eq("1 no problems", g.problems(), [])
        eq("1 kinds in order", g.kinds.map(\.id), ["handwritten", "printed", "forms", "typewritten", "low-resolution"])
        check("1 footnote names the corpus and the drafters",
              g.footnote.contains("one corpus") && g.footnote.contains("Claude and Gemini"), g.footnote)
        eq("1 the picker shows the bundled table", OCRPageGuidance.bundled, g)

        // A bad edit is refused.
        let bad = OCRPageGuidance(measured: "x", footnote: "f", kinds: [
            .init(id: "a", label: "A", pages: 1, picks: [
                .init(name: "P", nes: 90, appModel: "no-such-model", source: .init(file: "", route: "", attribute: "", value: "")),
                .init(name: "Q", nes: 95, appModel: nil, source: .init(file: "", route: "", attribute: "", value: "")),
            ], note: nil),
        ])
        eq("1 unknown app_model and wrong order are problems", bad.problems(),
           ["a: picks not best first", "a: P app_model no-such-model unknown"])

        // 2. The lines.
        let ids = OCRPageGuidance.builtInModelIDs
        let by = Dictionary(uniqueKeysWithValues: g.kinds.map { ($0.id, OCRPageGuidance.line($0, modelIDs: ids)) })
        eq("2 handwriting", by["handwritten"],
           "Handwriting (16 pages): Gemini 3.8 Flash 96.0, then Gemini 3.1 Pro 94.1.")
        eq("2 printed", by["printed"],
           "Printed or typeset (28 pages): Claude Sonnet 5.5 96.3 (not in this list yet), then Qwen3.6 27B (open) 94.8 "
           + "(not in this list yet). Gemini refused two of these pages; the app sends a refused page to a second model.")
        check("2 forms says it is only 4 pages", by["forms"]?.contains("(4 pages)") == true
              && by["forms"]?.contains("hint") == true, by["forms"] ?? "nil")
        check("2 typewriting says any leader", by["typewritten"]?.contains("95 or more") == true, by["typewritten"] ?? "nil")
        check("2 low resolution is tentative", by["low-resolution"]?.contains("Tentative") == true
              && by["low-resolution"]?.contains("89.7") == true, by["low-resolution"] ?? "nil")
        let pick = g.kinds[0].picks[0]
        eq("2 a model the app lacks is marked", OCRPageGuidance.text(pick, modelIDs: []),
           "Gemini 3.8 Flash 96.0 (not in this list yet)")

        // 3. Render guard.
        let ink = renderedInk(OCRPageGuidanceNote(guidance: g), saveAs: "note")
        check("3 note renders (\(ink) dark px)", ink > 1500)
        let one = OCRPageGuidance(measured: g.measured, footnote: g.footnote, kinds: [g.kinds[0]])
        let inkOne = renderedInk(OCRPageGuidanceNote(guidance: one), saveAs: "note-one-kind")
        check("3 every kind draws a line (\(ink) > \(inkOne) dark px)", ink > inkOne + 500 && inkOne > 300)
    }

    /// Dark pixels in the note drawn offscreen on white at the Settings form's width. Blank → 0. With
    /// `OCR_PAGE_GUIDANCE_RENDER_DIR` set, the note is also saved there as a PNG to look at.
    private static func renderedInk(_ view: some View, saveAs name: String) -> Int {
        let content = view
            .frame(width: 420, alignment: .leading)
            .padding(8)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return 0 }
        if let dir = ProcessInfo.processInfo.environment["OCR_PAGE_GUIDANCE_RENDER_DIR"],
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var ink = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let lum = (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
            if lum < 160 { ink += 1 }
        }
        return ink
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["OCR_PAGE_GUIDANCE_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
