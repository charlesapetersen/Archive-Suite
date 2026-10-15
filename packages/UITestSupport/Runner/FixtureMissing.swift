import Foundation

/// Thrown from a UI suite's setup when its GUI fixture is absent. A throw from setup is a test FAILURE.
///
/// W40.a4: the suites used to `XCTSkipUnless` the fixture, so a lane whose fixture build broke reported
/// green having run nothing. The VM runner rebuilds the fixture before every run, so absence is a fault.
public struct FixtureMissing: LocalizedError {
    public let path: String
    public let builder: String

    public init(path: String, builder: String) {
        self.path = path
        self.builder = builder
    }

    public var errorDescription: String? {
        "GUI fixture not found at \(path) — run \(builder) first. A missing fixture fails the suite rather "
            + "than skipping it, so a broken fixture build cannot pass as a green run."
    }
}
