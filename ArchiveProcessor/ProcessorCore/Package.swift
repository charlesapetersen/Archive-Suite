// swift-tools-version: 6.0
// ProcessorCore — Archive Processor's pure logic, testable without launching the app (W49.proc-unit-test-target).
//
// What goes here: rules that take values and return values, with no AppKit, Keychain, network, file writes or
// app state. The app links it statically like ArchiveCore and VisionOCRKit, and the ArchiveProcessorTests bundle
// (macOS/Tests/ArchiveProcessorTests, scheme ArchiveProcessorUnit) tests it with XCTest, not app-hosted, so the
// app's signing stays as it is (no debug dylib, no debug entitlement). New non-UI tests go there instead of into
// a new `#if DEBUG` driver inside the app; an existing driver moves here when its file is next touched.
import PackageDescription

let package = Package(
    name: "ProcessorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProcessorCore", targets: ["ProcessorCore"]),
    ],
    targets: [
        .target(name: "ProcessorCore"),
    ]
)
