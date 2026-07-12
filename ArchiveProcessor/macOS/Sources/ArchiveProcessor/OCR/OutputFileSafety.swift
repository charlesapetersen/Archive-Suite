import Foundation

/// File-identity and destination helpers for Processor output paths.
///
/// Review flows sometimes map an input directly as its own output (notably pre-OCRed PDFs). Any cleanup
/// routine must therefore prove that an output is a distinct generated file before removing it.
enum OutputFileSafety {
    /// Conservative same-file check that catches normal path aliases, case-only aliases on the default
    /// macOS filesystems, and symlinks. Ambiguity intentionally resolves toward preservation.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath().path
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath().path
        return left.compare(right, options: .caseInsensitive) == .orderedSame
    }

    /// Remove a proven generated output, but never when it aliases the source. Do not infer ownership of a
    /// same-basename JSON: when input and output directories coincide, that sidecar may be user metadata.
    /// Errors propagate so callers retain the output mapping for a later cleanup attempt.
    static func removeGeneratedOutput(_ outputURL: URL, for sourceURL: URL,
                                      fileManager: FileManager = .default) throws {
        guard !isSameFile(outputURL, sourceURL) else { return }
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
    }
}
