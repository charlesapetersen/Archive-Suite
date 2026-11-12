import Foundation

// MARK: - Where the layers live (W46.settings-layers)
//
// The general layer, the projects and the money ledger are the app's own store: one JSON file in Application Support.
// A collection's layer is a document inside the collection's output folder, `.archivesuite/collection-settings.json`
// (owner call 1, 2026-11-06), and each run that wrote into the collection is one small file beside it in
// `.archivesuite/runs/`, so the Reader, Notes and a second Mac can read what produced the collection. Its format is
// `SPEC/collection-settings.md`.
//
// These are the only files here written beside the output, so the writer is guarded: it writes only into an existing
// output folder, never through a symlink, atomically, and never over a run record; it never overwrites a document it
// could not read (an unreadable one is renamed aside, never deleted; one it could not even open, or a newer build's,
// is left alone).

/// The general layer, the projects and the ledger, in the app's own store.
struct GeneralSettingsFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = Self.currentSchemaVersion
    var general = SettingsLayer(kind: .general, name: "General")
    var projects: [SettingsLayer] = []
    var ledger: [SettingsLedgerEntry] = []
}

/// One run that wrote into the collection, with the settings frozen when it started. One file per run.
struct CollectionRunRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = Self.currentSchemaVersion
    var id: UUID
    var startedAt: Date
    /// `processFiles`, `batch`, `preOCRed`, `reOCR`, `mixed` or `liveCapture`.
    var kind: String
    var fileCount: Int
    var settings: ResolvedSettingsSnapshot
}

/// The collection's settings document.
struct CollectionSettingsDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let folderName = ".archivesuite"
    static let fileName = "collection-settings.json"
    static let runsFolderName = "runs"

    var schemaVersion = Self.currentSchemaVersion
    var createdAt: Date
    /// The collection's own answers; its `id` is the collection's id.
    var collection: SettingsLayer
    /// The project the collection belongs to, by id, with its name for a Mac that does not have the project.
    var projectID: UUID?
    var projectName: String?

    init(name: String, createdAt: Date = Date()) {
        self.createdAt = createdAt
        self.collection = SettingsLayer(kind: .collection, name: name)
    }

    static func folder(in outputDirectory: URL) -> URL {
        outputDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    static func url(in outputDirectory: URL) -> URL {
        folder(in: outputDirectory).appendingPathComponent(fileName)
    }

    static func runsFolder(in outputDirectory: URL) -> URL {
        folder(in: outputDirectory).appendingPathComponent(runsFolderName, isDirectory: true)
    }
}

enum CollectionSettingsError: Error, Equatable, CustomStringConvertible {
    case noOutputFolder(String)
    case notADirectory(String)
    case notARegularFile(String)
    case cannotRead(String)
    case newerSchema(Int)
    case tooLarge(Int)
    case writeFailed(String)

    var description: String {
        switch self {
        case .noOutputFolder(let p): return "the output folder \(p) does not exist"
        case .notADirectory(let p): return "\(p) is not a folder (a link or a file), so nothing was written there"
        case .notARegularFile(let p): return "\(p) is not an ordinary file, so it was left alone"
        case .cannotRead(let p): return "\(p) could not be opened, so it was left alone"
        case .newerSchema(let v): return "the collection's settings were written by a newer version (format \(v)); left unchanged"
        case .tooLarge(let n): return "the collection's settings file is \(n) bytes, too large to read; left unchanged"
        case .writeFailed(let m): return "the collection's settings could not be written: \(m)"
        }
    }
}

/// Reading and writing the collection's document and run records, with no state of its own.
enum CollectionSettingsFile {
    /// What reading the document found.
    enum Read: Equatable {
        case missing
        case document(CollectionSettingsDocument)
        /// Read in full but not a document this build understands; `write` renames it aside first.
        case unreadable
        /// Left alone: a newer build's document, a link, a folder, an oversized file, one that could not be opened.
        case refused(CollectionSettingsError)
    }

    static let maxBytes = 1024 * 1024

    /// ISO 8601, written with whole seconds, read with or without fractional seconds (another app or Mac may add them).
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// What is at a path, without following a final symlink. Only "no such file" is `.missing`; any other failure to
    /// look is `.unknown`, which every caller treats as "leave it alone".
    enum Probe: Equatable { case missing, directory, file(Int), other, unknown }

