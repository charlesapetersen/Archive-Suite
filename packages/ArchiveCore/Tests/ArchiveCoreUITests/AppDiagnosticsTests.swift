import ArchiveCoreUI
import Foundation
import Testing

@Suite("AppDiagnostics")
struct AppDiagnosticsTests {

    @Test
    func summaryTextIncludesAllBuildFields() {
        let info = AppDiagnosticsInfo(
            appName: "Archive Reader",
            bundleIdentifier: "com.archivereader.app",
            version: "1.0",
            build: "42",
            gitSHA: "abc1234",
            macOSVersion: "Version 15.2 (Build 24C101)",
            hardwareModel: "Mac15,6"
        )
        let text = info.summaryText
        #expect(text.contains("Archive Reader (com.archivereader.app)"))
        #expect(text.contains("Version: 1.0 (42)"))
        #expect(text.contains("Commit: abc1234"))
        #expect(text.contains("macOS: Version 15.2 (Build 24C101)"))
        #expect(text.contains("Hardware: Mac15,6"))
    }

    @Test
    func bugReportURLPrefillsTitleAndDiagnosticsBody() throws {
        let info = AppDiagnosticsInfo(
            appName: "Archive Notes",
            bundleIdentifier: "com.archivenotes.app",
            version: "1.0",
            build: "7",
            gitSHA: "deadbeef",
            macOSVersion: "Version 15.1",
            hardwareModel: "Mac15,6"
        )
        let url = try #require(info.bugReportURL())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(components.path.hasSuffix("/issues/new"))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["title"] == "[Archive Notes] ")
        let body = try #require(query["body"])
        #expect(body.contains("Version: 1.0 (7)"))
        #expect(body.contains("Commit: deadbeef"))
        #expect(body.contains("Export Logs"))
    }

    @Test
    func collectRecentLogsIncludesDiagnosticsHeader() {
        let output = AppDiagnostics.collectRecentLogs(subsystem: "com.archivesuite.test")
        #expect(output.contains("=== Archive Suite Diagnostics Log ==="))
        #expect(output.contains("Version:"))
        #expect(output.contains("macOS:"))
    }
}
