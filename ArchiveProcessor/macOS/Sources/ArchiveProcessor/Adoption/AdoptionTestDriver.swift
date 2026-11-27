#if DEBUG // a test driver, compiled out of Release
import ArchiveCore
import Foundation
import PDFKit

/// Headless, $0 self-test of the adoption tool (W49.corpus-adoption-tool), gated by `ADOPTION_TEST=1`, run by
/// `scripts/test-adoption.sh`. The fixture is a small pre-app tree made in `ADOPTION_TEST_DIR`: tagged and coloured
/// PDFs under `Archival Photos` and their originals under `Archival Photos JPEGS`. A fake label reader; never the
/// corpus, no model call, no network, no window.
///
///   1. The inventory proposes facts with their rules, matches originals (mirrored and by name), routes conflicts,
///      ambiguous or missing originals, ambiguous dates and multi-page pairs to review, and changes nothing.
///   2. The real corpus, and a derived archive inside the source, are refused.
///   3. A bulk decision accepts one reason group.
///   4. Conversion files catalogue pairs and preserved originals that verify, carries no Finder tags, and leaves the
///      source untouched; a second run changes nothing.
///   5. A run interrupted after an entry's filing was frozen resumes the same operation.
///   6. A source whose tags changed after the inventory is refused, and nothing is filed for it.
///   7. Labels are proposed without writing, then written only into the derived archive.
///   8. A non-empty destination without this run's ledger is refused.
@MainActor
enum AdoptionTestDriver {
    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["ADOPTION_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in
            await run()
            finish()
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["ADOPTION_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }

    // MARK: Fixture

    private static func pdf(_ url: URL, pages: Int = 1, tags: [String] = [], label: Int? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = PDFDocument()
        for index in 0..<pages { document.insert(PDFPage(), at: index) }
        guard let data = document.dataRepresentation() else { throw PDFError.writeFailed }
        try data.write(to: url, options: .withoutOverwriting)
        if !tags.isEmpty || label != nil {
            // Finder lists a colour label among the tags by its name, as the old archive's files show it.
            let colour = FinderLabel(labelNumber: label).map { [$0.tokenName] } ?? []
            _ = try CoordinatedTagWriter.write(url) { _, _ in (tags + colour, label ?? 0) }
        }
    }

    private static func jpeg(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture original \(url.lastPathComponent)".utf8).write(to: url, options: .withoutOverwriting)
    }

    /// Every file under `root` with its bytes' digest, tags and label: what "the source is untouched" compares.
    private static func snapshot(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                result[url.path] = "dir"
                continue
            }
            let digest = (try? AdoptionConversion.digest(of: url))?.base64EncodedString() ?? "?"
            result[url.path] = "\(digest) \(TagReading.read(url))"
        }
        return result
    }

    private static func entry(_ manifest: AdoptionManifest, _ path: String) -> AdoptionManifest.Entry? {
        manifest.entries.first { $0.path == path }
    }

    // MARK: Cases

