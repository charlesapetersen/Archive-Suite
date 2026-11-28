import OSLog

/// Structured `os.Logger` categories for Archive Processor (W49.suite-tester-diagnostics).
/// Collected by Help ▸ Export Logs… via `OSLogStore(scope: .currentProcessIdentifier)`.
enum ProcessorLog {
    static let subsystem = "com.archiveprocessor.app"

    static let pipeline = Logger(subsystem: subsystem, category: "Pipeline")
    static let capture = Logger(subsystem: subsystem, category: "Capture")
    static let localModels = Logger(subsystem: subsystem, category: "LocalModels")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
}
