import Foundation

/// W41.app-openrouter-unmeasured — OpenRouter's model listing (`GET /api/v1/models`, no key), so an OpenRouter key can
/// run any image-reading model the user prefers, not only the pinned routes the bench measured (owner, 2026-11-18:
/// "The user should be able to run any models they prefer via OpenRouter"). Every model the listing says takes an
/// image and returns text, at a price it lists, is offered after the pinned routes, marked not measured; a model id
/// the user typed (`CustomModelStore`, provider OpenRouter) is offered at the listing's price, or unpriced when the
/// listing has none. Such a model has no provider pinned (`OpenRouterRoute.unpinned`): OpenRouter picks the upstream,
/// every request says `data_collection: "deny"`, and its `max_price` is the price the estimate showed.
///
/// Read with the endpoint prices (`OpenRouterPrices`), when the OpenRouter models show in Settings or a run is set up
/// with an OpenRouter key: at most once a day, a failed attempt waits an hour, one request with no retries. Kept in
/// UserDefaults so the next launch's model list has it.
enum OpenRouterListing {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let name: String
        /// Dollars per million tokens; nil when the listing gives no usable price (a router's `-1`, a missing field).
        let inputPer1M: Double?
        let outputPer1M: Double?
        /// The listing names `reasoning` among the model's supported parameters.
        let reasons: Bool

