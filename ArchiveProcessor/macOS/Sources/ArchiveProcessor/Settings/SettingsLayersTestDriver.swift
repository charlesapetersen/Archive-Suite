#if DEBUG // a test driver, compiled out of Release
import ArchiveCore
import Foundation

/// Headless, $0 self-test of the settings layers and the collection's settings document (W46.settings-layers), gated
/// by `SETTINGS_LAYERS_TEST=1` (does nothing in normal use). Every file it writes is under a fresh scratch folder in
/// `SETTINGS_LAYERS_TEST_DIR` (else the temporary folder): never the app's own store, never an output folder of the
/// user's, never the corpus. No Keychain read, no network, no window. Run by `scripts/test-settings-layers.sh`.
@MainActor
enum SettingsLayersTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SETTINGS_LAYERS_TEST"] == "1" else { return }
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
    private static let day = Date(timeIntervalSince1970: 1_793_793_600)   // noon UTC, 2026-11-04 in any US zone

    private static func run() {
        let base = ProcessInfo.processInfo.environment["SETTINGS_LAYERS_TEST_DIR"].map(URL.init(fileURLWithPath:))
            ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("settings-layers-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        values()
        resolution(root)
        money()
        solverInputs()
        documentWrites(root)
        freezing(root)
        generalStore(root)
        ledger(root)
        processingCapture()
        finish()
    }

    // MARK: Values

    private static func values() {
        let all: [SettingsValue] = [.bool(true), .int(3), .double(2.5), .string("x"), .strings(["a", "b"]),
                                    .numbers(["typewritten": 60, "handwritten": 40])]
        let back = try? JSONDecoder().decode([SettingsValue].self, from: JSONEncoder().encode(all))
        eq("every value kind round-trips through JSON", back ?? [], all)
        let unknown = Data(#"{"type":"blob","value":1}"#.utf8)
        check("an unknown value kind does not decode", (try? JSONDecoder().decode(SettingsValue.self, from: unknown)) == nil)
    }

    // MARK: Resolution

    private static func resolution(_ root: URL) {
        var general = SettingsLayer(kind: .general, name: "General")
        var project = SettingsLayer(kind: .project, name: "Letters")
        var collection = SettingsLayer(kind: .collection, name: "Box 12")

        var r = SettingsResolver(general: general, project: project, collection: collection)
        let built = r.resolve(.hours)
        check("an unanswered value is the built-in one", built.layer == nil && built.value == .double(8))
        eq("the built-in source reads as the free default", built.sourceText, "built in: Free, on this Mac")

        general.set(.hours, .double(12), source: .setByUser(day))
        r.general = general
        eq("the general layer answers when nothing nearer does", r.resolve(.hours).layer, .general)
        eq("the source names the general settings and the day", r.resolve(.hours).sourceText,
           "from your general settings, you set this on 2026-11-04")

        project.set(.hours, .double(4), source: .startingPoint("A few dollars, overnight", day))
        r.project = project
        eq("a project's own value wins over the general layer", r.resolve(.hours).value, .double(4))
        eq("the project's source names it", r.resolve(.hours).sourceText,
           "from the project “Letters”, filled by “A few dollars, overnight” on 2026-11-04")

        collection.set(.mix, .numbers(["handwritten": 100]), source: .measured(day, sample: 200))
        collection.set(.hours, .double(2), source: .setByUser(day))
        r.collection = collection
        eq("the collection's own value wins", r.resolve(.hours).value, .double(2))
        eq("a measured value says so, with its sample", r.resolve(.mix).sourceText,
           "set for this collection, measured on 2026-11-04 from 200 photos")

        collection.reset(.hours)
        r.collection = collection
        eq("a reset shows the inherited value again", r.resolve(.hours).value, .double(4))
        check("a reset leaves the collection's other values", r.resolve(.mix).layer == .collection)

        general.set(.hours, .double(20), source: .setByUser(day))
        project.reset(.hours)
        r.general = general; r.project = project
        eq("inheritance is live: a later general change reaches the collection", r.resolve(.hours).value, .double(20))

        check("a collection cannot hold a general-only value",
              !collection.set(.cluster, .bool(true), source: .setByUser(day))
              && !project.set(.keys, .strings(["gemini"]), source: .setByUser(day)))
        check("a value of the wrong kind is refused", !general.set(.hours, .string("eight"), source: .setByUser(day)))
        check("an unknown key is refused", !general.set(SettingsKey(rawValue: "colour"), .bool(true), source: .setByUser(day)))

        // A hand-edited document cannot smuggle in a general-only or wrongly-typed value.
        var smuggled = SettingsLayer(kind: .collection, name: "Edited")
        smuggled.entries["cluster"] = SettingsEntry(value: .bool(true), source: .setByUser(day))
        smuggled.entries["hours"] = SettingsEntry(value: .string("all night"), source: .setByUser(day))
        let rs = SettingsResolver(general: general, project: nil, collection: smuggled)
        check("a smuggled general-only value is ignored", rs.resolve(.cluster).value == .bool(false))
        eq("a smuggled wrongly-typed value is ignored", rs.resolve(.hours).value, .double(20))

        let card = SettingsKey.override(stage: "reading", part: "handwritten")
        check("a stage override is a key any layer may hold",
              collection.set(card, .string("lightonocr3-4b-8bit"), source: .setByUser(day)))
        r.collection = collection
        check("overrides are resolved with the catalog",
              r.resolveAll()[card.rawValue]?.value == .string("lightonocr3-4b-8bit")
              && r.resolveAll().count == SettingsKey.catalog.count + 1)
    }

    // MARK: Money

    private static func money() {
        var general = SettingsLayer(kind: .general, name: "General")
        var collection = SettingsLayer(kind: .collection, name: "C")
        collection.set(.batchCeilingUSD, .double(50), source: .setByUser(day))
        var r = SettingsResolver(general: general, project: nil, collection: collection)
        eq("under the habit none nothing is spent, whatever the collection says", r.ceilingUSD(), 0)

        general.set(.moneyHabit, .string(MoneyHabit.perBatch.rawValue), source: .setByUser(day))
        r.general = general
        eq("per batch, the collection's ceiling", r.ceilingUSD(), 50)

        general.set(.moneyHabit, .string(MoneyHabit.perMonth.rawValue), source: .setByUser(day))
        general.set(.monthCeilingUSD, .double(30), source: .setByUser(day))
        r.general = general
        eq("per month, the remainder, no more than a batch ceiling a layer set", r.ceilingUSD(spentThisMonthUSD: 12), 18)
        r.collection = nil
        eq("per month with no batch ceiling, the whole remainder", r.ceilingUSD(spentThisMonthUSD: 12), 18)
        eq("an overspent month leaves nothing", r.ceilingUSD(spentThisMonthUSD: 40), 0)
        r.collection = SettingsLayer(kind: .collection, name: "C2")
        r.collection?.set(.batchCeilingUSD, .double(10), source: .setByUser(day))
        eq("per month, a batch ceiling below the remainder holds", r.ceilingUSD(spentThisMonthUSD: 12), 10)
        check("a value that is not a finite number is refused (JSON cannot hold it)",
              !general.set(.monthCeilingUSD, .double(.infinity), source: .setByUser(day))
              && !general.set(.mix, .numbers(["typewritten": .nan]), source: .setByUser(day)))
    }

    // MARK: Solver inputs

    private static func solverInputs() {
        let r = SettingsResolver(general: SettingsLayer(kind: .general, name: "General"), project: nil, collection: nil)
        let a = r.answers(pages: 300)
        let skipped = SettingsAnswers.skippedInterview
        check("with nothing answered the solver gets the skipped interview (owner call 3)",
              a.staysOnMac == skipped.staysOnMac && a.ceilingUSD == skipped.ceilingUSD
              && a.priorities == skipped.priorities && a.hours == skipped.hours && a.mix == skipped.mix
              && a.preference == skipped.preference && a.pages == 300)

        var general = SettingsLayer(kind: .general, name: "General")
        general.set(.keys, .strings(["gemini", "openrouter"]), source: .detected(day))
        general.set(.plans, .strings(["claude"]), source: .detected(day))
        general.set(.cluster, .bool(true), source: .setByUser(day))
        general.set(.gpusPerJob, .int(0), source: .setByUser(day))
        general.set(.excludedModelFamilies, .strings(["gemini"]), source: .setByUser(day))
        var collection = SettingsLayer(kind: .collection, name: "C")
        collection.set(.priorities, .strings(["dates", "reading", "bogus"]), source: .setByUser(day))
        collection.set(.preference, .string("cheapestWithinPoint"), source: .setByUser(day))
        collection.set(.staysOnMac, .bool(false), source: .setByUser(day))
        collection.set(.checkingMinutes, .double(-5), source: .setByUser(day))
        let r2 = SettingsResolver(general: general, project: nil, collection: collection)
        let res = r2.resources(macMemoryGB: 16)
        check("resources come from the general layer, the memory from the Mac",
              res.keys == ["gemini", "openrouter"] && res.plans == ["claude"] && res.cluster
              && res.gpusPerJob == 1 && res.macMemoryGB == 16 && res.excludedModelFamilies == ["gemini"])
        let a2 = r2.answers(pages: 10)
        check("answers come from the nearest layer; an unknown priority is dropped, minutes are never negative",
              a2.priorities == [.dates, .reading] && a2.preference == .cheapestWithinPoint
              && !a2.staysOnMac && a2.checkingMinutes == 0)
    }

    // MARK: The document

    private static func folder(_ root: URL, _ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func documentWrites(_ root: URL) {
        let out = folder(root, "out")
        eq("a folder without a document reads as missing", CollectionSettingsFile.read(in: out), .missing)
        var doc = CollectionSettingsDocument(name: "Box 12", createdAt: day)
        doc.collection.set(.languages, .strings(["en", "de"]), source: .setByUser(day))
        check("the document writes into a new .archivesuite folder",
              (try? CollectionSettingsFile.write(doc, in: out)) != nil
              && fm.fileExists(atPath: CollectionSettingsDocument.url(in: out).path))
        eq("and reads back the same", CollectionSettingsFile.read(in: out), .document(doc))
        let names = (try? fm.contentsOfDirectory(atPath: out.path)) ?? []
        eq("nothing else is written into the output folder", names, [".archivesuite"])

        // A document another app or Mac wrote with fractional seconds, and one entry of a kind this build does not
        // know: read, the unknown entry dropped, the rest kept.
        let foreign = folder(root, "foreign")
        _ = folder(foreign, ".archivesuite")
        let foreignJSON = """
        {"schemaVersion":1,"createdAt":"2026-11-04T12:00:00.250Z","collection":{"id":"\(UUID().uuidString)",
        "kind":"collection","name":"F","entries":{
        "hours":{"value":{"type":"double","value":3},"source":{"setByUser":{"_0":"2026-11-04T12:00:00Z"}}},
        "mix":{"value":{"type":"histogram","value":[1,2]},"source":{"setByUser":{"_0":"2026-11-04T12:00:00Z"}}}}}}
        """
        try? Data(foreignJSON.utf8).write(to: CollectionSettingsDocument.url(in: foreign))
        if case .document(let d) = CollectionSettingsFile.read(in: foreign) {
            check("fractional seconds read, and an unknown value kind drops only its entry",
                  d.collection.entries.keys.sorted() == ["hours"])
        } else {
            check("fractional seconds read, and an unknown value kind drops only its entry", false, "not read")
        }

        // A document that cannot be opened is left alone, not renamed aside or replaced.
        let locked = folder(root, "locked")
        _ = folder(locked, ".archivesuite")
        let lockedURL = CollectionSettingsDocument.url(in: locked)
        let lockedBytes = (try? CollectionSettingsFile.encoder().encode(doc)) ?? Data()
        try? lockedBytes.write(to: lockedURL)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedURL.path)
        let lockedRead = CollectionSettingsFile.read(in: locked)
        let lockedWrite = (try? CollectionSettingsFile.write(doc, in: locked)) == nil
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedURL.path)
        check("a document that cannot be opened is refused and left exactly as it was",
              lockedRead == .refused(.cannotRead(lockedURL.path)) && lockedWrite
              && (try? Data(contentsOf: lockedURL)) == lockedBytes
              && ((try? fm.contentsOfDirectory(atPath: lockedURL.deletingLastPathComponent().path)) ?? []).count == 1)

        // A plain file where the folder should be.
        let plain = folder(root, "plainfile")
        try? Data("x".utf8).write(to: plain.appendingPathComponent(".archivesuite"))
        check("a file named .archivesuite is refused and kept",
              (try? CollectionSettingsFile.write(doc, in: plain)) == nil
              && (try? Data(contentsOf: plain.appendingPathComponent(".archivesuite"))) == Data("x".utf8))

        // Too large to be ours.
        let big = folder(root, "big")
        _ = folder(big, ".archivesuite")
        let bigBytes = Data(count: CollectionSettingsFile.maxBytes + 1)
        try? bigBytes.write(to: CollectionSettingsDocument.url(in: big))
        check("an oversized document is refused and left alone",
              CollectionSettingsFile.read(in: big) == .refused(.tooLarge(bigBytes.count))
              && (try? CollectionSettingsFile.write(doc, in: big)) == nil
              && (try? Data(contentsOf: CollectionSettingsDocument.url(in: big)))?.count == bigBytes.count)

        // Unreadable: renamed aside, never deleted, then a fresh document.
        let broken = folder(root, "broken")
        let dir = folder(broken, ".archivesuite")
        let junk = Data("not json {".utf8)
        try? junk.write(to: CollectionSettingsDocument.url(in: broken))
        eq("an unreadable file reads as unreadable", CollectionSettingsFile.read(in: broken), .unreadable)
        let wrote = (try? CollectionSettingsFile.write(doc, in: broken, now: day)) != nil
        let aside = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains("unreadable") }
        check("an unreadable file is set aside with its bytes, and a fresh document written",
              wrote && aside.count == 1
              && (try? Data(contentsOf: dir.appendingPathComponent(aside[0]))) == junk
              && CollectionSettingsFile.read(in: broken) == .document(doc))

        // Newer schema: left exactly as it is.
        let newer = folder(root, "newer")
        _ = folder(newer, ".archivesuite")
        let future = Data(#"{"schemaVersion": 99, "future": true}"#.utf8)
        try? future.write(to: CollectionSettingsDocument.url(in: newer))
        eq("a newer build's document is refused", CollectionSettingsFile.read(in: newer), .refused(.newerSchema(99)))
        check("and is not overwritten",
              (try? CollectionSettingsFile.write(doc, in: newer)) == nil
              && (try? Data(contentsOf: CollectionSettingsDocument.url(in: newer))) == future)

        // A link where the folder should be: nothing is written through it.
        let linked = folder(root, "linked")
        let elsewhere = folder(root, "elsewhere")
        try? fm.createSymbolicLink(at: linked.appendingPathComponent(".archivesuite"), withDestinationURL: elsewhere)
        check("a linked .archivesuite folder is refused and nothing lands where it points",
              (try? CollectionSettingsFile.write(doc, in: linked)) == nil
              && ((try? fm.contentsOfDirectory(atPath: elsewhere.path)) ?? ["x"]).isEmpty)

        // A link where the file should be.
        let fileLinked = folder(root, "filelinked")
        _ = folder(fileLinked, ".archivesuite")
        let target = root.appendingPathComponent("target.json")
        let original = Data("keep me".utf8)
        try? original.write(to: target)
        try? fm.createSymbolicLink(at: CollectionSettingsDocument.url(in: fileLinked), withDestinationURL: target)
        check("a linked document file is refused and its target untouched",
              (try? CollectionSettingsFile.write(doc, in: fileLinked)) == nil
              && (try? Data(contentsOf: target)) == original)

        let missing = root.appendingPathComponent("no-such-folder")
        check("no output folder: nothing is created",
              (try? CollectionSettingsFile.write(doc, in: missing)) == nil && !fm.fileExists(atPath: missing.path))

        let notCollection = folder(root, "wrongkind")
        var wrong = doc
        wrong.collection.kind = .general
        try? fm.createDirectory(at: notCollection.appendingPathComponent(".archivesuite"), withIntermediateDirectories: true)
        try? CollectionSettingsFile.encoder().encode(wrong).write(to: CollectionSettingsDocument.url(in: notCollection))
        eq("a document whose layer is not a collection is unreadable", CollectionSettingsFile.read(in: notCollection),
           .unreadable)
    }

    // MARK: Freezing a run

    private static func freezing(_ root: URL) {
        let store = SettingsLayerStore(directory: folder(root, "store-freeze"))
        store.setGeneral(.hours, .double(10), source: .setByUser(day))
        let project = store.addProject(named: "Letters")
        if let project {
            store.updateProject(project.id) { $0.set(.staysOnMac, .bool(false), source: .setByUser(day)) }
        }
        let out = folder(root, "freeze-out")
        let made = store.updateCollection(in: out) {
            $0.projectID = project?.id
            $0.collection.set(.languages, .strings(["fr"]), source: .setByUser(day))
        }
        check("a collection's layer is written into its folder with its project", made?.projectName == "Letters")

        let processing = ["selectedProvider": SettingsValue.string("gemini")]
        let run1 = UUID(), run2 = UUID()
        let s1 = store.snapshot(outputDirectory: out, runID: run1, processing: processing, macMemoryGB: 16, now: day)
        check("resolving a run writes nothing", CollectionSettingsFile.runs(in: out).isEmpty)
        store.setGeneral(.hours, .double(6), source: .setByUser(day))
        let s2 = store.snapshot(outputDirectory: out, runID: run2, processing: processing, macMemoryGB: 16,
                                now: day.addingTimeInterval(60))
        let p1 = store.record(s1, kind: "processFiles", fileCount: 3, in: out)
        let p2 = store.record(s2, kind: "batch", fileCount: 5, in: out)
        check("recording writes without a problem", p1 == nil && p2 == nil)
        check("the snapshot holds each value with its source",
              s1.values["hours"]?.value == .double(10) && s1.values["hours"]?.layer == .general
              && s1.values["staysOnMac"]?.layer == .project && s1.values["languages"]?.layer == .collection
              && s1.values["cluster"]?.layer == nil && s1.projectName == "Letters" && s1.macMemoryGB == 16
              && s1.processing == processing && s1.collectionID == made?.collection.id && s1.runID == run1)
        let runs = CollectionSettingsFile.runs(in: out)
        check("each run is its own record in the collection, oldest first, frozen as it started",
              runs.map(\.id) == [run1, run2] && runs.map(\.kind) == ["processFiles", "batch"]
              && runs[0].settings.values["hours"]?.value == .double(10)
              && runs[1].settings.values["hours"]?.value == .double(6) && runs[1].fileCount == 5)
        eq("the run count reads the names alone", CollectionSettingsFile.runCount(in: out), 2)
        if case .document(let doc) = CollectionSettingsFile.read(in: out) {
            check("recording leaves the collection's own layer as it was", doc.collection.entries.count == 1)
        } else {
            check("recording leaves the collection's own layer as it was", false, "no document")
        }
        check("a run record is never written over",
              store.record(s1, kind: "processFiles", fileCount: 3, in: out) != nil
              && CollectionSettingsFile.runs(in: out).count == 2)

        readByReaderAndNotes(out, runs: [run1, run2])

        let fresh = folder(root, "freeze-fresh")
        let s3 = store.snapshot(outputDirectory: fresh, runID: UUID(), processing: [:], macMemoryGB: 16, now: day)
        store.record(s3, kind: "processFiles", fileCount: 1, in: fresh)
        if case .document(let d) = CollectionSettingsFile.read(in: fresh) {
            check("a first run creates the collection, and its record names it",
                  CollectionSettingsFile.runs(in: fresh).first?.settings.collectionID == d.collection.id)
        } else {
            check("a first run creates the collection", false, "no document")
        }

        if let project { store.deleteProject(project.id) }
        let s4 = store.snapshot(outputDirectory: out, runID: UUID(), processing: [:], macMemoryGB: 16, now: day)
        check("a deleted project falls back to the general layer and keeps its name on record",
              s4.values["staysOnMac"]?.layer == nil && s4.projectName == "Letters")

        let newer = folder(root, "freeze-newer")
        _ = folder(newer, ".archivesuite")
        let future = Data(#"{"schemaVersion": 7}"#.utf8)
        try? future.write(to: CollectionSettingsDocument.url(in: newer))
        let s5 = store.snapshot(outputDirectory: newer, runID: UUID(), processing: [:], macMemoryGB: 16, now: day)
        let p5 = store.record(s5, kind: "processFiles", fileCount: 1, in: newer)
        check("a collection that cannot be written still yields the snapshot, with the problem named",
              p5 != nil && s5.values["hours"]?.value == .double(6)
              && (try? Data(contentsOf: CollectionSettingsDocument.url(in: newer))) == future
              && CollectionSettingsFile.runs(in: newer).isEmpty)

        pendingRecords(root, snapshot: s1)
    }

    /// What this writer wrote, read back by the Reader's and Notes' reader in ArchiveCore (W46.settings-reader-notes),
    /// in the words this app's Settings window uses: the contract test for `SPEC/collection-settings.md`.
    private static func readByReaderAndNotes(_ out: URL, runs: [UUID]) {
        guard let record = CollectionSettingsRecord.load(collectionFolder: out) else {
            check("the Reader and Notes read the collection's record", false, "nothing read")
            return
        }
        check("the Reader and Notes read the collection's record, newest run first",
              !record.documentIsNewer && !record.documentUnreadable && record.unreadableRunCount == 0
              && record.runs.map(\.id) == runs.reversed().map(\.uuidString) && record.projectName == "Letters"
              && record.ownSettings.map(\.key) == ["languages"] && record.runs.first?.fileCount == 5
              && record.runs.first?.kind == "batch")
        let latest = record.runs.first
        let shown = Dictionary(uniqueKeysWithValues: (latest?.settings ?? []).map { ($0.key, $0) })
        var mismatched: [String] = []
        for key in SettingsKey.catalog {
            let resolved = CollectionSettingsFile.runs(in: out).last?.settings.values[key.rawValue]
            guard let resolved, let row = shown[key.rawValue] else { mismatched.append(key.rawValue); continue }
            if row.label != key.label || row.value != key.describe(resolved.value) { mismatched.append(key.rawValue) }
        }
        check("the Reader and Notes show every value in this app's own words", mismatched.isEmpty,
              mismatched.joined(separator: ","))
        let override = SettingsKey(rawValue: "override.ocr.handwritten")
        eq("an override's label matches", CollectionSettingsVocabulary.label(override.rawValue), override.label)
        eq("the Reader and Notes know every catalog key's label",
           Set(CollectionSettingsVocabulary.labels.keys), Set(SettingsKey.catalog.map(\.rawValue)))
        eq("the Reader and Notes ignore the same general-only values in a collection",
           CollectionSettingsVocabulary.generalOnlyKeys, Set(SettingsKey.generalOnly.map(\.rawValue)))
        // Every answer's words: a case added on this side and not the other shows as its raw name there.
        var samples: [(SettingsKey, SettingsValue)] = [
            (.priorities, .strings(SettingsPriority.allCases.map(\.rawValue))),
            (.hours, .double(1)), (.hours, .double(8)), (.batchCeilingUSD, .double(2.5)),
            (.checkingMinutes, .double(20)), (.mix, .numbers(["a": 10, "b": 90])), (.weights, .numbers([:])),
            (override, .string("")), (.period, .string("")),
        ]
        samples += MoneyHabit.allCases.map { (.moneyHabit, .string($0.rawValue)) }
        samples += SettingsPreference.allCases.map { (.preference, .string($0.rawValue)) }
        samples += FineTuningAnswer.allCases.map { (.fineTuning, .string($0.rawValue)) }
        let words = samples.allSatisfy { key, value in
            let core: CollectionSettingValue
            switch value {
            case .bool(let b): core = .bool(b)
            case .int(let i): core = .int(i)
            case .double(let d): core = .double(d)
            case .string(let t): core = .string(t)
            case .strings(let t): core = .strings(t)
            case .numbers(let n): core = .numbers(n)
            }
            return CollectionSettingsVocabulary.describe(key.rawValue, core) == key.describe(value)
        }
        check("the Reader and Notes put every answer in the same words", words)
    }

    /// The snapshot rides in the pending run and batch, survives a write and a read, and changes neither fingerprint.
    private static func pendingRecords(_ root: URL, snapshot: ResolvedSettingsSnapshot) {
        let dir = folder(root, "pending")
        let model = LLMModel(id: "settings-layers-test", displayName: "Settings Layers Test", provider: .gemini,
                             supportsThinking: false, returnsMd: false, inputCostPer1M: 0, outputCostPer1M: 0,
                             batchDiscount: 0)
        var run = OCRProcessor.PendingRun(
            provider: .gemini, model: model, thinkingLevel: nil, fileURLs: [dir.appendingPathComponent("a.jpg")],
            outputDirectory: dir, enableTagging: false, enableSegmentJSON: false, enableCollectionSegmentation: false,
            confirmCollectionIDs: false, reviewDocumentSegmentation: false, preOCRedInput: false,
            previousTextCharCount: 0, sendPreviousImage: false, customPrompt: nil, startedAt: day, gatewayConfig: nil,
            completedResults: [:])
        run.resolvedSettings = snapshot
        let runURL = dir.appendingPathComponent("pending_run.json")
        let runBack = OCRProcessor._testWritePendingRun(run, to: runURL)
            ? OCRProcessor._testReadPendingRun(from: runURL) : nil
        eq("the pending run keeps the frozen settings through a write and a read", runBack?.resolvedSettings, snapshot)

        var batch = OCRProcessor.PendingBatch(
            batchId: "batches/settings-layers", provider: .gemini, model: model, thinkingLevel: nil,
            fileURLs: [dir.appendingPathComponent("a.jpg")], outputDirectory: dir, enableTagging: false,
            sendPreviousImage: false, submittedAt: day, taggingMode: .none,
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: ["batches/settings-layers"])
        let bare = OCRProcessor.pendingBatchLifecycleFingerprint(batch)
        batch.resolvedSettings = snapshot
        eq("the frozen settings are outside the paid batch's fingerprint",
           OCRProcessor.pendingBatchLifecycleFingerprint(batch), bare)
        let batchURL = dir.appendingPathComponent("pending_batch.json")
        let batchBack = OCRProcessor._testWritePendingBatch(batch, to: batchURL)
            .flatMap { _ in OCRProcessor._testReadPendingBatch(from: batchURL) }
        eq("the pending batch keeps the frozen settings through a write and a read", batchBack?.resolvedSettings, snapshot)
    }

    // MARK: The general store

    private static func generalStore(_ root: URL) {
        let dir = folder(root, "store")
        let a = SettingsLayerStore(directory: dir)
        a.setGeneral(.fineTuning, .string("cluster"), source: .setByUser(day))
        a.appendLedger(SettingsLedgerEntry(date: day, usd: 1.25, collectionID: nil, runID: nil))
        let b = SettingsLayerStore(directory: dir)
        check("the general layer and the ledger persist in the app's store",
              b.general.entry(.fineTuning)?.value == .string("cluster") && b.file.ledger.map(\.usd) == [1.25])
        check("a reset in the general layer persists",
              b.resetGeneral(.fineTuning) && SettingsLayerStore(directory: dir).general.entry(.fineTuning) == nil)

        let newerShape = folder(root, "store-newer-shape")
        var later = GeneralSettingsFile()
        later.schemaVersion = 2
        later.general.set(.hours, .double(1), source: .setByUser(day))
        let laterBytes = (try? CollectionSettingsFile.encoder().encode(later)) ?? Data()
        try? laterBytes.write(to: newerShape.appendingPathComponent("settings-general.json"))
        let n = SettingsLayerStore(directory: newerShape)
        check("a newer build's general file is read as nothing and never written over",
              n.readOnly && !n.setGeneral(.hours, .double(3), source: .setByUser(day)) && n.addProject(named: "P") == nil
              && (try? Data(contentsOf: newerShape.appendingPathComponent("settings-general.json"))) == laterBytes)

        let shut = folder(root, "store-shut")
        let shutURL = shut.appendingPathComponent("settings-general.json")
        let shutBytes = (try? CollectionSettingsFile.encoder().encode(GeneralSettingsFile())) ?? Data()
        try? shutBytes.write(to: shutURL)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shutURL.path)
        let sh = SettingsLayerStore(directory: shut)
        let shutSaved = sh.setGeneral(.hours, .double(3), source: .setByUser(day))
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: shutURL.path)
        check("a general file that cannot be opened is never written over",
              sh.readOnly && !shutSaved && (try? Data(contentsOf: shutURL)) == shutBytes)

        let odd = folder(root, "store-newer")
        let future = Data(#"{"schemaVersion": 9}"#.utf8)
        try? future.write(to: odd.appendingPathComponent("settings-general.json"))
        let c = SettingsLayerStore(directory: odd)
        let saved = c.setGeneral(.hours, .double(3), source: .setByUser(day))
        check("an unreadable general file is never written over",
              !saved && c.lastProblem != nil
              && (try? Data(contentsOf: odd.appendingPathComponent("settings-general.json"))) == future)
    }

    // MARK: The money ledger (W46.settings-ledger)

    private static func ledger(_ root: URL) {
        let dir = folder(root, "ledger-store")
        let out = folder(root, "ledger-output")
        let store = SettingsLayerStore(directory: dir)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let lastMonth = day.addingTimeInterval(-20 * 86_400)   // 2026-10-15
        let old = day.addingTimeInterval(-500 * 86_400)

        check("a free batch writes no ledger line",
              !store.recordSpend(usd: 0, runID: UUID(), outputDirectory: out, files: 3, now: day) && store.file.ledger.isEmpty)
        check("a batch's cost that is not a number writes nothing",
              !store.recordSpend(usd: .nan, runID: UUID(), outputDirectory: out, files: 3, now: day))

        // A batch whose collection has a settings document: the line carries its id and name.
        let doc = store.updateCollection(in: out) { $0.collection.name = "Box 12" }
        let run1 = UUID()
        check("a paid batch writes a line", store.recordSpend(usd: 1.5, runID: run1, outputDirectory: out, files: 40, now: day))
        let line = store.file.ledger.last
        check("the line names the batch's collection and its run",
              line?.collectionID == doc?.collection.id && doc != nil && line?.collectionName == "Box 12"
              && line?.runID == run1 && line?.files == 40 && line?.date == day)
        check("the same run is never counted twice",
              !store.recordSpend(usd: 1.5, runID: run1, outputDirectory: out, files: 40, now: day) && store.file.ledger.count == 1)
        let bare = folder(root, "ledger-bare")
        store.recordSpend(usd: 0.25, runID: UUID(), outputDirectory: bare, files: 2, now: day.addingTimeInterval(60))
        eq("a folder with no settings document is named by the folder", store.file.ledger.last?.collectionName, "ledger-bare")
        store.appendLedger(SettingsLedgerEntry(date: lastMonth, usd: 9, collectionID: nil, runID: nil))
        store.appendLedger(SettingsLedgerEntry(date: old, usd: 4, collectionID: nil, runID: nil))

        let month = store.monthSpend(now: day, calendar: cal)
        eq("the month counts only its own batches", month.usd, 1.75)
        eq("the month's batches, newest first", month.entries.map(\.usd), [0.25, 1.5])
        eq("the month in words", month.summary, "$1.75 by 2 batches")
        eq("the month before is its own", store.monthSpend(now: lastMonth, calendar: cal).usd, 9)
        eq("an empty month", SettingsMonthSpend().summary, "nothing yet")
        eq("an empty month against its limit", SettingsMonthSpend().summary(of: 20), "$0.00 of $20.00, no batches yet")
        eq("the month against its limit", month.summary(of: 20), "$1.75 of $20.00, from 2 batches")
        eq("spentThisMonthUSD is the month's total", store.spentThisMonthUSD(now: day, calendar: cal), 1.75)

        store.recordSpend(usd: 2, runID: UUID(), outputDirectory: nil, files: 5, now: day.addingTimeInterval(120))
        check("a line older than the keeping time is dropped when a batch is recorded",
              !store.file.ledger.contains { $0.date == old } && store.file.ledger.contains { $0.date == lastMonth })
        eq("a batch with no output folder is still counted", store.file.ledger.last?.collectionName, nil as String?)
        let back = SettingsLayerStore(directory: dir)
        eq("the ledger persists in the app's store", back.file.ledger, store.file.ledger)

        // What the solver reads: the remainder of the month, through the resolver.
        var general = SettingsLayer(kind: .general, name: "General")
        general.set(.moneyHabit, .string(MoneyHabit.perMonth.rawValue), source: .setByUser(day))
        general.set(.monthCeilingUSD, .double(5), source: .setByUser(day))
        let spent = back.spentThisMonthUSD(now: day, calendar: cal)
        eq("the solver's ceiling is what the ledger leaves of the month",
           SettingsResolver(general: general).answers(pages: 10, spentThisMonthUSD: spent).ceilingUSD, 1.25)

        // A store that cannot write keeps the line in memory, so the session's next batch still counts it.
        let odd = folder(root, "ledger-newer")
        let future = Data(#"{"schemaVersion": 9}"#.utf8)
        try? future.write(to: odd.appendingPathComponent("settings-general.json"))
        let ro = SettingsLayerStore(directory: odd)
        let wrote = ro.recordSpend(usd: 3, runID: UUID(), outputDirectory: nil, files: 1, now: day)
        check("a read-only store counts the batch in memory and writes nothing",
              !wrote && ro.spentThisMonthUSD(now: day, calendar: cal) == 3
              && (try? Data(contentsOf: odd.appendingPathComponent("settings-general.json"))) == future)
    }

    // MARK: Processing capture

    private static func processingCapture() {
        let suite = "APSettingsLayersTest-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { check("a scratch defaults suite", false); return }
        defer { d.removePersistentDomain(forName: suite) }
        d.set("openai", forKey: DefaultsKeys.selectedProvider)
        d.set(7, forKey: DefaultsKeys.ocrWorkerCount)
        d.set("gpt-x", forKey: ModelSelectionStore.modelKey(for: .openai))
        let v = ProcessingSettingsCapture.capture(d)
        check("the run's processing settings are captured, stored or defaulted",
              v[DefaultsKeys.selectedProvider] == .string("openai") && v[DefaultsKeys.ocrWorkerCount] == .int(7)
              && v[DefaultsKeys.textColumns] == .int(1)
              && v[ModelSelectionStore.modelKey(for: .openai)] == .string("gpt-x"))
        check("no API key is ever captured", !v.keys.contains { $0.lowercased().contains("apikey") })
        d.set(Double.infinity, forKey: DefaultsKeys.contextCharCount)
        d.set("https://user:secret@gateway.example.edu/v1?token=abc", forKey: DefaultsKeys.gatewayBaseURL)
        let w = ProcessingSettingsCapture.capture(d)
        check("a stored value that is not a finite number is captured as its default",
              w[DefaultsKeys.contextCharCount] == .double(0))
        eq("a gateway address is recorded without its credentials or query", w[DefaultsKeys.gatewayBaseURL],
           .string("https://gateway.example.edu/v1"))
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let report = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["SETTINGS_LAYERS_TEST_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
    }
}
#endif
