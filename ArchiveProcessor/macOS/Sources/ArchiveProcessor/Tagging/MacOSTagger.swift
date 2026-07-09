import Foundation
import AppKit

struct MacOSTagger {

    /// When true, every file written by `applyTags` gets a trailing "Unread" tag (as the last tag).
    /// Set once per run by the processor from the selected `TaggingMode` (real-tagging modes only —
    /// off for "No tagging" and "Copy source tags"). Written on the main actor before a run begins
    /// and only read during tagging, so the cross-actor access is safe.
    nonisolated(unsafe) static var stampUnread = false

    // Read macOS Finder tags from a file
    static func readTags(from url: URL) -> [String] {
        var tags: [String] = []
        do {
            let resourceValues = try url.resourceValues(forKeys: [.tagNamesKey])
            tags = resourceValues.tagNames ?? []
        } catch {
            // Silently return empty if tags can't be read
        }
        return tags
    }

    /// Apply macOS Finder tags to a file.
    /// - Parameter appColor: when non-nil, THIS is the authoritative app color (Red/Purple) and no
    ///   color detection is done on `tags`, so a *subject* tag that is literally "Red"/"Purple" is
    ///   never promoted to a Finder color label. When nil, Red/Purple are detected within `tags`.
    static func applyTags(_ tags: [String], to url: URL, appColor: String? = nil, colorIsAuthoritative: Bool = false) throws {
        // Copy-source mode (stampUnread == false): pass the source tag names through verbatim. Do NOT
        // reinterpret color words as Finder labels or touch the label number — the standard color names
        // round-trip as labels on their own, and manual mapping here would drop one of several colors
        // or convert a genuine subject tag ("Blue") into a color swatch.
        if !stampUnread {
            let verbatim = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !verbatim.isEmpty else { return }
            try (url as NSURL).setResourceValue(verbatim, forKey: .tagNamesKey)
            return
        }

        // Real-tagging modes: the app assigns exactly one of Red (box) / Purple (folder). Drop any
        // incoming "Unread" so we can re-add it exactly once, last.
        var incoming = tags
        incoming.removeAll { $0.caseInsensitiveCompare("Unread") == .orderedSame }
        let filtered = incoming.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let colorTagName: String?
        let textTags: [String]
        if colorIsAuthoritative {
            // The caller (GeneratedTags) supplies the authoritative color; never treat a subject string
            // as a color even when it's nil — a document about the "Red Scare" keeps "Red" as a text tag.
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

        try (url as NSURL).setResourceValue(allTagNames, forKey: .tagNamesKey)

        // Apply the label color, or clear it to 0 when this page has no color — otherwise a stale
        // Red/Purple swatch survives a Redo/re-tag where the page's classification changed.
        if let colorTag = colorTagName, finderLabelIndex(for: colorTag) >= 0 {
            try (url as NSURL).setResourceValue(finderLabelIndex(for: colorTag), forKey: .labelNumberKey)
        } else {
            try (url as NSURL).setResourceValue(0, forKey: .labelNumberKey)
        }
    }

    static func applyTags(_ generatedTags: GeneratedTags, to url: URL) throws {
        // Pass the app-assigned color explicitly so a subject tag equal to "Red"/"Purple" isn't
        // promoted to a Finder color label.
        try applyTags(generatedTags.allTags, to: url, appColor: generatedTags.colorTag, colorIsAuthoritative: true)
    }

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
