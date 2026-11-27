import ArchiveCore
import Foundation

/// The adoption tool's headless entry (`scripts/adopt-archive.sh`), one step per launch (W49.corpus-adoption-tool).
/// Started only by `ARCHIVE_ADOPT`; in normal use it does nothing. Each step writes its report into the state folder
/// and exits. The source is read only; the real corpus is refused (`AdoptionInventory.protectedRoots`).
///
///   inventory  ARCHIVE_ADOPT_SOURCE, optional ARCHIVE_ADOPT_ORIGINALS (`none` for no originals tree; unset uses the
///              pre-app `Archival Photos JPEGS` beside an `Archival Photos` source), ARCHIVE_ADOPT_COLOURS
///              (`red-box-purple-folder`, the default, or `none`).
///   classify   optional, before convert: finds box and folder photos with no tag or colour mark.
///              ARCHIVE_ADOPT_CLASSIFY_ROUTE (`vision-heuristic`, $0, or `<provider>:<model id>` with its key in
///              ARCHIVE_ADOPT_CLASSIFY_KEY). Alone it prints the estimated time and cost and changes nothing;
///              ARCHIVE_ADOPT_CLASSIFY_RUN=1 with ARCHIVE_ADOPT_CLASSIFY_MAX_COST (dollars) runs it within that cap.
///   decide     ARCHIVE_ADOPT_DECISION (accept|skip|review) for waiting entries whose reasons are all in
///              ARCHIVE_ADOPT_REASONS (comma-separated codes); ARCHIVE_ADOPT_KEEP_ORIGINAL=0 drops their originals.
///   convert    ARCHIVE_ADOPT_DEST, a new or empty folder (or the one this state folder's ledger names).
///   verify     re-reads the derived archive against the manifest and the source.
///   labels     proposes container runs from Box/Folder labels; ARCHIVE_ADOPT_APPLY=1 writes them,
///              ARCHIVE_ADOPT_RASTER_FALLBACK=1 reads a label without an original from its PDF's first page.
@MainActor
enum AdoptionCommand {
    private static var didRun = false

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard !didRun, let step = env["ARCHIVE_ADOPT"], !step.isEmpty else { return }
        didRun = true
        Task { @MainActor in
            let (text, ok, stateIsSafe) = await runStep(step: step, env: env)
            // Only a state folder that passed its placement check is ever written to.
            if stateIsSafe, let state = env["ARCHIVE_ADOPT_STATE"] {
                try? text.write(to: URL(fileURLWithPath: state).appendingPathComponent("last-step.txt"),
                                atomically: true, encoding: .utf8)
            }
            FileHandle.standardOutput.write(Data(text.utf8))
            exit(ok ? 0 : 1)
        }
    }

    static func run(step: String, env: [String: String]) async -> (String, Bool) {
        let (text, ok, _) = await runStep(step: step, env: env)
        return (text, ok)
    }

    /// The state folder is checked against the protected corpus and the archives before anything is written to it,
    /// then locked for the step so two runs cannot freeze one entry twice.
    private static func prepareState(_ state: URL, step: String, env: [String: String]) throws -> Int32 {
        try AdoptionInventory.refuseProtected(state)
        let manifestURL = state.appendingPathComponent(AdoptionManifest.fileName)
        var trees: [URL] = []
        if step == "inventory" {
            trees = [env["ARCHIVE_ADOPT_SOURCE"], env["ARCHIVE_ADOPT_ORIGINALS"]].compactMap { $0 }
                .filter { $0 != "none" && !$0.isEmpty }.map { URL(fileURLWithPath: $0, isDirectory: true) }
            if env["ARCHIVE_ADOPT_ORIGINALS"] == nil, let source = trees.first,
               let beside = AdoptionInventory.legacyOriginals(beside: source) { trees.append(beside) }
        } else if let manifest = try? AdoptionManifest.decode(Data(contentsOf: manifestURL)) {
            trees = [manifest.sourceRoot, manifest.originalsRoot].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        }
        let planned = AdoptionInventory.canonicalPath(state)
        for tree in trees {
            let a = planned.pathComponents.map { $0.lowercased() }
            let b = AdoptionInventory.canonicalPath(tree).pathComponents.map { $0.lowercased() }
            if a.starts(with: b) || b.starts(with: a) {
                throw AdoptionError.statePlacement("must be outside the source and the originals")
            }
        }
        try FileManager.default.createDirectory(at: planned, withIntermediateDirectories: true)
        let lock = open(planned.appendingPathComponent(".adoption.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw AdoptionError.busy }
        return lock
    }

    private static func runStep(step: String, env: [String: String]) async -> (String, Bool, Bool) {
        guard let statePath = env["ARCHIVE_ADOPT_STATE"], !statePath.isEmpty else {
            return ("ARCHIVE_ADOPT_STATE is required\n", false, false)
        }
        let state = URL(fileURLWithPath: statePath, isDirectory: true)
        let manifestURL = state.appendingPathComponent(AdoptionManifest.fileName)
        let lock: Int32
        do { lock = try prepareState(state, step: step, env: env) } catch {
            return ("adoption \(step) refused: \(error.localizedDescription)\n", false, false)
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        let (text, ok) = await perform(step: step, env: env, state: state, manifestURL: manifestURL)
        return (text, ok, true)
    }

    private static func perform(step: String, env: [String: String], state: URL, manifestURL: URL) async -> (String, Bool) {
        do {
            switch step {
            case "inventory":
                guard let sourcePath = env["ARCHIVE_ADOPT_SOURCE"] else { return ("ARCHIVE_ADOPT_SOURCE is required\n", false) }
                let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
                let originals: URL? = switch env["ARCHIVE_ADOPT_ORIGINALS"] {
                case "none": nil
                case nil, "": AdoptionInventory.legacyOriginals(beside: source)
                case let path?: URL(fileURLWithPath: path, isDirectory: true)
                }
                guard let colours = AdoptionManifest.ColourPreset(rawValue: env["ARCHIVE_ADOPT_COLOURS"] ?? "red-box-purple-folder") else {
                    return ("ARCHIVE_ADOPT_COLOURS must be red-box-purple-folder or none\n", false)
                }
                if FileManager.default.fileExists(atPath: manifestURL.path) {
                    return ("\(manifestURL.path) exists; use a new state folder for a new inventory\n", false)
                }
                let manifest = try await PDFGenerator.runWorker {
                    try AdoptionInventory.run(source: source, originals: originals, colours: colours)
                }
                try manifest.encoded().write(to: manifestURL, options: .withoutOverwriting)
                let report = AdoptionReport.inventory(manifest)
                try write(report, "inventory-report.md", in: state)
                return (report, true)
            case "classify":
                var manifest = try AdoptionManifest.decode(Data(contentsOf: manifestURL))
                let ledger = AdoptionInventory.canonicalDirectory(state).flatMap { try? AdoptionLedger.load(from: $0) }
                guard let route = AdoptionClassify.Route(env["ARCHIVE_ADOPT_CLASSIFY_ROUTE"] ?? "") else {
                    return ("ARCHIVE_ADOPT_CLASSIFY_ROUTE must be \(AdoptionClassify.Route.heuristicName) or "
                            + "<provider>:<model id> from the Processor's model list\n", false)
                }
                let key = env["ARCHIVE_ADOPT_CLASSIFY_KEY"] ?? ""
                if case .model = route, key.isEmpty { return ("ARCHIVE_ADOPT_CLASSIFY_KEY is required for \(route.name)\n", false) }
                let estimate = await AdoptionClassify.estimate(manifest, ledger: ledger, route: route)
                var report = AdoptionReport.classifyEstimate(estimate, route: route)
                guard env["ARCHIVE_ADOPT_CLASSIFY_RUN"] == "1" else {
                    report += "\nNothing was classified. To run it, repeat with run and a cost cap of at least the estimate.\n"
                    try write(report, "classify-estimate.md", in: state)
                    return (report, true)
                }
                guard let dollars = estimate.dollars else {
                    return (report + "\nNot run: the model's price is not known, so its cost cannot be shown first.\n", false)
                }
                if dollars > 0 {
                    guard let cap = env["ARCHIVE_ADOPT_CLASSIFY_MAX_COST"].flatMap(Double.init), cap >= dollars else {
                        return (report + "\nNot run: ARCHIVE_ADOPT_CLASSIFY_MAX_COST must be at least "
                                + "\(CostEstimate.money(dollars)).\n", false)
                    }
                }
                let result = try await AdoptionClassify.run(&manifest, ledger: ledger, route: route,
                                                            judge: route.judge(apiKey: key))
                try manifest.encoded().write(to: manifestURL, options: .atomic)
                report += "\n" + AdoptionReport.classified(result, route: route)
                try write(report, "classify-report.md", in: state)
                return (report, result.failed.isEmpty)
            case "decide":
                var manifest = try AdoptionManifest.decode(Data(contentsOf: manifestURL))
                guard let decision = AdoptionManifest.Decision(rawValue: env["ARCHIVE_ADOPT_DECISION"] ?? "") else {
                    return ("ARCHIVE_ADOPT_DECISION must be accept, skip or review\n", false)
                }
                let codes = (env["ARCHIVE_ADOPT_REASONS"] ?? "").split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let reasons = Set(codes.compactMap(AdoptionManifest.Reason.init(rawValue:)))
                guard !reasons.isEmpty, reasons.count == codes.count else {
                    return ("ARCHIVE_ADOPT_REASONS must list known reason codes\n", false)
                }
                let keep = env["ARCHIVE_ADOPT_KEEP_ORIGINAL"].map { $0 != "0" }
                let changed = manifest.decide(decision, reasons: reasons, keepOriginal: keep)
                try manifest.encoded().write(to: manifestURL, options: .atomic)
                return ("\(changed) entries set to \(decision.rawValue)\n", true)
            case "convert":
                guard let dest = env["ARCHIVE_ADOPT_DEST"] else { return ("ARCHIVE_ADOPT_DEST is required\n", false) }
                let manifest = try AdoptionManifest.decode(Data(contentsOf: manifestURL))
                let outcomes = try await AdoptionConversion.run(manifest, destination: URL(fileURLWithPath: dest, isDirectory: true),
                                                                state: state)
                let verification = try AdoptionVerification.run(manifest, state: state)
                let report = AdoptionReport.conversion(outcomes) + "\n" + AdoptionReport.verification(verification)
                try write(report, "conversion-report.md", in: state)
                let failed = outcomes.contains { outcome in
                    switch outcome.state {
                    case .failed, .skipped: true
                    case .converted, .alreadyConverted: false
                    }
                }
                return (report, !failed && verification.passed)
            case "verify":
                let manifest = try AdoptionManifest.decode(Data(contentsOf: manifestURL))
                let verification = try AdoptionVerification.run(manifest, state: state)
                let report = AdoptionReport.verification(verification)
                try write(report, "verification-report.md", in: state)
                return (report, verification.passed)
            case "labels":
                let manifest = try AdoptionManifest.decode(Data(contentsOf: manifestURL))
                let results = try await AdoptionLabels.run(manifest, state: state, apply: env["ARCHIVE_ADOPT_APPLY"] == "1",
                                                           rasterFallback: env["ARCHIVE_ADOPT_RASTER_FALLBACK"] == "1")
                let report = AdoptionReport.labels(results)
                try write(report, "labels-report.md", in: state)
                return (report, !results.contains { if case .refused = $0.outcome { true } else { false } })
            default:
                return ("unknown ARCHIVE_ADOPT step \(step)\n", false)
            }
        } catch {
            return ("adoption \(step) failed: \(error.localizedDescription)\n", false)
        }
    }

    private static func write(_ text: String, _ name: String, in state: URL) throws {
        try text.write(to: state.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// Plain-language summaries for the reviewer; the manifest holds every detail.
enum AdoptionReport {
    static let listLimit = 200

    static func inventory(_ manifest: AdoptionManifest) -> String {
        var lines = ["# Adoption inventory", "",
                     "Source: \(manifest.sourceRoot)",
                     "Originals: \(manifest.originalsRoot ?? "none")",
                     "Colours: \(manifest.colours.rawValue)",
                     "Whole tree read: \(manifest.complete ? "yes" : "no — \(manifest.unreadable.count) unreadable folders")",
                     "", "PDFs: \(manifest.entries.count)"]
        for decision in [AdoptionManifest.Decision.accept, .review, .skip] {
            lines.append("- \(decision.rawValue): \(manifest.entries.filter { $0.decision == decision }.count)")
        }
        let matched = manifest.entries.filter { $0.original.state == .matched }
        lines.append("- originals matched: \(matched.count) (mirrored \(matched.filter { $0.original.rule == "mirrored" }.count), "
                     + "by name \(matched.filter { $0.original.rule == "stem" }.count))")
        let typed = manifest.entries.compactMap(\.proposal.itemType)
        lines.append("- Box/Folder: \(typed.count) (from colour \(typed.filter { $0.rule.hasPrefix("colour") }.count))")
        lines += ["", "## Waiting for review, by reason", ""]
        for reason in AdoptionManifest.Reason.allCases {
            let count = manifest.entries.filter { $0.review.contains(reason) }.count
            if count > 0 { lines.append("- `\(reason.rawValue)`: \(count)") }
        }
        let waiting = manifest.entries.filter { $0.decision == .review }
        if !waiting.isEmpty {
            lines += ["", "## Entries waiting (first \(min(listLimit, waiting.count)) of \(waiting.count))", ""]
            for entry in waiting.prefix(listLimit) {
                var detail = entry.review.map(\.rawValue).joined(separator: ", ")
                if !entry.original.candidates.isEmpty { detail += "; candidates: " + entry.original.candidates.joined(separator: ", ") }
                lines.append("- \(entry.path) — \(detail)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func classifyEstimate(_ estimate: AdoptionClassify.Estimate, route: AdoptionClassify.Route) -> String {
        var lines = ["# Adoption label classifier: estimate", "", "Route: \(route.name)",
                     "Files to read: \(estimate.candidates) (one page, no Box or Folder tag or colour, not yet read)"]
        let vision = String(format: "%.1f", estimate.visionSecondsPerPage)
        lines.append(estimate.sampled > 0
            ? "Vision on this Mac: \(vision) s a file, timed on \(estimate.sampled) of them ($0)"
            : "Vision on this Mac: not timed, no files to read")
        switch route {
        case .heuristic:
            lines.append("Classifier: the Processor's keyword rules on this Mac; nothing is sent anywhere")
        case .model(let model):
            lines.append("Classifier: \(model.displayName), sent the Vision text only (never the image), "
                         + "about \(String(format: "%.1f", estimate.secondsPerCall)) s a call")
        }
        lines.append("Estimated time: \(TimeEstimate.fmt(estimate.seconds))")
        if let dollars = estimate.dollars, let each = estimate.dollarsPerPage {
            lines.append("Estimated cost: \(CostEstimate.money(dollars)) (\(CostEstimate.money(each)) a file, the Processor's "
                         + "estimate for a text-only classification; a reasoning model may cost more)")
        } else {
            lines.append("Estimated cost: unknown, the model's price is not listed")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func classified(_ result: AdoptionClassify.Result, route: AdoptionClassify.Route) -> String {
        var lines = ["# Adoption label classifier: result", "",
                     "- box labels: \(result.boxes.count)", "- folder labels: \(result.folders.count)",
                     "- documents: \(result.documents)", "- no text read: \(result.unread.count)"]
        if case .model = route { lines.append("- model calls: \(result.calls)") }
        lines.append("Labels found wait for review as `type-classified`.")
        for path in (result.boxes + result.folders).prefix(listLimit) { lines.append("- \(path)") }
        for path in result.failed { lines.append("- FAILED \(path): not read; a later run tries it again") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func conversion(_ outcomes: [AdoptionConversion.Outcome]) -> String {
        var lines = ["# Adoption conversion", ""]
        let converted = outcomes.filter { $0.state == .converted }
        lines.append("- converted: \(converted.count) (originals preserved: \(converted.filter(\.keptOriginal).count))")
        lines.append("- already converted: \(outcomes.filter { $0.state == .alreadyConverted }.count)")
        for outcome in outcomes {
            switch outcome.state {
            case .skipped(let why): lines.append("- skipped \(outcome.path): \(why)")
            case .failed(let why): lines.append("- FAILED \(outcome.path): \(why)")
            default: break
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func verification(_ result: AdoptionVerification.Result) -> String {
        var lines = ["# Adoption verification", "", "- verified: \(result.verified.count)",
                     "- problems: \(result.findings.count)"]
        lines += result.findings.map { "- \($0.path): \($0.problem)" }
        lines.append(result.passed ? "\nVERIFIED" : "\nNOT VERIFIED")
        return lines.joined(separator: "\n") + "\n"
    }

    static func labels(_ results: [AdoptionLabels.DirectoryResult]) -> String {
        var lines = ["# Adoption labels", ""]
        for result in results {
            let state: String = switch result.outcome {
            case .proposed: "proposed (not written)"
            case .wrote: "written"
            case .unchanged: "unchanged"
            case .changedSinceRead: "changed since read; not written"
            case .refused(let why): "refused: \(why)"
            }
            var line = "- \(result.path.isEmpty ? "(top folder)" : result.path): \(result.markers.count) labels, \(state)"
            if !result.unread.isEmpty { line += "; \(result.unread.count) without an original, unread" }
            if result.warnings > 0 { line += "; \(result.warnings) warnings" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
