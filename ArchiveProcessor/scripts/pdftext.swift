// Extract the selectable text layer from a PDF (the Processor writes a 2-page PDF: image + OCR text).
// Usage: pdftext <file.pdf>   → prints the text to stdout.
import Foundation
import PDFKit
guard CommandLine.arguments.count > 1,
      let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else { exit(2) }
var out = ""
for i in 0..<doc.pageCount { out += (doc.page(at: i)?.string ?? "") + "\n" }
print(out)