    static func probe(_ url: URL) -> Probe {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return errno == ENOENT ? .missing : .unknown }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file(Int(st.st_size))
        default: return .other
        }
    }

    static func read(in outputDirectory: URL) -> Read {
        let dir = CollectionSettingsDocument.folder(in: outputDirectory)
        switch probe(dir) {
        case .missing: return .missing
        case .directory: break
        case .unknown: return .refused(.cannotRead(dir.path))
        case .file, .other: return .refused(.notADirectory(dir.path))
        }
        let file = CollectionSettingsDocument.url(in: outputDirectory)
        switch probe(file) {
        case .missing: return .missing
        case .file(let size) where size > maxBytes: return .refused(.tooLarge(size))
        case .file: break
        case .unknown: return .refused(.cannotRead(file.path))
        case .directory, .other: return .refused(.notARegularFile(file.path))
        }
        // A file that cannot be opened (permissions, a placeholder not downloaded) is not proof it is broken.
        guard let data = try? Data(contentsOf: file) else { return .refused(.cannotRead(file.path)) }
        struct Version: Decodable { let schemaVersion: Int }
        guard let version = try? decoder().decode(Version.self, from: data) else { return .unreadable }
        guard version.schemaVersion <= CollectionSettingsDocument.currentSchemaVersion else {
            return .refused(.newerSchema(version.schemaVersion))
        }
        guard let doc = try? decoder().decode(CollectionSettingsDocument.self, from: data),
              doc.collection.kind == .collection else { return .unreadable }
        return .document(doc)
    }

    /// Make sure `<output>/.archivesuite` (and, with `runs`, its `runs` folder) is a real folder, creating one level at
    /// a time; never through a link.
    private static func ensureFolders(in outputDirectory: URL, runs: Bool) throws {
        guard probe(outputDirectory) == .directory || isDirectoryFollowingLinks(outputDirectory) else {
            throw CollectionSettingsError.noOutputFolder(outputDirectory.path)
        }
        var folders = [CollectionSettingsDocument.folder(in: outputDirectory)]
        if runs { folders.append(CollectionSettingsDocument.runsFolder(in: outputDirectory)) }
        for dir in folders {
            switch probe(dir) {
            case .directory: continue
            case .missing:
                do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false) }
                catch { throw CollectionSettingsError.writeFailed(error.localizedDescription) }
                guard probe(dir) == .directory else { throw CollectionSettingsError.notADirectory(dir.path) }
            case .unknown: throw CollectionSettingsError.cannotRead(dir.path)
            case .file, .other: throw CollectionSettingsError.notADirectory(dir.path)
            }
        }
    }

    /// The output folder itself may be a link the user chose; that is theirs, so it is followed.
    private static func isDirectoryFollowingLinks(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Write the document atomically into `<output>/.archivesuite/`. Re-checks what is on disk first, so a document
    /// that became unreadable or newer since it was read is not overwritten: an unreadable one is renamed aside, one
    /// that is refused is left alone.
    static func write(_ doc: CollectionSettingsDocument, in outputDirectory: URL, now: Date = Date()) throws {
        try ensureFolders(in: outputDirectory, runs: false)
        switch read(in: outputDirectory) {
        case .refused(let e): throw e
        case .unreadable: try setAside(in: outputDirectory, now: now)
        case .missing, .document: break
        }
        let data: Data
        do { data = try encoder().encode(doc) }
        catch { throw CollectionSettingsError.writeFailed(error.localizedDescription) }
        guard data.count <= maxBytes else { throw CollectionSettingsError.tooLarge(data.count) }
        do { try data.write(to: CollectionSettingsDocument.url(in: outputDirectory), options: .atomic) }
        catch { throw CollectionSettingsError.writeFailed(error.localizedDescription) }
    }

    /// Write one run's record as a new file in `.archivesuite/runs/`, named by its start and id; never over a file.
    static func writeRun(_ record: CollectionRunRecord, in outputDirectory: URL) throws {
        try ensureFolders(in: outputDirectory, runs: true)
        let data: Data
        do { data = try encoder().encode(record) }
        catch { throw CollectionSettingsError.writeFailed(error.localizedDescription) }
        let name = "\(stamp(record.startedAt))-\(record.id.uuidString).json"
        let url = CollectionSettingsDocument.runsFolder(in: outputDirectory).appendingPathComponent(name)
        guard probe(url) == .missing else { throw CollectionSettingsError.writeFailed("\(name) already exists") }
        // O_EXCL: never over a file, never through a link.
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch { throw CollectionSettingsError.writeFailed(error.localizedDescription) }
    }

    /// The collection's run records, oldest first; a file that is not one is skipped.
    static func runs(in outputDirectory: URL) -> [CollectionRunRecord] {
        let dir = CollectionSettingsDocument.runsFolder(in: outputDirectory)
        guard probe(CollectionSettingsDocument.folder(in: outputDirectory)) == .directory, probe(dir) == .directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard case .file(let size) = probe(url), size <= maxBytes, let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? decoder().decode(CollectionRunRecord.self, from: data)
        }
    }

    /// How many run records the collection has, by name alone (Settings shows the count; no file is decoded).
    static func runCount(in outputDirectory: URL) -> Int {
        let dir = CollectionSettingsDocument.runsFolder(in: outputDirectory)
        guard probe(CollectionSettingsDocument.folder(in: outputDirectory)) == .directory, probe(dir) == .directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return names.filter { $0.hasSuffix(".json") }.count
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Rename an unreadable document aside, never delete it: `collection-settings.unreadable-<stamp>.json`.
    static func setAside(in outputDirectory: URL, now: Date) throws {
        let file = CollectionSettingsDocument.url(in: outputDirectory)
        let dir = file.deletingLastPathComponent()
        var target = dir.appendingPathComponent("collection-settings.unreadable-\(stamp(now)).json")
        if probe(target) != .missing {
            target = dir.appendingPathComponent("collection-settings.unreadable-\(stamp(now))-\(UUID().uuidString).json")
        }
        do { try FileManager.default.moveItem(at: file, to: target) }
        catch { throw CollectionSettingsError.writeFailed("could not set the unreadable file aside: \(error.localizedDescription)") }
    }
}

