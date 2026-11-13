import Foundation
import XCTest

/// Vision OCR's suite as a test target (W42.int-s1). The checks stay top-level code in
/// Tests/main.swift — about 25,000 lines whose globals the checks share — so this runs the
/// `visionocr-checks` product the way run_tests.sh runs its swiftc build: from the package root
/// (the checks read App/ and Sources/ by relative path), with the package's own helper and the
/// plate fixtures compiled from Tools/make-plate-fixtures.swift.
///
/// Run it optimized, under the heavy lock (the suite runs Vision, the Flattener and processes):
///   python3 ops/autonomous/heavy-run.py run -- \
///     swift test -c release -Xswiftc -enable-testing --package-path packages/VisionOCRKit
/// VISIONOCR_TIER and VISIONOCR_SECTIONS pass through for a partial run, as with run_tests.sh.
final class ChecksTests: XCTestCase {
    func testVisionOCRSuite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let checks = products.appendingPathComponent("visionocr-checks")
        let helper = products.appendingPathComponent("visionocr-recognise")
        for tool in [checks, helper] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path), "missing \(tool.path)")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionocrkit-checks-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // As run_tests.sh's _plates: the tool is copied to main.swift so swiftc treats it as top-level code.
        let platesSource = scratch.appendingPathComponent("main.swift")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Tools/make-plate-fixtures.swift"),
                                         to: platesSource)
        let plates = scratch.appendingPathComponent("make-plate-fixtures")
        let arch = machineArchitecture()
        XCTAssertEqual(try run("/usr/bin/xcrun", ["swiftc", "-target", "\(arch)-apple-macos14.0",
                                                  "-o", plates.path, platesSource.path], in: root), 0,
                       "Tools/make-plate-fixtures.swift did not compile")

        var environment = ProcessInfo.processInfo.environment
        environment["VISIONOCR_HELPER"] = helper.path
        environment["VISIONOCR_PLATE_FIXTURES"] = plates.path
        environment["VISIONOCR_SECTION_TIMINGS"] = scratch.appendingPathComponent("sections.tsv").path
        let log = scratch.appendingPathComponent("checks.log")
        let status = try run(checks.path, [], in: root, environment: environment, log: log)
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let failures = output.components(separatedBy: "\n").filter { $0.hasPrefix("  FAIL") }
        let summary = output.components(separatedBy: "\n").last { $0.hasSuffix(" passed") } ?? "no summary"
        print("visionocr-checks: \(summary)")
        XCTAssertEqual(status, 0, "visionocr-checks: \(summary)\n" + failures.joined(separator: "\n"))
    }

    private func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String], in directory: URL,
                     environment: [String: String]? = nil, log: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
