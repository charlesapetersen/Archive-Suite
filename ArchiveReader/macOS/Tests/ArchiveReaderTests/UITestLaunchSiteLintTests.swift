// UITestLaunchSiteLintTests.swift — no UITest may construct its app-under-test with a bare initializer.
//
// W26.vmuitest-blind. `XCUIApplication()` inherits whatever window state the previous run left on disk.
// When that state says "no windows open", SwiftUI never opens `Window("Archive Reader")`, the app comes
// up with a menu bar and nothing else, and EVERY window assertion in the UITest bundle fails with a
// message that reads like a product regression. The seam that prevents it is
// `XCUIApplication.archiveUITestApp()` (see `Tests/ArchiveReaderUITests/UITestLaunch.swift`), and the
// seam only works if every launch site goes through it.
//
// `UITestLaunchTests` (in the UITest bundle) guards the ARGUMENTS the factory seeds. This guards the
// CALL SITES, which is the half that can rot silently: a new UITest file written with a bare
// `XCUIApplication()` passes on a clean guest and fails only once some earlier run has poisoned the
// state — i.e. it fails later, elsewhere, and looks like someone else's bug.
//
// It lives in the UNIT bundle on purpose. This is the app-hosted suite that runs on the host, where
// `#filePath` is a real `/Users/…` path the Debug temporary-exception entitlement can read. The UITest
// runner in the VM builds from the `/Volumes/My Shared Files/repo` mount, which its sandbox cannot read —
// a lint there would have to skip in exactly the lane it is protecting.

import XCTest

final class UITestLaunchSiteLintTests: XCTestCase {

    /// `…/Tests/ArchiveReaderUITests`, derived from this file's own location.
    private static var uiTestSourceDir: URL {
        URL(fileURLWithPath: #filePath)                 // …/Tests/ArchiveReaderTests/<this file>
            .deletingLastPathComponent()                 // …/Tests/ArchiveReaderTests
            .deletingLastPathComponent()                 // …/Tests
            .appendingPathComponent("ArchiveReaderUITests", isDirectory: true)
    }

    /// The file that is ALLOWED to say `XCUIApplication()` — it is the factory.
    private static let factoryFile = "UITestLaunch.swift"

    private func uiTestSources() throws -> [URL] {
        let dir = Self.uiTestSourceDir
        // A build from a mounted repo (the VM) cannot read its own sources from a sandboxed test host.
        // Skip on that specific, checkable condition — never on a read error, which would let a genuine
        // regression pass as "unreadable".
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: dir.path),
                          "UITest sources not readable at \(dir.path) — this lint only runs on a host "
                          + "checkout, not on a build from the /Volumes mount inside the GUI VM")
        let all = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// The lint is only meaningful if it actually found the sources it claims to police.
    func testTheLintCanSeeTheUITestSources() throws {
        let files = try uiTestSources()
        XCTAssertGreaterThanOrEqual(files.count, 5,
                                    "expected the ArchiveReaderUITests sources, found \(files.count) at "
                                    + Self.uiTestSourceDir.path)
        XCTAssertTrue(files.contains { $0.lastPathComponent == Self.factoryFile },
                      "\(Self.factoryFile) is the seam this lint exists for; it is missing")
    }

    /// THE detector, factored out so the self-test below exercises the real thing rather than an
    /// approximation of it. One definition, two callers — a matcher the tests re-implement is a matcher
    /// whose bugs the tests cannot see.
    ///
    /// Comments are stripped BEFORE looking, rather than skipping only lines that START with `//`: the
    /// sanctioned call sites carry a TRAILING comment naming the thing they no longer do —
    /// `app = .archiveUITestApp()   // never a bare XCUIApplication()` — so a whole-line check flags
    /// exactly the code this lint exists to bless. (Found the first time it ran: the fix's own comment
    /// failed the fix's own lint.) Splitting on `//` is naive about `//` inside a string literal, which
    /// can only ever cause a MISS, never a false accusation — the safe direction for a lint like this.
    static func isBareConstruction(_ line: some StringProtocol) -> Bool {
        // Only the CONSTRUCTION spelling. `XCUIApplication.archiveUITestApp()`, a type annotation, and
        // `XCUIApplication.self` all lack the `()` and are untouched.
        (line.components(separatedBy: "//").first ?? "").contains("XCUIApplication()")
    }

    /// No bare `XCUIApplication()` outside the factory.
    func testNoUITestConstructsTheAppWithABareInitializer() throws {
        var offenders: [String] = []
        for file in try uiTestSources() where file.lastPathComponent != Self.factoryFile {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.isBareConstruction(line) {
                offenders.append("\(file.lastPathComponent):\(i + 1): "
                                 + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a UITest constructed its app-under-test with a bare XCUIApplication(), which "
                      + "inherits the previous run's window state (W26.vmuitest-blind). Use "
                      + "XCUIApplication.archiveUITestApp():\n" + offenders.joined(separator: "\n"))
    }

    /// The lint must be able to FAIL. It caught nothing above only because the tree is clean, so prove the
    /// detector fires against the exact text it is looking for — otherwise a broken matcher reads as green.
    func testTheLintDetectsAPlantedBareInitializer() {
        XCTAssertTrue(Self.isBareConstruction("let app = XCUIApplication()"),
                      "the matcher must fire on a bare initializer")
        XCTAssertTrue(Self.isBareConstruction("        app = XCUIApplication()  // with a comment"),
                      "a trailing comment must not hide a real violation")
    }

    /// …and must NOT fire on the spellings the fix itself uses, or the lint forbids its own fix. The
    /// second case is the one that actually bit: the sanctioned call site mentions the banned spelling
    /// in its trailing comment.
    func testTheLintDoesNotFireOnTheSanctionedSpellings() {
        XCTAssertFalse(Self.isBareConstruction("let app = XCUIApplication.archiveUITestApp()"),
                       "archiveUITestApp() must not be mistaken for a bare initializer")
        XCTAssertFalse(Self.isBareConstruction(
            "        app = .archiveUITestApp()   // never a bare XCUIApplication() — see UITestLaunch"),
                       "a comment ABOUT the banned spelling, on a sanctioned line, is not a violation")
        XCTAssertFalse(Self.isBareConstruction("// let app = XCUIApplication()"),
                       "a fully commented-out line is prose, not a call site")
        XCTAssertFalse(Self.isBareConstruction("    private var app: XCUIApplication!"),
                       "a type annotation is not a construction")
    }
}
