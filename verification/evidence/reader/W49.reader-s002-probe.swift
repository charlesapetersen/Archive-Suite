import Foundation
import PDFKit
// W49.reader-s002-reproduce: the Reader viewer's PDF opens, run on a cloud placeholder (SF_DATALESS).
// Usage: swift W49.reader-s002-probe.swift <placeholder.pdf> <viewer|neighbour|prefetch|guarded>
func dataless(_ p: String) -> Bool { var s = stat(); stat(p, &s); return (s.st_flags & UInt32(SF_DATALESS)) != 0 }
let p = CommandLine.arguments[1], mode = CommandLine.arguments[2], url = URL(fileURLWithPath: p)
// The engine launches this shell with materialization OFF process-wide; a Finder-launched Reader has the default (on). Match that.
print("set process ON:", setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON), "now:", getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS))
print("before: dataless=\(dataless(p))")
if mode == "guarded" { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) }
let t = Date()
var pages = -1
switch mode {
case "neighbour":
    // DocumentViewerModel.openDocument (prepareNeighbours): runs for the files either side of the one opened.
    if let doc = PDFDocument(url: url) { pages = doc.pageCount; for i in 0..<min(doc.pageCount, 8) { _ = doc.page(at: i)?.string } }
case "prefetch":
    // PreviewImagePrefetcher.render: opens the file afresh and draws page 0 into a bitmap.
    if let doc = PDFDocument(url: url), let page = doc.page(at: 0),
       let ctx = CGContext(data: nil, width: 200, height: 260, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        pages = doc.pageCount; page.draw(with: .cropBox, to: ctx)
    }
default:
    // DocumentViewerModel.loadDocument (viewer and PreviewSheet), and the guarded control.
    if let doc = PDFDocument(url: url) { pages = doc.pageCount; _ = doc.page(at: 0) }
}
print("mode=\(mode) pages=\(pages) secs=\(String(format: "%.2f", Date().timeIntervalSince(t)))")
print("after: dataless=\(dataless(p))")
if !dataless(p) {
    do { try FileManager.default.evictUbiquitousItem(at: url); print("evicted") } catch { print("evict failed: \(error)") }
}
