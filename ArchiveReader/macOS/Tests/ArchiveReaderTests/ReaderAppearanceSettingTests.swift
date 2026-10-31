import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// W48.appearance-reader — the Reader side of the Appearance setting: its stored value and default in a scratch
/// defaults suite, the UI-test reset that keeps one test's choice out of the next, `apply`, the live follow that
/// `ArchiveReaderApp.init` starts, and the Reader's own colour (`ReaderColors.warningInk`), which has to resolve
/// per appearance. Ledger row R-48.
@MainActor
final class ReaderAppearanceSettingTests: XCTestCase {

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "reader-appearance-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testNothingStoredReadsAsSystemAndAStoredChoiceReadsBack() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
        defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .dark)
        defaults.set(AppAppearance.light.rawValue, forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .light)
        defaults.set("sepia", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system, "an unknown value reads as System")
    }

    func testAFixtureUITestLaunchStartsFromSystemUnlessItAsksToKeepTheChoice() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let key = AppAppearance.defaultsKey

        defaults.set("dark", forKey: key)
        ReaderAppearanceUITestDefaults.clearStoredChoiceIfUITest(arguments: ["ArchiveReader"], defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: key), "dark", "a real launch never loses the owner's choice")

        ReaderAppearanceUITestDefaults.clearStoredChoiceIfUITest(
            arguments: ["ArchiveReader", "-ARUITestRootPath", "/tmp/x", "-ARUITestKeepAppearance", "YES"],
            defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: key), "dark", "the relaunch check keeps the choice")

        ReaderAppearanceUITestDefaults.clearStoredChoiceIfUITest(
            arguments: ["ArchiveReader", "-ARUITestRootPath", "/tmp/x"], defaults: defaults)
        XCTAssertNil(defaults.string(forKey: key))
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
    }

    func testApplySetsTheApplicationAppearance() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        AppAppearance.dark.apply(to: app)
        XCTAssertEqual(app.appearance?.name, .darkAqua)
        AppAppearance.light.apply(to: app)
        XCTAssertEqual(app.appearance?.name, .aqua)
        AppAppearance.system.apply(to: app)
        XCTAssertNil(app.appearance, "System leaves NSApp.appearance nil, so the app follows macOS")
    }

    /// `ArchiveReaderApp.init` (which also runs in this unit-test host) calls `AppAppearance.follow()` on the
    /// standard defaults; a write to the key — what the Settings picker's `@AppStorage` does — must reach
    /// `NSApp.appearance` without a relaunch.
    func testAChangeToTheStoredChoiceIsAppliedLive() {
        let defaults = UserDefaults.standard
        let key = AppAppearance.defaultsKey
        let saved = defaults.object(forKey: key)
        let before = NSApplication.shared.appearance
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            NSApplication.shared.appearance = before
        }
        defaults.set(AppAppearance.dark.rawValue, forKey: key)
        XCTAssertTrue(waitFor { NSApplication.shared.appearance?.name == .darkAqua }, "Dark should apply live")
        defaults.set(AppAppearance.light.rawValue, forKey: key)
        XCTAssertTrue(waitFor { NSApplication.shared.appearance?.name == .aqua }, "Light should apply live")
        defaults.set(AppAppearance.system.rawValue, forKey: key)
        XCTAssertTrue(waitFor { NSApplication.shared.appearance == nil }, "System should clear it live")
    }

    func testTheWarningInkResolvesInTheAppearanceItIsShownIn() throws {
        var resolved: [NSAppearance.Name: NSColor] = [:]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                resolved[name] = ReaderColors.warningInk.usingColorSpace(.sRGB)
            }
        }
        let light = try XCTUnwrap(resolved[.aqua]), dark = try XCTUnwrap(resolved[.darkAqua])
        XCTAssertLessThan(light.redComponent, 0.6, "Light: the deep amber")
        XCTAssertGreaterThan(dark.redComponent, 0.9, "Dark: the pale orange")
    }

    private func waitFor(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
