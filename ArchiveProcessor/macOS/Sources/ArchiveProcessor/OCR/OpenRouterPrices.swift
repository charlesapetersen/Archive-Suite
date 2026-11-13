import Foundation

/// OpenRouter's own prices for each pinned route (W42.int-s2), read from its endpoints listing
/// (`GET /api/v1/models/<model>/endpoints`, no key) instead of typed in: the row for the pinned upstream provider and
/// precision, never another provider's, because OpenRouter serves an open model from several providers at different
/// prices and the measured figures hold only for the one measured. The cost estimate, the Settings note and the
/// request's price ceiling all read `priced(_:)`; a route the listing has not answered for keeps the bench's frozen
/// price (`OpenRouterRoute.catalog`) and `source(_:)` says so.
///
/// Fetched only when OpenRouter is the chosen provider (Settings, a run's start), at most once a day; kept in
/// UserDefaults so the next launch's estimate has them. No custom models: the catalog is still the list.
enum OpenRouterPrices {
    struct Price: Codable, Equatable, Sendable {
        /// Dollars per million tokens, as `LLMModel` keeps them.
        let inputPer1M: Double
        let outputPer1M: Double
        /// The listing's endpoint tag the price was read from (`deepinfra/fp8`).
        let tag: String
        let fetched: Date
    }

    static let defaultsKey = "openRouterEndpointPrices"
    static let maxAge: TimeInterval = 24 * 3600

    /// The pinned route's row in an endpoints listing: the exact tag, else the pinned provider's row at the pinned
    /// precision (a tag like `z-ai` names the provider, and the listing may add the precision). Nil when the listing
    /// has no such row or its price is not a positive number: the route then keeps the bench's price.
    static func parse(_ data: Data, route: OpenRouterRoute, now: Date = Date()) -> Price? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["data"] as? [String: Any],
              (body["id"] as? String) == route.model.id,
              let endpoints = body["endpoints"] as? [[String: Any]] else { return nil }
        let provider = route.providerTag.split(separator: "/").first.map(String.init) ?? route.providerTag
        let row = endpoints.first { ($0["tag"] as? String) == route.providerTag }
            ?? endpoints.first {
                let tag = $0["tag"] as? String ?? ""
                return (tag == provider || tag.hasPrefix(provider + "/"))
                    && ($0["quantization"] as? String ?? "unknown") == route.precision
            }
        guard let row, let tag = row["tag"] as? String, let pricing = row["pricing"] as? [String: Any],
              let input = perMillion(pricing["prompt"]), let output = perMillion(pricing["completion"]),
              input > 0, output > 0 else { return nil }
        return Price(inputPer1M: input, outputPer1M: output, tag: tag, fetched: now)
    }

    /// The listing gives dollars per token as a string ("0.0000002").
    private static func perMillion(_ value: Any?) -> Double? {
        let perToken = (value as? String).flatMap(Double.init) ?? (value as? Double)
        // Rounded to a millionth of a dollar per million tokens: the string's float noise is not a price.
        return perToken.map { ($0 * 1_000_000 * 1_000_000).rounded() / 1_000_000 }
    }

    static func stored(_ defaults: UserDefaults = .standard) -> [String: Price] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Price].self, from: data)) ?? [:]
    }

    static func store(_ prices: [String: Price], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(prices) { defaults.set(data, forKey: defaultsKey) }
    }

    /// The route's model at the listing's price, or as the catalog has it when the listing has not answered.
    static func priced(_ route: OpenRouterRoute, _ prices: [String: Price]? = nil) -> LLMModel {
        guard let price = (prices ?? stored())[route.model.id] else { return route.model }
        let m = route.model
        return LLMModel(id: m.id, displayName: m.displayName, provider: m.provider, supportsThinking: m.supportsThinking,
                        returnsMd: m.returnsMd, inputCostPer1M: price.inputPer1M, outputCostPer1M: price.outputPer1M,
                        batchDiscount: m.batchDiscount)
    }

    /// Where the price came from, for the Settings note.
    static func source(_ route: OpenRouterRoute, _ prices: [String: Price]? = nil) -> String {
        guard let price = (prices ?? stored())[route.model.id] else {
            return "the price the bench paid (OpenRouter's listing not read yet)"
        }
        let day = DateFormatter.localizedString(from: price.fetched, dateStyle: .medium, timeStyle: .none)
        return "OpenRouter's listed price for \(price.tag), read \(day)"
    }

    /// Reads the listing for every catalog route whose stored price is missing or older than a day (all of them when
    /// `force`), and keeps what it found. Returns one line per route read, for logs and the live check.
    @discardableResult
    static func refreshIfStale(force: Bool = false, defaults: UserDefaults = .standard) async -> [String] {
        var prices = stored(defaults)
        var report: [String] = []
        for route in OpenRouterRoute.catalog {
            if !force, let have = prices[route.model.id], Date().timeIntervalSince(have.fetched) < maxAge { continue }
            guard let url = URL(string: "\(OpenAICompatibleClient.openRouterBaseURL)/models/\(route.model.id)/endpoints")
            else { continue }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "GET"
            do {
                let (data, response) = try await NetworkSession.data(for: request, policy: .idempotent)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let price = parse(data, route: route) {
                    prices[route.model.id] = price
                    report.append("\(route.model.id) \(price.tag): $\(price.inputPer1M) in, $\(price.outputPer1M) out per 1M")
                } else {
                    report.append("\(route.model.id): no \(route.providerTag) row (HTTP \(status)); the bench's price stays")
                }
            } catch {
                report.append("\(route.model.id): \(error.localizedDescription); the bench's price stays")
            }
        }
        store(prices, defaults)
        for line in report { NSLog("[OpenRouter] price \(line)") }
        return report
    }
}
