import Foundation
import ImageIO
import PDFKit

// vision-page-kind <list.tsv>: W41.bench-vision-kind. Vision OCR's page sorter
// (`Recogniser.pageKind`: newspaper, photograph, handwriting, other) on each page of a list,
// a label that needs no model and no paid call. Each row is `id <TAB> file`, a JPEG/PNG page
// image or a PDF (its first page). Built against vision-ocr's `Sources/` (run.sh), never edited.
//
// As the app judges a page, with two documented differences: an image is wrapped as
// `makeSearchablePDF` wraps it, and its camera tags are read from the file
// (`Flattener.cameraExposed`), then `Flattener.photographed` judges the wrapped page and
// `Flattener.mosaic` whether it is a paste-up; Vision reads the page as the no-rebuild route
// does (`Recogniser.render`, `recognisePage`, `fittedToGutters`, as Tools/score-page-kind and
// score-page-hand take it); `isHandwritten` judges `handSignals` on that render, not on the
// rebuilt page's `.ink.jpg` the app keeps; and handwriting is always looked for, as if
// `handwritingApart` were on. Prints one row a page; reads only, and writes nothing but stdout
// and a scratch directory it removes. Exit 2 when the list is unreadable or empty.

Prefs.register(migrate: false)
let settings = Prefs.Snapshot.current()
guard CommandLine.arguments.count == 2,
      let list = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: vision-page-kind <list.tsv>\n".utf8)); exit(2)
}
let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("vision-page-kind-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
print(["id", "vision_kind", "paste_up", "photo", "camera", "hand", "lines", "wide_w"].joined(separator: "\t"))
var measured = 0, unread = 0
for row in list.split(whereSeparator: \.isNewline) where !row.hasPrefix("#") {
    let f = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 2 else { continue }
    measured += 1
    autoreleasepool {
        var url = URL(fileURLWithPath: f[1]), camera = false
        if url.pathExtension.lowercased() != "pdf" {
            camera = Flattener.cameraExposed(CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
            guard let wrapped = Flattener.wrapImage(url, into: scratch) else {
                print("\(f[0])\tunread"); unread += 1; return
            }
            url = wrapped
        }
        defer { if url.deletingLastPathComponent() == scratch { try? FileManager.default.removeItem(at: url) } }
        guard let page = PDFDocument(url: url)?.page(at: 0),
              let image = Recogniser.render(page, settings: settings),
              let read = try? Recogniser.recognisePage(image, settings: settings) else {
            print("\(f[0])\tunread"); unread += 1; return
        }
        let lines = Recogniser.fittedToGutters(read, of: image)
        let pasteUp = Flattener.mosaic(of: page) != nil
        let photo = Flattener.photographed(page, box: Flattener.fullBox(of: page), cameraExposed: camera)
        var hand = false
        let kind = Recogniser.pageKind(of: lines, pasteUp: pasteUp, photograph: photo, handwritten: {
            hand = Recogniser.isHandwritten(Recogniser.handSignals(of: lines, image: image)); return hand
        })
        let shape = Recogniser.pageShape(of: lines)
        print([f[0], kind.rawValue, pasteUp ? "1" : "0", photo ? "1" : "0", camera ? "1" : "0",
               hand ? "1" : "0", "\(shape.lines)", String(format: "%.3f", shape.wideWidth)]
              .joined(separator: "\t"))
        fflush(stdout)
    }
}
FileHandle.standardError.write(Data("\(measured) page(s), \(unread) unread\n".utf8))
try? FileManager.default.removeItem(at: scratch)
exit(measured == 0 ? 2 : 0)
