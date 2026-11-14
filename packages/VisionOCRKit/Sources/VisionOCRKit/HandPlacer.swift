// HandPlacer.swift — the hand placer (W42.int-s5-hands): a handwritten page's reading placed on its own written lines,
// for the searchable layer on the page image (`execution-plans/processing-review/13-stage-rules/05-placement.md` §3,
// `hand-blla-ctc`). kraken's blla finds the lines; McCATMuS's CTC output force-aligns the reading's lines onto them,
// the surer of a one-to-one and a reflow-tolerant match kept (`Resources/place-hands.py`, which says how). The page's
// confidence decides, against `gate`, whether the caller lays the layer or keeps the text page.
//
// It runs in its own download (`ModelDownloads.Item.hands`, `Hands/` under the model home): a Python with kraken and
// PyTorch, nothing at install, fetched when the user asks (`download`). Like a model reader it runs as a separate
// process holding every reader slot (so it never shares the Mac's memory with a reader), under `ModelGuard`'s limits,
// stopped past `seconds`. Measured in the app on 24 hand pages: 15-31 s a page on the CPU, physical footprint up to
// about 6.2 GB (W42.int-s5-hands, `ArchiveProcessor/scripts/measure-hands.sh`).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum HandPlacer {
    /// The alignment confidence under which a page gets the text page instead (owner, 2026-11-06, option a).
    public static let gate = 0.67
    /// A page's limit, the model readers' 540 s and a margin for loading.
    static let seconds: Double = 600
    /// The footprint cap, the placer's own: its physical footprint passed 6 GB on 4 of 24 smoke pages (W42.int-s5-hands;
    /// resident size said 3.3-4.2 GB), over the 4 GB `Prefs.defaultModelMemoryGB` gives a Mac under 16 GB. The route
    /// fits 16 GB, not 8 (`place-hands-cost.md`); the memory-pressure and swap stops still guard a small Mac.
    public static let memoryGB: Double = 10

    /// A page's placement: the lines to write, and what decided them.
    public struct Placement: @unchecked Sendable {
        /// The found lines that hold text, each with the reading's words aligned to it.
        public let lines: TextLayer.Lines
        /// The mean aligned-character score over the reading's characters (0 to 1).
        public let confidence: Double
        /// 1: one reading line a found line; 8: a reading line over up to 8 found lines (the reader reflowed).
        public let span: Int
        /// Lines blla found, and the reading's own.
        public let detected: Int
        public let readingLines: Int
        /// Seconds the whole run took, and its process's peak memory in MB: the larger of its resident size and the
        /// physical footprint sampled while it ran.
        public let seconds: Double
        public let peakMB: Int
        /// Whether the layer is laid (`gate`): a page under it, or with no line placed, gets the text page.
        public var passesGate: Bool { confidence >= HandPlacer.gate && !lines.isEmpty }
    }

    public enum Failure: LocalizedError, Equatable {
        case notInstalled
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "the handwriting placer has not been downloaded"
            case .failed(let why): return why
            }
        }
    }

    // MARK: - The download

    /// Whether the placer's download is in place and runs.
    public static func isInstalled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ModelDownloads.Item.hands.installed(environment)
            && FileManager.default.fileExists(atPath: model(environment).path)
    }

    /// The download in decimal MB.
    public static var downloadMB: Int { ModelDownloads.Item.hands.downloadMB }

    /// Downloads, checks and installs the placer (`ModelDownloads.install`): `progress` gets the share fetched, 0 to 1.
    /// A failure or a cancel leaves nothing half installed.
    public static func download(environment: [String: String] = ProcessInfo.processInfo.environment,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let plan = ModelDownloads.Item.hands.plan
        // No `ModelDownloads.sweep` here: a reader's download may be staging beside this one (the review of
        // W42.int-s5-hands); a staging folder a crash leaves is swept by the host's next reader download.
        let home = ModelRuntime.home(environment)
        let total = Double(max(plan.bytes, 1))
        try await ModelDownloads.install(plan, home: home, source: .current(environment)) { progress(Double($0) / total) }
    }

    static func root(_ environment: [String: String]) -> URL {
        ModelRuntime.home(environment).appendingPathComponent(ModelDownloads.Item.hands.plan.destination)
    }

    static func model(_ environment: [String: String]) -> URL {
        root(environment).appendingPathComponent("models/McCATMuS_nfd_nofix_V1.mlmodel")
    }

    /// The placer's script, beside the app's resources or the package's (as `ModelRuntime.script` finds the reader's);
    /// `VISIONOCR_HANDS_SCRIPT` is the suite's way to it.
    static func script(_ environment: [String: String]) -> URL? {
        if let override = environment["VISIONOCR_HANDS_SCRIPT"], !override.isEmpty { return URL(fileURLWithPath: override) }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("place-hands.py")
        #if SWIFT_PACKAGE
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return Bundle.module.url(forResource: "place-hands", withExtension: "py") ?? bundled
        #else
        return bundled
        #endif
    }

    struct Command: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    /// How to place `reading` (a UTF-8 file) on `image`, writing `out`; throws when the download is not in place.
    static func command(image: URL, reading: URL, out: URL,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Command {
        guard isInstalled(environment) else { throw Failure.notInstalled }
        guard let script = script(environment), FileManager.default.fileExists(atPath: script.path) else {
            throw Failure.failed("the handwriting placer's script is not in this build")
        }
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1",
                   "PYTORCH_ENABLE_MPS_FALLBACK": "1"]
        for key in ["HOME", "TMPDIR"] { env[key] = environment[key] }
        return Command(executable: root(environment).appendingPathComponent("bin/python3"),
                       arguments: ["-I", script.path, image.path, reading.path, out.path,
                                   "--model", model(environment).path, "--device", "cpu"],
                       environment: env)
    }

    // MARK: - Placing a page

    /// Places `reading` on `image` (the page as the layer will sit on it). Synchronous and seconds a page: call it off
    /// the main thread. `memoryGB` caps the process's footprint (`memoryGB` below when nil).
    public static func place(image: CGImage, reading: String, memoryGB: Double? = nil,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             isCancelled: () -> Bool = { false }) throws -> Placement {
        assert(!Thread.isMainThread, "HandPlacer.place on the main thread")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("visionocr-hands-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // A JPEG at the camera's quality, as the bench's pages were.
        let imageURL = dir.appendingPathComponent("page.jpg"), readingURL = dir.appendingPathComponent("reading.txt")
        let out = dir.appendingPathComponent("placed.json")
        guard let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.failed("the page could not be handed to the placer")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.failed("the page could not be handed to the placer") }
        try Data(reading.utf8).write(to: readingURL)
        let command = try command(image: imageURL, reading: readingURL, out: out, environment: environment)
        let started = Date()
        let footprintMB = try run(command, memoryGB: memoryGB ?? Self.memoryGB, isCancelled: isCancelled)
        guard let data = try? Data(contentsOf: out) else { throw Failure.failed("the handwriting placer wrote nothing") }
        return try decode(data, seconds: Date().timeIntervalSince(started), footprintMB: footprintMB)
    }

    /// The script's JSON as a placement.
    static func decode(_ data: Data, seconds: Double, footprintMB: Int = 0) throws -> Placement {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Out: Decodable {
            let lines: [Line]; let confidence: Double; let span: Int; let detected: Int
            let reading_lines: Int; let peak_rss: Int64
        }
        guard let o = try? JSONDecoder().decode(Out.self, from: data) else {
            throw Failure.failed("the handwriting placer's output could not be read")
        }
        let lines = o.lines.compactMap { l -> PageLine? in
            guard l.box.count == 4, l.box[2] > 0, l.box[3] > 0, !l.text.isEmpty, l.box.allSatisfy(\.isFinite) else { return nil }
            return PageLine(text: l.text, box: CGRect(x: l.box[0], y: l.box[1], width: l.box[2], height: l.box[3]),
                            confidence: Float(o.confidence))
        }
        return Placement(lines: TextLayer.lines(lines), confidence: o.confidence.isFinite ? o.confidence : 0, span: o.span,
                         detected: o.detected, readingLines: o.reading_lines, seconds: seconds,
                         peakMB: max(Int(o.peak_rss / 1_048_576), footprintMB))
    }

    /// Runs the placer alone among the model readers, under their memory guard and `seconds`; returns the largest
    /// physical footprint sampled, in MB.
    private static func run(_ command: Command, memoryGB: Double, isCancelled: () -> Bool) throws -> Int {
        let locks: [Int32]
        do { locks = try Recogniser.takeReaderSlot(1, isCancelled: isCancelled) } catch {
            throw Failure.failed("the handwriting placer could not start: \(error.localizedDescription)")
        }
        defer { locks.forEach { close($0) } }
        if ModelGuard.pressure() >= ModelGuard.critical {
            throw Failure.failed("the Mac's memory pressure was critical, so the handwriting placer was not started")
        }
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let capMB = Int(min(max(memoryGB.isFinite ? memoryGB : Prefs.defaultModelMemoryGB(), 0), 1024) * 1024)
        let swap0 = ModelGuard.swapUsedMB()
        do { try process.run() } catch {
            throw Failure.failed("the handwriting placer could not be started (\(error.localizedDescription))")
        }
        let group = Runner.processGroup(of: process)
        let deadline = Date().addingTimeInterval(seconds)
        var sampled = Date.distantPast
        var peak = 0
        while process.isRunning {
            if isCancelled() {
                Runner.stop(process, knownGroup: group)
                throw Failure.failed("cancelled")
            }
            if Date() > deadline {
                Runner.stop(process, knownGroup: group)
                throw Failure.failed("the handwriting placer took longer than \(Int(seconds)) seconds")
            }
            if Date().timeIntervalSince(sampled) >= ModelGuard.every {
                sampled = Date()
                let footprint = ModelGuard.footprintMB(leader: process.processIdentifier, group: group)
                peak = max(peak, footprint)
                if let why = ModelGuard.verdict(footprintMB: footprint, capMB: capMB, pressure: ModelGuard.pressure(),
                                                swapGrowthMB: ModelGuard.swapUsedMB() - swap0) {
                    Runner.stop(process, knownGroup: group)
                    throw Failure.failed("the handwriting placer \(why)")
                }
            }
            usleep(50_000)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.failed("the handwriting placer stopped with status \(process.terminationStatus)")
        }
        return peak
    }
}
