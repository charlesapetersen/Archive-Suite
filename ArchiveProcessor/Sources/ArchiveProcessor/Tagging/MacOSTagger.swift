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

    // Apply macOS Finder tags to a file
    static func applyTags(_ tags: [String], to url: URL) throws {
        // In stamping modes, drop any incoming "Unread" so we can re-add it exactly once, last.
        var incoming = tags
        if stampUnread {
            incoming.removeAll { $0.caseInsensitiveCompare("Unread") == .orderedSame }
        }
        // Filter empty tags
        let filtered = incoming.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Build NSURLTagNamesKey-compatible array
        // Color tags need special treatment via NSURLLabelNumberKey
        let colorTagName = filtered.first { $0 == "Red" || $0 == "Purple" || $0 == "Orange" || $0 == "Gray" || $0 == "Green" || $0 == "Blue" || $0 == "Yellow" }
        let textTags = filtered.filter { $0 != colorTagName }

        var allTagNames = textTags
        if let color = colorTagName { allTagNames.insert(color, at: 0) }
        // Real-tagging modes: "Unread" is always the final tag on every output (even if nothing else).
        if stampUnread { allTagNames.append("Unread") }

        guard !allTagNames.isEmpty else { return }

        try (url as NSURL).setResourceValue(allTagNames, forKey: .tagNamesKey)

        // Apply label color if needed
        if let colorTag = colorTagName {
            let labelIndex = finderLabelIndex(for: colorTag)
            if labelIndex >= 0 {
                try (url as NSURL).setResourceValue(labelIndex, forKey: .labelNumberKey)
            }
        }
    }

    static func applyTags(_ generatedTags: GeneratedTags, to url: URL) throws {
        try applyTags(generatedTags.allTags, to: url)
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
