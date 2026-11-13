import Foundation

/// OpenRouter's own prices for each pinned route (W42.int-s2), read from its endpoints listing
/// (`GET /api/v1/models/<model>/endpoints`, no key) instead of typed in: the row for the pinned upstream provider and
/// precision, never another provider's, because OpenRouter serves an open model from several providers at different
/// prices and the measured figures hold only for the one measured. The model list (so the cost estimate) and the
/// Settings note read `priced(_:)`; the request's price ceiling is the run's model's price
/// (`OpenRouterRoute.ceiling`), the one its estimate showed. A route the listing has not answered for keeps the
/// bench's frozen price (`OpenRouterRoute.catalog`) and `source(_:)` says so. Segmentation's OpenRouter voter keeps
/// the bench's price, as its cost figure does.
///
/// Read only when the Settings note for an OpenRouter model shows, so only when OpenRouter is chosen: at most once a
/// day, a failed attempt waits an hour, one short request per route with no retries. Kept in UserDefaults so the
/// next launch's estimate has them. No custom models: the catalog is still the list.
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
    static let attemptKey = "openRouterEndpointPricesAttempted"
    static let maxAge: TimeInterval = 24 * 3600
    static let retryAfter: TimeInterval = 3600
    /// A listed price above this many times the bench's is not taken: the estimate and ceiling keep the bench's.
    static let maxRise = 3.0

    /// The pinned route's row in an endpoints listing: the one row with exactly the pinned tag; for a pinned tag that
    /// names only the provider (`z-ai`, `alibaba`), the one row of that provider at the pinned precision. Nil when no
    /// row or more than one matches, or its price is not finite and positive, or it is more than `maxRise` times the
    /// bench's: the route then keeps the bench's price.
    static func parse(_ data: Data, route: OpenRouterRoute, now: Date = Date()) -> Price? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["data"] as? [String: Any],
              (body["id"] as? String) == route.model.id,
              let endpoints = body["endpoints"] as? [[String: Any]] else { return nil }
        var rows = endpoints.filter { ($0["tag"] as? String) == route.providerTag }
        if rows.isEmpty, !route.providerTag.contains("/") {
            rows = endpoints.filter {
                let tag = $0["tag"] as? String ?? ""
                return (tag == route.providerTag || tag.hasPrefix(route.providerTag + "/"))
                    && ($0["quantization"] as? String ?? "unknown") == route.precision
            }
        }
        guard rows.count == 1, let row = rows.first, let tag = row["tag"] as? String,
              let pricing = row["pricing"] as? [String: Any],
              let input = perMillion(pricing["prompt"]), let output = perMillion(pricing["completion"]),
              input.isFinite, output.isFinite, input > 0, output > 0,
              input <= route.model.inputCostPer1M * maxRise, output <= route.model.outputCostPer1M * maxRise
        else { return nil }
        return Price(inputPer1M: input, outputPer1M: output, tag: tag, fetched: now)
    }

    /// The listing gives dollars per token as a string ("0.0000002").
    private static func perMillion(_ value: Any?) -> Double? {
        let perToken = (value as? String).flatMap(Double.init) ?? (value as? Double)
        // Rounded to a millionth of a dollar per million tokens: the string's float noise is not a price.
        return perToken.map { ($0 * 1_000_000 * 1_000_000).rounded() / 1_000_000 }
    }

    static func stored(_ defaults: UserDefaults = .standard) -> [String: Price] {
        // A no-wire test checks the catalog's prices: what a real launch read earlier must not leak into it.
        if defaults === UserDefaults.standard, NetworkSession.testTransportIsActive { return [:] }
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
        if !force, let tried = defaults.object(forKey: attemptKey) as? Date,
           Date().timeIntervalSince(tried) < retryAfter { return [] }
        defaults.set(Date(), forKey: attemptKey)
        var prices = stored(defaults)
        var report: [String] = []
        for route in OpenRouterRoute.catalog {
            if !force, let have = prices[route.model.id], Date().timeIntervalSince(have.fetched) < maxAge { continue }
            guard let url = URL(string: "\(OpenAICompatibleClient.openRouterBaseURL)/models/\(route.model.id)/endpoints")
            else { continue }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "GET"
            do {
                // `.nonIdempotent` is the no-retry policy: an unanswered listing waits for the next attempt.
                let (data, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let price = parse(data, route: route) {
                    prices[route.model.id] = price
                    report.append("\(route.model.id) \(price.tag): $\(price.inputPer1M) in, $\(price.outputPer1M) out per 1M")
                } else {
                    report.append("\(route.model.id): no usable \(route.providerTag) row (HTTP \(status)); the bench's price stays")
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
