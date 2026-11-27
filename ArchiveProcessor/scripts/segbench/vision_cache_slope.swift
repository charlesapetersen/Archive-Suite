import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// W49.proc-vision-page-cache — does the reading copy's straightening slope read the same from the Vision reader's own
// full-page pass (accurate, language correction, en-US) as from its separate 1,600-pixel pass (accurate, no
// correction)? Compiled with the REAL ReadingCopy, VisionClient and PageVisionCache by vision_cache_slope.sh.
// usage: vision_cache_slope <list.tsv: id<TAB>image> <out.tsv> <scratch dir>
// Each page is read as stored and turned by +2.5 and -4 degrees (written to the scratch dir, never beside the input).

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

@main
struct VisionCacheSlope {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count == 4 else { print("usage: vision_cache_slope <list.tsv> <out.tsv> <scratch>"); exit(2) }
        let list = (try? String(contentsOfFile: a[1], encoding: .utf8)) ?? ""
        let scratch = URL(fileURLWithPath: a[3], isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var rows = ["id\tdelta\town\tshared\town_s\tshared_s"]
        for line in list.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count >= 2, let upright = ImageEncoding.orientedCGImage(url: URL(fileURLWithPath: f[1])) else { continue }
            for delta in [0.0, 2.5, -4.0] {
                guard let img = delta == 0 ? upright : ReadingCopy.straightened(upright, by: -delta) else { continue }
                let url = scratch.appendingPathComponent("\(f[0])_\(delta).jpg")
                guard write(img, to: url), let page = ImageEncoding.orientedCGImage(url: url) else { continue }
                var t = Date()
                let own = await Task.detached { ReadingCopy.lineAngle(of: page) }.value
                let ownSeconds = Date().timeIntervalSince(t)
                t = Date()
                _ = try? await VisionClient(settings: .default).ocr(imageURL: url)
                let shared = VisionClient.finishedDefaultSnapshot(imageURL: url, rotationDegrees: 0)
                    .flatMap(ReadingCopy.lineAngle(of:))
                let sharedSeconds = Date().timeIntervalSince(t)
                func s(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
                rows.append("\(f[0])\t\(delta)\t\(s(own))\t\(s(shared))\t\(String(format: "%.2f", ownSeconds))\t\(String(format: "%.2f", sharedSeconds))")
                try? FileManager.default.removeItem(at: url)
            }
            print(f[0])
        }
        try? (rows.joined(separator: "\n") + "\n").write(toFile: a[2], atomically: true, encoding: .utf8)
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(d)
    }
}
