import XCTest
import AppKit
import ArchiveCore

/// W48.appearance-* — the stored Appearance value, its default, and what each value sets on an app.
/// Uses a throwaway defaults suite, never the app's real domain.
final class AppAppearanceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "AppAppearanceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testTheDefaultIsSystem() {
        XCTAssertEqual(AppAppearance.defaultValue, .system)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
    }

    func testTheKeyIsTheOneEveryAppShares() {
        XCTAssertEqual(AppAppearance.defaultsKey, "archiveAppearance")
    }

    func testAStoredValueReadsBack() {
        for value in AppAppearance.allCases {
            defaults.set(value.rawValue, forKey: AppAppearance.defaultsKey)
            XCTAssertEqual(AppAppearance.stored(in: defaults), value)
        }
    }

    func testAnUnknownValueReadsAsSystem() {
        defaults.set("sepia", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
        defaults.set(3, forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
    }

    func testEachValueNamesItsAppearance() {
        XCTAssertNil(AppAppearance.system.appearanceName)
        XCTAssertEqual(AppAppearance.light.appearanceName, .aqua)
        XCTAssertEqual(AppAppearance.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppAppearance.allCases.map(\.title), ["System", "Light", "Dark"])
    }

    @MainActor
    func testApplySetsAndClearsTheAppAppearance() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        AppAppearance.dark.apply(to: app)
        XCTAssertEqual(app.appearance?.name, .darkAqua)
        AppAppearance.light.apply(to: app)
        XCTAssertEqual(app.appearance?.name, .aqua)
        AppAppearance.system.apply(to: app)
        XCTAssertNil(app.appearance)
    }
}
