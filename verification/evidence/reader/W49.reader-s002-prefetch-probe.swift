import AppKit
import Foundation
// W49.reader-s002-reproduce: the shipped PreviewImagePrefetcher, run on a cloud placeholder (SF_DATALESS).
// Historical build, from the pre-fix reproduction revision (92568b5f):
// swiftc -parse-as-library -o /tmp/s002prefetch \
//   ArchiveReader/macOS/Sources/ArchiveReader/Views/PreviewImagePrefetcher.swift verification/evidence/reader/W49.reader-s002-prefetch-probe.swift
// Run: /tmp/s002prefetch <placeholder.pdf>
// Current regression: PreviewImagePrefetchTests.testCloudPlaceholderStaysRemoteUntilDownloadAndShow.
// The call is the one the browser list makes on every selection change
// (PreviewImagePrefetchModifier: `PreviewImagePrefetcher.shared.prefetch(paths: model.previewPrefetchPaths(...))`),
// with or without the preview sheet shown.
import SwiftUI
// Stand-in for the app's model, which the file's SwiftUI modifier names; the probe calls the prefetcher directly.
@MainActor final class NavigationModel: ObservableObject {
    @Published var selection = Set<Int>()
    @Published var showingPreview = false
    func previewPrefetchPaths(neighbours: Bool) -> [String] { [] }
}

func dataless(_ p: String) -> Bool { var s = stat(); stat(p, &s); return (s.st_flags & UInt32(SF_DATALESS)) != 0 }

@main
struct Probe {
    @MainActor static func main() {
        let p = CommandLine.arguments[1]
        // The engine launches this shell with materialization OFF process-wide; a Finder-launched Reader has the default (on).
        print("set process ON:", setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON))
        print("before: dataless=\(dataless(p)) stamp.isDataless=\(PreviewImagePrefetcher.FileStamp.of(p)?.isDataless ?? false)")
        let t = Date()
        PreviewImagePrefetcher.shared.prefetch(paths: [p])   // what selecting the row does
        while PreviewImagePrefetcher.shared.image(path: p, pageIndex: 0) == nil, Date().timeIntervalSince(t) < 60 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            // Once the file is downloaded its stamp changes, so look the bitmap up by the new stamp too.
            if !dataless(p), PreviewImagePrefetcher.shared.image(path: p, pageIndex: 0) == nil {
                PreviewImagePrefetcher.shared.prefetch(paths: [p])
            }
        }
        let image = PreviewImagePrefetcher.shared.image(path: p, pageIndex: 0)
        print("bitmap=\(image.map { "\($0.image.width)x\($0.image.height)" } ?? "none") secs=\(String(format: "%.2f", Date().timeIntervalSince(t)))")
        print("after: dataless=\(dataless(p))")
        if !dataless(p) {
            do { try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: p)); print("evicted") } catch { print("evict failed: \(error)") }
        }
    }
}
