import OSLog

/// Structured `os.Logger` categories for Archive Notes (W49.suite-tester-diagnostics).
/// Collected by Help ▸ Export Logs… via `OSLogStore(scope: .currentProcessIdentifier)`.
enum NotesLog {
    static let subsystem = "com.archivenotes.app"

    static let store = Logger(subsystem: subsystem, category: "Store")
    static let index = Logger(subsystem: subsystem, category: "Index")
    static let organization = Logger(subsystem: subsystem, category: "Organization")
    static let links = Logger(subsystem: subsystem, category: "Links")
    static let zotero = Logger(subsystem: subsystem, category: "Zotero")
    static let editor = Logger(subsystem: subsystem, category: "Editor")
}
