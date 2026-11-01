import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// The production `VisionClient` returns these app-domain types. This intentionally minimal command-line
// host supplies their shape while compiling the REAL client source above — no SwiftUI app launch needed.
enum DocumentClassification: Sendable {}

struct OCRResult: Sendable {
    var text: String?
    var classification: DocumentClassification?
    var rotationDegrees: Int?
    var errorMessage: String?
    var errorCode: String?
}

enum OCRError: Error { case imageLoadFailed }

@main
struct VisionOCRHeadlessDriver {
    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APVisionOCR-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }
        func note(_ text: String) { results.append("NOTE: \(text)") }

        let texts = ["ARCHIVE VISION OCR ALPHA", "ARCHIVE VISION OCR BRAVO"]
        let imageURLs = texts.enumerated().map { index, _ in
            root.appendingPathComponent("vision-\(index + 1).png")
        }
        for (url, text) in zip(imageURLs, texts) {
            check("synthetic PNG \(url.lastPathComponent) writes", makePNG(text: text, at: url))
        }

        let settings = VisionOCRSettings(
            languages: ["en-US"], usesFastRecognition: false, minimumConfidence: 0,
            customWords: ["ARCHIVE", "VISION"])
        check("settings are valid", settings.isValid)
        check("settings survive Codable snapshot", roundTrips(settings))
        check("performance-core concurrency is positive", VisionClient.recommendedConcurrency > 0)

        let client = VisionClient(settings: settings)
        for (url, token) in zip(imageURLs, ["ALPHA", "BRAVO"]) {
            do {
                let result = try await client.ocr(imageURL: url)
                let normalized = (result.text ?? "").uppercased()
                check("\(url.lastPathComponent) returns its synthetic token", normalized.contains(token))
                check("\(url.lastPathComponent) returns no classification", result.classification == nil)
                check("\(url.lastPathComponent) returns neutral rotation", result.rotationDegrees == 0)
                check("\(url.lastPathComponent) has no OCR error", result.errorMessage == nil && result.errorCode == nil)
            } catch {
                check("\(url.lastPathComponent) does not throw", false)
                note("\(url.lastPathComponent) threw \(error.localizedDescription)")
            }
        }

        // W40.fix-processor-vision-ignores-exif: an iPhone shot stores its pixels as the sensor saw them and
        // says in EXIF how to turn them upright. Each JPEG below stores the page turned, tagged with the
        // orientation that puts it back; Vision must read the token as it does on the upright page.
        // Accurate recognition finds the turn of clean text on its own (measured 2026-11-01); fast
        // recognition, a Settings choice, reads mirrored garbage or nothing at all without the tag.
        for orientation: CGImagePropertyOrientation in [.up, .down, .right, .left] {
            let url = root.appendingPathComponent("vision-exif-\(orientation.rawValue).jpg")
            let token = "TAGGED\(orientation.rawValue)"
            check("synthetic JPEG \(url.lastPathComponent) writes",
                  makeJPEG(text: "ARCHIVE VISION OCR \(token)", orientation: orientation, at: url))
            for fast in [false, true] {
                var levelSettings = settings
                levelSettings.usesFastRecognition = fast
                let name = "\(url.lastPathComponent) (\(fast ? "fast" : "accurate"))"
                do {
                    let result = try await VisionClient(settings: levelSettings).ocr(imageURL: url)
                    let normalized = (result.text ?? "").uppercased().replacingOccurrences(of: " ", with: "")
                    check("\(name) (EXIF orientation \(orientation.rawValue)) returns its token upright",
                          normalized.contains(token))
                    if !normalized.contains(token) {
                        note("\(name) read \(result.text ?? "nil") / \(result.errorCode ?? "-")")
                    }
                } catch {
                    check("\(name) does not throw", false)
                    note("\(name) threw \(error.localizedDescription)")
                }
            }
        }

        let passed = !results.contains { $0.hasPrefix("FAIL") }
        print((passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n"))
        exit(passed ? 0 : 1)
    }

    private static func makePNG(text: String, at url: URL) -> Bool {
        let width = 1600, height = 440
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 82, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 72, y: 185)
        CTLineDraw(line, context)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Draws the upright page, then stores its pixels turned so that `orientation` is what puts them back
    /// upright, and tags the JPEG with it, as a camera does.
    private static func makeJPEG(text: String, orientation: CGImagePropertyOrientation, at url: URL) -> Bool {
        let staging = url.deletingPathExtension().appendingPathExtension("upright.png")
        guard makePNG(text: text, at: staging),
              let source = CGImageSourceCreateWithURL(staging as CFURL, nil),
              let upright = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let w = CGFloat(upright.width), h = CGFloat(upright.height)
        let quarterTurn = orientation == .right || orientation == .left
        let storedWidth = Int(quarterTurn ? h : w), storedHeight = Int(quarterTurn ? w : h)
        guard let context = CGContext(
            data: nil, width: storedWidth, height: storedHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        // CoreGraphics is y-up, so a positive angle turns the content counterclockwise.
        switch orientation {
        case .down:  // stored half a turn round
            context.translateBy(x: w, y: h); context.rotate(by: .pi)
        case .right: // stored a quarter turn counterclockwise; viewing turns it clockwise
            context.translateBy(x: h, y: 0); context.rotate(by: .pi / 2)
        case .left:  // stored a quarter turn clockwise
            context.translateBy(x: 0, y: w); context.rotate(by: -.pi / 2)
        default: break
        }
        context.draw(upright, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let stored = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { return false }
        CGImageDestinationAddImage(destination, stored, [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 0.95
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func roundTrips(_ settings: VisionOCRSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings),
              let restored = try? JSONDecoder().decode(VisionOCRSettings.self, from: data) else { return false }
        return restored == settings
    }
}
