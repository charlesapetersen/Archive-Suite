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

    private static func roundTrips(_ settings: VisionOCRSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings),
              let restored = try? JSONDecoder().decode(VisionOCRSettings.self, from: data) else { return false }
        return restored == settings
    }
}