/// The layers as the app holds them: the general file in memory, collections read from their folders when needed.
@MainActor
final class SettingsLayerStore: ObservableObject {
    static let shared = SettingsLayerStore(directory: SettingsLayerStore.realDirectory)

    @Published private(set) var file: GeneralSettingsFile
    /// The last thing that went wrong reading or writing, for the Settings window and the run log; cleared by the next
    /// write that succeeds.
    @Published private(set) var lastProblem: String?

    let directory: URL
    var generalURL: URL { directory.appendingPathComponent("settings-general.json") }
    /// Set when the general file exists but could not be read as this build's: nothing is ever written over it.
    private(set) var readOnly = false
    /// The problem that stays while the store is read-only, so a later success elsewhere does not hide it.
    private var standingProblem: String? {
        readOnly ? "Your general settings file could not be read by this version; it was left unchanged." : nil
    }

    /// `~/Library/Application Support/ArchiveProcessor/`, beside the pending-run record.
    nonisolated static var realDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArchiveProcessor", isDirectory: true)
    }

    init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent("settings-general.json")
        file = GeneralSettingsFile()
        switch CollectionSettingsFile.probe(url) {
        case .missing: return
        case .file: break
        default: readOnly = true
        }
        if !readOnly, let data = try? Data(contentsOf: url),
           let decoded = try? CollectionSettingsFile.decoder().decode(GeneralSettingsFile.self, from: data),
           decoded.schemaVersion <= GeneralSettingsFile.currentSchemaVersion, decoded.general.kind == .general {
            file = decoded
            return
        }
        // Not this build's file, or one that could not be opened: start from the built-in values but never write over
        // it, so a newer build's settings, projects and ledger survive a run of this one.
        readOnly = true
        lastProblem = standingProblem
    }

    var general: SettingsLayer { file.general }
    var projects: [SettingsLayer] { file.projects }

    func project(_ id: UUID?) -> SettingsLayer? {
        guard let id else { return nil }
        return file.projects.first { $0.id == id }
    }

    // MARK: General layer and projects

    @discardableResult
    func setGeneral(_ key: SettingsKey, _ value: SettingsValue, source: SettingsSource) -> Bool {
        guard !readOnly, file.general.set(key, value, source: source) else { return false }
        return saveGeneral()
    }

    @discardableResult
    func resetGeneral(_ key: SettingsKey) -> Bool {
        guard !readOnly else { return false }
        file.general.reset(key)
        return saveGeneral()
    }

    /// Put a whole general layer in place, as an interview writes it (W46.settings-interviews).
    @discardableResult
    func replaceGeneral(_ layer: SettingsLayer) -> Bool {
        guard !readOnly, layer.kind == .general else { return false }
        var l = layer
        l.id = file.general.id
        file.general = l
        return saveGeneral()
    }

    @discardableResult
    func addProject(named name: String) -> SettingsLayer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnly, !trimmed.isEmpty else { return nil }
        let p = SettingsLayer(kind: .project, name: trimmed)
        file.projects.append(p)
        return saveGeneral() ? p : nil
    }

    @discardableResult
    func updateProject(_ id: UUID, _ change: (inout SettingsLayer) -> Void) -> Bool {
        guard !readOnly, let i = file.projects.firstIndex(where: { $0.id == id }) else { return false }
        var p = file.projects[i]
        change(&p)
        p.id = id
        p.kind = .project
        file.projects[i] = p
        return saveGeneral()
    }

    /// A collection that names a deleted project reads the general layer, and keeps the project's name on record.
    @discardableResult
    func deleteProject(_ id: UUID) -> Bool {
        guard !readOnly else { return false }
        file.projects.removeAll { $0.id == id }
        return saveGeneral()
    }

    @discardableResult
    func appendLedger(_ entry: SettingsLedgerEntry) -> Bool {
        guard entry.usd.isFinite else { return false }
        // Kept in memory even when it cannot be saved (a read-only store, a failed write), so this session's next
        // batch still counts it against the month.
        file.ledger.append(entry)
        return saveGeneral()
    }

    @discardableResult
    private func saveGeneral() -> Bool {
        guard !readOnly else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try CollectionSettingsFile.encoder().encode(file).write(to: generalURL, options: .atomic)
            lastProblem = nil
            return true
        } catch {
            lastProblem = "Your general settings could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Collections

    /// The resolver for a collection's folder: its own layer, its project's, and the general layer.
    func resolver(for doc: CollectionSettingsDocument?) -> SettingsResolver {
        SettingsResolver(general: file.general, project: project(doc?.projectID), collection: doc?.collection)
    }

    /// Change a collection's layer in its folder, creating the document if there is none.
    @discardableResult
    func updateCollection(in outputDirectory: URL,
                          _ change: (inout CollectionSettingsDocument) -> Void) -> CollectionSettingsDocument? {
        var doc: CollectionSettingsDocument
        switch CollectionSettingsFile.read(in: outputDirectory) {
        case .document(let d): doc = d
        case .missing, .unreadable: doc = CollectionSettingsDocument(name: outputDirectory.lastPathComponent)
        case .refused(let e): lastProblem = e.description; return nil
        }
        let id = doc.collection.id
        change(&doc)
        doc.collection.id = id
        doc.collection.kind = .collection
        doc.projectName = project(doc.projectID)?.name ?? doc.projectName
        do {
            try CollectionSettingsFile.write(doc, in: outputDirectory)
            lastProblem = standingProblem
            return doc
        } catch {
            lastProblem = "\(error)"
            return nil
        }
    }

    /// Resolve the layers for a run about to write into `outputDirectory`, without writing anything: the snapshot the
    /// run's pending record carries. `runID` joins it to the run record `record` later writes.
    func snapshot(outputDirectory: URL, runID: UUID, processing: [String: SettingsValue],
                  macMemoryGB: Double = SettingsLayerStore.thisMacMemoryGB,
                  now: Date = Date()) -> ResolvedSettingsSnapshot {
        var doc: CollectionSettingsDocument?
        if case .document(let d) = CollectionSettingsFile.read(in: outputDirectory) { doc = d }
        let resolver = resolver(for: doc)
        return ResolvedSettingsSnapshot(
            runID: runID, resolvedAt: now, collectionID: doc?.collection.id, projectID: resolver.project?.id,
            projectName: resolver.project?.name ?? doc?.projectName,
            macMemoryGB: macMemoryGB, values: resolver.resolveAll(), processing: processing)
    }

    /// Record a run in the collection: the document (created if there is none, so the collection has an id) and one
    /// run file. Called once the run is committed to start (its pending record saved), so a refused start leaves
    /// nothing. Returns the problem, if any, for the run log; it never stops the run.
    @discardableResult
    func record(_ snapshot: ResolvedSettingsSnapshot, kind: String, fileCount: Int, in outputDirectory: URL) -> String? {
        var snapshot = snapshot
        var problem: String?
        switch CollectionSettingsFile.read(in: outputDirectory) {
        case .document(let d):
            snapshot.collectionID = d.collection.id
        case .missing, .unreadable:
            let doc = CollectionSettingsDocument(name: outputDirectory.lastPathComponent, createdAt: snapshot.resolvedAt)
            do {
                try CollectionSettingsFile.write(doc, in: outputDirectory, now: snapshot.resolvedAt)
                snapshot.collectionID = doc.collection.id
            } catch { problem = "\(error)" }
        case .refused(let e):
            problem = e.description
        }
        if problem == nil {
            let record = CollectionRunRecord(id: snapshot.runID, startedAt: snapshot.resolvedAt, kind: kind,
                                             fileCount: fileCount, settings: snapshot)
            do { try CollectionSettingsFile.writeRun(record, in: outputDirectory) }
            catch { problem = "\(error)" }
        }
        lastProblem = problem ?? standingProblem
        if let problem { NSLog("ArchiveProcessor: the collection's settings record was not written: %@", problem) }
        return problem
    }

    /// What the ledger records for the current calendar month, which a per-month ceiling is read against.
    func spentThisMonthUSD(now: Date = Date(), calendar: Calendar = .current) -> Double {
        monthSpend(now: now, calendar: calendar).usd
    }

    /// The current calendar month's ledger lines and their total.
    func monthSpend(now: Date = Date(), calendar: Calendar = .current) -> SettingsMonthSpend {
        let lines = file.ledger.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) && $0.usd.isFinite }
        return SettingsMonthSpend(usd: lines.reduce(0) { $0 + max(0, $1.usd) },
                                  entries: lines.sorted { $0.date > $1.date })
    }

    /// Lines older than this are dropped when a batch is recorded: only the current month is read, and a year back
    /// is kept for the user to look over.
    static let ledgerKeepDays = 400

    /// Record what a finished batch spent (W46.settings-ledger), whatever the money habit is, so switching to a
    /// monthly limit later starts from what this month really spent. A free batch writes nothing; a run already in
    /// the ledger (by its id) is not counted twice. The collection is read from its folder, so a batch that created it
    /// has its id. Returns whether a line was written.
    @discardableResult
    func recordSpend(usd: Double, runID: UUID?, outputDirectory: URL?, files: Int,
                     now: Date = Date()) -> Bool {
        guard usd.isFinite, usd > 0 else { return false }
        if let runID, file.ledger.contains(where: { $0.runID == runID }) { return false }
        var collectionID: UUID?
        var name = outputDirectory?.lastPathComponent
        if let outputDirectory, case .document(let d) = CollectionSettingsFile.read(in: outputDirectory) {
            collectionID = d.collection.id
            name = d.collection.name
        }
        let cutoff = now.addingTimeInterval(-Double(Self.ledgerKeepDays) * 86_400)
        file.ledger.removeAll { $0.date < cutoff }
        return appendLedger(SettingsLedgerEntry(date: now, usd: usd, collectionID: collectionID, runID: runID,
                                                collectionName: name, files: files))
    }

    nonisolated static var thisMacMemoryGB: Double {
        (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()
    }
}

