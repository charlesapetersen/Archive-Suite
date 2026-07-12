#!/bin/bash
# Standalone pure regression for post-parse controlled-vocabulary enforcement.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/main.swift" <<'SWIFT'
import Foundation

func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { exit(1) }
}

let vocabulary = ["Civil Rights", "Labor Unions", "Science", "civil rights", "  "]
let proposed = [" civil rights ", "INVENTED", "LABOR UNIONS", "Civil Rights", "science"]
check("filters inventions, trims input, deduplicates, and preserves canonical spelling",
      ControlledVocabulary.enforce(proposed, vocabulary: vocabulary)
        == ["Civil Rights", "Labor Unions", "Science"])
check("empty vocabulary preserves free-form behavior and six-tag cap",
      ControlledVocabulary.enforce([" a ", "b", "c", "d", "e", "f", "g"], vocabulary: [])
        == [" a ", "b", "c", "d", "e", "f"])
check("empty or whitespace-only configured vocabulary accepts nothing",
      ControlledVocabulary.enforce(["Anything"], vocabulary: ["", "  "]).isEmpty)
check("Unicode case folding matches and deduplicates sharp-s spellings",
      ControlledVocabulary.enforce(["STRASSE", "Straße"], vocabulary: ["Straße", "STRASSE"])
        == ["Straße"])
check("canonical Unicode normalization matches composed and decomposed text",
      ControlledVocabulary.enforce(["Cafe\u{301}"], vocabulary: ["Café"])
        == ["Café"])
SWIFT

swiftc macOS/Sources/ArchiveProcessor/Tagging/ControlledVocabulary.swift "$work/main.swift" -o "$work/test"
"$work/test"
