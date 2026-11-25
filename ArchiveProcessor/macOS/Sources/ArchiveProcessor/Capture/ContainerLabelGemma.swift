import Foundation
import ArchiveCore

/// W47.ct-capture-gemma — Gemma 3 12B on a server on this Mac, for a label's repository, collection title, collection
/// number and date where the gateway is off or is itself a local model (owner, 2026-11-13: "GPT 5.6 Luna on the
/// gateway, else Gemma 3 12B"; `SPEC/containers.md` §A value and its source). Read as `ct_read.py` ran it: the same
/// prompt (`ContainerLabelReader.localModelPrompt`), the upright photo, temperature 0, a 640-token cap.
///
/// Measured there (`segbench-results/ct-read.md`, 4-bit MLX on the 18 GB M3 Pro): a median 14.93 s a label photo,
/// 8.04 GB at its peak. See `segbench-results/ct-gemma-route-fields.md` for paired accuracy by field through
/// mlx-vlm's server using the app's JPEG encoder. The external route needs a server on this Mac that lists Gemma
/// (`find`): the gateway's own address when it
/// is a local model, else the three presets' (`LocalModelRoute.Server`): only addresses on this Mac, though a server
/// there that forwards to the cloud (a proxy) cannot be told apart. If no external server answers, the app can
/// use the reader downloaded with the operator's consent.
enum ContainerLabelGemma {
    /// The name each server lists it under: the measured MLX build, and the other servers' usual names for the same model.
    static let ids: [LocalModelRoute.Server: String] = [
        .mlxVLM: "mlx-community/gemma-3-12b-it-4bit", .ollama: "gemma3:12b", .lmStudio: "google/gemma-3-12b",
    ]
    /// `ct_read.py` `MAX_TOKENS`: its replies are one short JSON object.
    static let maxTokens = 640
    /// Twice the slowest of its 192 photos there would be about 40 s; a first call also loads the model (about 8 GB).
    static let timeout: TimeInterval = 180
    /// For Process Files' status line: the median a label through mlx-vlm's server with this request (`segbench-results/ct-gemma-route.md`, 60 photos).
    static let secondsPerLabel = 13.04
    static let imageLongSide = 1600
    /// How long a found (or missing) server is remembered, so a run of labels asks the servers once.
    static let rememberFor: TimeInterval = 120

