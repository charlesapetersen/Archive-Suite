// NewspaperLayout.swift — PP-DocLayoutV3 for newspaper pages (W46.layout-newspapers). The app owns the kind gate,
// crop reading and whole-page fallback. This detector only returns the model's regions, in its own reading order,
// with every label kept. It shares the checked reading runtime, but has its own pinned weights (`ModelDownloads`),
// downloaded only when the user asks. Detection never downloads, and runs alone among the kit's model readers,
// with the same memory-pressure, swap and process-footprint guards as the hand placer.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum NewspaperLayout {
    /// One region, normalised to the upright page, origin top-left. `order` is the detector's native 1-based rank.
    /// A picture stays in this stream: excluding it loses handwriting and some headlines.
    public struct Region: Sendable, Equatable {
        public let box: CGRect
        public let order: Int
        public let label: String
        public let score: Double

        public init(box: CGRect, order: Int, label: String, score: Double = 1) {
            self.box = box
            self.order = order
            self.label = label
            self.score = score
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case notInstalled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "the newspaper layout detector has not been downloaded"
            case .failed(let why): return why
            }
        }
    }

    /// Loading and detection measured under two seconds together on the bench. A stalled process is stopped,
    /// rather than holding a page indefinitely; a failed detector makes the app read the whole page.
    static let seconds: Double = 60

    private static let items: [ModelDownloads.Item] = [.runtime, .newspaperLayout]

    /// Whether both the shared runtime and this detector's pinned model snapshot are in place.
    public static func isInstalled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        items.allSatisfy { installed($0, environment) }
    }

    /// The currently missing downloads in decimal MB, including the shared runtime when it is absent.
    public static var downloadMB: Int { downloadMB(environment: ProcessInfo.processInfo.environment) }

    public static func downloadMB(environment: [String: String]) -> Int {
        let bytes = items.filter { !installed($0, environment) }.reduce(Int64(0)) { $0 + $1.plan.bytes }
        return Int((Double(bytes) / 1_000_000).rounded(.up))
    }

    /// Fetches and checks the missing pieces, installing each whole. An incomplete model directory does not count
    /// as installed, so it is fetched again even when the pinned snapshot's directory exists.
    public static func download(environment: [String: String] = ProcessInfo.processInfo.environment,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let missing = items.filter { !installed($0, environment) }
        let total = Double(max(missing.reduce(Int64(0)) { $0 + $1.plan.bytes }, 1))
        var done: Int64 = 0
        for item in missing {
            try Task.checkCancellation()
            let previous = done
            try await ModelDownloads.install(item.plan, home: ModelRuntime.home(environment), source: .current(environment)) {
                progress(min(1, Double(previous + $0) / total))
            }
            done += item.plan.bytes
        }
        progress(1)
    }

    private static func installed(_ item: ModelDownloads.Item, _ environment: [String: String]) -> Bool {
        item.installed(environment) && (item != .newspaperLayout || ["config.json", "model.safetensors"].allSatisfy {
            FileManager.default.fileExists(atPath: model(environment).appendingPathComponent($0).path)
        })
    }

    static func model(_ environment: [String: String]) -> URL {
        let plan = ModelDownloads.Item.newspaperLayout.plan
        guard case .hub(_, let revision, _) = plan else { preconditionFailure("newspaper layout must be a pinned snapshot") }
        return ModelRuntime.home(environment).appendingPathComponent(plan.destination)
            .appendingPathComponent("snapshots/\(revision)")
    }

    static func script(_ environment: [String: String]) -> URL? {
        if let path = environment["VISIONOCR_NEWSPAPER_SCRIPT"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("detect-newspaper.py")
        #if SWIFT_PACKAGE
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return Bundle.module.url(forResource: "detect-newspaper", withExtension: "py") ?? bundled
        #else
        return bundled
        #endif
    }

    struct Command: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    static func command(image: URL, out: URL,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Command {
        guard isInstalled(environment) else { throw Failure.notInstalled }
        guard let script = script(environment), FileManager.default.fileExists(atPath: script.path) else {
            throw Failure.failed("the newspaper detector's script is not in this build")
        }
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1",
                   "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"]
        for key in ["HOME", "TMPDIR"] { env[key] = environment[key] }
        return Command(executable: ModelRuntime.home(environment).appendingPathComponent("Runtime/bin/python3"),
                       arguments: ["-I", script.path, image.path, out.path, "--model", model(environment).path],
                       environment: env)
    }

    /// Detects the page's regions. Synchronous: call off the main thread. The process defaults to a 3 GB footprint
    /// cap (the bench's MLX peak was 1.52 GB); it holds all kit reader slots, so a reader cannot load alongside it.
    /// The caller reads whole when detection fails or these regions do not cover enough of Vision's ink.
    public static func detect(image: CGImage, memoryGB: Double = 3,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              isCancelled: () -> Bool = { false }) throws -> [Region] {
        assert(!Thread.isMainThread, "NewspaperLayout.detect on the main thread")
        if isCancelled() { throw CancellationError() }
        guard isInstalled(environment) else { throw Failure.notInstalled }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("visionocr-newspaper-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("page.png"), out = dir.appendingPathComponent("regions.json")
        // Lossless handoff: the caller's upright pixels, without adding a second JPEG quantisation.
        guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.failed("the page could not be handed to the newspaper detector")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.failed("the page could not be handed to the newspaper detector")
        }
        let command = try command(image: imageURL, out: out, environment: environment)
        try run(command, memoryGB: memoryGB, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        guard let data = try? Data(contentsOf: out) else { throw Failure.failed("the newspaper detector wrote nothing") }
        return try decode(data)
    }

    /// The model's viewer schema, decoded without changing its native order. A malformed reply is a failed page;
    /// invalid individual geometry is ignored. No label filter runs, including on pictures and tables.
    static func decode(_ data: Data) throws -> [Region] {
        struct Row: Decodable {
            let bbox: [Double]
            let reading_order: Int
            let label: String
            let score: Double
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw Failure.failed("the newspaper detector's output could not be read")
        }
        return rows.enumerated().sorted {
            $0.element.reading_order == $1.element.reading_order ? $0.offset < $1.offset
                : $0.element.reading_order < $1.element.reading_order
        }.compactMap { _, row in
            guard row.bbox.count == 4, row.bbox.allSatisfy(\.isFinite), row.score.isFinite,
                  row.reading_order > 0, row.score >= 0.5 else { return nil }
            let y0 = max(0, row.bbox[0] / 1000), x0 = max(0, row.bbox[1] / 1000)
            let y1 = min(1, row.bbox[2] / 1000), x1 = min(1, row.bbox[3] / 1000)
            guard x1 > x0, y1 > y0 else { return nil }
            return Region(box: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                          order: row.reading_order, label: row.label, score: row.score)
        }
    }

    static func run(_ command: Command, memoryGB: Double, isCancelled: () -> Bool) throws {
        let locks = try Recogniser.takeReaderSlot(1, isCancelled: isCancelled)
        defer { locks.forEach { close($0) } }
        if isCancelled() { throw CancellationError() }
        guard ModelGuard.pressure() < ModelGuard.critical else {
            throw Failure.failed("the Mac's memory pressure was critical, so the newspaper detector was not started")
        }
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let capMB = Int(min(max(memoryGB.isFinite ? memoryGB : 3, 0), 1024) * 1024)
        let swap0 = ModelGuard.swapUsedMB()
        do { try process.run() } catch {
            throw Failure.failed("the newspaper detector could not be started (\(error.localizedDescription))")
        }
        let group = Runner.processGroup(of: process)
        let deadline = Date().addingTimeInterval(seconds)
        var sampled = Date.distantPast
        while process.isRunning {
            if isCancelled() {
                Runner.stop(process, knownGroup: group)
                throw CancellationError()
            }
            if Date() > deadline {
                Runner.stop(process, knownGroup: group)
                throw Failure.failed("the newspaper detector took longer than \(Int(seconds)) seconds")
            }
            if Date().timeIntervalSince(sampled) >= ModelGuard.every {
                sampled = Date()
                let footprint = ModelGuard.footprintMB(leader: process.processIdentifier, group: group)
                if let why = ModelGuard.verdict(footprintMB: footprint, capMB: capMB, pressure: ModelGuard.pressure(),
                                                swapGrowthMB: ModelGuard.swapUsedMB() - swap0) {
                    Runner.stop(process, knownGroup: group)
                    throw Failure.failed("the newspaper detector \(why)")
                }
            }
            usleep(50_000)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.failed("the newspaper detector stopped with status \(process.terminationStatus)")
        }
    }
}
