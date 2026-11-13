import CoreGraphics
import Foundation
import Vision

/// W42.int-s5 — the reading copy's one geometry step: straightening (`01-reading-copy.md` §3, switch
/// `straightenReadingCopy`, on by default). A page whose lines slope by a median of 1 degree or more is turned level
/// after reading, on a canvas that holds all of it, so nothing is cropped and every mark stays; the image page shows
/// that copy and its layer is read on it. No crop, no dewarp, no shading correction (owner, 2026-11-06).
///
/// The angle is the bench's (`scripts/segbench/place_geom.py` `page_angle`): the median slope of the bottom edges of
/// Vision's lines at least a quarter of the page wide; 0 when there are none. The 1 degree trigger is
/// `place-geom-real5.md`'s: below it a turn changes nothing (−0.1, −1.5 to +1.2), above it more lines select on 162 of
/// 229 skewed images.
enum ReadingCopy {
    /// The trigger, in degrees of median line slope.
    static let straightenThreshold = 1.0
    /// Lines narrower than this share of the page are not counted: a short line's slope is mostly noise.
    static let minimumLineWidth = 0.25
    /// The longest side the angle is measured at: enough for Vision to find a page's lines, and fast.
    static let measureSide = 1600

    /// The median slope of `image`'s lines in degrees: positive when a line falls to the right (y down, as the bench
    /// measures). nil when Vision fails or finds no line wide enough to count. Synchronous: call it off the main thread.
    static func lineAngle(of image: CGImage) -> Double? {
        let small = downscaled(image, longSide: measureSide) ?? image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: small, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let (w, h) = (Double(small.width), Double(small.height))
        let slopes: [Double] = (request.results ?? []).compactMap { o in
            // Vision's points are normalised with a bottom-left origin; the bench's y runs down.
            let (l, r) = (o.bottomLeft, o.bottomRight)
            let dx = Double(r.x - l.x), dy = -Double(r.y - l.y)
            guard dx >= minimumLineWidth else { return nil }
            return atan2(dy * h, dx * w) * 180 / .pi
        }
        return median(slopes)
    }

    /// `image` turned level by `degrees` (as `lineAngle` gives it) about its centre, on a white canvas that holds all of
    /// it. nil when the turn cannot be drawn.
    static func straightened(_ image: CGImage, by degrees: Double) -> CGImage? {
        // y down, a line falling to the right is turned back by −degrees; in CoreGraphics' y-up space that is +degrees.
        let t = degrees * .pi / 180
        let (w, h) = (Double(image.width), Double(image.height))
        let (c, s) = (abs(cos(t)), abs(sin(t)))
        let ow = Int((w * c + h * s).rounded(.up)), oh = Int((w * s + h * c).rounded(.up))
        let space = image.colorSpace?.model == .monochrome ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = space.model == .monochrome ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard ow > 0, oh > 0,
              let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: ow, height: oh))
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: CGFloat(t))
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// The turn a page needs, in degrees, or nil when it is level enough to leave.
    static func straighteningTurn(for image: CGImage) -> Double? {
        guard let a = lineAngle(of: image), abs(a) >= straightenThreshold else { return nil }
        return a
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func downscaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > longSide else { return image }
        let k = Double(longSide) / Double(long)
        let (w, h) = (max(1, Int(Double(image.width) * k)), max(1, Int(Double(image.height) * k)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
