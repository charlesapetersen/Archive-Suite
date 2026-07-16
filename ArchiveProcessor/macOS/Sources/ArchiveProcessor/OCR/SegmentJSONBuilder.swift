import Foundation
import ArchiveCore

/// Shared builder for the per-segment metadata JSON sidecar the Processor writes next to a document's
/// output PDF. Consolidates the two byte-identical implementations that previously lived inline in
/// `OCRProcessor.writeSegmentJSON` (Process Files) and `LiveCaptureProcessor.writeSegmentJSON`
/// (Live Capture) — see SUITE_TODO "De-dup sweep … REMAINDER (5) segment-JSON sidecar builder".
///
/// Deliberately **pure**: it builds the JSON `Data` only. Each caller keeps ownership of computing the
/// sidecar URL and doing the atomic disk write, so the file-write surface (the file-safety-critical
/// part) is left byte-for-byte unchanged by this de-duplication.
enum SegmentJSONBuilder {
    /// Build the sidecar JSON `Data` for one document segment, or `nil` if serialization fails.
    ///
    /// - Parameters:
    ///   - fileURLs: the segment's page files, in order. Used for **both** the `[Image: …]` body
    ///     markers and the emitted `files` list (both call sites pass the same list for both).
    ///   - texts: `texts[i]` pairs with `fileURLs[i]`; a missing or empty text contributes only the
    ///     image marker (no body text line), exactly as the two original implementations did.
    ///   - tags: the generated tags whose date/subjects/format/author/recipient/etc. fields populate
    ///     the sidecar.
    ///   - formatOverride: when non-nil (`"box_label"` / `"folder_label"`), overrides `tags.format`
    ///     in the emitted `format` field. The Live path always passes `nil` (it writes JSON for
    ///     documents only); the Process-Files path passes the box/folder override for label segments.
    ///
    /// The output is `[.prettyPrinted, .sortedKeys]` JSON, so it is byte-for-byte deterministic.
    static func buildData(fileURLs: [URL], texts: [String],
                          tags: GeneratedTags, formatOverride: String? = nil) -> Data? {
        // Body text with per-image markers (image marker always; text line only when non-empty).
        var bodyParts: [String] = []
        for (i, url) in fileURLs.enumerated() {
            let text = i < texts.count ? texts[i] : ""
            bodyParts.append("[Image: \(url.lastPathComponent)]")
            if !text.isEmpty { bodyParts.append(text) }
        }

        var dict: [String: Any] = [:]
        if let date = tags.machineDate { dict["date"] = date }
        dict["date_uncertain"] = tags.dateUncertain
        dict["subjects"] = tags.subjectTags.map { GeneratedTags.capitalizeFirstLetters($0) }
        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }
        // Box/folder label override wins over tags.format (Process-Files path); nil-op for documents.
        if let f = formatOverride { dict["format"] = f }
        dict["files"] = fileURLs.map { $0.lastPathComponent }
        dict["body"] = bodyParts.joined(separator: "\n\n")

        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }
}
