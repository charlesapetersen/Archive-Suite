import Foundation
import Vision
import ImageIO
import Darwin

/// The operator-controlled, on-device Vision recognition settings. These are deliberately a value type:
/// a run snapshots them at launch so changing Settings cannot alter an interrupted run when it resumes.
struct VisionOCRSettings: Codable, Equatable, Sendable {
    var languages: [String]
    var usesFastRecognition: Bool
    var minimumConfidence: Float
    var customWords: [String]

    static let `default` = VisionOCRSettings(
        languages: ["en-US"], usesFastRecognition: false, minimumConfidence: 0.0, customWords: [])

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> VisionOCRSettings {
        let languages = defaults.string(forKey: DefaultsKeys.visionLanguages)?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let words = defaults.string(forKey: DefaultsKeys.visionCustomVocabulary)?
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let rawConfidence = defaults.object(forKey: DefaultsKeys.visionMinimumConfidence) as? Double
        return VisionOCRSettings(
            languages: languages.isEmpty ? Self.default.languages : languages,
            usesFastRecognition: defaults.bool(forKey: DefaultsKeys.visionFastRecognition),
            minimumConfidence: Float(min(1, max(0, rawConfidence ?? 0))),
            customWords: words)
    }

    var isValid: Bool {
        !languages.isEmpty
            && languages.allSatisfy { !$0.isEmpty && !$0.contains("\n") }
            && minimumConfidence.isFinite && (0...1).contains(minimumConfidence)
            && customWords.allSatisfy { !$0.isEmpty && !$0.contains("\n") }
    }
}

/// Local, no-network OCR via macOS Vision. It is intentionally transcription-only: Vision returns no
/// document class, date, segment, or Finder tags. Those optional judgement paths remain disabled until
/// the separate Vision+LLM hybrid backend exists.
struct VisionClient {
    let settings: VisionOCRSettings

    /// Vision work is CPU-bound rather than HTTP/rate limited. Apple Silicon exposes performance cores as
    /// perflevel0; Intel and unusual hosts fall back to the active logical processor count. Never return
    /// zero — an unavailable sysctl must reduce parallelism safely, not prevent OCR from starting.
    static var recommendedConcurrency: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return Int(cores)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    func ocr(
        imageURL: URL,
        previousText: String? = nil,
        previousImageURL: URL? = nil,
        customPrompt: String? = nil,
        imageScale: Double = 1.0
    ) async throws -> OCRResult {
        // The shared client shape deliberately accepts the LLM-only context/prompt/scale arguments. Vision
        // has no prompt or multi-image context channel and reads the original image to retain small text.
        _ = (previousText, previousImageURL, customPrompt, imageScale)
        let settings = settings
        return try await Task.detached(priority: .userInitiated) {
            try Self.transcribe(imageURL: imageURL, settings: settings)
        }.value
    }

    private static func transcribe(imageURL: URL, settings: VisionOCRSettings) throws -> OCRResult {
        guard settings.isValid else {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision OCR settings are invalid.", errorCode: "vision_settings")
        }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.imageLoadFailed
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = settings.usesFastRecognition ? .fast : .accurate
        request.usesLanguageCorrection = !settings.usesFastRecognition
        request.recognitionLanguages = settings.languages
        request.customWords = settings.customWords

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision could not read this image: \(error.localizedDescription)",
                             errorCode: "vision_request_failed")
        }

        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= settings.minimumConfidence else { return nil }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        guard !lines.isEmpty else {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision found no text meeting the confidence threshold.",
                             errorCode: "vision_no_text")
        }
        // Vision has no document-classification channel. The normal call path concurrently derives any
        // selected local rotation correction and replaces this neutral orientation before output is written.
        return OCRResult(text: lines.joined(separator: "\n"), classification: nil,
                         rotationDegrees: 0, errorMessage: nil, errorCode: nil)
    }
}
