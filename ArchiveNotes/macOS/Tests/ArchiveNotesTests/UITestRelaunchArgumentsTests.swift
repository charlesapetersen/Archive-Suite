import Testing
import Foundation
@testable import ArchiveNotes

// W49.notes-relaunch-args-flake — a UI test's arguments survive Restart and Switch's relaunch, which a sandboxed
// app starts with none: saved by a harness launch only, taken once by a bare launch within the age limit, and read
// back through the argument domain. A scratch defaults suite for the handover; the argument-domain check restores it.

@Suite("UI test relaunch arguments")
struct UITestRelaunchArgumentsTests {
    private static let harness = ["-ApplePersistenceIgnoreState", "YES", "-ANUITestStorePath", "/tmp/AN-Fixture",
                                  "-ANUITestStoreBookmarkSuite", "scratch.suite"]

    private func scratch() -> (UserDefaults, String) {
        let name = "com.archivenotes.tests.relaunch-args.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func aHarnessLaunchHandsItsArgumentsToTheNextBareLaunch() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        UITestRelaunchArguments.saveForRelaunch(Self.harness, isHarnessLaunch: true, defaults: defaults, now: now)
        #expect(UITestRelaunchArguments.take(own: [], defaults: defaults, now: now.addingTimeInterval(3)) == Self.harness)
        #expect(defaults.object(forKey: UITestRelaunchArguments.key) == nil, "taken once")
        #expect(UITestRelaunchArguments.take(own: [], defaults: defaults, now: now) == nil)
    }

    @Test func aNormalLaunchSavesNothing() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        UITestRelaunchArguments.saveForRelaunch(["-SomeSetting", "1"], isHarnessLaunch: false, defaults: defaults)
        #expect(defaults.object(forKey: UITestRelaunchArguments.key) == nil)
    }

    @Test func aLeftOverHandoverIsDroppedNotTaken() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let then = Date()
        UITestRelaunchArguments.saveForRelaunch(Self.harness, isHarnessLaunch: true, defaults: defaults, now: then)
        let late = then.addingTimeInterval(UITestRelaunchArguments.maxAge + 1)
        #expect(UITestRelaunchArguments.take(own: [], defaults: defaults, now: late) == nil)
        #expect(defaults.object(forKey: UITestRelaunchArguments.key) == nil, "removed, so a later launch never takes it")
    }

    @Test func aLaunchWithArgumentsOfItsOwnKeepsThem() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        UITestRelaunchArguments.saveForRelaunch(Self.harness, isHarnessLaunch: true, defaults: defaults)
        #expect(UITestRelaunchArguments.take(own: ["-ANUITestStorePath", "/tmp/other"], defaults: defaults, now: Date()) == nil)
        #expect(defaults.object(forKey: UITestRelaunchArguments.key) == nil)
    }

    @Test func argumentsReadAsACommandLine() {
        let domain = UITestRelaunchArguments.argumentDomain(["stray", "-a", "1", "-b", "two words", "-dangling"])
        #expect(domain.count == 2)
        #expect(domain["a"] as? String == "1")
        #expect(domain["b"] as? String == "two words")
    }

    @Test func installedArgumentsReadAsPassedOnes() {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let key = "ANUITestRelaunchArgumentsProbe\(UUID().uuidString)"
        defaults.set("persisted", forKey: key)
        defer { defaults.removeObject(forKey: key) }
        UITestRelaunchArguments.install(["-\(key)", "handed over"], in: defaults)
        #expect(defaults.string(forKey: key) == "handed over", "the argument domain wins over a stored value")
    }
}
