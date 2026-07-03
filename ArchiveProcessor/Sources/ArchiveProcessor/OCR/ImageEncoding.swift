import Foundation
import ImageIO

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
}
