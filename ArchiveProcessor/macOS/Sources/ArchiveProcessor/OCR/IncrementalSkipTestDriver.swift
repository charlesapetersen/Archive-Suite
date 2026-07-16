import Foundation

/// Headless, key-free ($0) functional test of `IncrementalSkip` — the incremental-processing
/// skip decision — gated by `INCREMENTAL_SKIP_TEST=1` (does nothing in normal use). No OCR, no
/// network, no cost, no GUI. It builds scratch files with controlled modification dates in a
/// temporary directory (never the corpus) and asserts the conservative "when in doubt, PROCESS"
/// rule across every fail-safe branch. Writes an `ALL PASS` / `SOME FAILED` report to
/// `INCREMENTAL_SKIP_TEST_OUT` (or a temp file) + NSLog, then exits. Test scaffolding only.
@MainActor
enum IncrementalSkipTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["INCREMENTAL_SKIP_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "APIncrementalSkip-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }

        // Fixed reference instant (app context — `Date()` is fine here) with relative offsets so the
        // test is deterministic regardless of wall-clock. older < base < newer.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = base.addingTimeInterval(-3600)
        let newer = base.addingTimeInterval(3600)

        @discardableResult
        func writeFile(_ url: URL, _ contents: String = "x", mtime: Date? = nil) -> URL {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(contents.utf8).write(to: url)
            if let mtime { try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
            return url
        }

        func partition(_ inputs: [URL], _ out: URL) -> IncrementalSkip.Decision {
            IncrementalSkip.partition(inputs: inputs, outputDirectory: out)
        }

        // ── 1. No output PDF exists → PROCESS. ───────────────────────────────────────────────────
        do {
            let dir = root.appendingPathComponent("t1", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let src = writeFile(dir.appendingPathComponent("a.jpg"), mtime: base)
            let d = partition([src], out)
            check("no output → process", d.toProcess == [src] && d.skipped.isEmpty)
        }

        // ── 2. Output PDF exists and is NEWER than source → SKIP. ────────────────────────────────
        do {
            let dir = root.appendingPathComponent("t2", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let src = writeFile(dir.appendingPathComponent("a.jpg"), mtime: base)
            writeFile(out.appendingPathComponent("a.pdf"), mtime: newer)
            let d = partition([src], out)
            check("output newer → skip", d.skipped == [src] && d.toProcess.isEmpty)
        }

        // ── 3. Output exists but source is NEWER (edited since) → PROCESS. ───────────────────────
        do {
            let dir = root.appendingPathComponent("t3", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let src = writeFile(dir.appendingPathComponent("a.jpg"), mtime: newer)
            writeFile(out.appendingPathComponent("a.pdf"), mtime: older)
            let d = partition([src], out)
            check("source newer than output → process", d.toProcess == [src] && d.skipped.isEmpty)
        }

        // ── 4. Equal mtimes → SKIP (unchanged). ──────────────────────────────────────────────────
        do {
            let dir = root.appendingPathComponent("t4", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let src = writeFile(dir.appendingPathComponent("a.jpg"), mtime: base)
            writeFile(out.appendingPathComponent("a.pdf"), mtime: base)
            let d = partition([src], out)
            check("equal mtime → skip", d.skipped == [src])
        }

        // ── 5. Base-name collision within inputs → BOTH process (ambiguous), even with a matching PDF. ─
        do {
            let out = root.appendingPathComponent("t5/out", isDirectory: true)
            let a = writeFile(root.appendingPathComponent("t5/A/doc.jpg"), mtime: base)
            let b = writeFile(root.appendingPathComponent("t5/B/doc.jpg"), mtime: base)
            writeFile(out.appendingPathComponent("doc.pdf"), mtime: newer)
            let d = partition([a, b], out)
            check("base-name collision → both process", Set(d.toProcess) == Set([a, b]) && d.skipped.isEmpty)
        }

        // ── 6. Candidate output IS the source itself (re-OCR PDF, out dir == source dir) → PROCESS. ─
        do {
            let dir = root.appendingPathComponent("t6", isDirectory: true)
            let src = writeFile(dir.appendingPathComponent("doc.pdf"), mtime: base)
            let d = partition([src], dir)   // output dir == source's own dir; candidate == doc.pdf == src
            check("candidate == source → process", d.toProcess == [src] && d.skipped.isEmpty)
        }

        // ── 7. A DIRECTORY named <base>.pdf is not an output → PROCESS. ──────────────────────────
        do {
            let dir = root.appendingPathComponent("t7", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let src = writeFile(dir.appendingPathComponent("a.jpg"), mtime: base)
            try? fm.createDirectory(at: out.appendingPathComponent("a.pdf"), withIntermediateDirectories: true)
            let d = partition([src], out)
            check("output path is a directory → process", d.toProcess == [src])
        }

        // ── 8. Source file does not exist (unreadable mtime) → PROCESS. ─────────────────────────
        do {
            let dir = root.appendingPathComponent("t8", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let ghost = dir.appendingPathComponent("ghost.jpg")   // never written
            writeFile(out.appendingPathComponent("ghost.pdf"), mtime: newer)
            let d = partition([ghost], out)
            check("nonexistent source → process", d.toProcess == [ghost])
        }

        // ── 9. Mixed-case source maps to same-case output (real pipeline naming). ────────────────
        do {
            let dir = root.appendingPathComponent("t9", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let src = writeFile(dir.appendingPathComponent("Report.jpg"), mtime: base)
            writeFile(out.appendingPathComponent("Report.pdf"), mtime: newer)
            let d = partition([src], out)
            check("mixed-case base → skip via same-case output", d.skipped == [src])
        }

        // ── 10. re-OCR cross-directory: PDF source, output in a DIFFERENT dir, newer → SKIP. ─────
        do {
            let dir = root.appendingPathComponent("t10", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let src = writeFile(dir.appendingPathComponent("scan.pdf"), mtime: base)
            writeFile(out.appendingPathComponent("scan.pdf"), mtime: newer)
            let d = partition([src], out)
            check("re-OCR cross-dir output newer → skip", d.skipped == [src])
        }

        // ── 11. Realistic mix: order preserved; only the safe-to-skip file is skipped. ───────────
        do {
            let dir = root.appendingPathComponent("t11", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let done = writeFile(dir.appendingPathComponent("1done.jpg"), mtime: base)      // has newer pdf → skip
            let neu = writeFile(dir.appendingPathComponent("2new.jpg"), mtime: base)        // no pdf → process
            let edited = writeFile(dir.appendingPathComponent("3edited.jpg"), mtime: newer) // older pdf → process
            writeFile(out.appendingPathComponent("1done.pdf"), mtime: newer)
            writeFile(out.appendingPathComponent("3edited.pdf"), mtime: older)
            let d = partition([done, neu, edited], out)
            check("mixed set: only already-processed skipped", d.skipped == [done])
            check("mixed set: process list ordered [new, edited]", d.toProcess == [neu, edited])
        }

        // ── 12. All already processed → skipped == inputs (drives the "nothing to do" early return). ─
        do {
            let dir = root.appendingPathComponent("t12", isDirectory: true)
            let out = dir.appendingPathComponent("out", isDirectory: true)
            let a = writeFile(dir.appendingPathComponent("a.jpg"), mtime: base)
            let b = writeFile(dir.appendingPathComponent("b.jpg"), mtime: base)
            writeFile(out.appendingPathComponent("a.pdf"), mtime: newer)
            writeFile(out.appendingPathComponent("b.pdf"), mtime: newer)
            let d = partition([a, b], out)
            check("all processed → all skipped", d.skipped == [a, b] && d.toProcess.isEmpty)
        }

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["INCREMENTAL_SKIP_TEST_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("archiveprocessor-incremental-skip-result.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
