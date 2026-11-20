import Foundation
import PDFKit
func dataless(_ p: String) -> Bool { var s = stat(); stat(p, &s); return (s.st_flags & UInt32(SF_DATALESS)) != 0 }
let p = CommandLine.arguments[1]; let guarded = CommandLine.arguments[2] == "guarded"
// The engine launches this shell with materialization OFF process-wide; a Finder-launched Notes has the default (on). Match that.
print("set process ON:", setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON), "now:", getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS))
print("before: dataless=\(dataless(p))")
if guarded { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) }
let t = Date()
// Same calls as ReaderPreviewPopover.showPDF (Views/ReaderPreviewPopover.swift:228-234).
let doc = PDFDocument(url: URL(fileURLWithPath: p))
let page = doc?.page(at: 0)
print("mode=\(guarded ? "guarded" : "unguarded (popover)") doc=\(doc != nil) pages=\(doc?.pageCount ?? -1) page0=\(page != nil) secs=\(String(format: "%.2f", Date().timeIntervalSince(t)))")
print("after: dataless=\(dataless(p))")
