import XCTest
import ArchiveCore

/// W48.appearance-* — the stored Appearance value and its default. Applying it is AppKit and lives in each app
/// (Processor: `Models/AppAppearance+AppKit.swift`, proven by `AppearanceSettingUITests`).
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

    func testEachValueHasItsPickerTitle() {
        XCTAssertEqual(AppAppearance.allCases.map(\.title), ["System", "Light", "Dark"])
    }
}
