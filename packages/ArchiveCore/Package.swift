// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ArchiveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        // The suite's shared AppKit/SwiftUI controls (the tag-entry field). Kept out of ArchiveCore,
        // which stays UI-free so the Processor and every non-UI caller link no app framework (W9.c3).
        .library(name: "ArchiveCoreUI", targets: ["ArchiveCoreUI"]),
    ],
    targets: [
        .target(name: "ArchiveCore"),
        .target(name: "ArchiveCoreUI", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    ]
)
