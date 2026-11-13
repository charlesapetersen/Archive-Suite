#!/bin/bash
# W42.int-s2: every page reading goes through PageReaders.reader (OCR/PageReaders.swift). Fails, naming the line, when
# a production source calls a client's `ocr(` itself or builds a page-reading client outside that file. Test drivers
# and contracts (DEBUG-only, *TestDriver.swift / *Contract.swift) drive clients directly on purpose and are skipped.
# Pure shell, $0, instant. Also run by scripts/test-page-reader.sh.
set -uo pipefail
cd "$(dirname "$0")/../macOS/Sources/ArchiveProcessor"
seam="OCR/PageReaders.swift"
files=$(find . -name '*.swift' ! -name '*TestDriver.swift' ! -name '*Contract.swift' ! -path "./$seam" | sort)
# A call of a client's ocr (not its definition), or a page-reading client made outside the seam: VisionClient and
# the direct-provider clients are page readers only, so constructing one anywhere else reads around the protocol.
hits=$(grep -nE '\.ocr\(|(^|[^A-Za-z])(VisionClient|AnthropicClient|GeminiClient|MistralClient)\(' $files \
       | grep -vE '^\./[^:]+:[0-9]+:\s*(///|//)' | grep -v 'func ocr(' || true)
status=0
if [ -n "$hits" ]; then
    echo "FAIL a page is read around PageReaders.reader (use it, or add the reader there):"
    echo "$hits" | sed 's/^/  /'
    status=1
fi
# Every LLMProvider case has its reader: the factory's switch must name each one.
cases=$(sed -n '/^enum LLMProvider/,/^}/p' Models/ProviderModels.swift | grep -oE '^    case [a-zA-Z]+' | awk '{print $2}')
for c in $cases; do
    grep -qE "case \.$c[:,]" "$seam" || { echo "FAIL LLMProvider.$c has no reader in $seam"; status=1; }
done
[ $status = 0 ] && echo "PASS every page reading goes through PageReaders ($(echo "$cases" | wc -l | tr -d ' ') providers)"
exit $status
