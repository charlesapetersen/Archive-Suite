import Foundation
import PDFKit
// Stand-in for ArchiveCore's guard, copied from CorpusWalker.withDatalessMaterializationDisabled.
enum CorpusWalker {
    static func withDatalessMaterializationDisabled<T>(_ body: () throws -> T) rethrows -> T {
        let prior = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, prior >= 0 ? prior : IOPOL_DEFAULT) }
        return try body()
    }
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
// Match a Finder-launched Notes: materialisation on process-wide (the engine starts with it off).
print("set process ON:", setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON))
print("before: dataless=\(PreviewCloudFile.isDataless(url))")
var t = Date()
switch PreviewCloudFile.opening(url) {
case .show(let d): print("opening=show pages=\(d.pageCount)")
case .inCloud: print("opening=inCloud")
case .unreadable: print("opening=unreadable")
}
print(String(format: "secs=%.2f", Date().timeIntervalSince(t)), "after opening: dataless=\(PreviewCloudFile.isDataless(url))")
t = Date()
print("download (Download and Show) ->", PreviewCloudFile.download(url), String(format: "secs=%.2f", Date().timeIntervalSince(t)))
switch PreviewCloudFile.opening(url) {
case .show(let d): print("re-opening=show pages=\(d.pageCount)")
case .inCloud: print("re-opening=inCloud")
case .unreadable: print("re-opening=unreadable")
}
try FileManager.default.evictUbiquitousItem(at: url)
sleep(2)
print("after evict: dataless=\(PreviewCloudFile.isDataless(url))")
