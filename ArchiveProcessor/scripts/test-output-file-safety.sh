#!/bin/bash
# Key-free standalone regression test for OutputFileSafety. Uses only a fresh temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/files"

cat > "$work/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let original = root.appendingPathComponent("Original.PDF")
let alias = root.appendingPathComponent("original.pdf")
let distinct = root.appendingPathComponent("generated.pdf")
let symlink = root.appendingPathComponent("linked.pdf")
let sourceJSON = root.appendingPathComponent("Original.json")
let generatedJSON = root.appendingPathComponent("generated.json")
let occupiedPDF = root.appendingPathComponent("report.pdf")
let occupiedPDF2 = root.appendingPathComponent("report (2).pdf")

try Data("original".utf8).write(to: original)
try Data("generated".utf8).write(to: distinct)
try Data("source metadata".utf8).write(to: sourceJSON)
try Data("generated metadata".utf8).write(to: generatedJSON)
try Data("old report".utf8).write(to: occupiedPDF)
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)

func check(_ label: String, _ condition: Bool) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
        exit(1)
    }
    print("PASS: \(label)")
}

check("identical URL is the same file", OutputFileSafety.isSameFile(original, original))
check("case-only alias is preserved conservatively", OutputFileSafety.isSameFile(original, alias))
check("symlink alias is the same file", OutputFileSafety.isSameFile(original, symlink))
check("generated output is distinct", !OutputFileSafety.isSameFile(original, distinct))

try OutputFileSafety.removeGeneratedOutput(original, for: original)
check("source-as-output PDF is preserved", FileManager.default.fileExists(atPath: original.path))
check("source-as-output JSON is preserved", FileManager.default.fileExists(atPath: sourceJSON.path))

try OutputFileSafety.removeGeneratedOutput(distinct, for: original)
check("distinct generated PDF is removed", !FileManager.default.fileExists(atPath: distinct.path))
check("unproven same-basename JSON is preserved", FileManager.default.fileExists(atPath: generatedJSON.path))

var reserved = Set<String>()
let uniquePDF = OutputFileSafety.reserveUniqueDestination(preferred: occupiedPDF, reservedPaths: &reserved)
check("existing destination receives a numbered name", uniquePDF == occupiedPDF2)
let nextPDF = OutputFileSafety.reserveUniqueDestination(preferred: occupiedPDF, reservedPaths: &reserved)
check("reserved destination is not reused", nextPDF.lastPathComponent == "report (3).pdf")

var imageReservations = Set<String>()
let reusedSource = OutputFileSafety.reserveUniqueDestination(
    preferred: original, allowedExisting: original, reservedPaths: &imageReservations)
check("intentional source-as-image destination is reused", reusedSource == original)

let txSource1 = root.appendingPathComponent("tx-1.bin")
let txSource2 = root.appendingPathComponent("tx-2.bin")
let txDest1 = root.appendingPathComponent("filed/tx-1.bin")
let txDest2 = root.appendingPathComponent("filed/tx-2.bin")
try Data("one".utf8).write(to: txSource1)
try Data("two".utf8).write(to: txSource2)
var copyCount = 0
do {
    try OutputFileSafety.relocateArtifactSet([
        .init(source: txSource1, destination: txDest1),
        .init(source: txSource2, destination: txDest2),
    ], copyItem: { source, destination in
        copyCount += 1
        if copyCount == 2 {
            // Model a filesystem failure that leaves a partial destination behind.
            try Data("partial".utf8).write(to: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    })
    check("injected partial-copy failure throws", false)
} catch {
    check("partial-copy rollback preserves every source",
          FileManager.default.fileExists(atPath: txSource1.path)
          && FileManager.default.fileExists(atPath: txSource2.path))
check("partial-copy rollback removes created destinations",
      !FileManager.default.fileExists(atPath: txDest1.path)
      && !FileManager.default.fileExists(atPath: txDest2.path))
}

// Simulate another actor creating a final destination after preflight while staging is in progress.
do {
    try OutputFileSafety.relocateArtifactSet([
        .init(source: txSource1, destination: txDest1),
        .init(source: txSource2, destination: txDest2),
    ], copyItem: { source, temporary in
        try FileManager.default.copyItem(at: source, to: temporary)
        if source == txSource1 {
            try Data("external owner".utf8).write(to: txDest2)
        }
    })
    check("destination race aborts the transaction", false)
} catch {
    check("destination race preserves every source",
          FileManager.default.fileExists(atPath: txSource1.path)
          && FileManager.default.fileExists(atPath: txSource2.path))
    check("destination race rolls back only this transaction's installed file",
          !FileManager.default.fileExists(atPath: txDest1.path))
    check("destination race preserves the other actor's file",
          (try? String(contentsOf: txDest2, encoding: .utf8)) == "external owner")
}
try FileManager.default.removeItem(at: txDest2)

try OutputFileSafety.relocateArtifactSet([
    .init(source: txSource1, destination: txDest1),
    .init(source: txSource2, destination: txDest2),
])
check("successful artifact transaction verifies destinations",
      FileManager.default.fileExists(atPath: txDest1.path)
      && FileManager.default.fileExists(atPath: txDest2.path))
check("successful artifact transaction cleans sources only after verification",
      !FileManager.default.fileExists(atPath: txSource1.path)
      && !FileManager.default.fileExists(atPath: txSource2.path))
SWIFT

swiftc macOS/Sources/ArchiveProcessor/OCR/OutputFileSafety.swift "$work/main.swift" -o "$work/test-output-file-safety"
"$work/test-output-file-safety" "$work/files"
