// RenderProbe.swift — the visual truth XCUITest can't see.
//
// XCUITest reports the *accessibility tree*: an element exists, is hittable, has a label.
// It cannot tell you whether a PDF/scan actually drew, whether a thumbnail is blank, or
// whether a view rendered the wrong colour. This helper renders a SwiftUI view or a
// `CGImage` to real pixels, computes pixel-level statistics, and exposes guards that fail
// on exactly that class of "exists but renders blank" bug — headlessly, in the unit bundle,
// with no app launch and no TCC/Accessibility prompt.
//
// Rendered PNGs are also written to an artifact directory (and attached to the .xcresult) so
// a session — or the owner — can open the actual pixels and eyeball them.

import XCTest
import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Pixel statistics

/// Pixel-level summary of a rendered bitmap. Cheap, deterministic, machine-independent.
struct PixelStats {
    let width: Int
    let height: Int
    var pixelCount: Int { width * height }

    /// Fraction of pixels that are NOT near-white and NOT transparent. ~0 ⇒ a blank white page.
    let nonWhiteFraction: Double
    /// Mean Rec.709 luminance over all pixels, 0 (black) … 1 (white). Transparent pixels count as 0.
    let meanLuminance: Double
    /// Fraction of fully-transparent pixels.
    let transparentFraction: Double
    /// Luminance range (max − min) over opaque pixels, 0 … 1. ~0 ⇒ a *uniform field* — one flat
    /// colour (white, grey, or black) with nothing meaningful drawn, regardless of that colour.
    let luminanceSpread: Double

    /// True when the render is effectively blank. A render is "blank" two ways:
    ///  • near-white / transparent (`nonWhiteFraction` ≈ 0), or
    ///  • a *uniform field of any single colour* (`luminanceSpread` ≈ 0) — the "blank grey/black
    ///    rectangle" placeholder that is 100% non-white yet drew nothing meaningful.
    /// This is the "the PDF/thumbnail/view didn't actually draw" failure mode the accessibility
    /// tree is blind to.
    func isEffectivelyBlank(nonWhiteThreshold: Double = 0.01, uniformEpsilon: Double = 0.03) -> Bool {
        nonWhiteFraction < nonWhiteThreshold || luminanceSpread < uniformEpsilon
    }

    /// Scan a `CGImage` into a known RGBA8 buffer and summarise it. The image is drawn into a
    /// fresh device-RGB, premultiplied-last context so byte order is always R,G,B,A — no
    /// dependence on the source image's own (often ambiguous) bitmap layout.
    static func from(cgImage: CGImage) -> PixelStats {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else {
            return PixelStats(width: 0, height: 0, nonWhiteFraction: 0, meanLuminance: 0,
                              transparentFraction: 0, luminanceSpread: 0)
        }
        let bytesPerRow = w * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs, bitmapInfo: info),
              let data = { () -> UnsafeMutableRawPointer? in
                  ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                  return ctx.data
              }() else {
            return PixelStats(width: w, height: h, nonWhiteFraction: 0, meanLuminance: 0,
                              transparentFraction: 0, luminanceSpread: 0)
        }

        let ptr = data.bindMemory(to: UInt8.self, capacity: h * bytesPerRow)
        var nonWhite = 0
        var transparent = 0
        var opaque = 0
        var lumSum = 0.0
        var minLum = 1.0
        var maxLum = 0.0
        for y in 0..<h {
            let row = y * bytesPerRow
            for x in 0..<w {
                let o = row + x * 4
                let r = ptr[o], g = ptr[o + 1], b = ptr[o + 2], a = ptr[o + 3]
                if a == 0 { transparent += 1; continue }
                opaque += 1
                if !(r > 250 && g > 250 && b > 250) { nonWhite += 1 }
                let lum = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0
                lumSum += lum
                if lum < minLum { minLum = lum }
                if lum > maxLum { maxLum = lum }
            }
        }
        let count = Double(w * h)
        return PixelStats(
            width: w, height: h,
            nonWhiteFraction: Double(nonWhite) / count,
            meanLuminance: lumSum / count,
            transparentFraction: Double(transparent) / count,
            luminanceSpread: opaque > 0 ? (maxLum - minLum) : 0
        )
    }
}

// MARK: - Rendering + artifacts

/// Pure render/decode/write functions. No XCTest state — see the `XCTestCase` guards below.
enum RenderProbe {

    /// Render a SwiftUI view to PNG data at a fixed point size (the general "see this view" path).
    /// Runs on the main actor — `ImageRenderer` is `@MainActor`.
    @MainActor
    static func pngData(from view: some View, size: CGSize, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return pngData(from: cg)
    }

    /// Render the real AppKit view used by a table cell. Kept separate from the SwiftUI overload so a
    /// test cannot accidentally prove that a look-alike SwiftUI label draws while the NSTableCell does not.
    @MainActor
    static func pngData(fromAppKitView view: NSView, size: CGSize) -> Data? {
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Encode a `CGImage` to PNG data.
    static func pngData(from cgImage: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Decode PNG (or any ImageIO-readable) data to a `CGImage`.
    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Where rendered artifacts land. Override with `ARCHIVE_TEST_ARTIFACT_DIR` to point a
    /// session at a path it will `Read` (e.g. the scratchpad); otherwise a stable temp subdir.
    static func artifactDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["ARCHIVE_TEST_ARTIFACT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveReaderTestArtifacts", isDirectory: true)
    }
}

// MARK: - Guards (XCTestCase-attached, so failures blame the caller's line)

extension XCTestCase {

    /// Write PNG data to the artifact directory, attach it to the .xcresult, and log its path.
    @discardableResult
    func writeRenderArtifact(_ data: Data, named name: String,
                             file: StaticString = #filePath, line: UInt = #line) -> URL? {
        let dir = RenderProbe.artifactDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            print("ARTIFACT \(name): \(url.path)")   // grep "ARTIFACT " in test logs to find + Read the pixels
            let att = XCTAttachment(data: data, uniformTypeIdentifier: UTType.png.identifier)
            att.name = name
            att.lifetime = .keepAlways
            add(att)
            return url
        } catch {
            XCTFail("failed to write render artifact \(name): \(error)", file: file, line: line)
            return nil
        }
    }

    /// Assert a rendered image actually drew something — the guard XCUITest cannot express.
    /// Returns the stats so callers can add tighter, content-specific assertions.
    @discardableResult
    func assertRendersNonBlank(_ cgImage: CGImage?, _ name: String,
                               nonWhiteThreshold: Double = 0.01,
                               file: StaticString = #filePath, line: UInt = #line) -> PixelStats? {
        guard let cgImage else {
            XCTFail("\(name): no image was produced (render returned nil)", file: file, line: line)
            return nil
        }
        let stats = PixelStats.from(cgImage: cgImage)
        XCTAssertFalse(
            stats.isEffectivelyBlank(nonWhiteThreshold: nonWhiteThreshold),
            "\(name) rendered effectively blank — nonWhite=\(String(format: "%.4f", stats.nonWhiteFraction)) "
            + "transparent=\(String(format: "%.4f", stats.transparentFraction)) "
            + "meanLuminance=\(String(format: "%.3f", stats.meanLuminance)). "
            + "The accessibility tree would still report this element as present.",
            file: file, line: line
        )
        return stats
    }
}
