/// How far to shrink a page before it goes up for OCR (W49.proc-ocr-scale-by-pixels; owner, 2026-11-25 walkthrough).
///
/// The size target is measured against the JPEG the page would be sent as, not against the input file: an
/// uncompressed TIFF or PNG scan is large on disk only because it is not JPEG yet, so scaling by its file bytes
/// shrank it far below the target (a 12.3 MB 2000×1500 scan went up at 985×739 for a 3 MB target). The page is
/// first encoded at its full scale (the 2,048 px long-edge cap applied); only when that JPEG is over the target is it
/// scaled down, by √(target / encoded bytes), since JPEG size grows with pixel area.
public enum OCRUploadScale {
    /// The dimension scale relative to the source's long edge, in (0, 1]: what `ImageEncoding.loadImageAsJPEG` takes.
    /// `encodedLongEdge` and `encodedBytes` describe the JPEG encoded at full scale (already capped), `sourceLongEdge`
    /// the input image. 1.0 when that JPEG is within `targetBytes`.
    public static func dimensionScale(sourceLongEdge: Int, encodedLongEdge: Int, encodedBytes: Int,
                                      targetBytes: Double) -> Double {
        guard sourceLongEdge > 0, encodedLongEdge > 0, encodedBytes > 0,
              Double(encodedBytes) > targetBytes else { return 1.0 }
        let longEdge = Double(min(encodedLongEdge, sourceLongEdge)) * (max(0, targetBytes) / Double(encodedBytes)).squareRoot()
        return min(1.0, max(1.0, longEdge.rounded()) / Double(sourceLongEdge))
    }
}
