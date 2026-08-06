// tag-vocabulary-driver.swift — the executable half of `test-tag-vocabulary.sh` (W26.vocab).
//
// Compiled together with the REAL `MacOSTagger.swift`, `SystemTagsProvider.swift` and
// `DefaultsKeys.swift` against the REAL ArchiveCore, so every assertion below runs against shipping
// code rather than a replica. The Processor has no XCTest bundle; this is the same standalone-swiftc
// pattern as `test-drive-store.sh` and `test-controlled-vocabulary.sh`.
//
// Phases are separate PROCESSES on purpose (see the script): the relaunch claim is only worth
// anything if the second reader is a genuinely new process with fresh statics.
//
// File safety: every path used here is created under the scratch directory the script passes in.
// Nothing reads or writes a real corpus, and `ARCHIVEPROC_TAGVOCAB_FILE` keeps the vocabulary out of
// the operator's Application Support.

import Foundation
import ArchiveCore

// MARK: - Tiny harness

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var failures = 0
    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        lock.lock(); defer { lock.unlock() }
        if condition {
            print("  PASS: \(name)")
        } else {
            failures += 1
            let d = detail()
            print("  FAIL: \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
    }
}

private let results = Results()
private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    results.check(name, condition, detail())
}

private func multisetEqual(_ a: [String], _ b: [String]) -> Bool { a.sorted() == b.sorted() }

private func readBack(_ url: URL) -> (tags: [String], label: Int) {
    guard let rv = try? url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey]) else {
        return ([], -1)
    }
    return (rv.tagNames ?? [], rv.labelNumber ?? 0)
}

