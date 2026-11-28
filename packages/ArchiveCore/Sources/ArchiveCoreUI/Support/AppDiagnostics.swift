import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Non-PII build and environment summary attached to tester bug reports and exported logs (W49.suite-tester-diagnostics).
public struct AppDiagnosticsInfo: Equatable, Sendable {
    public static let defaultRepositoryURL = "https://github.com/charlesapetersen/Archive-Suite"

    public let appName: String
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let gitSHA: String
    public let macOSVersion: String
    public let hardwareModel: String

    public init(
        appName: String,
        bundleIdentifier: String,
        version: String,
        build: String,
        gitSHA: String,
        macOSVersion: String,
        hardwareModel: String
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.gitSHA = gitSHA
        self.macOSVersion = macOSVersion
        self.hardwareModel = hardwareModel
    }

    public static func current(bundle: Bundle = .main) -> AppDiagnosticsInfo {
        let info = bundle.infoDictionary ?? [:]
        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info["CFBundleVersion"] as? String) ?? "unknown"
        let sha = (info["ArchiveGitSHA"] as? String) ?? "dev"
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let hw = Self.readHardwareModel()
        return AppDiagnosticsInfo(
            appName: appName,
            bundleIdentifier: bundleID,
            version: version,
            build: build,
            gitSHA: sha,
            macOSVersion: macOS,
            hardwareModel: hw
        )
    }

    /// Plain-text summary suitable for clipboard or log header (no user file paths, keys, or corpus text).
    public var summaryText: String {
        """
        App: \(appName) (\(bundleIdentifier))
        Version: \(version) (\(build))
        Commit: \(gitSHA)
        macOS: \(macOSVersion)
        Hardware: \(hardwareModel)
        """
    }

    /// GitHub new-issue URL prefilled with app/version/SHA/macOS and sections for tester reports.
    public func bugReportURL(repository: String = AppDiagnosticsInfo.defaultRepositoryURL) -> URL? {
        guard var components = URLComponents(string: "\(repository)/issues/new") else { return nil }
        let title = "[\(appName)] "
        let body = """
        ### What happened


        ### Steps to reproduce
        1. 
        2. 

        ### Expected behavior


        ### Diagnostics
        ```
        \(summaryText)
        ```
        _(If helpful, choose Help ▸ Export Logs… and attach the saved log file.)_
        """
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    private static func readHardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Shared Help-menu actions for bug reporting, copying diagnostics, and exporting process logs.
@MainActor
public enum AppDiagnostics {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.archivesuite.app",
                                    category: "Diagnostics")

    public static func copyDiagnosticsInfo(bundle: Bundle = .main) {
        let text = AppDiagnosticsInfo.current(bundle: bundle).summaryText
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log.info("Copied diagnostics info to clipboard")
    }

    public static func openBugReport(
        bundle: Bundle = .main,
        repository: String = AppDiagnosticsInfo.defaultRepositoryURL
    ) {
        guard let url = AppDiagnosticsInfo.current(bundle: bundle).bugReportURL(repository: repository) else { return }
        log.info("Opening bug report page")
        NSWorkspace.shared.open(url)
    }

    /// Collects recent structured log entries from this process via `OSLogStore(scope: .currentProcessIdentifier)`,
    /// which requires no extra sandbox entitlements.
    public nonisolated static func collectRecentLogs(
        bundle: Bundle = .main,
        subsystem: String? = nil,
        lastHours: TimeInterval = 24,
        maxEntries: Int = 5000
    ) -> String {
        let info = AppDiagnosticsInfo.current(bundle: bundle)
        let targetSubsystem = subsystem ?? info.bundleIdentifier
        var lines: [String] = [
            "=== Archive Suite Diagnostics Log ===",
            info.summaryText,
            "Exported: \(Date().formatted(.iso8601))",
            ""
        ]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-lastHours))
            let entries = try store.getEntries(at: position)
            let formatter = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            var matched: [String] = []
            for case let entry as OSLogEntryLog in entries {
                let entrySub = entry.subsystem
                let relevant = entrySub == targetSubsystem
                    || entrySub.hasPrefix("com.archive")
                    || entry.level == .error
                    || entry.level == .fault
                guard relevant else { continue }
                let level = levelLabel(entry.level)
                let stamp = entry.date.formatted(formatter)
                matched.append("[\(stamp)] [\(level)] [\(entrySub)/\(entry.category)] \(entry.composedMessage)")
            }
            if matched.count > maxEntries {
                lines.append("… (\(matched.count - maxEntries) earlier entries omitted) …")
                matched = Array(matched.suffix(maxEntries))
            }
            if matched.isEmpty {
                lines.append("(No structured log entries recorded in this session.)")
            } else {
                lines.append(contentsOf: matched)
            }
        } catch {
            lines.append("(Could not read process log store: \(error.localizedDescription))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Prompts for a save location via `NSSavePanel` and writes the diagnostics log exclusively to the chosen URL.
    public static func exportLogs(bundle: Bundle = .main, subsystem: String? = nil) {
        let info = AppDiagnosticsInfo.current(bundle: bundle)
        let slug = info.appName.lowercased().replacingOccurrences(of: " ", with: "-")
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics Log"
        panel.message = "Save recent diagnostic logs to attach to a bug report. No archive document text or API keys are included."
        panel.nameFieldStringValue = "\(slug)-diagnostics-\(stamp).log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let targetSubsystem = subsystem ?? info.bundleIdentifier
        Task.detached(priority: .userInitiated) {
            let content = Self.collectRecentLogs(bundle: bundle, subsystem: targetSubsystem)
            let data = Data(content.utf8)
            do {
                try data.write(to: destination, options: .atomic)
                await MainActor.run {
                    Self.log.info("Exported diagnostics log (\(data.count, privacy: .public) bytes)")
                }
            } catch {
                await MainActor.run {
                    Self.log.error("Failed to export diagnostics log: \(error.localizedDescription, privacy: .public)")
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Could Not Export Logs"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private nonisolated static func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: "LOG"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .error: "ERROR"
        case .fault: "FAULT"
        @unknown default: "LOG"
        }
    }
}

/// Unified Help / Feedback / Diagnostics menu shared across Archive Reader, Archive Notes, and Archive Processor.
public struct DiagnosticsCommands: Commands {
    private let repositoryURL: String

    public init(repositoryURL: String = AppDiagnosticsInfo.defaultRepositoryURL) {
        self.repositoryURL = repositoryURL
    }

    public var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Report a Bug / Send Feedback…") {
                AppDiagnostics.openBugReport(repository: repositoryURL)
            }
            Divider()
            Button("Copy Diagnostics Info") {
                AppDiagnostics.copyDiagnosticsInfo()
            }
            Button("Export Logs…") {
                AppDiagnostics.exportLogs()
            }
        }
    }
}
