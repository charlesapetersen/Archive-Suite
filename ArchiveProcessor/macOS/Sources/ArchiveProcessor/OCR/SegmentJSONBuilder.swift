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
    ///   - enclosureOf: W37.dual-date — when this document is an enclosure, the first page file name of
    ///     its covering-letter segment (same naming as `files`), emitted as `enclosure_of`. `nil` → no key.
    ///
    /// W37 also emits `sent_with` (the `ArchiveDate.wireValue`, e.g. "1958-03-12" / "1950s") and
    /// `sent_with_uncertain` — only when `tags.sentWith` is set, so a sidecar without a sent-with date is
    /// byte-identical to the pre-W37 output.
    ///
    ///   - entities: W46.ent-feature — the entity feature's `entities` object (`EntityResult.sidecarObject`), when it
    ///     ran on this document. It then holds the document's sender, recipients and sending place, each with its
    ///     evidence, so the tagging call's `author_name`, `recipient_name` and `author_location` are left out: one
    ///     answer per field. `nil` → the sidecar is byte-identical to the output before the feature. Where the feature
    ///     did not run and the page text is Apple Vision's, the callers pass `tags` without the tagging call's sender
    ///     (`EntityRunPolicy.sidecarTags`, W46.ent-feature-owner-calls), so no sidecar carries a Vision-read sender.
    ///
    ///   - dating: W46.date-route — the dating route's `dating` object (`DateRoute.Decision.sidecarObject`): the
    ///     evidence class, the quote and its place, the interval where measured, second-role dates. `nil` → no key.
    ///
    /// The output is `[.prettyPrinted, .sortedKeys]` JSON, so it is byte-for-byte deterministic.
    static func buildData(fileURLs: [URL], texts: [String],
                          tags: GeneratedTags, formatOverride: String? = nil,
                          enclosureOf: String? = nil, entities: [String: Any]? = nil,
                          dating: [String: Any]? = nil) -> Data? {
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
        if let sentWith = tags.sentWith {
            dict["sent_with"] = sentWith.wireValue
            dict["sent_with_uncertain"] = tags.sentWithUncertain
        }
        if let enclosureOf { dict["enclosure_of"] = enclosureOf }
        if let dating { dict["dating"] = dating }
        dict["subjects"] = tags.subjectTags.map { GeneratedTags.capitalizeFirstLetters($0) }
        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }
        if let entities {
            dict["entities"] = entities
            dict["author_name"] = nil
            dict["recipient_name"] = nil
            dict["author_location"] = nil
        }
        // Box/folder label override wins over tags.format (Process-Files path); nil-op for documents.
        if let f = formatOverride { dict["format"] = f }
        dict["files"] = fileURLs.map { $0.lastPathComponent }
        dict["body"] = bodyParts.joined(separator: "\n\n")

        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    /// The box/folder label `format` override the Process-Files path applies to a label segment, or
    /// `nil` for a plain document. Preserves the original precedence — the inline code ran
    /// `if isBox { … }` then `if isFolder { … }`, so a segment flagged both resolved to `folder_label`
    /// (the later assignment won).
    static func labelFormatOverride(isBox: Bool, isFolder: Bool) -> String? {
        if isFolder { return "folder_label" }
        if isBox { return "box_label" }
        return nil
    }
}