// MARK: - The app's processing settings, as a run reads them

/// The durable processing settings a run reads from `UserDefaults`, captured for the frozen record. Formerly the
/// capture half of the old named processing profiles (removed by W46.settings-layers): the effective value of each key,
/// stored or defaulted as the views default it, and every provider's selected model. Never an API key.
enum ProcessingSettingsCapture {
    private struct Descriptor { let key: String; let def: SettingsValue }

    private static let descriptors: [Descriptor] = [
        .init(key: DefaultsKeys.selectedProvider, def: .string(LLMProvider.gemini.rawValue)),
        .init(key: DefaultsKeys.selectedThinking, def: .string(ThinkingLevel.low.rawValue)),

        .init(key: DefaultsKeys.useGateway, def: .bool(false)),
        .init(key: DefaultsKeys.useAppleVision, def: .bool(false)),
        .init(key: DefaultsKeys.visionUseLLMJudgment, def: .bool(false)),
        .init(key: DefaultsKeys.visionLanguages, def: .string("en-US")),
        .init(key: DefaultsKeys.visionFastRecognition, def: .bool(false)),
        .init(key: DefaultsKeys.visionMinimumConfidence, def: .double(0)),
        .init(key: DefaultsKeys.visionCustomVocabulary, def: .string("")),
        .init(key: DefaultsKeys.gatewayBaseURL, def: .string("")),
        .init(key: DefaultsKeys.gatewayModelID, def: .string("")),
        .init(key: DefaultsKeys.gatewayDisplayName, def: .string("")),
        .init(key: DefaultsKeys.gatewayInputCost, def: .double(-1)),
        .init(key: DefaultsKeys.gatewayOutputCost, def: .double(-1)),
        .init(key: DefaultsKeys.gatewayUpstreamProvider, def: .string(LLMProvider.anthropic.rawValue)),
        .init(key: DefaultsKeys.gatewayLocalModel, def: .bool(false)),
        .init(key: DefaultsKeys.gatewayLocalEscalates, def: .bool(false)),

        .init(key: DefaultsKeys.batchMode, def: .bool(false)),
        .init(key: DefaultsKeys.preOCRedInput, def: .bool(false)),
        .init(key: DefaultsKeys.skipAlreadyProcessed, def: .bool(false)),
        .init(key: DefaultsKeys.ocrWorkerCount, def: .int(4)),
        .init(key: DefaultsKeys.imageResolutionPercent, def: .double(100)),
        .init(key: DefaultsKeys.standardImageSizeMB, def: .double(3.0)),
        .init(key: DefaultsKeys.pdfImageSizeMB, def: .double(2.0)),
        .init(key: DefaultsKeys.textColumns, def: .int(1)),
        .init(key: DefaultsKeys.exportedImageSizeMB, def: .double(3.0)),
        .init(key: DefaultsKeys.outputImageFile, def: .bool(true)),
        .init(key: DefaultsKeys.contextCharCount, def: .double(0)),
        .init(key: DefaultsKeys.sendPreviousImage, def: .bool(false)),
        .init(key: DefaultsKeys.customOCRPrompt, def: .string("")),
        .init(key: DefaultsKeys.mergeDocuments, def: .bool(false)),
        .init(key: DefaultsKeys.writeLogFile, def: .bool(false)),

        .init(key: DefaultsKeys.rotationModeRaw, def: .string(RotationMode.standard.rawValue)),
        .init(key: DefaultsKeys.reviewRotation, def: .bool(false)),

        .init(key: DefaultsKeys.taggingModeRaw, def: .string(TaggingMode.automatic.rawValue)),
        .init(key: DefaultsKeys.segmentationApproach, def: .string(SegmentationApproach.defaultApproach.rawValue)),
        .init(key: DefaultsKeys.enableCollectionSegmentation, def: .bool(false)),
        .init(key: DefaultsKeys.confirmCollectionIDs, def: .bool(false)),
        .init(key: DefaultsKeys.reviewDocumentSegmentation, def: .bool(false)),
        .init(key: DefaultsKeys.enableSegmentJSON, def: .bool(true)),
        .init(key: DefaultsKeys.tagVocabulary, def: .string("")),

        .init(key: DefaultsKeys.liveProcessingMode, def: .string(LiveProcessingMode.stage.rawValue)),
    ]

