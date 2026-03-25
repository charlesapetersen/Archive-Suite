import Foundation
import AppKit

struct MacOSTagger {

    // Apply macOS Finder tags to a file
    static func applyTags(_ tags: [String], to url: URL) throws {
        var mutableURL = url
        // Filter empty tags
        let filtered = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filtered.isEmpty else { return }

        // Build NSURLTagNamesKey-compatible array
        // Color tags need special treatment via NSURLLabelNumberKey
        let colorTagName = filtered.first { $0 == "Red" || $0 == "Purple" || $0 == "Orange" || $0 == "Gray" || $0 == "Green" || $0 == "Blue" || $0 == "Yellow" }
        let textTags = filtered.filter { $0 != colorTagName }

        var allTagNames = textTags
        if let color = colorTagName { allTagNames.insert(color, at: 0) }

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
