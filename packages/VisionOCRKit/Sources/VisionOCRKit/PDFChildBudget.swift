import Foundation

/// A shared monotonic deadline for all the child processes used to write a searchable page.
public struct PDFChildBudget {
    public static let secondsPerPage: Double = 60

    private let seconds: Double
    private let deadline: DispatchTime
    private let isCancelled: () -> Bool

    public init(seconds: Double = Self.secondsPerPage, isCancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.seconds = seconds
        deadline = .now() + seconds
        self.isCancelled = isCancelled
    }

    enum TimedOut: LocalizedError {
        case after(Double)

        var errorDescription: String? {
            switch self {
            case .after(let seconds): return "PDF compression exceeded its \(seconds.formatted())-second limit"
            }
        }
    }

    public func check() throws {
        if isCancelled() { throw CancellationError() }
        if DispatchTime.now() >= deadline { throw TimedOut.after(seconds) }
    }

    /// Starts a configured process whose output goes to regular files or the null device.
    /// Waiting for a pipe's EOF instead could strand the caller behind a child or a descendant.
    public func run(_ process: Process) throws {
        try check()
        try process.run()
        let group = Runner.processGroup(of: process)
        do {
            while process.isRunning {
                try check()
                usleep(20_000)
            }
            try check()
        } catch {
            Runner.stop(process, knownGroup: group, graceSeconds: 0.5)
            throw error
        }
    }

    public func capture(_ process: Process) throws -> (out: Data, err: Data) {
        try Self.capture(process, stdout: true, stderr: true, budget: self, register: { _ in })
    }

    /// Capture only the requested streams. Files let the supervisor poll without a pipe filling up.
    static func capture(_ process: Process, stdout: Bool = false, stderr: Bool = false,
                        budget: Self?, register: (Process) -> Void) throws -> (out: Data, err: Data) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("visionocr-pdf-child-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let outURL = scratch.appendingPathComponent("stdout")
        let errURL = scratch.appendingPathComponent("stderr")

        func sink(_ url: URL) throws -> FileHandle {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return try FileHandle(forWritingTo: url)
        }
        let out = try stdout ? sink(outURL) : nil
        defer { try? out?.close() }
        let err = try stderr ? sink(errURL) : nil
        defer { try? err?.close() }
        if let out { process.standardOutput = out }
        if let err { process.standardError = err }
        process.standardInput = FileHandle.nullDevice

        if let budget {
            try budget.run(process)
        } else {
            try process.run()
            register(process)
            process.waitUntilExit()
        }
        return (try stdout ? Data(contentsOf: outURL) : Data(), try stderr ? Data(contentsOf: errURL) : Data())
    }
}
