import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Detects the clockwise rotation needed to make an image's text upright, using local
/// macOS Vision text recognition. This is purely for *orientation scoring* — the actual
/// transcription still comes from the LLM.
///
/// Two-stage design (chosen after empirical testing on archive scans):
///   • Stage 1 — a `.fast` recognition pass in each of the 4 orientations reliably picks the
///     text *axis* (horizontal {0°,180°} vs vertical {90°,270°}) with large margins, but a
///     fast pass cannot tell upright from upside-down.
///   • Stage 2 — an `.accurate` + language-corrected pass on just the 2 orientations of the
///     chosen axis resolves the flip. The accurate recognizer orients text on its own, so both
///     passes read the same words with the same confidence (measured on the e2e fixtures,
///     W40.fix-processor-rotation-flip); what differs is the geometry. A line counts only when
///     its first character's box lies left of its last one in the orientation handed to Vision,
///     which holds for upright text and is reversed for text read upside-down.
///
/// Everything runs on a single downscaled (~1000px) CGImage; passes run in parallel on `visionQueue`.
/// Returns the best correction in {0, 90, 180, 270}, or `nil` when no orientation yields
/// confident text (caller falls back to the LLM's rotation guess).
enum RotationDetector {

    /// Max long-edge size of the downscaled image used for scoring. Orientation is obvious
    /// at low resolution, and downscaling is the single biggest speed win.
    private static let maxPixelSize = 1000

    /// Minimum total fast-pass score for the image to be considered to contain text.
    private static let minTextScore: Float = 0.30

    /// Maps a clockwise correction to the CGImagePropertyOrientation that, when handed to
    /// Vision, makes the text upright if that correction is the right one (EXIF semantics:
    /// .up=0°, .right=90° CW, .down=180°, .left=270° CW).
    private static let orientationFor: [Int: CGImagePropertyOrientation] =
        [0: .up, 90: .right, 180: .down, 270: .left]

    /// Every pass runs here, off the cooperative pool (W40.fix-processor-rotation-deadlock): run in a task group,
    /// four blocking passes per page and a segment's pages at once took every pool thread and hung. Four passes in
    /// flight keep a page's Stage 1 together without crowding the OCR work beside it.
    private static let visionQueue = VisionQueue(name: "ArchiveProcessor.RotationDetector.vision", width: 4)

    static func detectCorrection(imageURL: URL) async -> Int? {
        guard let cgImage = downscaledCGImage(from: imageURL) else { return nil }

        // Stage 1: fast pass in all four orientations (parallel) → choose the text axis.
        let fast: [Int: Float] = await withTaskGroup(of: (Int, Float).self) { group in
            for corr in [0, 90, 180, 270] {
                group.addTask { (corr, await queuedScore(cgImage: cgImage, orientation: orientationFor[corr]!, level: .fast, languageCorrection: false)) }
            }
            var out: [Int: Float] = [:]
            for await (corr, s) in group { out[corr] = s }
            return out
        }

        let horizontalTotal = (fast[0] ?? 0) + (fast[180] ?? 0)
        let verticalTotal = (fast[90] ?? 0) + (fast[270] ?? 0)
        guard (horizontalTotal + verticalTotal) >= minTextScore else { return nil }

        let axis = horizontalTotal >= verticalTotal ? [0, 180] : [90, 270]

        // Stage 2: accurate + language-corrected pass on the 2 axis orientations → resolve flip.
        let accurate: [Int: Float] = await withTaskGroup(of: (Int, Float).self) { group in
            for corr in axis {
                group.addTask { (corr, await queuedScore(cgImage: cgImage, orientation: orientationFor[corr]!, level: .accurate, languageCorrection: true)) }
            }
            var out: [Int: Float] = [:]
            for await (corr, s) in group { out[corr] = s }
            return out
        }

        return (accurate[axis[0]] ?? 0) >= (accurate[axis[1]] ?? 0) ? axis[0] : axis[1]
    }

    // MARK: - Scoring

    /// `score` on `visionQueue`, awaited without holding a cooperative-pool thread.
    private static func queuedScore(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        level: VNRequestTextRecognitionLevel,
        languageCorrection: Bool
    ) async -> Float {
        await visionQueue.run {
            score(cgImage: cgImage, orientation: orientation, level: level, languageCorrection: languageCorrection)
        }
    }

    /// One Vision text-recognition pass at the given orientation. For the fast pass the score
    /// is Σ(confidence); for the accurate pass it is Σ(confidence × recognized-length) over the
    /// lines that read left to right in this orientation (`readsForward`).
    private static func score(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        level: VNRequestTextRecognitionLevel,
        languageCorrection: Bool
    ) -> Float {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = languageCorrection
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return 0
        }

        guard let observations = request.results, !observations.isEmpty else { return 0 }

        var total: Float = 0
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            if level == .accurate {
                guard readsForward(candidate) else { continue }
                total += candidate.confidence * Float(candidate.string.count)
            } else {
                total += candidate.confidence
            }
        }
        // Small per-observation nudge (fast pass only) breaks ties toward more text lines.
        return level == .fast ? total + Float(observations.count) * 0.001 : total
    }

    /// Whether the line's first character sits left of its last in the oriented image. Vision's
    /// boxes are in the coordinates of the orientation it was given, so a line Vision turned over
    /// to read comes back with its characters running right to left. Assumes left-to-right scripts,
    /// which is the whole archive. Lines too short to tell count.
    private static func readsForward(_ candidate: VNRecognizedText) -> Bool {
        let text = candidate.string
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }),
              first < last,
              let a = try? candidate.boundingBox(for: first..<text.index(after: first)),
              let b = try? candidate.boundingBox(for: last..<text.index(after: last))
        else { return true }
        return a.boundingBox.midX < b.boundingBox.midX
    }

    // MARK: - Decoding

    /// Decode `imageURL` once as a downscaled CGImage (long edge ≤ maxPixelSize).
    private static func downscaledCGImage(from imageURL: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
