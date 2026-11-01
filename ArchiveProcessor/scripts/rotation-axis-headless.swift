import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Compiled with the real RotationDetector. Synthetic fixtures use no window server, saved settings,
// network or corpus. Optional benchmark input is the frozen, upright *-original.jpg panel, read-only.
@main
struct RotationAxisHeadlessDriver {
    static func main() async throws {
        setbuf(stdout, nil)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        func write(_ image: CGImage, name: String, orientation: Int = 1) throws -> URL {
            let url = scratch.appendingPathComponent(name + ".jpg")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw NSError(domain: "fixture destination", code: 1) }
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "fixture write", code: 1) }
            return url
        }
        func page(lines: [String], fontSize: CGFloat = 22) -> CGImage {
            let c = CGContext(data: nil, width: 740, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 740, height: 1000))
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            let font = CTFontCreateWithName("Courier" as CFString, fontSize, nil)
            for (i, line) in lines.enumerated() {
                c.textPosition = CGPoint(x: 40, y: 940 - CGFloat(i) * (fontSize + 8))
                CTLineDraw(CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, line as CFString,
                           [kCTFontAttributeName: font] as CFDictionary)!), c)
            }
            return c.makeImage()!
        }
        func rotated(_ image: CGImage, clockwise: Int) -> CGImage {
            let swap = clockwise % 180 != 0
            let w = swap ? image.height : image.width, h = swap ? image.width : image.height
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            c.rotate(by: -CGFloat(clockwise) * .pi / 180)
            c.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                    width: CGFloat(image.width), height: CGFloat(image.height)))
            return c.makeImage()!
        }

        if CommandLine.arguments.count > 1 {
            let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let originals = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("-original.jpg") &&
                    !["p086", "p094", "p096"].contains($0.lastPathComponent.components(separatedBy: "-")[0]) }
                .sorted { $0.path < $1.path }
            guard originals.count == 96 else { print("FAIL: expected all 96 frozen originals, found \(originals.count)"); exit(1) }
            var exact = 0, wrongAxis = 0, flipped = 0, abstained = 0
            let started = Date()
            for (i, url) in originals.enumerated() {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    print("FAIL: cannot decode benchmark page \(i + 1)"); exit(1)
                }
                // Only one page's generated rotations live at once; originals stay read-only.
                for deg in [0, 90, 180, 270] {
                    let copy = try write(rotated(image, clockwise: deg), name: "benchmark")
                    let found = await RotationDetector.detectCorrection(imageURL: copy)
                    let want = (360 - deg) % 360
                    if found == want { exact += 1 }
                    else if let found {
                        if found % 180 != want % 180 { wrongAxis += 1 } else { flipped += 1 }
                    } else { abstained += 1 }
                    print("page=\(i + 1),source=\(url.deletingPathExtension().lastPathComponent),turn=\(deg),want=\(want),found=\(found.map(String.init) ?? "nil")")
                }
            }
            // Measurement only: retain every miss and abstention in the denominator.
            print("TOTAL pages=96 turns=384 exact=\(exact) wrongAxis=\(wrongAxis) flipped=\(flipped) nil=\(abstained) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
            return
        }

        var failures = 0
        func check(_ label: String, _ actual: Int?, _ expected: Int?) {
            let ok = actual == expected
            print("\(ok ? "PASS" : "FAIL"): \(label): \(actual.map(String.init) ?? "nil"), expected \(expected.map(String.init) ?? "nil")")
            if !ok { failures += 1 }
        }
        let fixtures: [(String, CGImage, Bool)] = [
            ("prose", page(lines: ["ARCHIVE ROTATION REGRESSION", "A letter from the historical archive.",
                                  "Please keep these pages in order.", "The reading direction determines rotation.",
                                  "Small numbers alone must not choose an axis.", "Thank you for your careful attention."]), true),
            ("table", page(lines: ["Annual accounts: amounts and entries"] +
                           (1...20).map { "Account \($0 + 10)   123   456   789   234" }), true),
            // Identical numeric columns can be read in competing directions. Abstain rather
            // than asserting that the synthetic drawing's order is visible to the recognizer.
            ("numeric-grid", page(lines: (1...20).map { "\($0 + 10)   123   456   789   234   567" }), false),
            ("dense", page(lines: (1...30).map { "Line \($0): A dense typescript with small print." }, fontSize: 18), true)
        ]
        for (name, image, directional) in fixtures {
            for deg in [0, 90, 180, 270] {
                let url = try write(rotated(image, clockwise: deg), name: "\(name)-\(deg)")
                check("\(name) physical \(deg)", await RotationDetector.detectCorrection(imageURL: url), directional ? (360 - deg) % 360 : nil)
            }
        }
        // Two copies of exactly the same text, one on each axis: neither is a reliable
        // whole-page correction. A fast-axis winner or an unconditional max vote invents one.
        let mixed = CGContext(data: nil, width: 1000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        mixed.setFillColor(CGColor(gray: 1, alpha: 1)); mixed.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let block = fixtures[0].1.cropping(to: CGRect(x: 0, y: 0, width: 740, height: 350))!
        mixed.draw(block, in: CGRect(x: 0, y: 0, width: 740, height: 350))
        mixed.draw(rotated(block, clockwise: 90), in: CGRect(x: 650, y: 260, width: 350, height: 740))
        let mixedURL = try write(mixed.makeImage()!, name: "mixed")
        check("competing axes abstain", await RotationDetector.detectCorrection(imageURL: mixedURL), nil)
        for (exif, correction) in [(1, 0), (6, 270), (3, 180), (8, 90)] {
            let url = try write(fixtures[0].1, name: "exif-\(exif)", orientation: exif)
            check("EXIF \(exif) applied once", await RotationDetector.detectCorrection(imageURL: url), correction)
        }
        let blank = try write(page(lines: []), name: "blank")
        check("blank abstains", await RotationDetector.detectCorrection(imageURL: blank), nil)
        let short = try write(page(lines: ["I"]), name: "single-character")
        check("single character has no reading direction", await RotationDetector.detectCorrection(imageURL: short), nil)
        let corrupt = scratch.appendingPathComponent("corrupt.jpg")
        try Data("not an image".utf8).write(to: corrupt)
        check("unreadable input abstains", await RotationDetector.detectCorrection(imageURL: corrupt), nil)
        check("missing input abstains", await RotationDetector.detectCorrection(imageURL: scratch.appendingPathComponent("absent.jpg")), nil)
        print(failures == 0 ? "ALL PASS" : "SOME FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
