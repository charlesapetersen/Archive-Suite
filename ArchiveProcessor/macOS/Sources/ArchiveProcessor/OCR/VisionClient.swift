import Foundation
import Vision
import ImageIO
import Darwin

/// The operator-controlled, on-device Vision recognition settings. These are deliberately a value type:
/// a run snapshots them at launch so changing Settings cannot alter an interrupted run when it resumes.
struct VisionOCRSettings: Codable, Equatable, Sendable {
    /// Empty when the user chose none: Vision then detects each page's language itself (W49.proc-vision-language-auto).
    var languages: [String]
    var usesFastRecognition: Bool
    var minimumConfidence: Float
    var customWords: [String]

    static let `default` = VisionOCRSettings(
        languages: ["en-US"], usesFastRecognition: false, minimumConfidence: 0.0, customWords: [])

    /// An unset key is the default, en-US; a field the user emptied is no language chosen, so detection.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> VisionOCRSettings {
        let languages = defaults.string(forKey: DefaultsKeys.visionLanguages)?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? Self.default.languages
        let words = defaults.string(forKey: DefaultsKeys.visionCustomVocabulary)?
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let rawConfidence = defaults.object(forKey: DefaultsKeys.visionMinimumConfidence) as? Double
        return VisionOCRSettings(
            languages: languages,
            usesFastRecognition: defaults.bool(forKey: DefaultsKeys.visionFastRecognition),
            minimumConfidence: Float(min(1, max(0, rawConfidence ?? 0))),
            customWords: words)
    }

    var isValid: Bool {
        languages.allSatisfy { !$0.isEmpty && !$0.contains("\n") }
            && minimumConfidence.isFinite && (0...1).contains(minimumConfidence)
            && customWords.allSatisfy { !$0.isEmpty && !$0.contains("\n") }
    }
}

/// Local, no-network OCR via macOS Vision. It is intentionally transcription-only: Vision returns no
/// document class, date, segment, or Finder tags. Those optional judgement paths remain disabled until
/// the separate Vision+LLM hybrid backend exists.
struct VisionClient: Sendable {
    let settings: VisionOCRSettings
    var rotationDegrees: Int = 0

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
        return try await Self.visionQueue.run {
            try Self.transcribe(imageURL: imageURL, settings: settings, rotationDegrees: rotationDegrees)
        }
    }

    /// The blocking Vision pass runs off the cooperative pool (W40.fix-processor-rotation-deadlock): a detached task
    /// still runs there, and the cascade's second reader calls this inside page task groups sized by the worker count.
    private static let visionQueue = VisionQueue(name: "ArchiveProcessor.VisionClient.vision", width: recommendedConcurrency)

    private static func transcribe(imageURL: URL, settings: VisionOCRSettings, rotationDegrees: Int) throws -> OCRResult {
        guard settings.isValid else {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision OCR settings are invalid.", errorCode: "vision_settings")
        }
        let image: CGImage
        let orientation: CGImagePropertyOrientation
        if rotationDegrees % 360 == 0 {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OCRError.imageLoadFailed
            }
            image = decoded
            orientation = storedOrientation(of: source)
        } else {
            // The run's clockwise correction is measured after EXIF, as for the label's model image.
            guard let oriented = ImageEncoding.orientedCGImage(url: imageURL),
                  let turned = ImageEncoding.rotate(oriented, byDegreesClockwise: rotationDegrees) else {
                throw OCRError.imageLoadFailed
            }
            image = turned
            orientation = .up
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = settings.usesFastRecognition ? .fast : .accurate
        request.usesLanguageCorrection = !settings.usesFastRecognition
        // Match VisionOCRKit's Recogniser: let Vision detect the language when the list is empty.
        if !settings.languages.isEmpty { request.recognitionLanguages = settings.languages }
        request.automaticallyDetectsLanguage = settings.languages.isEmpty
        request.customWords = settings.customWords

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision could not read this image: \(error.localizedDescription)",
                             errorCode: "vision_request_failed")
        }

        let kept = (request.results ?? []).compactMap { observation -> (text: String, confidence: Float)? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= settings.minimumConfidence else { return nil }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : (line, candidate.confidence)
        }
        let lines = kept.map(\.text)
        guard !lines.isEmpty else {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision found no text meeting the confidence threshold.",
                             errorCode: "vision_no_text")
        }
        // Vision has no document-classification channel. The normal call path concurrently derives any
        // selected local rotation correction and replaces this neutral orientation before output is written.
        // W46.post-read-quality-flag: Vision's own confidence says whether this reading probably went wrong.
        return OCRResult(text: lines.joined(separator: "\n"), classification: nil,
                         rotationDegrees: 0, errorMessage: nil, errorCode: nil,
                         readPoorly: ReadQualityFlag.applies(to: settings) ? ReadQualityFlag.assess(kept) : nil)
    }

    /// The first image's EXIF/TIFF orientation, `.up` when it is absent or out of range.
    private static func storedOrientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }
}
