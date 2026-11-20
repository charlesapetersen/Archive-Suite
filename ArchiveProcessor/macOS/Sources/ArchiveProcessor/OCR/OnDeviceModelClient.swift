import Foundation
import CoreGraphics
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

/// W47.wh-readers-lost-clients — the macOS 27 on-device model (`SystemLanguageModel`) as a page reader, as the bench
/// read the owner's 96 with it (`segbench/fm_ocr.swift`, `r1-foundation.md`): the same instructions and request, greedy
/// sampling, a fresh session per page, guardrails `permissiveContentTransformations` (the stock one refused an owner
/// page), replies capped at 4,096 tokens, on this Mac only (Private Cloud Compute is never called). A lower-scoring
/// reader (owner call 15): 42.4 NES strict on the 96 against Apple Vision's 83.1, so it is never a default or a pick.
///
/// The loop stop: a third of the 96 loop until the cap (about 80 s a page). The stream is cut as soon as the reply's
/// tail repeats (`isLooping`), and the page fails as cut off, as a page reaching the cap fails on every client
/// (`OCRResult.cutOff`): the bench scored those pages empty, so the figure the row shows is the one this gives.
struct OnDeviceModelClient: Sendable {
    static let modelID = "apple-fm-27"
    static let instructions = """
    You are an OCR engine. Transcribe all the text on the page image exactly as written, \
    line by line, in reading order. Keep the original spelling, capitalisation and punctuation. \
    Do not summarise, translate, correct or explain. Output only the transcription.
    """
    static let ask = "Transcribe this page."
    static let cap = 4096

    /// One page at a time: the model is one on this Mac, and parallel sessions only queue behind it.
    private static let limiter = RequestLimiter(limit: 1)

    /// Whether this Mac can run it now (macOS 27 with Apple Intelligence on and the model downloaded).
    static var isAvailable: Bool { unavailableReason == nil }

    /// Why it cannot run here, in the user's words; nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            switch SystemLanguageModel(guardrails: .permissiveContentTransformations).availability {
            case .available: return nil
            case .unavailable(let why): return "The macOS on-device model is not available on this Mac (\(why))."
            @unknown default: return "The macOS on-device model is not available on this Mac."
            }
        }
        #endif
        return "The macOS on-device model needs macOS 27."
    }

    func ocr(imageURL: URL) async throws -> OCRResult {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            try await Self.limiter.acquire()
            defer { Task { await Self.limiter.release() } }
            return try await Self.read(imageURL: imageURL)
        }
        #endif
        return Self.unavailable(Self.unavailableReason ?? "")
    }

    static func unavailable(_ message: String) -> OCRResult {
        OCRResult(text: nil, classification: nil, errorMessage: message, errorCode: "fm_unavailable")
    }

    #if canImport(FoundationModels)
    @available(macOS 27.0, *)
    private static func read(imageURL: URL) async throws -> OCRResult {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard case .available = model.availability else { return unavailable(unavailableReason ?? "") }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw OCRError.imageLoadFailed }
        let attachment = Attachment(image)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cap)
        var text = ""
        var checkedAt = 0
        var outputTokens = 0
        do {
            let stream = session.streamResponse(options: options) { ask; attachment }
            for try await snapshot in stream {
                text = snapshot.content
                outputTokens = snapshot.usage.output.totalTokenCount
                // Checked every 40 characters, as the stop was measured (`isLooping`).
                if text.count - checkedAt >= 40 {
                    checkedAt = text.count
                    if isLooping(text) { return .cutOff }
                }
            }
        } catch let error as LanguageModelError {
            return failure(error)
        }
        if outputTokens >= cap || isLooping(text) { return .cutOff }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return OCRResult(text: nil, classification: nil, errorMessage: "The on-device model read no text on this page.",
                             errorCode: "fm_no_text")
        }
        return OCRResult(text: trimmed, classification: nil, errorMessage: nil, errorCode: nil)
    }

    @available(macOS 27.0, *)
    private static func failure(_ error: LanguageModelError) -> OCRResult {
        let code: String
        switch error {
        case .guardrailViolation: code = "fm_guardrail"
        case .refusal: code = "fm_refusal"
        case .contextSizeExceeded: code = "fm_context"
        // Another app holding the model, or a slow start: the request got no reading (`OCRFailureCode.requestFailed`).
        case .rateLimited: code = "fm_rate_limited_error"
        case .timeout: code = "fm_timeout_error"
        default: code = "fm_model"
        }
        return OCRResult(text: nil, classification: nil,
                         errorMessage: "The on-device model could not read this page: \(error.localizedDescription)",
                         errorCode: code)
    }
    #endif

    /// The loop stop: the reply's tail is one stretch of at most 200 characters repeated at least three times, over at
    /// least 400 characters. On the bench's own replies (the 96, and the 100 Latin pages of `r1-foundation.md`) it fires
    /// on 88 of the 90 that reached the cap, about 93% of the way before it, and on no reading that finished, but one
    /// Latin page whose reply was itself a loop ("of the of the …") ending just under the cap. The two it misses (a
    /// counting run, a paraphrase that drifts) still stop at the cap.
    static func isLooping(_ text: String) -> Bool {
        let t = Array(text.unicodeScalars)
        let n = t.count
        guard n >= 400 else { return false }
        for p in 1...min(200, n / 3) {
            var k = 1
            while (k + 1) * p <= n, t[(n - (k + 1) * p)..<(n - k * p)].elementsEqual(t[(n - p)..<n]) { k += 1 }
            if k >= 3, k * p >= 400 { return true }
        }
        return false
    }
}