    /// The server's model list (`GET /models`). A seam for the headless contract, which answers it without a server.
    /// `LocalModelRoute.listModels` does not go through `NetworkSession`, so while a headless driver's no-wire seam is
    /// active it lists nothing rather than reach a real server on this Mac.
    nonisolated(unsafe) static var listModels: @Sendable (String) async throws -> [String] = {
        NetworkSession.testTransportIsActive ? [] : try await LocalModelRoute.listModels(baseURL: $0)
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
    /// it, then a listed name that is plainly Gemma 3 12B instruction-tuned (an Ollama tag such as `gemma3:12b-it-qat`,
    /// or mlx-vlm's snapshot path for a cached build with no `main` ref). Never a cloud tag (Ollama lists its
    /// `…-cloud` models beside the local ones, and those calls leave the Mac) or a base `-pt` model. nil if none.
    static func pick(from listed: [String]) -> String? {
        let known = ([.mlxVLM, .ollama, .lmStudio] as [LocalModelRoute.Server]).compactMap { ids[$0] }
        if let id = known.first(where: listed.contains) { return id }
        return listed.first { id in
            let s = id.lowercased()
            guard s.contains("gemma-3-12b") || s.contains("gemma3:12b") else { return false }
            return !s.contains("cloud") && !s.contains("-pt")
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
        /// A call to the found server failed: treat it as no server for the rest of the window.
        func failed(_ key: [String], now: Date) { if found?.key == key, found?.server != nil { found = (key, nil, now) } }
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

    /// W49.proc-gemma-request-verify — the external request. `current` (the default) sends the photo re-encoded and
    /// before the prompt. `revised` sends the prompt first and the photo file itself when it needs no turn or scaling,
    /// else the same re-encoding: the change `ct-gemma-route-fields.md` measured on already upright photos. Kept behind
    /// a defaults key (`-containerLabelGemmaRequest revised` at launch) while it is verified; the owner sets the default.
    enum RequestStyle: String, Sendable { case current, revised }
    /// For the verification driver, which compares both in one process.
    nonisolated(unsafe) static var styleOverride: RequestStyle?
    static var style: RequestStyle {
        styleOverride ?? UserDefaults.standard.string(forKey: DefaultsKeys.containerLabelGemmaRequest)
            .flatMap(RequestStyle.init(rawValue:)) ?? .current
    }

    /// The upright photo the external request carries.
    static func image(photo: URL, rotation: Int, style: RequestStyle) -> Data? {
        if style == .revised,
           let source = ImageEncoding.sourceJPEGIfUpright(url: photo, rotationDegrees: rotation, longEdge: imageLongSide) {
            return source
        }
        return ImageEncoding.uprightJPEG(url: photo, rotationDegrees: rotation, longEdge: imageLongSide)
    }

    /// The chat request for one upright label photo.
    static func request(jpeg: Data, server: Server, style: RequestStyle = .current) -> URLRequest? {
        let image: [String: Any] = ["type": "image_url",
                                    "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]
        let text: [String: Any] = ["type": "text", "text": ContainerLabelReader.localModelPrompt]
        var body: [String: Any] = [
            "model": server.modelID, "temperature": 0, "max_tokens": maxTokens, "stream": false,
            "messages": [["role": "user", "content": style == .revised ? [text, image] : [image, text]]],
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

    /// Check the external servers first, then the reader the operator downloaded in this app.
    @MainActor
    static func prepare(gateway: GatewayConfig?) async -> Bool {
        if await find(gateway: gateway) != nil { return true }
        ManagedGemma.shared.offerIfNeeded()
        return ManagedGemma.shared.installed
    }

    /// A failed external request suppresses that address for the rest of the lookup window.
    /// The app-managed reader keeps the re-encoded photo under either style.
    static func read(photo: URL, rotation: Int, gateway: GatewayConfig?) async -> [ContainerField: String]? {
        let style = style
        let source = style == .revised
            ? ImageEncoding.sourceJPEGIfUpright(url: photo, rotationDegrees: rotation, longEdge: imageLongSide) : nil
        var encoded = source == nil
            ? ImageEncoding.uprightJPEG(url: photo, rotationDegrees: rotation, longEdge: imageLongSide) : nil
        guard let sent = source ?? encoded else { return nil }
        if let server = await find(gateway: gateway) {
            if let answer = await readExternal(jpeg: sent, server: server, gateway: gateway, style: style) {
                let fields = ContainerLabelReader.localModelFields(fromReply: answer)
                if !fields.isEmpty { return fields }
            }
        } else {
            await ManagedGemma.shared.offerIfNeeded()
        }
        if encoded == nil {
            encoded = ImageEncoding.uprightJPEG(url: photo, rotationDegrees: rotation, longEdge: imageLongSide)
        }
        guard !Task.isCancelled, let encoded, let answer = await ManagedGemma.shared.read(jpeg: encoded) else { return nil }
        let fields = ContainerLabelReader.localModelFields(fromReply: answer)
        return fields.isEmpty ? nil : fields
    }

    private static func readExternal(jpeg: Data, server: Server, gateway: GatewayConfig?,
                                     style: RequestStyle) async -> String? {
        guard let request = request(jpeg: jpeg, server: server, style: style) else { return nil }
        guard let (data, response) = try? await NetworkSession.data(for: request, policy: .nonIdempotent, maxRetries: 0),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            if !Task.isCancelled { await memory.failed(candidates(gateway: gateway), now: Date()) }
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first else { return nil }
        return LocalModelRoute.textAnswer((choice["message"] as? [String: Any])?["content"] as? String,
                                          finish: choice["finish_reason"] as? String)
    }
}