    static func run() async {
        guard let dir = ProcessInfo.processInfo.environment["ADOPTION_TEST_DIR"] else {
            check("0 ADOPTION_TEST_DIR is set", false); return
        }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let main = base.appendingPathComponent("tree/Archival Photos", isDirectory: true)
        let jpegs = base.appendingPathComponent("tree/Archival Photos JPEGS", isDirectory: true)
        do {
            try pdf(main.appendingPathComponent("Box 1/Box 1 label.pdf"), tags: ["1958"], label: FinderLabel.red.rawValue)
            try jpeg(jpegs.appendingPathComponent("Box 1/Box 1 label.jpg"))
            try pdf(main.appendingPathComponent("Box 1/Letter.pdf"), tags: ["1957", "3 March", "Unread", "Q2", "Eisenhower"])
            try jpeg(jpegs.appendingPathComponent("Box 1/Letter.jpg"))
            try pdf(main.appendingPathComponent("Box 1/Moved.pdf"), tags: ["Read"], label: FinderLabel.blue.rawValue)
            try jpeg(jpegs.appendingPathComponent("Elsewhere/Moved.jpeg"))
            try pdf(main.appendingPathComponent("Box 1/Conflict.pdf"), tags: ["Folder"], label: FinderLabel.red.rawValue)
            try jpeg(jpegs.appendingPathComponent("Box 1/Conflict.jpg"))
            try pdf(main.appendingPathComponent("Box 1/Twin.pdf"))
            try pdf(main.appendingPathComponent("Box 2/Twin.pdf"))
            try jpeg(jpegs.appendingPathComponent("x/Twin.jpg"))
            try jpeg(jpegs.appendingPathComponent("y/Twin.jpg"))
            try pdf(main.appendingPathComponent("Box 2/Lonely.pdf"), tags: ["1940s", "OCR Poor"])
            try pdf(main.appendingPathComponent("Box 2/Dates.pdf"), tags: ["1957", "1960"])
            try pdf(main.appendingPathComponent("Box 2/Two pages.pdf"), pages: 2)
            try jpeg(jpegs.appendingPathComponent("Box 2/Two pages.jpg"))
            try pdf(main.appendingPathComponent("Box 2/Folder A.pdf"), label: FinderLabel.purple.rawValue)
            try jpeg(jpegs.appendingPathComponent("Box 2/Folder A.jpg"))
            try pdf(main.appendingPathComponent("Box 3/Year and decade.pdf"), tags: ["1950s", "1957", "Checked Date"])
            try jpeg(jpegs.appendingPathComponent("Box 3/Year and decade.jpg"))
            try pdf(main.appendingPathComponent("Box 3/Day only.pdf"), tags: ["1957", "Day 12"])
            try pdf(main.appendingPathComponent("Box 3/Two types.pdf"), tags: ["Box", "Folder"])
            let locked = PDFDocument()
            locked.insert(PDFPage(), at: 0)
            guard let protected = locked.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "",
                                                                     PDFDocumentWriteOption.ownerPasswordOption: "fixture"])
            else { throw PDFError.writeFailed }
            try protected.write(to: main.appendingPathComponent("Box 2/Protected.pdf"), options: .withoutOverwriting)
        } catch {
            check("0 fixture tree", false, "\(error)"); return
        }
        let sourceBefore = snapshot(base.appendingPathComponent("tree"))
        let state = base.appendingPathComponent("state", isDirectory: true)
        let dest = base.appendingPathComponent("derived", isDirectory: true)
        let env = ["ARCHIVE_ADOPT_STATE": state.path, "ARCHIVE_ADOPT_SOURCE": main.path, "ARCHIVE_ADOPT_DEST": dest.path]

        // 1. Inventory.
        let (inventoryText, inventoryOK) = await AdoptionCommand.run(step: "inventory", env: env)
        check("1 inventory runs", inventoryOK, inventoryText)
        guard let data = try? Data(contentsOf: state.appendingPathComponent(AdoptionManifest.fileName)),
              var manifest = try? AdoptionManifest.decode(data) else {
            check("1 manifest written", false); return
        }
        check("1 the originals tree beside Archival Photos is used", manifest.originalsRoot?.hasSuffix("Archival Photos JPEGS") == true)
        check("1 every PDF is listed, tagged or not", manifest.entries.count == 14, "\(manifest.entries.map(\.path))")
        check("1 the walk was complete", manifest.complete)
        let letter = entry(manifest, "Box 1/Letter.pdf")
        check("1 a clean entry is accepted with its mirrored original",
              letter?.decision == .accept && letter?.original.rule == "mirrored" && letter?.keepOriginal == true)
        check("1 tag facts are proposed with their evidence",
              letter?.proposal.documentDate?.value == "1957-03" && letter?.proposal.readState?.value == "unread"
                && letter?.proposal.quality?.value == 2 && letter?.proposal.subjects == ["Eisenhower"]
                && letter?.proposal.documentDate?.evidence.contains("March") == true, "\(String(describing: letter?.proposal))")
        let box = entry(manifest, "Box 1/Box 1 label.pdf")
        check("1 Red becomes Box by the legacy colour rule, and the colour is kept",
              box?.proposal.itemType?.value == "box" && box?.proposal.itemType?.rule == "colour:red-box-purple-folder"
                && box?.proposal.colour?.value == "red" && box?.decision == .accept)
        check("1 Purple becomes Folder", entry(manifest, "Box 2/Folder A.pdf")?.proposal.itemType?.value == "folder")
        check("1 an original found by name alone says so", entry(manifest, "Box 1/Moved.pdf")?.original.rule == "stem"
              && entry(manifest, "Box 1/Moved.pdf")?.original.path == "Elsewhere/Moved.jpeg")
        check("1 a Box/Folder tag against the colour waits for review",
              entry(manifest, "Box 1/Conflict.pdf")?.review == [.typeConflict]
                && entry(manifest, "Box 1/Conflict.pdf")?.proposal.itemType?.value == "folder")
        check("1 duplicate originals wait for review with their candidates",
              entry(manifest, "Box 2/Twin.pdf")?.review == [.originalAmbiguous]
                && entry(manifest, "Box 2/Twin.pdf")?.original.candidates == ["x/Twin.jpg", "y/Twin.jpg"])
        check("1 a missing original waits for review", entry(manifest, "Box 2/Lonely.pdf")?.review == [.originalMissing])
        check("1 two year tags wait for review", entry(manifest, "Box 2/Dates.pdf")?.review.contains(.dateAmbiguous) == true)
        check("1 one original for a two-page PDF waits for review",
              entry(manifest, "Box 2/Two pages.pdf")?.review == [.originalMultipage])
        let yearDecade = entry(manifest, "Box 3/Year and decade.pdf")
        check("1 a Year supersedes a Decade, and a Checked Date travels with it",
              yearDecade?.proposal.documentDate?.value == "1957" && yearDecade?.proposal.documentDate?.checked == true
                && yearDecade?.decision == .accept, "\(String(describing: yearDecade?.proposal.documentDate))")
        check("1 a Day with no Month waits as an incomplete date",
              entry(manifest, "Box 3/Day only.pdf")?.review.contains(.dateIncomplete) == true)
        check("1 a Box and a Folder tag together wait as a type conflict",
              entry(manifest, "Box 3/Two types.pdf")?.review.contains(.typeConflict) == true)
        check("1 an encrypted PDF waits and cannot be accepted in bulk",
              entry(manifest, "Box 2/Protected.pdf")?.review.contains(.pdfUnreadable) == true)
        check("1 the inventory changes nothing in the source", snapshot(base.appendingPathComponent("tree")) == sourceBefore)
        let (again, againOK) = await AdoptionCommand.run(step: "inventory", env: env)
        check("1 a second inventory never overwrites the reviewed manifest", !againOK, again)

        // 2. Refusals.
        do {
            _ = try AdoptionInventory.run(source: main, originals: nil, colours: .none, protected: [main])
            check("2 the protected corpus is refused", false)
        } catch { check("2 the protected corpus is refused", (error as? AdoptionError).map { if case .protectedCorpus = $0 { true } else { false } } ?? false) }
        do {
            _ = try await AdoptionConversion.run(manifest, destination: main.appendingPathComponent("Derived"),
                                                 state: base.appendingPathComponent("state-inside"))
            check("2 a derived archive inside the source is refused", false)
        } catch { check("2 a derived archive inside the source is refused", error as? AdoptionError == .destinationInsideSource) }
        do {
            _ = try await AdoptionConversion.run(manifest, destination: jpegs.appendingPathComponent("Derived"),
                                                 state: base.appendingPathComponent("state-originals"))
            check("2 a derived archive inside the originals is refused", false)
        } catch { check("2 a derived archive inside the originals is refused", error as? AdoptionError == .destinationInsideSource) }
        var insideState = env
        insideState["ARCHIVE_ADOPT_STATE"] = main.appendingPathComponent(".adopt").path
        let (stateText, stateOK) = await AdoptionCommand.run(step: "inventory", env: insideState)
        check("2 a state folder inside the source is refused before anything is written", !stateOK
              && !FileManager.default.fileExists(atPath: main.appendingPathComponent(".adopt").path), stateText)
        let lock = open(state.appendingPathComponent(".adoption.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        flock(lock, LOCK_EX)
        let (busyText, busyOK) = await AdoptionCommand.run(step: "verify", env: env)
        flock(lock, LOCK_UN); close(lock)
        check("2 a second step on a busy state folder is refused", !busyOK && busyText.contains("another adoption step"), busyText)
        check("2 refusals change nothing in the source", snapshot(base.appendingPathComponent("tree")) == sourceBefore)

        // 3. A bulk decision.
        var decideEnv = env
        decideEnv["ARCHIVE_ADOPT_DECISION"] = "accept"
        decideEnv["ARCHIVE_ADOPT_REASONS"] = "original-missing,original-multipage"
        decideEnv["ARCHIVE_ADOPT_KEEP_ORIGINAL"] = "0"
        let (decided, decidedOK) = await AdoptionCommand.run(step: "decide", env: decideEnv)
        manifest = (try? AdoptionManifest.decode(Data(contentsOf: state.appendingPathComponent(AdoptionManifest.fileName)))) ?? manifest
        check("3 the reason group is accepted, others still wait", decidedOK && decided.hasPrefix("2 entries")
              && entry(manifest, "Box 2/Lonely.pdf")?.decision == .accept
              && entry(manifest, "Box 2/Two pages.pdf")?.keepOriginal == false
              && entry(manifest, "Box 1/Conflict.pdf")?.decision == .review, decided)

        // 5 (first half). Interrupt one entry after its filing is frozen.
        AdoptionConversion._testInterruptAfterPreparing = "Box 1/Letter.pdf"
        let (firstText, firstOK) = await AdoptionCommand.run(step: "convert", env: env)
        check("5 the interrupted run reports the entry it did not finish", !firstOK && firstText.contains("FAILED Box 1/Letter.pdf"), firstText)
        let frozen = (try? AdoptionLedger.load(from: AdoptionInventory.canonicalDirectory(state)!))??.items["Box 1/Letter.pdf"]
        check("5 its filing was frozen before it stopped", frozen != nil && frozen?.completed == false)

        // 4. Conversion, completed by the resumed run.
        let (convertText, convertOK) = await AdoptionCommand.run(step: "convert", env: env)
        check("4 conversion finishes and verifies", convertOK && convertText.contains("VERIFIED"), convertText)
        let resumed = (try? AdoptionLedger.load(from: AdoptionInventory.canonicalDirectory(state)!))??.items["Box 1/Letter.pdf"]
        check("5 the resumed run used the same operation", resumed?.operationID == frozen?.operationID && resumed?.completed == true)
        let fm = FileManager.default
        let derivedLetter = dest.appendingPathComponent("Box 1/Letter.pdf")
        check("4 the pair is filed at the source's relative path",
              fm.fileExists(atPath: derivedLetter.path)
                && fm.fileExists(atPath: dest.appendingPathComponent("Box 1/" + CatalogueRecord.companionFilename(forPDFFilename: "Letter.pdf")).path))
        check("4 the derived PDF carries no Finder tags", TagReading.read(derivedLetter) == .success(tagNames: [], labelNumber: 0)
              || TagReading.read(derivedLetter) == .success(tagNames: [], labelNumber: nil), "\(TagReading.read(derivedLetter))")
        check("4 the matched original is preserved", fm.fileExists(atPath: dest.appendingPathComponent("Box 1/Preservation").path))
        check("4 entries waiting for review are not converted",
              !fm.fileExists(atPath: dest.appendingPathComponent("Box 1/Conflict.pdf").path)
                && !fm.fileExists(atPath: dest.appendingPathComponent("Box 2/Twin.pdf").path))
        let lonely = (try? AdoptionLedger.load(from: AdoptionInventory.canonicalDirectory(state)!))??.items["Box 2/Lonely.pdf"]
        check("4 an accepted entry without an original is converted without one",
              fm.fileExists(atPath: dest.appendingPathComponent("Box 2/Lonely.pdf").path)
                && lonely?.completed == true && lonely?.preservation == nil)
        check("4 conversion changes nothing in the source", snapshot(base.appendingPathComponent("tree")) == sourceBefore)
        do {
            let reader = try CatalogueReader(grantedRoot: dest, rootInstanceID: UUID(), mode: .adopted,
                                             identifyPDF: CataloguePDFIdentity.identify)
            let facts = reader.snapshot(.init(relativePDFPaths: ["Box 1/Box 1 label.pdf"], isComplete: false))
                .facts(at: "Box 1/Box 1 label.pdf")
            let fields = try facts.document.get().document.fields
            if case .value(let type)? = fields?.itemType?.current {
                check("4 a reader sees the converted Box with its import evidence",
                      type == "box" && fields?.itemType?.origin == "imported"
                        && fields?.itemType?.evidence.first?.quote == "Finder colour Red")
            } else { check("4 a reader sees the converted Box", false) }
            let checked = try reader.snapshot(.init(relativePDFPaths: ["Box 3/Year and decade.pdf"], isComplete: false))
                .facts(at: "Box 3/Year and decade.pdf").document.get().document.fields?.documentDate
            check("4 the carried check is current", checked?.isChecked == true)
        } catch { check("4 a reader opens the derived archive", false, "\(error)") }
        let derivedBefore = snapshot(dest)
        let (secondText, secondOK) = await AdoptionCommand.run(step: "convert", env: env)
        check("4 a second run changes nothing", secondOK && secondText.contains("converted: 0") && snapshot(dest) == derivedBefore, secondText)

        // 6. A changed source.
        let dates = main.appendingPathComponent("Box 2/Dates.pdf")
        if let index = manifest.entries.firstIndex(where: { $0.path == "Box 2/Dates.pdf" }) {
            manifest.entries[index].decision = .accept
            try? manifest.encoded().write(to: state.appendingPathComponent(AdoptionManifest.fileName), options: .atomic)
        }
        _ = try? CoordinatedTagWriter.write(dates) { tags, label in (tags + ["Added later"], label) }
        let (changedText, changedOK) = await AdoptionCommand.run(step: "convert", env: env)
        check("6 a file changed after the inventory is refused", !changedOK && changedText.contains("FAILED Box 2/Dates.pdf")
              && !fm.fileExists(atPath: dest.appendingPathComponent("Box 2/Dates.pdf").path), changedText)
        _ = try? CoordinatedTagWriter.write(dates) { tags, label in (tags.filter { $0 != "Added later" }, label) }

        // 7. Labels.
        let reader: AdoptionLabels.Reader = { type, photo in
            var fields = ContainerFieldSet()
            fields[type == .box ? .container : .folder] = ContainerValue(type == .box ? "Box 1" : "Folder A", source: .label,
                                                                       reader: "fixture")
            return (fields, "label text from \(photo.lastPathComponent)")
        }
        for index in manifest.entries.indices where manifest.entries[index].path.hasPrefix("Box 1/")
            && manifest.entries[index].decision == .review { manifest.entries[index].decision = .skip }
        let containers = dest.appendingPathComponent("Box 1/.archivesuite/containers.json")
        do {
            let proposed = try await AdoptionLabels.run(manifest, state: state, apply: false, reader: reader)
            check("7 labels are proposed without writing", proposed.contains { $0.path == "Box 1" && $0.outcome == .proposed }
                  && !fm.fileExists(atPath: containers.path), "\(proposed)")
            let applied = try await AdoptionLabels.run(manifest, state: state, apply: true, reader: reader)
            check("7 a folder with files not yet converted is not written",
                  applied.contains { $0.path == "Box 2" && { if case .refused = $0.outcome { true } else { false } }($0) }
                    && !fm.fileExists(atPath: dest.appendingPathComponent("Box 2/.archivesuite").path), "\(applied)")
            check("7 accepted labels are written into the derived archive only",
                  applied.contains { $0.path == "Box 1" && $0.outcome == .wrote } && fm.fileExists(atPath: containers.path)
                    && !fm.fileExists(atPath: main.appendingPathComponent("Box 1/.archivesuite").path), "\(applied)")
            let written = ContainerFileStore.load(directory: dest.appendingPathComponent("Box 1"))
            if case .loaded(let file, _) = written {
                check("7 the run carries the label's reading", file.runs.contains { $0.fields[.container]?.value == "Box 1" })
            } else { check("7 the written container file loads", false) }
        } catch { check("7 labels", false, "\(error)") }
        check("7 labels change nothing in the source", snapshot(base.appendingPathComponent("tree")) == sourceBefore)

        // 8. A destination holding someone else's files.
        let other = base.appendingPathComponent("occupied", isDirectory: true)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        try? Data("not ours".utf8).write(to: other.appendingPathComponent("note.txt"))
        do {
            _ = try await AdoptionConversion.run(manifest, destination: other, state: base.appendingPathComponent("state-2"))
            check("8 a non-empty destination is refused", false)
        } catch {
            check("8 a non-empty destination is refused",
                  (error as? AdoptionError).map { if case .destinationNotEmpty = $0 { true } else { false } } ?? false, "\(error)")
        }
    }
}
#endif
