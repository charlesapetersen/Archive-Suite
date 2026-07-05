import Foundation

/// How a copied file reference is formatted (configurable in Options, ⌘,).
enum LinkFormat: String, Sendable, CaseIterable {
    case fileURL     // file:///Users/…
    case posixPath   // /Users/…
    case markdown    // [name](file://…)
    case html        // <a href="file://…">name</a>
}

/// Formats file references for the clipboard.
///
/// Percent-encoding is delegated to Foundation's `URL` so it is always correct — spaces → `%20`,
/// em dash (U+2014) → `%E2%80%94`, non-breaking space (U+00A0) → `%C2%A0` — never hand-rolled.
struct FileLinkFormatter: Sendable {
    var format: LinkFormat = .fileURL
    /// Number of blank lines to place between consecutive links when copying a group (Options).
    var newlinesBetweenLinks: Int = 1

    /// One formatted reference for a single file URL.
    func line(for url: URL) -> String {
        switch format {
        case .fileURL:
            return url.absoluteString
        case .posixPath:
            return url.path(percentEncoded: false)
        case .markdown:
            return "[\(displayName(for: url))](\(url.absoluteString))"
        case .html:
            return "<a href=\"\(url.absoluteString)\">\(displayName(for: url))</a>"
        }
    }

    /// The clipboard string for a selection of files.
    func clipboardString(for urls: [URL]) -> String {
        let separator = "\n" + String(repeating: "\n", count: max(0, newlinesBetweenLinks))
        return urls.map(line(for:)).joined(separator: separator)
    }

    private func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
