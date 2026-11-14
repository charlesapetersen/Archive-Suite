// visionocr-pdf — Vision OCR 1.16.0's searchable PDF of each file named, made headless with the app's own
// defaults (searchable PDF, rebuilt images, JBIG2): the size Archive Processor's output is measured against
// (W42.int-s5, Stage 5 of execution-plans/integration/00-plan.md). No window, no network.
//
//   visionocr-pdf <out-dir> <file>...
//
// Prints one line a file: bytes, seconds, outcome and the input's name. The defaults are this tool's own domain,
// never Vision OCR's, so the owner's settings are neither read nor changed.

@testable import VisionOCRKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: visionocr-pdf <out-dir> <file>...\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[0], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

Prefs.register(migrate: false)
let d = Prefs.store
d.set(Prefs.Mode.searchablePDF.rawValue, forKey: Prefs.mode)
d.set(true, forKey: Prefs.rebuildImages)
d.set(true, forKey: Prefs.useJBIG2)
d.set(false, forKey: Prefs.warnDigitalText)

var failed = false
for path in args.dropFirst() {
    let file = URL(fileURLWithPath: path)
    let out = outDir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".ocr.pdf")
    var outcome: Runner.Result.Outcome?
    let start = Date()
    OCRModel.makeSearchablePDF(file: file, output: out, rebuild: true, rebuildMode: .auto, password: nil,
                               control: RunControl(), progress: { _, _ in }, report: { o, _ in outcome = o })
    let seconds = Date().timeIntervalSince(start)
    let bytes = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.intValue ?? -1
    if outcome != .succeeded { failed = true }
    print("\(bytes)\t\(String(format: "%.1f", seconds))\t\(outcome.map { "\($0)" } ?? "none")\t\(file.lastPathComponent)")
}
exit(failed ? 1 : 0)
