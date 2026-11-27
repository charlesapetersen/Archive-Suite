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
        guard settings.isValid else {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision OCR settings are invalid.", errorCode: "vision_settings")
        }
        // W49.proc-vision-page-cache: the cascade's word count, the read-poorly check and the Vision reader read the
        // same page at the same turn with the same settings; the first pass answers the others.
        let (settings, rotationDegrees) = (settings, rotationDegrees)
        let key = PageVisionCache.key(imageURL, rotation: rotationDegrees, profile: Self.profile(settings))
        let read: Read = await PageVisionCache.shared.value(key, keeps: { if case .snapshot = $0 { true } else { false } }) {
            do {
                return .snapshot(try await Self.visionQueue.run {
                    try Self.recognise(imageURL: imageURL, settings: settings, rotationDegrees: rotationDegrees)
                })
            } catch OCRError.imageLoadFailed {
                return .imageLoadFailed
            } catch {
                return .requestFailed(error.localizedDescription)
            }
        }
        switch read {
        case .snapshot(let snapshot): return Self.result(snapshot, settings: settings)
        case .imageLoadFailed: throw OCRError.imageLoadFailed
        case .requestFailed(let message):
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Apple Vision could not read this image: \(message)",
                             errorCode: "vision_request_failed")
        }
    }

    /// One pass's outcome, as the cache keeps it. Only a snapshot is kept; a failure is retried by the next stage.
    private enum Read: Sendable {
        case snapshot(PageVisionSnapshot)
        case imageLoadFailed
        case requestFailed(String)
    }

    /// The finished default-settings pass over `imageURL` at `rotationDegrees`, if a stage has already run it; never
    /// starts one. `scripts/segbench/vision_cache_slope.sh` reads the straightening slope from it. The reading copy
    /// keeps its own pass: read from this one, the straighten decision moved on 7 of 297 page images
    /// (`segbench-results/vision-page-cache-slope.md`).
    static func finishedDefaultSnapshot(imageURL: URL, rotationDegrees: Int) -> PageVisionSnapshot? {
        guard let key = PageVisionCache.key(imageURL, rotation: rotationDegrees, profile: profile(.default)),
              case .snapshot(let snapshot)? = PageVisionCache.shared.finished(key, as: Read.self) else { return nil }
        return snapshot
    }

    /// Every setting that changes what the request returns. The confidence floor filters afterwards, so it is not one.
    static func profile(_ settings: VisionOCRSettings) -> String {
        "transcription|\(settings.usesFastRecognition ? "fast" : "accurate")|\(settings.languages.joined(separator: ","))"
            + "|\(settings.customWords.joined(separator: "\u{1F}"))"
    }

    /// The blocking Vision pass runs off the cooperative pool (W40.fix-processor-rotation-deadlock): a detached task
    /// still runs there, and the cascade's second reader calls this inside page task groups sized by the worker count.
    private static let visionQueue = VisionQueue(name: "ArchiveProcessor.VisionClient.vision", width: recommendedConcurrency)

    private static func recognise(imageURL: URL, settings: VisionOCRSettings, rotationDegrees: Int) throws -> PageVisionSnapshot {
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
        try handler.perform([request])
        // Vision's boxes are in the frame of the image as `orientation` turns it upright; record that frame's size.
        let sideways = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        return PageVisionSnapshot(observations: request.results ?? [], width: sideways ? image.height : image.width,
                                  height: sideways ? image.width : image.height)
    }

    private static func result(_ snapshot: PageVisionSnapshot, settings: VisionOCRSettings) -> OCRResult {
        let kept = snapshot.lines.compactMap { line -> (text: String, confidence: Float)? in
            guard line.confidence >= settings.minimumConfidence else { return nil }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, line.confidence)
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
