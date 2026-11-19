import Foundation
import ArchiveCore

/// W47.ct-capture-gemma — Gemma 3 12B on a server on this Mac, for a label's repository, collection title, collection
/// number and date where the gateway is off or is itself a local model (owner, 2026-11-13: "GPT 5.6 Luna on the
/// gateway, else Gemma 3 12B"; `SPEC/containers.md` §A value and its source). Read as `ct_read.py` ran it: the same
/// prompt (`ContainerLabelReader.localModelPrompt`), the upright photo, temperature 0, a 640-token cap.
///
/// Measured there (`segbench-results/ct-read.md`, 4-bit MLX on the 18 GB M3 Pro): a median 14.93 s a label photo,
/// 8.04 GB at its peak. It is used only when a server on this Mac lists it (`find`): the gateway's own address when it
/// is a local model, else the three presets' (`LocalModelRoute.Server`). Nothing is sent anywhere else, and with no
/// server answering the card proposes the parser's values, as before.
enum ContainerLabelGemma {
    /// The name each server lists it under: the measured MLX build, and the other servers' usual names for the same model.
    static let ids: [LocalModelRoute.Server: String] = [
        .mlxVLM: "mlx-community/gemma-3-12b-it-4bit", .ollama: "gemma3:12b", .lmStudio: "google/gemma-3-12b",
    ]
    /// `ct_read.py` `MAX_TOKENS`: its replies are one short JSON object.
    static let maxTokens = 640
    /// Twice the slowest of its 192 photos there would be about 40 s; a first call also loads the model (about 8 GB).
    static let timeout: TimeInterval = 180
    /// The measured median, for the operator (Settings) and the run's status line.
    static let secondsPerLabel = 14.93
    static let imageLongSide = 1600
    /// How long a found (or missing) server is remembered, so a run of labels asks the servers once.
    static let rememberFor: TimeInterval = 120

    /// The server's model list (`GET /models`). A seam for the headless contract, which answers it without a server.
    nonisolated(unsafe) static var listModels: @Sendable (String) async throws -> [String] = {
        try await LocalModelRoute.listModels(baseURL: $0)
    }

    struct Server: Equatable, Sendable {
        let baseURL: String
        let modelID: String
    }

    /// The addresses to ask, in order: the gateway's when it is a local model on this Mac, then the presets'.
    static func candidates(gateway: GatewayConfig?) -> [String] {
        var out: [String] = []
        if let gateway, gateway.isLocalModel, LocalModelRoute.isLoopback(gateway.baseURL) {
            out.append(GatewayConfig.normalizedBaseURL(gateway.baseURL))
        }
        for server in LocalModelRoute.Server.allCases where !out.contains(server.baseURL) { out.append(server.baseURL) }
        return out
    }

    /// The model ID to ask for among those a server lists: the measured build first, then any other server's name for
    /// it, then a listed name that is plainly Gemma 3 12B (an Ollama tag such as `gemma3:12b-it-qat`). nil if none.
    static func pick(from listed: [String]) -> String? {
        let known = ([.mlxVLM, .ollama, .lmStudio] as [LocalModelRoute.Server]).compactMap { ids[$0] }
        if let id = known.first(where: listed.contains) { return id }
        return listed.first { id in
            let s = id.lowercased()
            return s.contains("gemma-3-12b") || s.contains("gemma3:12b")
        }
    }

    private actor Memory {
        var found: (key: [String], server: Server?, at: Date)?
        func get(_ key: [String], now: Date) -> Server?? {
            guard let found, found.key == key, now.timeIntervalSince(found.at) < rememberFor else { return nil }
            return .some(found.server)
        }
        func set(_ key: [String], _ server: Server?, now: Date) { found = (key, server, now) }
        func clear() { found = nil }
    }
    private static let memory = Memory()

    /// The first server on this Mac that lists Gemma 3 12B, or nil. Remembered for `rememberFor`.
    static func find(gateway: GatewayConfig?) async -> Server? {
        let key = candidates(gateway: gateway)
        if let known = await memory.get(key, now: Date()) { return known }
        var found: Server?
        for baseURL in key {
            guard let listed = try? await listModels(baseURL), let id = pick(from: listed) else { continue }
            found = Server(baseURL: baseURL, modelID: id)
            break
        }
        await memory.set(key, found, now: Date())
        return found
    }

    /// Forgets the server found, for the contract's cases.
    static func forget() async { await memory.clear() }

    /// The chat request for one upright label photo.
    static func request(jpeg: Data, server: Server) -> URLRequest? {
        var body: [String: Any] = [
            "model": server.modelID, "temperature": 0, "max_tokens": maxTokens, "stream": false,
            "messages": [["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                ["type": "text", "text": ContainerLabelReader.localModelPrompt],
            ] as [[String: Any]]]],
        ]
        LocalModelRoute.applyReasoningOff(&body)
        guard let url = URL(string: "\(server.baseURL)/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(LocalModelRoute.placeholderKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        return request
    }

    /// Gemma's fields for the photo (its four only, `ContainerLabelReader.localModelFields`), or nil when no server
    /// lists it or the call fails, is cut at its cap, or gives none of them.
    static func read(photo: URL, rotation: Int, gateway: GatewayConfig?) async -> [ContainerField: String]? {
        guard let server = await find(gateway: gateway),
              let jpeg = ImageEncoding.uprightJPEG(url: photo, rotationDegrees: rotation, longEdge: imageLongSide),
              let request = request(jpeg: jpeg, server: server),
              let (data, response) = try? await NetworkSession.data(for: request, policy: .nonIdempotent, maxRetries: 0),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let answer = LocalModelRoute.textAnswer((choice["message"] as? [String: Any])?["content"] as? String,
                                                      finish: choice["finish_reason"] as? String) else { return nil }
        let fields = ContainerLabelReader.localModelFields(fromReply: answer)
        return fields.isEmpty ? nil : fields
    }
}
