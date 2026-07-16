import Foundation

/// Decides which inputs a re-run can safely skip because their output PDF already exists at the
/// destination and the source has not changed since.
///
/// **Safety-critical (Tier-2).** A *wrong skip* means a file the operator expected to be processed is
/// silently left without output — the opposite of a loud failure, and therefore worse. So the rule is
/// deliberately conservative: **when in doubt, PROCESS.** Every ambiguity (base-name collision,
/// unreadable timestamp, a candidate "output" that is actually the input itself) falls through to
/// processing rather than risk a silent miss.
///
/// The skip key is exactly the one the owner specified: *an existing output PDF at the destination +
/// source modification time.* This is input-side filtering only — it never changes how outputs are
/// written, so the write/finalize path (and the Recovery Core Directive) is untouched.
///
/// Note on dual output: when the run also exports a sized original image next to each PDF, this keys
/// off the **PDF** alone (per the specified skip key). A skipped file is guaranteed to have its PDF;
/// a missing sibling image from a prior partial run is not re-created. That is an accepted, documented
/// trade-off of the PDF-keyed design, not a data-loss path (the PDF — the OCR product — is present).
enum IncrementalSkip {
    struct Decision: Equatable {
        /// Inputs that must be processed this run (order preserved from the input list).
        var toProcess: [URL]
        /// Inputs safely recognized as already-processed and skipped (order preserved).
        var skipped: [URL]
    }

    /// Partition `inputs` into files to process vs. files safe to skip, keyed off an existing
    /// `<outputDirectory>/<base>.pdf` whose mtime is at or after the source's. Order is preserved.
    static func partition(
        inputs: [URL],
        outputDirectory: URL,
        fileManager: FileManager = .default
    ) -> Decision {
        // Count base names (extension-stripped, case-folded to match the output-collision domain in
        // OutputFileSafety.reserveUniqueDestination, which case-folds path keys). A base name shared by
        // two inputs is ambiguous — <base>.pdf can't be attributed to one source — so neither is skipped.
        var baseCounts: [String: Int] = [:]
        for url in inputs {
            baseCounts[folCaseBase(url), default: 0] += 1
        }

        var toProcess: [URL] = []
        var skipped: [URL] = []
        for url in inputs {
            if canSkip(source: url, outputDirectory: outputDirectory, baseCounts: baseCounts, fileManager: fileManager) {
                skipped.append(url)
            } else {
                toProcess.append(url)
            }
        }
        return Decision(toProcess: toProcess, skipped: skipped)
    }

    /// True only when EVERY guard passes; any uncertainty returns false (→ process). See type doc.
    private static func canSkip(
        source: URL,
        outputDirectory: URL,
        baseCounts: [String: Int],
        fileManager: FileManager
    ) -> Bool {
        // (1) Ambiguous base name → the output can't be uniquely attributed to this source → PROCESS.
        guard (baseCounts[folCaseBase(source)] ?? 0) == 1 else { return false }

        let base = source.deletingPathExtension().lastPathComponent
        let candidate = outputDirectory.appendingPathComponent(base + ".pdf")

        // (2) The candidate "output" must be a DISTINCT generated file, never the input itself
        //     (e.g. re-OCR of a PDF whose output directory is its own folder). Guards against
        //     treating the source as its own prior output and skipping it forever.
        guard !OutputFileSafety.isSameFile(candidate, source) else { return false }

        // (3) The output PDF must exist as a regular file (a directory named <base>.pdf is not output).
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }

        // (4) Both modification timestamps must be readable; a missing source or unreadable date → PROCESS.
        guard let sourceMTime = modificationDate(of: source, fileManager: fileManager),
              let outputMTime = modificationDate(of: candidate, fileManager: fileManager) else {
            return false
        }

        // (5) The source must NOT have changed after the output was written. If the source is newer, it
        //     was edited/replaced since — reprocess. Equal timestamps mean "unchanged" → safe to skip.
        return sourceMTime <= outputMTime
    }

    private static func folCaseBase(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        // Prefer the URL resource value; fall back to FileManager attributes for injected/edge cases.
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            return date
        }
        return (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