    static func capture(_ d: UserDefaults = .standard) -> [String: SettingsValue] {
        var values: [String: SettingsValue] = [:]
        for desc in descriptors {
            guard d.object(forKey: desc.key) != nil else { values[desc.key] = desc.def; continue }
            switch desc.def {
            case .bool: values[desc.key] = .bool(d.bool(forKey: desc.key))
            case .int: values[desc.key] = .int(d.integer(forKey: desc.key))
            case .double:
                // JSON has no infinity or NaN: one would make the pending record unwritable and stop the run.
                let x = d.double(forKey: desc.key)
                values[desc.key] = x.isFinite ? .double(x) : desc.def
            default:
                let text = d.string(forKey: desc.key) ?? ""
                values[desc.key] = .string(desc.key == DefaultsKeys.gatewayBaseURL ? Self.withoutCredentials(text) : text)
            }
        }
        for provider in LLMProvider.allCases {
            let key = ModelSelectionStore.modelKey(for: provider)
            if let id = d.string(forKey: key) { values[key] = .string(id) }
        }
        return values
    }

    /// A gateway address as recorded beside the output: scheme, host, port and path only, so a user name, password or
    /// token written into the address never reaches the collection's folder.
    static func withoutCredentials(_ address: String) -> String {
        guard var parts = URLComponents(string: address), parts.host != nil else { return address.isEmpty ? "" : "(not an address)" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? ""
    }
}
