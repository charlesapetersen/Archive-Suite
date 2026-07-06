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
///     chosen axis resolves the flip (upright reads as real words, inverted does not).
///
/// Everything runs on a single downscaled (~1000px) CGImage; passes run in parallel.
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

    static func detectCorrection(imageURL: URL) async -> Int? {
        guard let cgImage = downscaledCGImage(from: imageURL) else { return nil }

        // Stage 1: fast pass in all four orientations (parallel) → choose the text axis.
        let fast: [Int: Float] = await withTaskGroup(of: (Int, Float).self) { group in
            for corr in [0, 90, 180, 270] {
                group.addTask { (corr, score(cgImage: cgImage, orientation: orientationFor[corr]!, level: .fast, languageCorrection: false)) }
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
                group.addTask { (corr, score(cgImage: cgImage, orientation: orientationFor[corr]!, level: .accurate, languageCorrection: true)) }
            }
            var out: [Int: Float] = [:]
            for await (corr, s) in group { out[corr] = s }
            return out
        }

        return (accurate[axis[0]] ?? 0) >= (accurate[axis[1]] ?? 0) ? axis[0] : axis[1]
    }

    // MARK: - Scoring

    /// One Vision text-recognition pass at the given orientation. For the fast pass the score
    /// is Σ(confidence); for the accurate pass it is Σ(confidence × recognized-length), which
    /// rewards the orientation that reads real words.
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
                total += candidate.confidence * Float(candidate.string.count)
            } else {
                total += candidate.confidence
            }
        }
        // Small per-observation nudge (fast pass only) breaks ties toward more text lines.
        return level == .fast ? total + Float(observations.count) * 0.001 : total
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
