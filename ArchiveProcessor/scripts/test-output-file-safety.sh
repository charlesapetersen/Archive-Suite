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

try Data("original".utf8).write(to: original)
try Data("generated".utf8).write(to: distinct)
try Data("source metadata".utf8).write(to: sourceJSON)
try Data("generated metadata".utf8).write(to: generatedJSON)
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
SWIFT

swiftc macOS/Sources/ArchiveProcessor/OCR/OutputFileSafety.swift "$work/main.swift" -o "$work/test-output-file-safety"
"$work/test-output-file-safety" "$work/files"
