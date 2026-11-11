import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// W46.rotation-default: the app's RotationLCNet (the bundled PP-LCNet Core ML model) on a page list, each upright
// page turned 0/90/180/270 clockwise in memory, as rotation_vision.swift turns them for RotationDetector. The list's
// images are read-only; each turn is written to a scratch JPEG only while it is measured. One JSON line per turn.
//   rotation-lcnet-headless MODEL.mlmodelc LIST.tsv   (lines: id<TAB>path to the upright image)
@main
struct RotationLCNetDriver {
    static func rotated(_ image: CGImage, clockwise: Int) -> CGImage {
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

    static func main() async throws {
        setbuf(stdout, nil)
        RotationLCNet.modelURLOverride = URL(fileURLWithPath: CommandLine.arguments[1])
        guard RotationLCNet.isAvailable else { FileHandle.standardError.write(Data("model did not load\n".utf8)); exit(2) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let list = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        for line in list.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard f.count == 2 else { continue }
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: f[1]) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("{\"id\":\"\(f[0])\",\"error\":\"decode\"}"); continue
            }
            for deg in [0, 90, 180, 270] {
                let copy = scratch.appendingPathComponent("turn.jpg")
                guard let dest = CGImageDestinationCreateWithURL(copy as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw NSError(domain: "scratch destination", code: 1) }
                CGImageDestinationAddImage(dest, rotated(image, clockwise: deg),
                                           [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "scratch write", code: 1) }
                let t = Date()
                let found = await RotationLCNet.detectCorrection(imageURL: copy)
                let s = Date().timeIntervalSince(t)
                print("{\"id\":\"\(f[0])\",\"turn\":\(deg),\"found\":\(found.map(String.init) ?? "null"),\"seconds\":\(String(format: "%.3f", s))}")
            }
        }
    }
}