@discardableResult
private func makeFile(_ url: URL, tags: [String]? = nil, label: Int? = nil) -> URL {
    FileManager.default.createFile(atPath: url.path, contents: Data("scratch".utf8))
    if let tags { try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
    if let label { try? (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
    return url
}

/// Spin the main run loop until `condition` holds or `timeout` elapses. The harvest hands its result
/// back through `Task { @MainActor … }`, which needs the main queue to be serviced.
@MainActor
private func wait(upTo timeout: TimeInterval, for condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

// MARK: - Phases

/// Everything about the tag WRITE: that the vocabulary hook did not change what lands on disk, that
/// what it ingests is the VERIFIED on-disk result, and that a refused write contributes nothing.
@MainActor
private func phaseWrite(scratch: URL) {
    let vocabulary = ProcessorTagVocabulary.shared
    print("── phase: write (Tier-2 — the write path is unchanged by the vocabulary hook)")

    // (1) Real-tagging write. Expectations are copied verbatim from MacOSTaggerParityTests
    // .testBoxTagging, which predates the hook: if the hook perturbed the write, these differ.
    let box = makeFile(scratch.appendingPathComponent("box.pdf"))
    do {
        let result = try MacOSTagger.applyTags(["1962", "Red", "Corr", "Tax"], to: box,
                                               stampUnread: true)
        let (tags, label) = readBack(box)
        check("real-tagging write puts the same tags on disk as before the hook",
              multisetEqual(tags, ["Red", "Corr", "Tax", "1962", "Unread"]), "\(tags.sorted())")
        check("real-tagging write puts the same Finder label on disk as before the hook",
              label == 6, "label=\(label)")
        check("the write result reports what is on disk",
              multisetEqual(result.after, tags) && result.afterLabel == 6,
              "after=\(result.after.sorted()) afterLabel=\(String(describing: result.afterLabel))")
    } catch {
        check("real-tagging write succeeds", false, "\(error)")
    }

    // (2) Only the subjects reached the vocabulary — from a write whose own output contains a date,
    // a trailing Unread and the marker colour.
    let afterBox = Set(vocabulary.snapshot())
    check("the write's subjects entered the vocabulary", afterBox.isSuperset(of: ["Corr", "Tax"]),
          "\(afterBox.sorted())")
    check("the trailing Unread this write stamped is not a subject suggestion",
          !afterBox.contains("Unread"), "\(afterBox.sorted())")
    check("the date token this write stamped is not a subject suggestion",
          !afterBox.contains("1962"), "\(afterBox.sorted())")
    check("the marker colour this write stamped is not a subject suggestion",
          !afterBox.contains("Red"), "\(afterBox.sorted())")

    // (3) A colour word that is NOT the file's label stays a subject — the Red Scare case, through
    // the colour-authoritative path that actually produces it (label written as 0).
    let scare = makeFile(scratch.appendingPathComponent("scare.pdf"))
    do {
        _ = try MacOSTagger.applyTags(["Red", "Comm", "1955"], to: scare,
                                      appColor: nil, colorIsAuthoritative: true, stampUnread: true)
        let (tags, label) = readBack(scare)
        check("colour-authoritative write keeps 'Red' as a text tag and clears the label",
              tags.contains("Red") && label == 0, "tags=\(tags.sorted()) label=\(label)")
        check("…so 'Red' IS suggestable when it is a subject rather than a marker",
              vocabulary.snapshot().contains("Red"), "\(vocabulary.snapshot())")
    } catch {
        check("colour-authoritative write succeeds", false, "\(error)")
    }

    // (4) Copy-source pass-through: verbatim tags, label untouched, and the source's real tags are
    // what the vocabulary learns.
    let copy = makeFile(scratch.appendingPathComponent("copy.pdf"), tags: nil, label: 3)
    do {
        _ = try MacOSTagger.applyTags(["Deaver", "Blue", "Rcpt"], to: copy, stampUnread: false)
        let (tags, label) = readBack(copy)
        check("copy-source write passes tags through verbatim",
              multisetEqual(tags, ["Deaver", "Blue", "Rcpt"]), "\(tags.sorted())")
        check("copy-source write leaves the existing label untouched", label == 3, "label=\(label)")
        check("copy-source subjects entered the vocabulary",
              Set(vocabulary.snapshot()).isSuperset(of: ["Deaver", "Rcpt"]), "\(vocabulary.snapshot())")
    } catch {
        check("copy-source write succeeds", false, "\(error)")
    }

    // (5) A REFUSED write contributes nothing. The hook sits after the `try`, so a throw must leave
    // the vocabulary byte-identical — this is the assertion that pins that placement.
    let before = vocabulary.snapshot()
    let missing = scratch.appendingPathComponent("does-not-exist.pdf")
    var threw = false
    do { _ = try MacOSTagger.applyTags(["Never Suggested"], to: missing, stampUnread: true) }
    catch { threw = true }
    check("a write to a nonexistent file throws", threw)
    check("a refused write contributes NOTHING to the vocabulary",
          vocabulary.snapshot() == before,
          "added \(Set(vocabulary.snapshot()).subtracting(before).sorted())")

    // (6) A no-op copy-source write (empty tag array) does not change the file, and what it reports
    // is the file's REAL existing tags — so that is what the vocabulary learns. Asserted rather than
    // assumed, because `TagWriteResult.after == before` for a no-op is easy to misread as "nothing".
    let preTagged = makeFile(scratch.appendingPathComponent("pre.pdf"),
                             tags: ["Pre Existing Subject", "Unread"])
    do {
        let result = try MacOSTagger.applyTags([], to: preTagged, stampUnread: false)
        let (tags, _) = readBack(preTagged)
        check("an empty copy-source write is a no-op on disk",
              result.isNoOp && multisetEqual(tags, ["Pre Existing Subject", "Unread"]),
              "isNoOp=\(result.isNoOp) tags=\(tags.sorted())")
        check("a no-op still teaches the vocabulary the file's real subjects",
              vocabulary.snapshot().contains("Pre Existing Subject"), "\(vocabulary.snapshot())")
    } catch {
        check("empty copy-source write succeeds", false, "\(error)")
    }

    // (7) A tag the operator TYPES is flushed synchronously — the one ingest worth not losing to a
    // crash. Asserted by reading the file back BEFORE any explicit flush of ours: an assertion made
    // after `vocabulary.flush()` would pass even if `register` had stopped flushing at all, which is
    // what an earlier draft of this test did (caught by mutation, not by reading the code).
    SystemTagsProvider.shared.register(["Typed By Operator"])
    check("a typed tag is registered in memory", vocabulary.snapshot().contains("Typed By Operator"))
    check("…and is ON DISK immediately, with no flush from us",
          persistedNames(vocabularyFile).contains("Typed By Operator"),
          "\(persistedNames(vocabularyFile).sorted())")

    // The write-hook ingests use the debounced save, so the phase still flushes before exiting —
    // which is exactly what the harvest completion does in the app.
    vocabulary.flush()
}

/// The names actually written to the vocabulary JSON, read as an outsider would.
private func persistedNames(_ url: URL?) -> Set<String> {
    guard let url,
          let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let names = object["names"] as? [String] else { return [] }
    return Set(names)
}

/// Where `ProcessorTagVocabulary` was told to keep the store, from the same env var the script sets.
/// Read here rather than asked of the type, so the assertion cannot be satisfied by the code under
/// test agreeing with itself.
private let vocabularyFile: URL? = ProcessInfo.processInfo.environment["ARCHIVEPROC_TAGVOCAB_FILE"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

/// The relaunch claim, made by a process that did not do the writing, plus the real harvest.
@MainActor
private func phaseHarvest(scratch: URL, root: URL) {
    let vocabulary = ProcessorTagVocabulary.shared
    print("── phase: harvest (a NEW process — relaunch, then a real filesystem harvest)")

    let onLaunch = Set(vocabulary.snapshot())
    check("the previous process's written subjects survived the relaunch",
          onLaunch.isSuperset(of: ["Corr", "Tax", "Deaver", "Pre Existing Subject"]),
          "\(onLaunch.sorted())")
    check("the previous process's TYPED subject survived the relaunch",
          onLaunch.contains("Typed By Operator"), "\(onLaunch.sorted())")
    check("structural facets did not survive, because they never entered",
          onLaunch.isDisjoint(with: ["Unread", "1962", "1955"]), "\(onLaunch.sorted())")
    check("the vocabulary file loaded cleanly",
          vocabulary.loadFailure == nil, vocabulary.loadFailure ?? "")

    // The archive root for this phase comes from `-outputDirectory` in the ARGUMENT domain (see the
    // script): volatile, never persisted, so this test cannot disturb the operator's real settings.
    check("the provider sees the scratch archive root",
          ProcessorTagVocabulary.currentArchiveRoot()?.standardizedFileURL.path
            == root.standardizedFileURL.path,
          "\(String(describing: ProcessorTagVocabulary.currentArchiveRoot()?.path))")

    SystemTagsProvider.shared.warmUp()
    let harvested = wait(upTo: 20) {
        vocabulary.knownRoots().first?.harvestedAt != nil
    }
    check("the harvest completed and stamped the root", harvested,
          "\(vocabulary.knownRoots())")

    let afterHarvest = Set(vocabulary.snapshot())
    check("the harvest learned subjects that only exist on disk",
          afterHarvest.isSuperset(of: ["Harvested Subject A", "Harvested Subject B"]),
          "\(afterHarvest.sorted())")
    check("the harvest did NOT learn the marker colour off a labelled file",
          !afterHarvest.contains("Purple"), "\(afterHarvest.sorted())")
    check("the harvest did NOT learn read-state or date tokens",
          afterHarvest.isDisjoint(with: ["Unread", "Read", "1971", "P8"]), "\(afterHarvest.sorted())")
    check("the relaunched vocabulary still holds everything it arrived with",
          afterHarvest.isSuperset(of: onLaunch), "lost \(onLaunch.subtracting(afterHarvest).sorted())")
    check("the provider is ready", SystemTagsProvider.shared.isReady)

    // A second warm-up must not re-walk: the root is stamped and not yet stale.
    let stampBefore = vocabulary.knownRoots().first?.harvestedAt
    SystemTagsProvider.shared.warmUp()
    _ = wait(upTo: 1) { false }
    check("a second warm-up does not re-harvest a freshly stamped root",
          vocabulary.knownRoots().first?.harvestedAt == stampBefore,
          "\(String(describing: vocabulary.knownRoots().first?.harvestedAt))")

    vocabulary.flush()
}

/// The `$HOME` prohibition, through the real provider rather than the `isHarvestableRoot` unit test:
/// point the app's output directory at a forbidden folder and prove no root is recorded and no walk
/// starts. The owner's directive was "do not walk `$HOME` to emulate Spotlight"; this is that claim.
@MainActor
private func phaseForbiddenRoot(expectedNames: Int) {
    let vocabulary = ProcessorTagVocabulary.shared
    print("── phase: forbidden-root (no $HOME walk)")

    let configured = ProcessorTagVocabulary.currentArchiveRoot()
    check("the provider does see the forbidden directory as the configured output directory",
          configured != nil, "nil — the phase would pass vacuously")

    SystemTagsProvider.shared.warmUp()
    _ = wait(upTo: 2) { false }

    check("no forbidden root was recorded", vocabulary.knownRoots().isEmpty,
          "\(vocabulary.knownRoots())")
    check("no harvest is due for it",
          vocabulary.rootsNeedingHarvest(current: configured).isEmpty,
          "\(vocabulary.rootsNeedingHarvest(current: configured))")
    check("the vocabulary did not grow — nothing was walked",
          vocabulary.count == expectedNames,
          "count=\(vocabulary.count) expected=\(expectedNames)")
    check("the UI is not left spinning on a harvest that will never happen",
          SystemTagsProvider.shared.isReady)
}

/// Where the store resolves to, asserted **without constructing it**. A self-test driver's fixture
/// subjects must never reach the operator's real suggestion list, and the only safe way to check that
/// is to look at the resolved path: writing a tag and then looking for it in Application Support would
/// cause the pollution whenever the guard is broken.
///
/// `expectScratch` is 1 when the process was launched with a driver environment set.
private func phaseStorePath(expectScratch: Bool) {
    print("── phase: store-path (a self-test driver never writes the operator's vocabulary)")
    let path = ProcessorTagVocabulary.storeURL.path
    let inAppSupport = path.contains("/Application Support/")
    print("     resolved: \(path)")
    if expectScratch {
        check("a driver run resolves the store OUTSIDE Application Support", !inAppSupport, path)
        check("…and inside the temporary directory",
              path.hasPrefix(NSTemporaryDirectory()) || path.hasPrefix("/var/folders/")
                || path.hasPrefix("/private/var/folders/"), path)
    } else {
        // The negative control: without a driver environment the redirection must NOT happen, or the
        // assertion above would pass for the wrong reason (e.g. a store that is always in /tmp).
        check("a NORMAL run resolves the store inside Application Support", inAppSupport, path)
    }
}

// MARK: - Entry point

@main
struct TagVocabularyDriver {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: driver <phase> <scratch-dir> [root]\n".utf8))
            exit(2)
        }
        let phase = args[1]
        let scratch = URL(fileURLWithPath: args[2], isDirectory: true)

        switch phase {
        case "write":
            phaseWrite(scratch: scratch)
            // The write-hook ingests use the debounced save; land them before the process ends.
            ProcessorTagVocabulary.shared.flush()
        case "harvest":
            phaseHarvest(scratch: scratch, root: URL(fileURLWithPath: args[3], isDirectory: true))
            ProcessorTagVocabulary.shared.flush()
        case "forbidden":
            phaseForbiddenRoot(expectedNames: Int(args[3]) ?? -1)
        case "store-path":
            // Deliberately touches NOTHING else — in the negative-control run the store resolves to the
            // operator's real file, so this phase must never construct, read or flush it.
            phaseStorePath(expectScratch: args[3] == "scratch")
        default:
            FileHandle.standardError.write(Data("unknown phase \(phase)\n".utf8))
            exit(2)
        }

        exit(results.failures == 0 ? 0 : 1)
    }
}
