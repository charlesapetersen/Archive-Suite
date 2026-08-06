import Foundation
import AppKit
import ArchiveCore

/// Processor's FRESH-WRITE ADAPTER over `ArchiveCore.CoordinatedTagWriter`.
///
/// Every Processor tag write — OCR output tagging, copy-source pass-through, merge tagging,
/// review-flow re-tagging — goes through here. It translates the Processor's fresh-write
/// semantics (the per-call `stampUnread:` choice, color-authoritative vs. detection, copy-source
/// verbatim) into a transform closure and hands it to the shared audited primitive.
///
/// Those two decisions — `stampUnread:` and `finderLabelIndex` — remain Processor-specific; the actual
/// metadata I/O is delegated entirely to ArchiveCore (no direct `setResourceValue` in Processor sources).
///
/// **This type holds no state at all.** W16.cfg4 made `stampUnread:` a required per-call parameter; the
/// process-global flag it replaced (armed from `OCRProcessor.taggingMode`'s `didSet`) was the suite's last
/// ambient tagging global and W16.cfg6-fu deleted it. Which semantics a write uses is now an argument at
/// the call site and nothing else — never a value some earlier run, or some test driver whose `defer` a
/// crash skipped, left behind.
struct MacOSTagger {

    /// Read macOS Finder tags from a file. Throws on read failure so callers in the
    /// read-append-rewrite pattern bail instead of silently wiping existing tags with [].
    static func readTags(from url: URL) throws -> [String] {
        let result = TagReading.read(url)
        switch result {
        case .success(let tagNames, _):
            return tagNames
        case .failure(let message):
            throw TagWriteError.unreadable(message)
        }
    }

    /// Apply macOS Finder tags to a file via the shared audited primitive.
    /// - Parameter appColor: when non-nil, THIS is the authoritative app color (Red/Purple) and no
    ///   color detection is done on `tags`, so a *subject* tag that is literally "Red"/"Purple" is
    ///   never promoted to a Finder color label. When nil, Red/Purple are detected within `tags`.
    /// - Parameter stampUnread: **required — selects the whole write semantics, not just one tag.**
    ///   `true` (real-tagging modes) re-stamps a trailing "Unread", resolves the Red/Purple color, and
    ///   WRITES the Finder label (clearing it to 0 when there is no color). `false` (copy-source /
    ///   no-tagging) passes the tag names through VERBATIM and leaves the existing label untouched.
    ///   Pass `taggingMode.stampsUnread` for a real-tagging write, or a literal `false` for a
    ///   copy-source pass-through. There is deliberately no default: choosing wrongly silently
    ///   rewrites Finder metadata on irreplaceable files (W16.cfg4).
    @discardableResult
    static func applyTags(
        _ tags: [String],
        to url: URL,
        appColor: String? = nil,
        colorIsAuthoritative: Bool = false,
        stampUnread isStamping: Bool
    ) throws -> TagWriteResult {

        let result = try CoordinatedTagWriter.write(url) { current, label in
            // Copy-source mode (stampUnread == false): pass the source tag names through verbatim.
            // Do NOT reinterpret color words as Finder labels or touch the label number — the
            // standard color names round-trip as labels on their own, and manual mapping here would
            // drop one of several colors or convert a genuine subject tag ("Blue") into a swatch.
            if !isStamping {
                let verbatim = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !verbatim.isEmpty else { return nil }
                return (verbatim, label)  // preserve existing label untouched
            }

            // Real-tagging modes: the app assigns exactly one of Red (box) / Purple (folder).
            // Drop any incoming "Unread" so we can re-add it exactly once, last.
            var incoming = tags
            incoming.removeAll { $0.caseInsensitiveCompare("Unread") == .orderedSame }
            let filtered = incoming.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            let colorTagName: String?
            let textTags: [String]
            if colorIsAuthoritative {
                // The caller (GeneratedTags) supplies the authoritative color; never treat a subject
                // string as a color even when it's nil — a document about the "Red Scare" keeps
                // "Red" as a text tag.
                colorTagName = (appColor == "Red" || appColor == "Purple") ? appColor : nil
                if let c = colorTagName, let idx = filtered.firstIndex(of: c) {
                    var t = filtered; t.remove(at: idx); textTags = t
                } else {
                    textTags = filtered
                }
            } else {
                // Raw [String] callers: detect Red/Purple within the array (never other color words).
                let detected = filtered.first { ["Red", "Purple"].contains($0) }
                colorTagName = detected
                textTags = filtered.filter { $0 != detected }
            }

            var allTagNames = textTags
            if let color = colorTagName { allTagNames.insert(color, at: 0) }
            allTagNames.append("Unread")   // always the final tag on every real-tagging output

            // Compute the intended label: color's Finder index, or 0 (clear) when no color.
            let targetLabel: Int
            if let colorTag = colorTagName, finderLabelIndex(for: colorTag) >= 0 {
                targetLabel = finderLabelIndex(for: colorTag)
            } else {
                targetLabel = 0
            }

            return (allTagNames, targetLabel)
        }

        // Feed the subject-autocomplete vocabulary from what VERIFIED on disk, not from what we intended
        // (W26.vocab). One of three ingest paths that replaced the Spotlight query; `TagVocabulary` keeps
        // only the subject facet, so the trailing "Unread" and the date/priority/colour tokens this write
        // just stamped cannot become suggestions. Read-only with respect to the file — a suggestion list is
        // never a write authority — and after the `try`, so a refused write contributes nothing.
        ProcessorTagVocabulary.recordWrittenTags(result.after, labelNumber: result.afterLabel)
        return result
    }

    @discardableResult
    static func applyTags(
        _ generatedTags: GeneratedTags,
        to url: URL,
        stampUnread: Bool
    ) throws -> TagWriteResult {
        // Pass the app-assigned color explicitly so a subject tag equal to "Red"/"Purple" isn't
        // promoted to a Finder color label.
        try applyTags(
            generatedTags.allTags,
            to: url,
            appColor: generatedTags.colorTag,
            colorIsAuthoritative: true,
            stampUnread: stampUnread)
    }

    /// Finder label number for a color name. Processor-specific (the shared primitive works with
    /// `ArchiveColor`, but this adapter bridges the raw-string color names the Processor uses).
    private static func finderLabelIndex(for colorName: String) -> Int {
        switch colorName {
        case "Red": return 6
        case "Orange": return 7
        case "Yellow": return 5
        case "Green": return 2
        case "Blue": return 4
        case "Purple": return 3
        case "Gray": return 1
        default: return -1
        }
    }
}
