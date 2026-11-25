#!/bin/bash
# W49.proc-local-model-supervisor: every app-managed local model is started, kept and stopped by
# LocalModels/LocalModelSupervisor.swift, so two large models are never loaded at once. Fails, naming the line, when a
# production source starts a child process outside the reviewed files, runs a binary through LocalAgentClient outside
# the reviewed callers, names the managed Python/MLX runtime or its worker outside the supervisor, makes a second
# supervisor, or bundles another Python worker. Test drivers and contracts (DEBUG-only, *TestDriver.swift /
# *Contract.swift) are skipped. Pure shell, $0, instant. Also run by scripts/test-local-models.sh.
set -uo pipefail
cd "$(dirname "$0")/../macOS/Sources/ArchiveProcessor"
seam="LocalModels/LocalModelSupervisor.swift"
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(find . -name '*.swift' ! -name '*TestDriver.swift' \
    ! -name '*Contract.swift' ! -path "./$seam" -print0 | sort -z)
status=0
# Code lines only: a // or /// comment may name these freely.
code() { grep -nE "$1" "${files[@]}" | grep -vE '^\./[^:]+:[0-9]+:\s*//' || true; }
fail() { echo "FAIL $1"; echo "$2" | sed 's/^/  /'; status=1; }

# 1. A child process is made only where it was reviewed: adb/iproxy, qpdf, the agent CLIs, and the supervisor.
hits=$(code '(^|[^A-Za-z0-9_])Process(\(\)|\.run\()|:[[:space:]]*Process[[:space:]]*=|NSTask|posix_spawn|(^|[^A-Za-z0-9_.])system\(' | grep -vE '^\./(Net/USBBridge|OCR/SearchableArchival|OCR/LocalAgentClient)\.swift:' || true)
[ -n "$hits" ] && fail "a child process is started outside the reviewed files (a model server goes through $seam):" "$hits"

# 2. LocalAgentClient runs a binary only for the agent CLIs it was written for.
hits=$(code 'runAsync\(binaryPath:|runProcess\(binaryPath:' \
       | grep -vE '^\./(OCR/LocalAgentClient|OCR/ClaudeCLIUsage|OCR/LocalAgentValidator|Segmentation/WindowTransports)\.swift:' || true)
[ -n "$hits" ] && fail "a binary is run through LocalAgentClient outside its reviewed callers (models go through $seam):" "$hits"

# 3. The managed runtime and its worker are named only by the supervisor: its interpreter, uv, the worker script, a
#    model server's module started by argument, and the worker's environment.
hits=$(code 'bin/python|uv-aarch64|--managed-python|LocalModelWorker|"-m",[[:space:]]*"mlx|ARCHIVE_MODEL_(SECRET|REPO|REVISION|PORT)|"HF_HOME"|UV_PYTHON_INSTALL_DIR')
[ -n "$hits" ] && fail "the managed Python/MLX runtime is named outside $seam:" "$hits"

# 4. One supervisor: nothing else makes one (its initialiser is private; the contracts use forTest).
hits=$(code 'LocalModelSupervisor\.forTest\(|LocalModelSupervisor\(')
[ -n "$hits" ] && fail "a second LocalModelSupervisor is made outside the test contracts:" "$hits"
grep -qE '^    private init\(' "$seam" || fail "$seam's initialiser is not private" "$seam"
[ "$(grep -cE 'static let shared' "$seam")" = 1 ] || fail "$seam has no single shared supervisor" "$seam"

# 5. The supervisor's worker is the only Python bundled with the app.
hits=$(find . -name '*.py' ! -path './LocalModels/LocalModelWorker.py')
[ -n "$hits" ] && fail "a Python file besides LocalModels/LocalModelWorker.py is in the app's sources:" "$hits"

[ $status = 0 ] && echo "PASS every app-managed local model goes through $seam"
exit $status
