#if DEBUG // a test driver, compiled out of Release
import AppKit
import ArchiveCore
import Darwin
import PDFKit

/// Headless, $0 fault-injection test of the Improve OCR publication transaction (W44.reocr-processor), gated by
/// `REOCR_FILEWRITER_TEST=1` (does nothing in normal use). Every file is in `REOCR_FILEWRITER_TEST_DIR`, a scratch
/// folder the script makes; never the corpus. Run by `scripts/test-reocr-filewriter.sh`.
///
/// Each case makes a fresh Processor two-page PDF with Finder tags (one duplicated), a label, a custom extended
/// attribute, a resource fork, mode 0640 and set creation and modification dates, and a candidate from
/// `ReOCRIncrementalWriter`. What has to be true:
///   1. Accept publishes the candidate at the same path with every piece of metadata kept, a tag added after
///      `prepare` included; the kept original is the old file, byte for byte and with its metadata; the journal says
///      `published`.
///   2. A crash after the backup, after the temporary write, after `acceptReady` or just before the swap leaves the old
///      file live and whole; recovery says `notPublished` and removes the temporary file; a later accept still works.
///      A failure before the swap returns the journal to `prepared`; a metadata change after staging, or an in-place
///      write at the moment of the swap, is refused and the other writer's file is what stays.
///   3. A crash after the swap leaves the candidate live; recovery says `published`, unless the published file's
///      metadata no longer matches what was staged, or the displaced original was edited, which are conflicts.
///   4. A target changed after `prepare` (bytes, or replaced by another file) is refused and left as it is.
///   5. A link, a locked file and a target whose bytes are neither old nor new are refused or reported as a conflict,
///      and recovery never deletes a kept original.
@MainActor
enum ReOCRFileWriterTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REOCR_FILEWRITER_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private struct InjectedFailure: Error {}

    private static let model = LLMModel.geminiModels[0]
    private static func ocr(_ text: String) -> OCRResult {
        OCRResult(text: text, classification: nil, errorMessage: nil, errorCode: nil)
    }

    private static var root = URL(fileURLWithPath: "/nonexistent")
    private static var serial = 0

    /// A scratch archive file and its candidate; each case gets its own folder and versions store.
    private struct Case {
        let file: URL
        let writer: ReOCRFileWriter
        let original: Data
        let candidate: Data
    }

    private static func makeCase(_ name: String) throws -> Case {
        serial += 1
        let dir = root.appendingPathComponent("\(serial)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpg = dir.appendingPathComponent("scan.jpg"), pdf = dir.appendingPathComponent("Letter — 1952.pdf")
        let w = 120, h = 160
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 20, width: 70, height: 90))
        guard let image = ctx.makeImage(), let rep = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try rep.write(to: jpg)
        try PDFGenerator().generate(imageURL: jpg, result: ocr("The old reading."), model: model, outputURL: pdf)
        try FileManager.default.removeItem(at: jpg)
        // Metadata: tags (a duplicate on purpose), a label, a custom attribute, a resource fork, mode and dates.
        try (ReOCRFileWriter.fresh(pdf) as NSURL).setResourceValue(["Q2", "1952", "Q2"], forKey: .tagNamesKey)
        try (ReOCRFileWriter.fresh(pdf) as NSURL).setResourceValue(3, forKey: .labelNumberKey)
        _ = "kept".withCString { setxattr(pdf.path, "org.archivesuite.test", $0, 4, 0, XATTR_NOFOLLOW) }
        let fork: [UInt8] = Array(repeating: 0x5A, count: 300)
        _ = fork.withUnsafeBytes { setxattr(pdf.path, XATTR_RESOURCEFORK_NAME, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        chmod(pdf.path, 0o640)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 1_000_000_000, tv_nsec: 0)]
        utimensat(AT_FDCWD, pdf.path, &times, 0)
        var created = timespec(tv_sec: 900_000_000, tv_nsec: 0)
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME),
                            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        setattrlist(pdf.path, &list, &created, MemoryLayout<timespec>.size, 0)

        let original = try Data(contentsOf: pdf)
        guard let page = PDFGenerator().textPageData(result: ocr("The better reading."), model: model) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let candidate = try ReOCRIncrementalWriter.candidate(original: original, replacements: [1: page])
        let writer = ReOCRFileWriter(versionsRoot: dir.appendingPathComponent("Versions", isDirectory: true))
        return Case(file: pdf, writer: writer, original: original, candidate: candidate)
    }

    private static func tags(_ url: URL) -> [String] {
        (try? ReOCRFileWriter.fresh(url).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    private static func fault(at point: ReOCRFileWriter.FaultPoint) -> ReOCRFileWriter.Faults {
        { if $0 == point { throw ReOCRFileWriter.InjectedCrash() } }
    }

    private static func temporaries(_ c: Case) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: c.file.deletingLastPathComponent().path)) ?? [])
            .filter { $0.hasSuffix(".tmp") }
    }

    static func run() {
        defer { finish() }
        guard let dir = ProcessInfo.processInfo.environment["REOCR_FILEWRITER_TEST_DIR"] else {
            check("0 REOCR_FILEWRITER_TEST_DIR is set", false); return
        }
        root = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            // 1. The whole transaction.
            let c = try makeCase("accept")
            let before = try ReOCRFileWriter.metadata(c.file.path)
            let op = try c.writer.prepare(target: c.file)
            check("1 prepare keeps the original byte for byte", (try? Data(contentsOf: c.writer.backupURL(op.journal.operationID))) == c.original)
            check("1 the kept original has its metadata",
                  (try? ReOCRFileWriter.metadata(c.writer.backupURL(op.journal.operationID).path))
                    .map { ReOCRFileWriter.metadataDifference(before, $0, dates: false) == nil } == true)
            check("1 the journal records the original's metadata", op.journal.originalMetadata == before)
            // A tag added between prepare and accept must survive.
            try (ReOCRFileWriter.fresh(c.file) as NSURL).setResourceValue(["Q2", "1952", "Q2", "Added later"], forKey: .tagNamesKey)
            // Writing tag names clears the colour label; put it back, so publication has a label to keep.
            try (ReOCRFileWriter.fresh(c.file) as NSURL).setResourceValue(3, forKey: .labelNumberKey)
            let fresh = try ReOCRFileWriter.metadata(c.file.path)
            let j = try c.writer.accept(op, candidate: c.candidate)
            check("1 the journal says published", j.phase == .published && (try? c.writer.read(op.journal.operationID).phase) == .published)
            check("1 the file holds the candidate", (try? Data(contentsOf: c.file)) == c.candidate)
            let after = try ReOCRFileWriter.metadata(c.file.path)
            check("1 every piece of metadata is kept", ReOCRFileWriter.metadataDifference(fresh, after) == nil,
                  ReOCRFileWriter.metadataDifference(fresh, after) ?? "")
            check("1 tags are kept as a multiset, the later one included",
                  multisetEqual(tags(c.file), ["Q2", "1952", "Q2", "Added later"]), "\(tags(c.file))")
            check("1 the label is kept", (try? ReOCRFileWriter.fresh(c.file).resourceValues(forKeys: [.labelNumberKey]))?.labelNumber == 3)
            check("1 the creation and modification dates are kept",
                  after.created.seconds == 900_000_000 && after.modified.seconds == 1_000_000_000)
            check("1 mode 0640 is kept", after.mode == 0o640)
            check("1 the resource fork and custom attribute are kept",
                  after.xattrs[XATTR_RESOURCEFORK_NAME]?.count == 300 && after.xattrs["org.archivesuite.test"] == Data("kept".utf8))
            check("1 no temporary file is left", temporaries(c).isEmpty, "\(temporaries(c))")
            check("1 recovery finds nothing to do", c.writer.recover() == [.alreadyPublished(op.journal.operationID)])
            check("1 a second accept of the same operation is refused",
                  (try? c.writer.accept(ReOCRFileWriter.Operation(journal: j), candidate: c.candidate)) == nil)

            // 2. Crashes before publication.
            for point in [ReOCRFileWriter.FaultPoint.afterTemporaryWrite, .afterAcceptReady, .beforeSwap] {
                let c = try makeCase("crash-\(point.rawValue)")
                let op = try c.writer.prepare(target: c.file)
                let thrown = (try? c.writer.accept(op, candidate: c.candidate, faults: fault(at: point))) == nil
                check("2 a crash \(point.rawValue) stops the accept", thrown)
                check("2 after a crash \(point.rawValue) the old file is live", (try? Data(contentsOf: c.file)) == c.original)
                let r = c.writer.recover()
                check("2 recovery after \(point.rawValue) says not published", r == [.notPublished(op.journal.operationID)], "\(r)")
                check("2 recovery after \(point.rawValue) removes the temporary file", temporaries(c).isEmpty, "\(temporaries(c))")
                check("2 the kept original survives recovery after \(point.rawValue)",
                      FileManager.default.fileExists(atPath: c.writer.backupURL(op.journal.operationID).path))
                // Review again: a fresh prepare and accept still work.
                let again = try c.writer.prepare(target: c.file)
                try c.writer.accept(again, candidate: c.candidate)
                check("2 a later accept after \(point.rawValue) works", (try? Data(contentsOf: c.file)) == c.candidate)
            }
            do {
                let c = try makeCase("crash-afterBackup")
                let thrown = (try? c.writer.prepare(target: c.file, faults: fault(at: .afterBackup))) == nil
                check("2 a crash after the backup stops prepare and leaves the file", thrown && (try? Data(contentsOf: c.file)) == c.original)
                check("2 recovery ignores a backup with no journal and deletes nothing", c.writer.recover().isEmpty
                      && ((try? FileManager.default.contentsOfDirectory(atPath: c.writer.versionsRoot.path))?.count ?? 0) == 1)
            }

            // 3. A crash after the rename.
            do {
                let c = try makeCase("crash-afterSwap")
                let op = try c.writer.prepare(target: c.file)
                let thrown = (try? c.writer.accept(op, candidate: c.candidate, faults: fault(at: .afterSwap))) == nil
                check("3 a crash after the rename stops the accept", thrown)
                check("3 the candidate is live", (try? Data(contentsOf: c.file)) == c.candidate)
                let r = c.writer.recover()
                check("3 recovery says published", r == [.published(op.journal.operationID)], "\(r)")
                check("3 the journal now says published", (try? c.writer.read(op.journal.operationID).phase) == .published)
            }

            // 2b. A failure (not a crash) after `acceptReady` returns the journal to `prepared`, so a later operation's
            // publication of the same candidate is never credited to it.
            do {
                let c = try makeCase("fail-beforeSwap")
                let a = try c.writer.prepare(target: c.file)
                let failed = (try? c.writer.accept(a, candidate: c.candidate, faults: {
                    if $0 == .beforeSwap { throw InjectedFailure() }
                })) == nil
                check("2b a failure before the swap stops the accept", failed && (try? Data(contentsOf: c.file)) == c.original)
                check("2b the failed operation is back to prepared", (try? c.writer.read(a.journal.operationID).phase) == .prepared)
                check("2b no temporary file is left", temporaries(c).isEmpty, "\(temporaries(c))")
                let b = try c.writer.prepare(target: c.file)
                try c.writer.accept(b, candidate: c.candidate)
                let r = Set(c.writer.recover())
                check("2b recovery credits only the operation that published",
                      r == [.notPublished(a.journal.operationID), .alreadyPublished(b.journal.operationID)], "\(r)")
            }

            // 2c. A metadata change after staging, before the swap, is refused (the change time moved).
            do {
                let c = try makeCase("tag-after-staging")
                let op = try c.writer.prepare(target: c.file)
                do {
                    try c.writer.accept(op, candidate: c.candidate, faults: {
                        if $0 == .afterAcceptReady { _ = "x".withCString { setxattr(c.file.path, "org.archivesuite.late", $0, 1, 0, XATTR_NOFOLLOW) } }
                    })
                    check("2c a tag changed after staging is refused", false)
                } catch {
                    check("2c a tag changed after staging is refused", (error as? ReOCRFileWriter.Failure) == .targetChanged, "\(error)")
                }
                check("2c the file keeps its bytes and the late change", (try? Data(contentsOf: c.file)) == c.original
                      && ReOCRFileWriter.xattrs(c.file.path)["org.archivesuite.late"] != nil)
                check("2c the journal is back to prepared", (try? c.writer.read(op.journal.operationID).phase) == .prepared)
            }

            // 2d. An in-place write after the last check is caught after the swap and put back.
            do {
                let c = try makeCase("write-at-swap")
                let op = try c.writer.prepare(target: c.file)
                var edited = Data()
                do {
                    try c.writer.accept(op, candidate: c.candidate, faults: {
                        guard $0 == .beforeSwap, let h = try? FileHandle(forWritingTo: c.file) else { return }
                        _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("\n%late\n".utf8)); try? h.close()
                        edited = (try? Data(contentsOf: c.file)) ?? Data()
                    })
                    check("2d a write at the swap is refused", false)
                } catch {
                    check("2d a write at the swap is refused", (error as? ReOCRFileWriter.Failure) == .targetChanged, "\(error)")
                }
                check("2d the edited file is back in place", !edited.isEmpty && (try? Data(contentsOf: c.file)) == edited)
                check("2d no temporary file is left", temporaries(c).isEmpty, "\(temporaries(c))")
            }

            // 3b. A crash after the swap with the published file's metadata changed is a conflict, not a publication.
            do {
                let c = try makeCase("crash-afterSwap-metadata")
                let op = try c.writer.prepare(target: c.file)
                _ = try? c.writer.accept(op, candidate: c.candidate, faults: {
                    guard $0 == .afterSwap else { return }
                    removexattr(c.file.path, "org.archivesuite.test", XATTR_NOFOLLOW)
                    throw ReOCRFileWriter.InjectedCrash()
                })
                let r = c.writer.recover()
                check("3b lost metadata after the swap is a conflict", { if case .conflict = r.first { return true }; return false }(), "\(r)")
                check("3b the journal is not marked published", (try? c.writer.read(op.journal.operationID).phase) == .acceptReady)
            }

            // 3c. An edit that lands on the displaced original right after the swap, then a crash: recovery keeps the
            // edit and reports a conflict rather than deleting it.
            do {
                let c = try makeCase("edit-at-swap-crash")
                let op = try c.writer.prepare(target: c.file)
                let temp = c.file.deletingLastPathComponent()
                    .appendingPathComponent(".\(c.file.lastPathComponent).reocr-\(op.journal.operationID.uuidString).tmp")
                _ = try? c.writer.accept(op, candidate: c.candidate, faults: {
                    guard $0 == .justAfterSwap else { return }
                    if let h = try? FileHandle(forWritingTo: temp) {
                        _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("\n%late\n".utf8)); try? h.close()
                    }
                    throw ReOCRFileWriter.InjectedCrash()
                })
                let r = c.writer.recover()
                check("3c an edited displaced file is a conflict", { if case .conflict = r.first { return true }; return false }(), "\(r)")
                check("3c the edited version is kept", (try? Data(contentsOf: temp)).map { $0.count == c.original.count + 7 } == true)
            }

            // 4. A changed target is refused and left alone.
            do {
                let c = try makeCase("changed-bytes")
                let op = try c.writer.prepare(target: c.file)
                let h = try FileHandle(forWritingTo: c.file)
                try h.seekToEnd(); try h.write(contentsOf: Data("\n%edited\n".utf8)); try h.close()
                let edited = try Data(contentsOf: c.file)
                do { try c.writer.accept(op, candidate: c.candidate); check("4 changed bytes are refused", false) }
                catch { check("4 changed bytes are refused", (error as? ReOCRFileWriter.Failure) == .targetChanged, "\(error)") }
                check("4 the edited file is left as it is", (try? Data(contentsOf: c.file)) == edited)
            }
            do {
                let c = try makeCase("replaced")
                let op = try c.writer.prepare(target: c.file)
                // The same bytes, but a different file: another app saved over it.
                try FileManager.default.removeItem(at: c.file)
                try c.original.write(to: c.file)
                do { try c.writer.accept(op, candidate: c.candidate); check("4 a replaced file is refused", false) }
                catch { check("4 a replaced file is refused", (error as? ReOCRFileWriter.Failure) == .targetChanged, "\(error)") }
            }

            // 5. Links, locked files, conflicts.
            do {
                let c = try makeCase("link")
                let link = c.file.deletingLastPathComponent().appendingPathComponent("link.pdf")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: c.file)
                check("5 a link is refused", (try? c.writer.prepare(target: link)) == nil)
                check("5 the linked file is untouched", (try? Data(contentsOf: c.file)) == c.original)
            }
            do {
                let c = try makeCase("locked")
                chflags(c.file.path, UInt32(UF_IMMUTABLE))
                do { _ = try c.writer.prepare(target: c.file); check("5 a locked file is refused", false) }
                catch { check("5 a locked file is refused", (error as? ReOCRFileWriter.Failure) == .locked, "\(error)") }
                chflags(c.file.path, 0)
            }
            do {
                let c = try makeCase("conflict")
                let op = try c.writer.prepare(target: c.file)
                _ = try? c.writer.accept(op, candidate: c.candidate, faults: fault(at: .afterAcceptReady))
                try Data("someone else's file".utf8).write(to: c.file)
                let r = c.writer.recover()
                check("5 a file that is neither is a conflict", { if case .conflict = r.first { return true }; return false }(), "\(r)")
                check("5 a conflict keeps the original", FileManager.default.fileExists(atPath: c.writer.backupURL(op.journal.operationID).path))
                check("5 a conflict leaves the other file alone", (try? Data(contentsOf: c.file)) == Data("someone else's file".utf8))
            }
        } catch {
            check("no error is thrown", false, "\(error)")
        }
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REOCR_FILEWRITER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
