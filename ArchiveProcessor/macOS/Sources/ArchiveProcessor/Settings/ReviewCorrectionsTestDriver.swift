#if DEBUG // a test driver, compiled out of Release
import Foundation

/// Headless, $0 self-test of the collection's review records (W46.kit-corrections-store), gated by
/// `REVIEW_CORRECTIONS_TEST=1` (does nothing in normal use). Every file it writes is under a fresh scratch folder in
/// `REVIEW_CORRECTIONS_TEST_DIR` (else the temporary folder): never an output folder of the user's, never the corpus.
/// No Keychain read, no network, no window. Run by `scripts/test-review-corrections.sh`, which also leaves the
/// records it wrote in `REVIEW_CORRECTIONS_TEST_KEEP` (when set) for the kit's reader to count.
@MainActor
enum ReviewCorrectionsTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REVIEW_CORRECTIONS_TEST"] == "1" else { return }
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

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    private static let fm = FileManager.default
    private static let day = Date(timeIntervalSince1970: 1_793_793_600)

    private static func run() {
        let env = ProcessInfo.processInfo.environment
        let base = env["REVIEW_CORRECTIONS_TEST_DIR"].map(URL.init(fileURLWithPath:)) ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("review-corrections-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        building()
        writing(root, keep: env["REVIEW_CORRECTIONS_TEST_KEEP"].map(URL.init(fileURLWithPath:)))
        guarded(root)
        finish()
    }

    // MARK: Building

    private static func proposal(_ gap: Int, _ d: GapDecision, flagged: Bool = false, fixed: Bool = false) -> GapProposal {
        GapProposal(gap: gap, decision: d, confidence: flagged ? 0.6 : 0.95, agreed: !flagged, flagged: flagged,
                    cue: "", fixed: fixed)
    }

    private static func item(_ gap: Int, _ proposal: GapDecision, _ answer: FlaggedGapAnswer?) -> FlaggedGapItem {
        FlaggedGapItem(id: gap, leftURL: URL(fileURLWithPath: "/p\(gap)"), rightURL: URL(fileURLWithPath: "/p\(gap + 1)"),
                       leftRotation: 0, rightRotation: 0, proposal: proposal, confidence: 0.6, cue: "", answer: answer)
    }

    /// Seven pages: a box photo, then six document pages. Gap 0 is beside the box photo (fixed). Gap 1 flagged and
    /// kept, gap 2 flagged and split, gap 3 unflagged and left, gap 4 unflagged and changed in the skim, gap 5 beside
    /// page 6, which the skim removed.
    private static func scenario() -> (proposals: [GapProposal], pages: [ReviewedPage], items: [FlaggedGapItem],
                                       afterFlagged: [DocumentClassification], final: [DocumentClassification?]) {
        let proposals = [proposal(0, .new, fixed: true), proposal(1, .continue, flagged: true),
                         proposal(2, .continue, flagged: true), proposal(3, .continue), proposal(4, .continue),
                         proposal(5, .new)]
        let pages = (0..<7).map { ReviewedPage(name: "IMG_\($0).jpg", sha256: nil, output: "IMG_\($0).pdf") }
        let items = [item(1, .continue, .join), item(2, .continue, .split)]
        let afterFlagged: [DocumentClassification] = [.boxLabel, .documentStart, .documentContinuation, .documentStart,
                                                      .documentContinuation, .documentContinuation, .documentStart]
        var final: [DocumentClassification?] = afterFlagged
        final[5] = .documentStart
        final[6] = nil
        return (proposals, pages, items, afterFlagged, final)
    }

    private static func building() {
        let s = scenario()
        let gaps = ReviewCorrections.gaps(proposals: s.proposals, pages: s.pages, flagged: s.items,
                                          afterFlagged: s.afterFlagged, final: s.final)
        eq("build: the fixed gap and the gap beside a removed page are left out", gaps.map(\.gap), [1, 2, 3, 4])
        eq("build: rulings", gaps.map(\.ruling), [.checked, .checked, .accepted, .changed])
        eq("build: final calls", gaps.map(\.final), [.continue, .new, .continue, .new])
        eq("build: proposals kept", gaps.map(\.proposed), [.continue, .continue, .continue, .continue])
        eq("build: flagged kept", gaps.map(\.flagged), [true, true, false, false])
        eq("build: pages named left and right", gaps.first.map { [$0.left.name, $0.right.name] } ?? [],
           ["IMG_1.jpg", "IMG_2.jpg"])
        eq("build: person-ruled count", gaps.filter(\.personRuled).count, 3)

        // A flagged answer the skim then reverses is a change, not a check.
        var final = s.final
        final[3] = .documentContinuation
        let reversed = ReviewCorrections.gaps(proposals: s.proposals, pages: s.pages, flagged: s.items,
                                              afterFlagged: s.afterFlagged, final: final)
        eq("build: a flagged answer reversed in the skim is changed", reversed.first { $0.gap == 2 }?.ruling, .changed)

        // A page the skim turned into a folder photo ends both its gaps' place in the record.
        final = s.final
        final[3] = .folderLabel
        let labelled = ReviewCorrections.gaps(proposals: s.proposals, pages: s.pages, flagged: s.items,
                                              afterFlagged: s.afterFlagged, final: final)
        eq("build: gaps beside a page made a label photo are left out", labelled.map(\.gap), [1, 4])

        // Short or mismatched arrays never trap.
        let short = ReviewCorrections.gaps(proposals: s.proposals, pages: Array(s.pages.prefix(3)), flagged: [],
                                           afterFlagged: s.afterFlagged, final: [])
        eq("build: mismatched lengths give no gap", short.count, 0)
    }

    // MARK: Writing

    private static func request(_ out: URL, urls: [URL], runID: UUID, settings: ResolvedSettingsSnapshot?)
        -> ReviewCorrections.GapRequest {
        let s = scenario()
        return ReviewCorrections.GapRequest(
            runID: runID, recordedAt: day, settings: settings, outputDirectory: out, approach: "local",
            partner: "gemini", urls: urls, outputs: urls.map { $0.deletingPathExtension().appendingPathExtension("pdf") },
            proposals: s.proposals, flagged: s.items, afterFlagged: s.afterFlagged, final: s.final)
    }

    private static func sourcePages(_ root: URL) -> [URL] {
        let dir = root.appendingPathComponent("sources", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return (0..<7).map { n in
            let url = dir.appendingPathComponent("IMG_\(n).jpg")
            try? Data("page \(n)".utf8).write(to: url)
            return url
        }
    }

    private static func writing(_ root: URL, keep: URL?) {
        let out = root.appendingPathComponent("Box 1", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = sourcePages(root)
        let doc = CollectionSettingsDocument(name: "Lincoln box 1", createdAt: day)
        try? CollectionSettingsFile.write(doc, in: out, now: day)
        let runID = UUID()
        let snapshot = ResolvedSettingsSnapshot(runID: runID, resolvedAt: day, collectionID: nil, projectID: nil,
                                                projectName: "Lincoln", macMemoryGB: 16, values: [:], processing: [:])

        eq("write: recorded", ReviewCorrections.recordGaps(request(out, urls: urls, runID: runID, settings: snapshot)), nil)
        let read = ReviewCorrections.gapRecords(in: out)
        eq("write: one record read back", read.count, 1)
        if let r = read.first {
            eq("write: the run's id", r.runID, runID)
            eq("write: the collection's id from its document", r.owner.collectionID, doc.collection.id)
            eq("write: the collection's name from its document", r.owner.collectionName, "Lincoln box 1")
            eq("write: the project's name from the run", r.owner.projectName, "Lincoln")
            eq("write: gaps", r.gaps.map(\.gap), [1, 2, 3, 4])
            eq("write: person-ruled", r.personRuled, 3)
            eq("write: pages", r.pages, 7)
            eq("write: approach and partner", [r.approach, r.partner ?? ""], ["local", "gemini"])
            eq("write: the source's SHA-256", r.gaps.first?.left.sha256,
               InstitutionalComputeImport.sha256(of: urls[1]))
            eq("write: the output's name", r.gaps.first?.left.output, "IMG_1.pdf")
        }
        let file = ReviewCorrections.gapsURL(runID: runID, in: out)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check("write: ISO 8601 dates and sorted keys", text.contains("\"recordedAt\" : \"2026-11-04T12:00:00Z\"")
              && text.range(of: "\"approach\"")!.lowerBound < text.range(of: "\"gaps\"")!.lowerBound)

        // A resume that reviews again replaces the run's record instead of adding a second one.
        var again = request(out, urls: urls, runID: runID, settings: snapshot)
        again.final[4] = .documentStart
        eq("rewrite: recorded", ReviewCorrections.recordGaps(again), nil)
        let reread = ReviewCorrections.gapRecords(in: out)
        eq("rewrite: still one record for the run", reread.count, 1)
        eq("rewrite: the newer review", reread.first?.gaps.first { $0.gap == 3 }?.ruling, .changed)

        // An older review of the run arriving late (two writes racing) never replaces the newer one.
        var late = request(out, urls: urls, runID: runID, settings: snapshot)
        late.recordedAt = day.addingTimeInterval(-60)
        eq("late: no problem reported", ReviewCorrections.recordGaps(late), nil)
        eq("late: the newer review kept", ReviewCorrections.gapRecords(in: out).first?.gaps.first { $0.gap == 3 }?.ruling,
           .changed)

        // A newer build's record of the run is left alone.
        let newerRun = UUID()
        let newerURL = ReviewCorrections.gapsURL(runID: newerRun, in: out)
        let newerText = "{\"schemaVersion\": 2, \"kind\": \"gaps\"}"
        try? Data(newerText.utf8).write(to: newerURL)
        check("newer: refused", ReviewCorrections.recordGaps(request(out, urls: urls, runID: newerRun, settings: nil)) != nil)
        eq("newer: unchanged", (try? String(contentsOf: newerURL, encoding: .utf8)) ?? "", newerText)
        try? fm.removeItem(at: newerURL)

        // A second run adds its own record.
        var second = request(out, urls: urls, runID: UUID(), settings: nil)
        second.recordedAt = day.addingTimeInterval(60)
        _ = ReviewCorrections.recordGaps(second)
        eq("second run: two records", ReviewCorrections.gapRecords(in: out).count, 2)
        eq("second run: owner from the document even without a snapshot",
           ReviewCorrections.gapRecords(in: out).last?.owner.collectionID, doc.collection.id)

        // A run with no gap to record writes nothing.
        var empty = request(out, urls: urls, runID: UUID(), settings: nil)
        empty.proposals = []
        eq("empty: nothing to record", ReviewCorrections.recordGaps(empty), nil)
        eq("empty: no file", ReviewCorrections.gapRecords(in: out).count, 2)

        // Lines: the format the line-correction screen will write, read back.
        let lineRecord = LineReviewRecord(runID: runID, recordedAt: day,
                                          owner: ReviewCorrections.owner(settings: snapshot, in: out), lines: [
            ReviewedLine(page: ReviewedPage(name: "IMG_1.jpg", sha256: "ab", output: nil), line: 0,
                         boundary: [[0, 0], [100, 0], [100, 20], [0, 20]], baseline: [[0, 18], [100, 18]],
                         recognised: "Dear Sir", recognisedBy: "ocr-kraken-ppocrv6", corrected: "Dear Sirs", hand: "A. L."),
        ])
        do { try ReviewCorrections.write(lineRecord, in: out) } catch { check("lines: written", false, "\(error)") }
        eq("lines: read back", ReviewCorrections.lineRecords(in: out), [lineRecord])
        eq("lines: not read as gaps", ReviewCorrections.gapRecords(in: out).count, 2)

        // A file that is not a record is skipped.
        try? Data("not json".utf8).write(to: ReviewCorrections.folder(in: out).appendingPathComponent("gaps-broken.json"))
        eq("reading: a broken file is skipped", ReviewCorrections.gapRecords(in: out).count, 2)
        try? fm.removeItem(at: ReviewCorrections.folder(in: out).appendingPathComponent("gaps-broken.json"))

        if let keep {
            try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
            try? fm.copyItem(at: out, to: keep.appendingPathComponent("Box 1", isDirectory: true))
        }
    }

    // MARK: Guards

    private static func guarded(_ root: URL) {
        let urls = sourcePages(root)

        // No output folder: nothing is created.
        let missing = root.appendingPathComponent("no such folder", isDirectory: true)
        check("guard: no output folder", ReviewCorrections.recordGaps(request(missing, urls: urls, runID: UUID(),
                                                                             settings: nil)) != nil)
        check("guard: nothing created for a missing folder", !fm.fileExists(atPath: missing.path))

        // `.archivesuite` a link: nothing written through it.
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try? fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: CollectionSettingsDocument.folder(in: linked), withDestinationURL: elsewhere)
        check("guard: .archivesuite a link refused",
              ReviewCorrections.recordGaps(request(linked, urls: urls, runID: UUID(), settings: nil)) != nil)
        eq("guard: nothing written through the .archivesuite link",
           (try? fm.contentsOfDirectory(atPath: elsewhere.path)) ?? ["?"], [])

        // `corrections` a link: refused, nothing written through it.
        let sub = root.appendingPathComponent("sublinked", isDirectory: true)
        let away = root.appendingPathComponent("away", isDirectory: true)
        try? fm.createDirectory(at: CollectionSettingsDocument.folder(in: sub), withIntermediateDirectories: true)
        try? fm.createDirectory(at: away, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: ReviewCorrections.folder(in: sub), withDestinationURL: away)
        check("guard: corrections a link refused",
              ReviewCorrections.recordGaps(request(sub, urls: urls, runID: UUID(), settings: nil)) != nil)
        eq("guard: nothing written through the corrections link",
           (try? fm.contentsOfDirectory(atPath: away.path)) ?? ["?"], [])
        eq("guard: a linked corrections folder is not read", ReviewCorrections.gapRecords(in: sub).count, 0)

        // The run's record name a link or a folder: left alone, the link's target unchanged.
        let fileLinked = root.appendingPathComponent("filelinked", isDirectory: true)
        try? fm.createDirectory(at: ReviewCorrections.folder(in: fileLinked), withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.json")
        try? Data("keep me".utf8).write(to: target)
        let runID = UUID()
        try? fm.createSymbolicLink(at: ReviewCorrections.gapsURL(runID: runID, in: fileLinked), withDestinationURL: target)
        check("guard: a linked record name refused",
              ReviewCorrections.recordGaps(request(fileLinked, urls: urls, runID: runID, settings: nil)) != nil)
        eq("guard: the link's target unchanged", (try? String(contentsOf: target, encoding: .utf8)) ?? "", "keep me")
        let folderRun = UUID()
        try? fm.createDirectory(at: ReviewCorrections.gapsURL(runID: folderRun, in: fileLinked),
                                withIntermediateDirectories: true)
        check("guard: a folder at the record name refused",
              ReviewCorrections.recordGaps(request(fileLinked, urls: urls, runID: folderRun, settings: nil)) != nil)

        // `.archivesuite` an ordinary file: refused, the file unchanged.
        let filed = root.appendingPathComponent("filed", isDirectory: true)
        try? fm.createDirectory(at: filed, withIntermediateDirectories: true)
        try? Data("a file".utf8).write(to: CollectionSettingsDocument.folder(in: filed))
        check("guard: .archivesuite a file refused",
              ReviewCorrections.recordGaps(request(filed, urls: urls, runID: UUID(), settings: nil)) != nil)
        eq("guard: that file unchanged",
           (try? String(contentsOf: CollectionSettingsDocument.folder(in: filed), encoding: .utf8)) ?? "", "a file")
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let report = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REVIEW_CORRECTIONS_TEST_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
    }
}
#endif
