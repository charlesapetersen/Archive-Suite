// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ArchiveCore",
    platforms: [.macOS(.v14)],
    products: [ .library(name: "ArchiveCore", targets: ["ArchiveCore"]) ],
    targets: [
        .target(name: "ArchiveCore"),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    ]
)