        var priced: Bool { inputPer1M != nil && outputPer1M != nil }
    }

    struct Stored: Codable, Equatable, Sendable {
        let entries: [Entry]
        let fetched: Date
    }

    static let defaultsKey = "openRouterModelListing"
    static let attemptKey = "openRouterModelListingAttempted"
    static let maxAge: TimeInterval = 24 * 3600
    static let retryAfter: TimeInterval = 3600
    static let url = "\(OpenAICompatibleClient.openRouterBaseURL)/models"

    /// The listing's models that take an image and return text, in its order. Nil when the reply is not a listing.
    static func parse(_ data: Data) -> [Entry]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let arch = row["architecture"] as? [String: Any],
                  (arch["input_modalities"] as? [String])?.contains("image") == true,
                  (arch["output_modalities"] as? [String])?.contains("text") == true else { return nil }
            let pricing = row["pricing"] as? [String: Any]
            var input = perMillion(pricing?["prompt"]), output = perMillion(pricing?["completion"])
            // A charge per image or per request is one the estimate does not count and `max_price` does not cap, so a
            // model with one is not priced here (offered only typed, as unpriced).
            let extra = ["image", "request"].contains { key in
                pricing?[key] != nil && perMillion(pricing?[key]).map { $0 > 0 } != false
            }
            if input == nil || output == nil || extra { input = nil; output = nil }
            let params = row["supported_parameters"] as? [String] ?? []
            return Entry(id: id, name: (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                         inputPer1M: input, outputPer1M: output, reasons: params.contains("reasoning"))
        }
    }

    /// Dollars per token as the listing's string ("0.0000002"), per million; nil for a negative (a router's "-1"),
    /// non-finite, unreadable or missing price. Zero is a price (a free model).
    private static func perMillion(_ value: Any?) -> Double? {
        guard let perToken = (value as? String).flatMap(Double.init) ?? (value as? Double),
              perToken.isFinite, perToken >= 0 else { return nil }
        // Rounded to a millionth of a dollar per million tokens: the string's float noise is not a price.
        return (perToken * 1_000_000 * 1_000_000).rounded() / 1_000_000
    }

    static func stored(_ defaults: UserDefaults = .standard) -> Stored? {
        // A no-wire test checks the catalog: what a real launch read earlier must not leak into it.
        if defaults === UserDefaults.standard, NetworkSession.testTransportIsActive { return testListing }
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        // The model list is read on every Settings render: decode a listing once, not a few hundred entries a render.
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache, cached.data == data { return cached.listing }
        let listing = try? JSONDecoder().decode(Stored.self, from: data)
        cache = (data, listing)
        return listing
    }

    /// The no-wire tests' listing and typed ids, read in place of UserDefaults while the test transport is active.
    nonisolated(unsafe) static var testListing: Stored?
    nonisolated(unsafe) static var testTyped: [LLMModel] = []

    /// The OpenRouter ids the user typed (`CustomModelStore`), as stored.
    static func typedModels() -> [LLMModel] {
        NetworkSession.testTransportIsActive ? testTyped : CustomModelStore.shared.models(for: .openrouter)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (data: Data, listing: Stored?)?
    nonisolated(unsafe) private static var builtModels: (listing: Stored, models: [LLMModel])?

    static func store(_ listing: Stored, _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(listing) { defaults.set(data, forKey: defaultsKey) }
    }

    /// The listing's entry for `id`, if it lists that model as reading images.
    static func entry(_ id: String, in listing: Stored? = nil) -> Entry? {
        (listing ?? stored())?.entries.first { $0.id == id }
    }

    /// The picker's unmeasured models: every priced image model the listing has that no pinned route already offers,
    /// marked not measured, at the listing's price, with no batch discount.
    static func unmeasuredModels(_ listing: Stored? = nil) -> [LLMModel] {
        guard let listing = listing ?? stored() else { return [] }
        // Built once per listing: the model list is read on every render.
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let built = builtModels, built.listing == listing { return built.models }
        let pinned = Set(OpenRouterRoute.catalog.map(\.model.id))
        var seen = Set<String>()
        let models = listing.entries.compactMap { e -> LLMModel? in
            guard e.priced, !pinned.contains(e.id), seen.insert(e.id).inserted else { return nil }
            return model(e.id, name: e.name, entry: e)
        }
        builtModels = (listing, models)
        return models
    }

    /// A typed model id (`CustomModelStore`), at the listing's price when it lists one, else unpriced (no estimate, no
    /// price ceiling: `LLMModel.unpriced`, fixed here, so a listing read during the run cannot change the ceiling).
    static func typed(_ custom: LLMModel, _ listing: Stored? = nil) -> LLMModel {
        let e = entry(custom.id, in: listing)
        let base = custom.displayName == custom.id ? (e?.name ?? custom.id) : custom.displayName
        return model(custom.id, name: base, entry: e?.priced == true ? e : nil, reasons: custom.supportsThinking)
    }

    private static func model(_ id: String, name: String, entry: Entry?, reasons: Bool = false) -> LLMModel {
        LLMModel(id: id, displayName: "\(name) (not measured)", provider: .openrouter,
                 supportsThinking: entry?.reasons ?? reasons, returnsMd: false,
                 inputCostPer1M: entry?.inputPer1M ?? 0, outputCostPer1M: entry?.outputPer1M ?? 0, batchDiscount: 1,
                 unpriced: entry == nil ? true : nil)
    }

    /// Reads the listing when the stored one is missing or older than a day (always when `force`). Returns a line for
    /// logs and the live check.
    @discardableResult
    static func refreshIfStale(force: Bool = false, defaults: UserDefaults = .standard) async -> String? {
        if !force, let have = stored(defaults), Date().timeIntervalSince(have.fetched) < maxAge { return nil }
        if !force, let tried = defaults.object(forKey: attemptKey) as? Date,
           Date().timeIntervalSince(tried) < retryAfter { return nil }
        defaults.set(Date(), forKey: attemptKey)
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        let line: String
        do {
            // `.nonIdempotent` is the no-retry policy: an unanswered listing waits for the next attempt.
            let (data, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let entries = parse(data), !entries.isEmpty {
                store(Stored(entries: entries, fetched: Date()), defaults)
                line = "listing: \(entries.count) image models, \(entries.filter(\.priced).count) priced"
            } else {
                line = "listing: no usable reply (HTTP \(status)); the stored listing stays"
            }
        } catch {
            line = "listing: \(error.localizedDescription); the stored listing stays"
        }
        NSLog("[OpenRouter] \(line)")
        return line
    }

    /// Both OpenRouter readings a run's estimate rests on: the pinned routes' endpoint prices and this listing.
    static func refreshAllIfStale() async {
        await OpenRouterPrices.refreshIfStale()
        await refreshIfStale()
    }
}
