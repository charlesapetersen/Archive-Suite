// ThumbnailCacheKey.swift — pure key derivation for the PDF thumbnail disk cache
import Foundation
import CryptoKit

/// Derives a stable, collision-resistant cache filename from a thumbnail's identity.
///
/// Key formula: `sha256("\(linkKey)#p\(page)@\(mtime)@\(widthPt)x\(scale)") + ".png"`
/// Including `mtime` + spec in the key means a re-OCR (new mtime) or a spec change
/// naturally invalidates without an explicit purge.
public enum ThumbnailCacheKey: Sendable {
    /// Returns the cache filename (no directory) for a thumbnail.
    /// - Parameters:
    ///   - linkKey: The canonical `archivereader://` URL string for the source file.
    ///   - page: 1-based page number.
    ///   - mtime: Source file's content-modification date.
    ///   - pointWidth: Requested width in points.
    ///   - scale: Retina scale factor.
    public static func filename(
        linkKey: String,
        page: Int,
        mtime: Date,
        pointWidth: CGFloat,
        scale: CGFloat
    ) -> String {
        let input = "\(linkKey)#p\(page)@\(mtime.timeIntervalSince1970)@\(pointWidth)x\(scale)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".png"
    }
}
