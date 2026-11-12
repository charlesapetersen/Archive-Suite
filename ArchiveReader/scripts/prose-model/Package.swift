// swift-tools-version: 6.0
// W40.reader-prose-model's bench: the Reader's own CopyTextCleaner (a symlink into the app's sources) against
// line labels from the on-device Foundation Models model. Not part of any app; see README.md.
import PackageDescription
let package = Package(
    name: "ProseBench",
    platforms: [.macOS("27.0")],   // the image arm needs 27; the text arm alone runs on 26
    dependencies: [.package(path: "../../../packages/ArchiveCore")],
    targets: [
        .executableTarget(name: "prosebench", dependencies: [.product(name: "ArchiveCore", package: "ArchiveCore")],
                          path: "Sources/ProseBench",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
