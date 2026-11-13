#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import VisionOCRKit

/// PAID live check of W42.int-s2, a few tenths of a cent, gated by `PAGEREADER_LIVE=1` and a key in
/// `PAGEREADER_LIVE_KEY` (does nothing in normal use). Run by `scripts/live-page-reader.sh --paid`, which draws the two
/// smoke pages in a scratch folder and passes them in `PAGEREADER_LIVE_DIR`.
///
/// 1. Reads OpenRouter's endpoints listing (no key, free) and states the cost of the reads from the pinned upstream's
///    listed price BEFORE any paid call; stops if the route's price did not come from the listing.
/// 2. Reads both pages through `PageReaders.reader` (the app's one way to read a page) with Qwen3-VL 235B.
/// 3. Reports each reading's text, seconds and dollars, and what OpenRouter's key counter says was spent.
@MainActor
enum PageReaderLiveDriver {
    nonisolated static let envKey = "PAGEREADER_LIVE"

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env[envKey] == "1", let key = env["PAGEREADER_LIVE_KEY"], !key.isEmpty,
              let dir = env["PAGEREADER_LIVE_DIR"] else { return }
        Task { @MainActor in await run(key: key, dir: URL(fileURLWithPath: dir)) }
    }

    private static func run(key: String, dir: URL) async {
        var lines: [String] = []
        var ok = true
        defer {
            lines.append(ok ? "ALL PASS" : "FAILED")
            let text = lines.joined(separator: "\n") + "\n"
            if let out = ProcessInfo.processInfo.environment["PAGEREADER_LIVE_OUT"] {
                try? text.write(toFile: out, atomically: true, encoding: .utf8)
            } else { print(text) }
        }
        guard let route = OpenRouterRoute.forModel("qwen/qwen3-vl-235b-a22b-instruct") else {
            lines.append("FAIL no catalog route"); ok = false; return
        }
        for line in await OpenRouterPrices.refreshIfStale(force: true) { lines.append("LISTING \(line)") }
        guard let price = OpenRouterPrices.stored()[route.model.id] else {
            lines.append("FAIL the listing gave no \(route.providerTag) price; not reading"); ok = false; return
        }
        let model = OpenRouterPrices.priced(route)
        let pages = PageReaderTestDriver.smokePages
        let estimate = PageReaders.pagePrice(model) * Double(pages.count)
        lines.append(String(format: "ESTIMATE %d pages at $%.2f in, $%.2f out per 1M (%@): $%.4f, stated before calling",
                            pages.count, price.inputPer1M, price.outputPer1M, price.tag, estimate))
        let before = await keyUsage(key)
        guard let reader = try? PageReaders.reader(provider: .openrouter, model: model, apiKey: key, thinkingLevel: nil)
        else { lines.append("FAIL no reader"); ok = false; return }
        var total = 0.0
        for page in pages {
            let input = PageReaderInput(imageURL: dir.appendingPathComponent(page.name + ".png"))
            guard let reading = try? await reader.read(input) else {
                lines.append("FAIL \(page.name) threw"); ok = false; continue
            }
            let words = { (s: String) in s.lowercased().split { !$0.isLetter && !$0.isNumber } }
            let same = reading.text.map { words($0) == words(page.text) } ?? false
            total += reading.dollars ?? 0
            lines.append(String(format: "%@ %@ %.1f s $%.5f %@ | %@", same ? "PASS" : "FAIL", page.name, reading.seconds,
                                reading.dollars ?? -1, reading.detail.classification?.rawValue ?? "-",
                                (reading.text ?? reading.detail.errorMessage ?? "?").replacingOccurrences(of: "\n", with: "⏎")))
            if !same || reading.dollars == nil { ok = false }
        }
        lines.append(String(format: "PRICED readings $%.5f (the listing's price x the app's page estimate)", total))
        // OpenRouter's counter lags a few seconds behind a call.
        try? await Task.sleep(for: .seconds(8))
        if let before, let after = await keyUsage(key) {
            lines.append(String(format: "SPENT $%.5f by OpenRouter's key counter", after - before))
        } else {
            lines.append("SPENT unknown (the key counter did not answer)")
        }
    }

    /// The key's lifetime spend in dollars (`GET /api/v1/key`), free.
    private static func keyUsage(_ key: String) async -> Double? {
        guard let url = URL(string: "\(OpenAICompatibleClient.openRouterBaseURL)/key") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await NetworkSession.data(for: request, policy: .idempotent),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["data"] as? [String: Any] else { return nil }
        return (body["usage"] as? Double) ?? (body["usage"] as? NSNumber)?.doubleValue
    }
}
#endif
