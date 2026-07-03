import Foundation
import ImageIO
import CoreGraphics

/// Shared image→JPEG encoding used by every OCR provider client (single-shot and batch).
/// Centralizes the downscale math and JPEG parameters so all providers upload byte-identical images.
enum ImageEncoding {
    /// Long-edge cap (px) for images sent to OCR APIs (~3 MP). Vision LLMs downsample internally,
    /// so larger just wastes memory/CPU/bandwidth — and full-resolution phone photos otherwise
    /// beachball the app while decoding. The PDF page-1 image and the archived original are produced
    /// separately (PDFGenerator / dual-output copy) and are unaffected. Tunable.
    static let maxOCRDimension = 2048

    /// Load an image as JPEG for upload — efficiently. Reads dimensions from the file header and
    /// decodes straight to the target long edge (honoring EXIF orientation) via a thumbnail request,
    /// so the full-resolution bitmap is never materialized. `scale` (0–1) applies the user's
    /// resolution setting; the result is then capped at `maxOCRDimension`. Never upscales.
    static func loadImageAsJPEG(url: URL, scale: Double = 1.0) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceType = CGImageSourceGetType(source) as? String
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let pixelW = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelH = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxDim = max(pixelW, pixelH)

        // Apply the optional user scale, then cap for OCR. Never upscale.
        let scaledDim = (scale > 0 && scale < 1.0) ? Int(Double(maxDim) * scale) : maxDim
        let target = maxDim > 0 ? min(scaledDim, maxOCRDimension) : maxOCRDimension

        // Fast path: an already-small JPEG with normal orientation → send raw bytes, no decode.
        if sourceType == "public.jpeg" && orientation == 1 && maxDim > 0 && target >= maxDim {
            return try? Data(contentsOf: url)
        }

        // Decode directly to the target long edge — the thumbnail path avoids the full-res buffer
        // and bakes in orientation via kCGImageSourceCreateThumbnailWithTransform.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return try? Data(contentsOf: url)   // fallback: raw bytes
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Target-size JPEG encoding (independent of the OCR cap)
    //
    // Used to size the PDF-embedded image and the separately-exported image to their OWN target-MB
    // settings — deliberately NOT reusing loadImageAsJPEG / maxOCRDimension (that is the LLM/OCR path).
    // Never upscales; already-small inputs are returned/copied untouched.

    /// Encode a CGImage to JPEG, downscaling toward `targetMB` (0 or negative = no limit / full size).
    /// Uses a single sqrt(target/actual) area→dimension estimate, matching the OCR path's math.
    /// Returns the JPEG bytes plus the final pixel dimensions (needed for PDF embedding).
    static func encodeToTargetMB(_ image: CGImage, targetMB: Double, quality: Double = 0.9) -> (data: Data, width: Int, height: Int)? {
        guard let full = encodeJPEGData(image, quality: quality) else { return nil }
        let targetBytes = targetMB * 1_000_000
        if targetMB <= 0 || Double(full.count) <= targetBytes {
            return (full, image.width, image.height)
        }
        // JPEG size grows ~linearly with pixel AREA, so the linear scale is the square root.
        let ratio = (targetBytes / Double(full.count)).squareRoot()
        let newLong = max(1, Int((Double(max(image.width, image.height)) * ratio).rounded()))
        guard let small = scaled(image, longEdge: newLong),
              let data = encodeJPEGData(small, quality: quality) else {
            return (full, image.width, image.height)
        }
        return (data, small.width, small.height)
    }

    /// Write the image at `url` to `dest` as a JPEG of ~`targetMB`. A normal-orientation JPEG that is
    /// already at/under the target is copied byte-for-byte (pristine, no re-encode); everything else is
    /// decoded (EXIF orientation baked in) and re-encoded toward the target. `dest` should be a `.jpg`.
    @discardableResult
    static func writeSizedJPEG(from url: URL, to dest: URL, targetMB: Double, quality: Double = 0.9) -> Bool {
        let fm = FileManager.default
        if targetMB > 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let type = CGImageSourceGetType(src) as? String
            let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
            let fileSize = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? Int.max
            if type == "public.jpeg", orientation == 1, Double(fileSize) <= targetMB * 1_000_000 {
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: url, to: dest)) != nil { return true }
            }
        }
        guard let img = orientedCGImage(url: url),
              let enc = encodeToTargetMB(img, targetMB: targetMB, quality: quality) else { return false }
        try? fm.removeItem(at: dest)
        do { try enc.data.write(to: dest); return true } catch { return false }
    }

    /// Decode `url` to a full-resolution, EXIF-oriented CGImage (orientation baked into the pixels).
    static func orientedCGImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(w, h) > 0 ? max(w, h) : 100_000,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func encodeJPEGData(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Downscale a CGImage so its long edge is `longEdge` px (never upscales).
    private static func scaled(_ image: CGImage, longEdge: Int) -> CGImage? {
        let w = image.width, h = image.height
        let maxDim = max(w, h)
        guard longEdge > 0, maxDim > longEdge else { return image }
        let ratio = Double(longEdge) / Double(maxDim)
        let nw = max(1, Int((Double(w) * ratio).rounded()))
        let nh = max(1, Int((Double(h) * ratio).rounded()))
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = space.numberOfComponents == 1
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
