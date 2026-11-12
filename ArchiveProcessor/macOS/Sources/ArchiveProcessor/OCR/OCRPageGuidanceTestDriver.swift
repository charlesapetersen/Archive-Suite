#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation

/// Headless, $0 self-test of the OCR page-kind guidance (W41.app-ocr-hierarchy), gated by `OCR_PAGE_GUIDANCE_TEST=1`
/// (does nothing in normal use). No model call, no network, no Keychain read, no window. Run by
/// `scripts/test-ocr-page-guidance.sh`, which also checks every figure in the table against the bench result file it
/// names.
///
/// What has to be true:
///   1. The bundled ocr-page-guidance.json decodes and has no problems: picks best first, NES in range, and every
///      `app_model` a built-in model id.
///   2. The lines read as the user should see them, including "(not in this list yet)" for a model the app lacks.
///   3. (The note it drew is now the settings sheet's reading card; SettingsSheetTestDriver renders it.)
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
           "Handwriting (16 pages): Gemini 3.8 Flash 95.8, then Gemini 3.1 Pro 94.0.")
        eq("2 printed", by["printed"],
           "Printed or typeset (28 pages): Claude Sonnet 5.5 96.3 (not in this list yet), then Qwen3.6 27B (open) 94.8. "
           + "Gemini refused two of these pages; the app sends a refused page to a second model.")
        check("2 forms says it is only 4 pages", by["forms"]?.contains("(4 pages)") == true
              && by["forms"]?.contains("hint") == true, by["forms"] ?? "nil")
        check("2 typewriting says any leader", by["typewritten"]?.contains("95 or more") == true, by["typewritten"] ?? "nil")
        check("2 low resolution is tentative", by["low-resolution"]?.contains("Tentative") == true
              && by["low-resolution"]?.contains("89.7") == true, by["low-resolution"] ?? "nil")
        let pick = g.kinds[0].picks[0]
        eq("2 a model the app lacks is marked", OCRPageGuidance.text(pick, modelIDs: []),
           "Gemini 3.8 Flash 95.8 (not in this list yet)")
        // 3. The note it fed is gone: what reads which pages best is the settings sheet's reading card, rendered by
        // SettingsSheetTestDriver (W46.settings-sheet).
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

#endif
