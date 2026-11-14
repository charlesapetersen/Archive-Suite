// swift-tools-version:5.9
// VisionOCRKit — Vision OCR's reading engine as a package (W42.int-s1, Stage 1 of
// execution-plans/integration/00-plan.md): recognition, the page-kind detector, the flattener and
// its compression, JBIG2, the searchable-PDF writer, the model runtime, the model downloads and the
// memory guard. Vision OCR's SwiftUI screens are in App/ and are not part of any target here.
//
// Swift 5 language mode, as Vision OCR's swiftc build compiled it; macOS 14, Archive Processor's minimum.
import PackageDescription

let package = Package(
    name: "VisionOCRKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VisionOCRKit", targets: ["VisionOCRKit"]),
        // The recognition helper: one more process for Vision to run in (Recogniser.helperName).
        .executable(name: "visionocr-recognise", targets: ["visionocr-recognise"]),
    ],
    targets: [
        .target(
            name: "VisionOCRKit",
            path: "Sources/VisionOCRKit",
            resources: [
                .copy("Resources/read-model.py"),
                .copy("Resources/mac-ocr-LICENSE"),
            ]
        ),
        .executableTarget(
            name: "visionocr-recognise",
            dependencies: ["VisionOCRKit"],
            path: "Helper"
        ),
        // Vision OCR's suite (Tests/main.swift, top-level checks), unchanged but for its
        // `@testable import`. Build it `-c release -Xswiftc -enable-testing`: `-O` is load-bearing
        // (run_tests.sh), and release builds are not testable without the flag.
        .executableTarget(
            name: "visionocr-checks",
            dependencies: ["VisionOCRKit"],
            path: "Tests",
            sources: ["main.swift"]
        ),
        // Tools/score-gate.swift (Tools/gate/main.swift links to it): the production pipeline from the
        // command line, which Tools/ux-regression.sh publishes its set through. Built as the checks are.
        .executableTarget(
            name: "visionocr-gate",
            dependencies: ["VisionOCRKit"],
            path: "Tools/gate"
        ),
        // Tools/pdf/main.swift: Vision OCR's searchable PDF of named files with its defaults, headless; the size
        // baseline Archive Processor's output is measured against (W42.int-s5). Built as the checks are.
        .executableTarget(
            name: "visionocr-pdf",
            dependencies: ["VisionOCRKit"],
            path: "Tools/pdf"
        ),
        // Runs visionocr-checks as `swift test` would see it: from the package root, with the
        // package's helper, and fails unless every check passed.
        .testTarget(
            name: "VisionOCRKitTests",
            dependencies: ["visionocr-checks", "visionocr-recognise"],
            path: "PackageTests/VisionOCRKitTests"
        ),
    ]
)
