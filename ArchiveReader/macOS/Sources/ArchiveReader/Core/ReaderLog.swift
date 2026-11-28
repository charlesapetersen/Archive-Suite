import OSLog

/// Structured `os.Logger` categories for Archive Reader (W49.suite-tester-diagnostics).
/// Collected by Help ▸ Export Logs… via `OSLogStore(scope: .currentProcessIdentifier)`.
enum ReaderLog {
    static let subsystem = "com.archivereader.app"

    static let library = Logger(subsystem: subsystem, category: "Library")
    static let index = Logger(subsystem: subsystem, category: "Index")
    static let watcher = Logger(subsystem: subsystem, category: "Watcher")
    static let catalogue = Logger(subsystem: subsystem, category: "Catalogue")
    static let improveOCR = Logger(subsystem: subsystem, category: "ImproveOCR")
}
