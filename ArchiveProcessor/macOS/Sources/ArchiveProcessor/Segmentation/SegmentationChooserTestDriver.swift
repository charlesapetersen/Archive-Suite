import AppKit
import SwiftUI

/// Headless, $0 self-test of the approach chooser (W36.seg-opt-chooser), gated by `SEGMENTATION_CHOOSER_TEST=1`
/// (does nothing in normal use). No model call, no network, no Keychain read (the routes are passed in), no window:
/// the render guard draws offscreen with `ImageRenderer`. Run by `scripts/test-segmentation-chooser.sh`.
///
/// What has to be true:
///   1. The bundled options.json is fit to ship, including the per-model prices the chooser adds up.
///   2. Every approach's row text, at several page counts, is the figure the file holds, rounded as Part 3 §3 says:
///      whole percent, boundaries at least 1, errors as "1 in" two significant figures, a zero as "none in <test
///      pages> test pages", and the footnote built from the file.
///   3. The cost is §4's: dollars by API key at list price; a scheduled price change announced through its day
///      and applied from the next; "prices as of" past 90 days; the Claude plan's notional line
///      when only `claude` can run it; a mix adding its Claude and ChatGPT parts by route.
///   4. An approach that cannot run says why: the file's reason when unmeasured, the missing key or `claude`
///      otherwise, with the keys the wizard should offer. Manual always runs, at no cost.
///   5. Render guard: each row card draws non-blank pixels offscreen.
@MainActor
enum SegmentationChooserTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SEGMENTATION_CHOOSER_TEST"] == "1" else { return }
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

    private static func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s + " 12:00")!
    }

    static func run() {
        defer { finish() }
        let options: SegmentationOptions
        do { options = try SegmentationOptions.loadBundled() } catch {
            check("1 bundled options.json decodes", false, "\(error)")
            return
        }
        // 1. Fit to ship.
        eq("1 options.json has no problems", options.problems(), [])

        let all = SegmentationRoutes(hasAnthropicKey: true, hasGeminiKey: true, hasOpenAIKey: true, hasClaudeCLI: true)
        let keysOnly = SegmentationRoutes(hasAnthropicKey: true, hasGeminiKey: true, hasOpenAIKey: false,
                                          hasClaudeCLI: false)
        let today = day("2026-10-11")
        func row(_ a: SegmentationApproach, _ n: Int, _ r: SegmentationRoutes = keysOnly,
                 on d: Date? = nil) -> SegmentationRow {
            SegmentationRow.make(a, options: options, pageCount: n, routes: r, today: d ?? today)
        }

        // 2. Figures.
        let footnote = "Measured once on two boxes (363 pages) of one archive, 11 Oct 2026. Your material may differ."
        let claude = row(.claude, 1000)
        eq("2 claude no checking", claude.rightWithNoChecking, "about 87% of pages")
        eq("2 claude to check @1000", claude.toCheck, "about 102 boundaries to check")
        eq("2 claude after checking", claude.rightAfterChecking, "about 97% of pages")
        eq("2 claude unshown", claude.unshownErrors, "about 1 in 120 pages")
        eq("2 footnote", claude.footnote, footnote)
        eq("2 claude to check @363", row(.claude, 363).toCheck, "about 37 boundaries to check")
        eq("2 claude to check @1 (at least 1)", row(.claude, 1).toCheck, "about 1 boundary to check")
        eq("2 claude to check @0 (at least 1)", row(.claude, 0).toCheck, "about 1 boundary to check")

        let gemini = row(.gemini, 1000)
        eq("2 gemini no checking", gemini.rightWithNoChecking, "about 89% of pages")
        eq("2 gemini to check", gemini.toCheck, "about 242 boundaries to check")
        eq("2 gemini after checking", gemini.rightAfterChecking, "about 100% of pages")
        eq("2 gemini zero is not a promise", gemini.unshownErrors, "none in 363 test pages")

        let mix = row(.mix, 1000)
        eq("2 mix no checking", mix.rightWithNoChecking, "about 92% of pages")
        eq("2 mix to check", mix.toCheck, "about 102 boundaries to check")
        eq("2 mix after checking", mix.rightAfterChecking, "about 97% of pages")
        eq("2 mix unshown", mix.unshownErrors, "about 1 in 120 pages")

        let manual = row(.manual, 1000, .none)
        eq("2 manual proposes nothing", manual.rightWithNoChecking, nil)
        eq("2 manual to judge", manual.toCheck, "about 868 boundaries to judge")
        eq("2 manual after", manual.rightAfterChecking, "about 100% of pages")
        eq("4 manual runs with nothing", manual.unavailableReason, nil)
        eq("4 manual no cost", manual.costLines, ["No cost"])
        eq("4 manual cost pane $0", manual.costSummary, CostEstimate.money(0))
        eq("4 manual dollars", manual.apiDollars, 0)

        eq("2 two sig figs", ["121", "181.5", "47.3", "8.04", "1234", "0.5"].map {
            SegmentationRow.twoSignificant(Double($0)!) }, ["120", "180", "47", "8", "1200", "0.5"])

        // 3. Cost.
        eq("3 claude list", claude.costLines, ["about $16.93 by API key at list price"])
        check("3 claude dollars", abs((claude.apiDollars ?? 0) - 16.932352297593) < 1e-9, "\(claude.apiDollars as Any)")
        eq("3 claude cost pane", claude.costSummary, CostEstimate.money(16.932352297593))
        eq("3 claude scaled @363", row(.claude, 363).costLines, ["about $6.15 by API key at list price"])
        eq("3 tiny run", row(.gemini, 1).costLines.first, "about under $0.01 by API key at list price")
        eq("3 gemini intro price", gemini.costLines, ["about $3.61 by API key at list price"])
        eq("3 gemini intro price announced", gemini.priceNotes, ["Gemini: introductory price until 31 Dec 2026"])
        let later = row(.gemini, 1000, on: day("2027-01-15"))
        eq("3 gemini after the change", later.costLines, ["about $7.22 by API key at list price"])
        eq("3 gemini after the change: no intro note, stale price", later.priceNotes,
           ["Gemini prices as of 5 Oct 2026"])
        eq("3 gemini on the last intro day keeps the intro price",
           row(.gemini, 1000, on: day("2026-12-31")).costLines.first, "about $3.61 by API key at list price")
        eq("3 gemini the day after applies the new price", row(.gemini, 1000, on: day("2027-01-01")).costLines.first,
           "about $7.22 by API key at list price")
        eq("3 claude stale after 90 days", row(.claude, 1000, on: day("2027-01-10")).priceNotes,
           ["Claude prices as of 11 Oct 2026"])
        eq("3 claude not stale at 90 days", row(.claude, 1000, on: day("2027-01-09")).priceNotes, [])
        eq("3 claude fresh price has no note", claude.priceNotes, [])
        eq("3 mix by keys", mix.costLines, ["about $31.44 by API key at list price"])
        eq("3 mix: both prices fresh, no note", mix.priceNotes, [])

        let cliOnly = SegmentationRoutes(hasClaudeCLI: true)
        let claudePlan = row(.claude, 1000, cliOnly)
        eq("3 claude plan only runs", claudePlan.unavailableReason, nil)
        eq("3 claude plan line", claudePlan.costLines,
           ["Claude plan: uses about as much of your plan as $50.29 of API calls at list price; "
            + "measured on your account after the first run"])
        eq("3 claude plan has no dollars", claudePlan.apiDollars, nil)
        eq("3 claude plan cost pane", claudePlan.costSummary, "your plan")
        let mixPlan = row(.mix, 1000, SegmentationRoutes(hasOpenAIKey: true, hasClaudeCLI: true))
        eq("3 mix = Claude plan + ChatGPT dollars", mixPlan.costLines,
           ["about $14.51 by API key at list price",
            "Claude plan: uses about as much of your plan as $50.29 of API calls at list price; "
            + "measured on your account after the first run"])
        eq("3 mix plan: no Claude price note", mixPlan.priceNotes, [])
        check("3 mix dollars are ChatGPT's only", abs((mixPlan.apiDollars ?? 0) - 14.506758169934638) < 1e-9,
              "\(mixPlan.apiDollars as Any)")
        eq("3 key wins over plan when both", row(.claude, 1000, all).costLines, claude.costLines)

        // 4. Unavailable.
        let openai = row(.openai, 1000, all)
        check("4 openai measured (W36.seg-opt-openai): figures and a cost, runnable with the key",
              openai.canRun && openai.toCheck.hasPrefix("about ") && openai.apiDollars != nil
              && openai.costLines.count == 1, "\(openai.toCheck) \(openai.costLines)")
        let openaiNoKey = row(.openai, 1000, keysOnly)
        eq("4 openai without key", openaiNoKey.unavailableReason, "Needs an OpenAI API key.")
        eq("4 openai offers the OpenAI key", openaiNoKey.missingKeys, [.openai])
        if let opts = mutateBundled({ approaches in
            guard let i = approaches.firstIndex(where: { $0["id"] as? String == "openai" }) else { return false }
            approaches[i] = ["id": "openai", "label": "ChatGPT only", "available": false, "reason": "Not measured: R."]
            return true
        }) {
            let r = SegmentationRow.make(.openai, options: opts, pageCount: 1000, routes: all, today: today)
            check("4 an unmeasured row shows the file's reason and no figures",
                  r.unavailableReason == "Not measured: R." && r.toCheck == "" && opts.problems().isEmpty,
                  "\(r.unavailableReason as Any) \(opts.problems())")
        } else { check("4 an unmeasured row shows the file's reason and no figures", false, "could not rebuild the file") }
        let noClaude = row(.claude, 1000, .none)
        eq("4 claude without key or claude",
           noClaude.unavailableReason, "Needs an Anthropic API key, or the claude tool installed and signed in.")
        eq("4 claude offers the Anthropic key", noClaude.missingKeys, [.anthropic])
        check("4 unavailable row still shows its figures", noClaude.toCheck == claude.toCheck)
        eq("4 unavailable row still shows what the key would cost", noClaude.costLines, claude.costLines)
        eq("4 unavailable row adds nothing to a total", noClaude.apiDollars, nil)
        eq("4 unavailable cost pane", noClaude.costSummary, "—")
        let geminiNoKey = row(.gemini, 1000, SegmentationRoutes(hasAnthropicKey: true))
        eq("4 gemini without key: cost and intro note shown", geminiNoKey.costLines + geminiNoKey.priceNotes,
           gemini.costLines + gemini.priceNotes)
        let mixHalf = row(.mix, 1000, SegmentationRoutes(hasAnthropicKey: true))
        eq("4 mix missing ChatGPT prices the whole mix", mixHalf.costLines, mix.costLines)
        eq("4 mix missing ChatGPT adds no partial dollars", mixHalf.apiDollars, nil)
        let mixNoClaude = row(.mix, 1000, SegmentationRoutes(hasOpenAIKey: true))
        eq("4 mix names only the missing provider", mixNoClaude.missingKeys, [.anthropic])
        let mixNothing = row(.mix, 1000, .none)
        eq("4 mix names both", mixNothing.unavailableReason,
           "Needs an Anthropic API key, or the claude tool installed and signed in and an OpenAI API key.")
        eq("4 mix wizard offers both", mixNothing.missingKeys, [.anthropic, .openai])
        eq("4 gemini with only claude", row(.gemini, 1000, cliOnly).missingKeys, [.gemini])
        eq("4 all rows, one per case", SegmentationRow.all(options: options, pageCount: 10, routes: all).map(\.approach),
           SegmentationApproach.allCases)

        // A file whose per-model prices do not add up is refused.
        if let url = Bundle.main.url(forResource: SegmentationOptions.resourceName, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var approaches = json["approaches"] as? [[String: Any]],
           let i = approaches.firstIndex(where: { $0["id"] as? String == "claude" }),
           var cost = approaches[i]["cost"] as? [String: Any],
           var total = cost["total"] as? [String: Any] {
            total["list_usd_per_1000_pages"] = 99.0
            cost["total"] = total
            approaches[i]["cost"] = cost
            json["approaches"] = approaches
            let bad = (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? SegmentationOptions.decode($0) }
            check("1 mismatched per-model prices are a problem",
                  bad?.problems().contains("claude: per-model list prices do not add up to the total") == true,
                  "\(bad?.problems() ?? ["did not decode"])")
        } else {
            check("1 mismatched per-model prices are a problem", false, "could not rebuild the file")
        }

        // A model no voter runs is refused; two scheduled price changes do not decode.
        if let mutated = mutateBundled({ approaches in
            guard let i = approaches.firstIndex(where: { $0["id"] as? String == "claude" }),
                  var tokens = approaches[i]["tokens_per_1000_pages"] as? [String: Any],
                  var c = tokens["C"] as? [String: Any] else { return false }
            c["model"] = "claude-renamed-9"
            tokens["C"] = c
            approaches[i]["tokens_per_1000_pages"] = tokens
            return true
        }) {
            check("1 a model no voter runs is a problem",
                  mutated.problems().contains("claude: cost C is for claude-renamed-9, which no voter runs"),
                  "\(mutated.problems())")
        } else {
            check("1 a model no voter runs is a problem", false, "could not rebuild the file")
        }
        let twoChanges = mutateBundledData { approaches in
            guard let i = approaches.firstIndex(where: { $0["id"] as? String == "gemini" }),
                  var cost = approaches[i]["cost"] as? [String: Any],
                  var per = cost["per_model"] as? [String: Any],
                  var g = per["G"] as? [String: Any] else { return false }
            g["after_2027_06_30"] = g["after_2026_12_31"]
            per["G"] = g; cost["per_model"] = per; approaches[i]["cost"] = cost
            return true
        }
        check("1 two scheduled price changes are refused",
              twoChanges != nil && (try? SegmentationOptions.decode(twoChanges!)) == nil)

        // 5. Render guard.
        for r in [claude, gemini, mix, manual, openai, noClaude, claudePlan] {
            let name = "\(r.approach.rawValue)\(r.canRun ? "" : "-unavailable")"
            let ink = renderedInk(SegmentationRowCard(row: r, scaleCaption: "per 1,000 pages"), saveAs: name)
            check("5 renders \(r.approach.rawValue)\(r.canRun ? "" : " (unavailable)") (\(ink) dark px)", ink > 300)
        }
    }

    /// Dark pixels in the card drawn offscreen on white at the Process Files panel's width. Blank → 0.
    /// The bundled file with `change` applied to its approaches, re-encoded; nil when it cannot be rebuilt.
    private static func mutateBundledData(_ change: (inout [[String: Any]]) -> Bool) -> Data? {
        guard let url = Bundle.main.url(forResource: SegmentationOptions.resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var approaches = json["approaches"] as? [[String: Any]],
              change(&approaches) else { return nil }
        json["approaches"] = approaches
        return try? JSONSerialization.data(withJSONObject: json)
    }

    private static func mutateBundled(_ change: (inout [[String: Any]]) -> Bool) -> SegmentationOptions? {
        mutateBundledData(change).flatMap { try? SegmentationOptions.decode($0) }
    }

    /// With `SEGMENTATION_CHOOSER_RENDER_DIR` set, each card is also saved there as a PNG to look at.
    private static func renderedInk(_ view: some View, saveAs name: String) -> Int {
        let content = view
            .frame(width: 320, alignment: .leading)
            .padding(8)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return 0 }
        if let dir = ProcessInfo.processInfo.environment["SEGMENTATION_CHOOSER_RENDER_DIR"],
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
        if let out = ProcessInfo.processInfo.environment["SEGMENTATION_CHOOSER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
