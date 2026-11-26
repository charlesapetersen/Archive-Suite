import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// W49.proc-vision-page-cache — compiled with the REAL PageVisionCache, VisionClient and RotationDetector by
// test-vision-page-cache.sh. It checks that a repeated Vision pass over the same unchanged page file is answered by
// the first one (also while it is still running), that a changed file, another turn or other request settings read
// again, and that the cached readings are the ones an uncached Vision request gives.

enum DocumentClassification: Sendable {}

struct OCRResult: Sendable {
    var text: String?
    var classification: DocumentClassification?
    var rotationDegrees: Int?
    var errorMessage: String?
    var errorCode: String?
    var readPoorly: ReadQualityFlag? = nil
}

enum OCRError: Error { case imageLoadFailed }

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@main
struct VisionPageCacheHeadlessDriver {
    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APVisionPageCache-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) { results.append("\(condition ? "PASS" : "FAIL"): \(name)") }

        // MARK: The cache itself
        let cache = PageVisionCache(capacity: 2)
        let file = root.appendingPathComponent("page.png")
        check("fixture page writes", makePNG(text: "ARCHIVE PAGE CACHE ALPHA", at: file))
        let calls = Counter()
        let key = PageVisionCache.key(file, profile: "test")
        check("an existing file has a key", key != nil)
        check("a missing file has none (its pass runs uncached)",
              PageVisionCache.key(root.appendingPathComponent("missing.png"), profile: "test") == nil)
        check("a turn of 360 is the same key as none", PageVisionCache.key(file, rotation: 360, profile: "test") == key)
        check("a turn of -90 is the key of 270",
              PageVisionCache.key(file, rotation: -90, profile: "test") == PageVisionCache.key(file, rotation: 270, profile: "test"))

        // Eight callers at once: one pass, joined by the rest while it runs.
        let answers = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await cache.value(key) { () async -> Int in
                        calls.bump()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        return 7
                    }
                }
            }
            var all: [Int] = []
            for await a in group { all.append(a) }
            return all
        }
        check("eight concurrent callers get the one answer", answers == Array(repeating: 7, count: 8))
        check("eight concurrent callers ran the pass once", calls.value == 1)
        check("the statistics count one pass and seven reuses",
              cache.statistics == PageVisionCache.Counts(computed: 1, reused: 7))
        let again = await cache.value(key) { () async -> Int in calls.bump(); return 8 }
        check("a later caller is answered from the finished pass", again == 7 && calls.value == 1)

        // A nil answer is an answer.
        let nilKey = PageVisionCache.key(file, profile: "nil")
        let first: Int? = await cache.value(nilKey) { () async -> Int? in calls.bump(); return nil }
        let second: Int? = await cache.value(nilKey) { () async -> Int? in calls.bump(); return 1 }
        check("a nil answer is kept", first == nil && second == nil && calls.value == 2)

        // A result the caller says not to keep is not kept.
        let failKey = PageVisionCache.key(file, profile: "fail")
        _ = await cache.value(failKey, keeps: { $0 > 0 }) { () async -> Int in calls.bump(); return 0 }
        let retried = await cache.value(failKey, keeps: { $0 > 0 }) { () async -> Int in calls.bump(); return 5 }
        check("a result not to be kept is asked again", retried == 5 && calls.value == 4)

        // Capacity 2: the third entry pushes out the oldest (the "test" key).
        let evicted = await cache.value(key) { () async -> Int in calls.bump(); return 9 }
        check("the oldest entry goes once the cache is full", evicted == 9 && calls.value == 5)

        // A rewritten file is a new key, even at the same path.
        check("fixture page rewrites", makePNG(text: "ARCHIVE PAGE CACHE BRAVO, A LONGER LINE", at: file))
        check("a rewritten file has another key", PageVisionCache.key(file, profile: "test") != key)

        // MARK: VisionClient through the shared cache
        PageVisionCache.shared.removeAll()
        let page = root.appendingPathComponent("vision.png")
        check("Vision fixture writes", makePNG(text: "ARCHIVE VISION CACHE CHARLIE", at: page))
        let strict = VisionOCRSettings(languages: ["en-US"], usesFastRecognition: false, minimumConfidence: 1.0,
                                       customWords: [])
        do {
            let a = try await VisionClient(settings: .default).ocr(imageURL: page)
            let b = try await VisionClient(settings: .default).ocr(imageURL: page)
            check("the default reading finds the token", (a.text ?? "").uppercased().contains("CHARLIE"))
            check("a second default reading is the same", a.text == b.text && a.errorCode == b.errorCode)
            check("the second default reading reused the first pass",
                  PageVisionCache.shared.statistics == PageVisionCache.Counts(computed: 1, reused: 1))
            let filtered = try await VisionClient(settings: strict).ocr(imageURL: page)
            check("another confidence floor reuses the pass", PageVisionCache.shared.statistics.computed == 1)
            check("and applies its own floor", filtered.text == nil || filtered.text == a.text)
            let fast = try await VisionClient(settings: VisionOCRSettings(
                languages: ["en-US"], usesFastRecognition: true, minimumConfidence: 0, customWords: [])).ocr(imageURL: page)
            _ = fast
            check("fast recognition is its own pass", PageVisionCache.shared.statistics.computed == 2)
            _ = try await VisionClient(settings: .default, rotationDegrees: 90).ocr(imageURL: page)
            check("another turn is its own pass", PageVisionCache.shared.statistics.computed == 3)

            // The cached reading is what an uncached Vision request gives.
            check("the reading is an uncached request's", a.text == reference(page))
        } catch {
            check("VisionClient does not throw (\(error))", false)
        }
        do {
            _ = try await VisionClient(settings: .default).ocr(imageURL: root.appendingPathComponent("absent.png"))
            check("a missing page throws", false)
        } catch {
            check("a missing page still throws imageLoadFailed", (error as? OCRError) == .imageLoadFailed)
        }

        // MARK: RotationDetector through the shared cache, on the e2e fixtures turned four ways
        PageVisionCache.shared.removeAll()
        let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/e2e-fixtures")
        let jpgs = ((try? fm.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
        check("three fixture pages", jpgs.count == 3)
        var right = 0, total = 0
        for jpg in jpgs {
            for deg in [0, 90, 180, 270] {
                let out = root.appendingPathComponent("\(jpg.deletingPathExtension().lastPathComponent)-\(deg).jpg")
                guard turned(jpg, clockwise: deg, to: out) else { check("\(out.lastPathComponent) writes", false); continue }
                let once = await RotationDetector.detectCorrection(imageURL: out)
                let twice = await RotationDetector.detectCorrection(imageURL: out)
                total += 1
                // The page was turned `deg` clockwise; the correction turns it back.
                if once == (360 - deg) % 360, twice == once { right += 1 }
            }
        }
        check("every turned fixture gets its correction, twice (\(right)/\(total))", right == total && total == 12)
        check("each page's rotation pass ran once",
              PageVisionCache.shared.statistics == PageVisionCache.Counts(computed: total, reused: total))

        for r in results { print(r) }
        let failed = results.filter { $0.hasPrefix("FAIL") }.count
        print(failed == 0 ? "ALL PASS (\(results.count) checks)" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }

    /// The page read the way VisionClient read it before the cache: one request, default settings, lines joined.
    static func reference(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        request.customWords = []
        try? VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { o -> String? in
            guard let c = o.topCandidates(1).first else { return nil }
            let t = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func turned(_ url: URL, clockwise degrees: Int, to out: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        let quarter = degrees / 90 % 4
        let (w, h) = quarter % 2 == 0 ? (image.width, image.height) : (image.height, image.width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(quarter) * .pi / 2)   // clockwise in CoreGraphics' y-up space
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let turned = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, turned, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func makePNG(text: String, at url: URL) -> Bool {
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
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
