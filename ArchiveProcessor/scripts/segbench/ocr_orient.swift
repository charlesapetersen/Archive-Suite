// segbench page-orientation check: Apple Vision text recognition run on one image at each of the four turns, scored
// by the recognised characters weighted by confidence, so a page photographed sideways or upside down is found
// (W47.item-fields-owner-ok, 2026-11-05: the owner's label sheet showed 36 photos turned, because matching a JPEG
// to its PDF's orientation does not make it upright when the PDF is not).
// Usage: segbench-ocr-orient <images.txt>   one image path per line.
// Output, one line per image on stdout: "<path>\t<score up>\t<score right>\t<score down>\t<score left>", where
// right means the text reads upright once the image is turned 90 degrees clockwise. .fast recognition: the scores only rank
// the turns. Limit, measured 2026-11-05 on 627 pages: a sideways page with little text, often handwriting, scores
// too low to pick its direction (one was scored upside down), and .accurate is worse, since it reads some text at
// every turn. The sheet therefore turns only clear wins, takes eye-checked turns from a file, and lets the reader
// turn a page. Exit status 1 if any image failed.
import Foundation
import Vision
import ImageIO

func score(_ image: CGImage, _ o: CGImagePropertyOrientation) throws -> Double {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, orientation: o, options: [:]).perform([request])
    return (request.results ?? []).reduce(0.0) { acc, obs in
        guard let c = obs.topCandidates(1).first else { return acc }
        return acc + Double(c.confidence) * Double(c.string.count)
    }
}

guard CommandLine.arguments.count == 2,
      let list = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: segbench-ocr-orient <images.txt>\n".data(using: .utf8)!)
    exit(2)
}
var failed = false
// Vision's orientation names the image's own orientation: .right means the image must turn 90 degrees clockwise.
let turns: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
for path in list.split(separator: "\n").map(String.init) where !path.isEmpty {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("\(path): image load failed\n".data(using: .utf8)!)
        failed = true
        continue
    }
    do {
        let s = try turns.map { try score(image, $0) }
        print(([path] + s.map { String(format: "%.1f", $0) }).joined(separator: "\t"))
        fflush(stdout)
    } catch {
        FileHandle.standardError.write("\(path): \(error)\n".data(using: .utf8)!)
        failed = true
    }
}
exit(failed ? 1 : 0)
