import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Detects the clockwise correction in {0, 90, 180, 270} using local Vision recognition.
/// The accurate recognizer reads text in all four turns and reports character boxes in the
/// supplied image's frame. First-to-last character direction therefore gives both axis and flip
/// in one pass, without the fast recognizer's unreliable axis choice. Assumes left-to-right text.
/// Returns nil without a clear reading direction; callers keep the OCR model's rotation guess.
enum RotationDetector {
    private static let maxPixelSize = 1000
    private static let minTextScore: Float = 0.30
    // Mixed-axis pages need a clear dominant direction, not a residual from opposing vectors.
    private static let minDirectionShare: Float = 0.80

    // Blocking Vision work stays off Swift's cooperative pool. The width also bounds a segment's
    // concurrent page requests (W40.fix-processor-rotation-deadlock).
    private static let visionQueue = VisionQueue(name: "ArchiveProcessor.RotationDetector.vision", width: 4)

    static func detectCorrection(imageURL: URL) async -> Int? {
        // W49.proc-vision-page-cache: the agreement rule and the comparative route's fallback both ask; one pass answers.
        // A page that did not load or a request that threw is not kept: the next stage tries again, as before.
        let pass: Pass = await PageVisionCache.shared.value(PageVisionCache.key(imageURL, profile: profile),
                                                            keeps: { $0 != .failed }) {
            guard let image = downscaledCGImage(from: imageURL) else { return .failed }
            return await visionQueue.run { correction(cgImage: image) }
        }
        if case .read(let correction) = pass { return correction }
        return nil
    }

    private enum Pass: Sendable, Equatable {
        case read(Int?)
        case failed
    }

    /// The pass's request settings, for the shared cache.
    static let profile = "rotation|\(maxPixelSize)|accurate|corrected|0.015"

    private static func correction(cgImage: CGImage) -> Pass {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.015
        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request])
        } catch { return .failed }
        return .read(correction(PageVisionSnapshot(observations: request.results ?? [], width: cgImage.width,
                                             height: cgImage.height, characterBoxes: true)))
    }

    /// The correction a pass's lines vote for, or nil without a clear reading direction.
    static func correction(_ snapshot: PageVisionSnapshot) -> Int? {
        var votes = [Float](repeating: 0, count: 4)
        for line in snapshot.lines {
            guard line.confidence > 0, let a = line.firstCharacter, let b = line.lastCharacter else { continue }
            // Vision normalizes x and y independently. Restore pixels before comparing axes on
            // nonsquare pages. Missing/single-character/coincident boxes cannot establish direction.
            let dx = (b.midX - a.midX) * CGFloat(snapshot.width)
            let dy = (b.midY - a.midY) * CGFloat(snapshot.height)
            guard dx.isFinite, dy.isFinite, hypot(dx, dy) > 0 else { continue }
            // y points up: right → 0 CW, up → 90 CW, left → 180 CW, down → 270 CW.
            let quarter = (Int((atan2(dy, dx) / (.pi / 2)).rounded()) + 4) % 4
            votes[quarter] += line.confidence * Float(line.text.count)
        }
        let total = votes.reduce(0, +)
        guard total >= minTextScore, let best = votes.indices.max(by: { votes[$0] < votes[$1] }),
              votes[best] >= total * minDirectionShare else { return nil }
        return best * 90
    }

    /// Apply EXIF once while decoding, then pass .up to Vision in the displayed image's frame.
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
