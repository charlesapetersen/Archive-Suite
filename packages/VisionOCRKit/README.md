# VisionOCRKit

Vision OCR's reading engine as a Swift package: recognition with Apple Vision, the page-kind detector, the
flattener and its compression, JBIG2, the searchable-PDF writer, the local-model runtime, the model downloads and
the memory guard. Moved here from `~/Claude/vision-ocr` (release 1.16.0) with its history, as Stage 1 of
[`execution-plans/integration/00-plan.md`](../../execution-plans/integration/00-plan.md). Vision OCR's own
measurement records, bug register and planning documents stay in that repository.

| Path | What it is |
|---|---|
| `Sources/VisionOCRKit/` | The library target; `Resources/read-model.py` is the local-model reader script |
| `Sources/VisionOCRKit/PageReader.swift` | The `PageReader` protocol every reader of a page sits behind (W42.int-s2); Archive Processor's clients conform in its `OCR/PageReaders.swift` |
| `Helper/` | `visionocr-recognise`, the executable product that runs Vision in more processes |
| `Tests/main.swift` | Vision OCR's suite, as the `visionocr-checks` executable target |
| `PackageTests/` | The `swift test` target that runs `visionocr-checks` |
| `App/` | Vision OCR's SwiftUI screens; in no package target, built only by `build.sh` |
| `Tools/` | Vision OCR's scorers, probes and harnesses (`ux-regression.sh`) |

Build and test (both take the heavy lock; the suite runs Vision and the flattener):

```bash
python3 ops/autonomous/heavy-run.py run -- swift build -c release --arch arm64 --arch x86_64 \
  -Xswiftc -enable-testing --package-path packages/VisionOCRKit
python3 ops/autonomous/heavy-run.py run -- swift test -c release -Xswiftc -enable-testing \
  --package-path packages/VisionOCRKit
```

`visionocr-pdf <out-dir> <file>...` (`Tools/pdf/`) makes Vision OCR 1.16.0's searchable PDF of each file with its defaults, headless, and prints bytes and seconds: the size baseline for Archive Processor's output (W42.int-s5, `ArchiveProcessor/scripts/measure-output.sh`).

A whole-package release build needs `-Xswiftc -enable-testing`, because `visionocr-checks`, `visionocr-gate` and `visionocr-pdf` use `@testable import`; without it those targets fail with "unable to resolve Swift module dependency". The library and the helper build without it (`--product visionocr-recognise`), and so does a debug build. The `ux-regression.sh` run was not repeated after the move (owner, 2026-11-13: the suite's matching count is enough; Vision OCR's `testdocs/` corpus stays on the OneDrive backup), so `Tools/ux-regression.sh` through the package products is wired but has not been run.

`-c release` matters: the suite's own notes (`run_tests.sh`) explain why `-O` is load-bearing. `run_tests.sh` and
`build.sh` still build the suite and Vision OCR's app with `swiftc` from these sources, as a reference lane.
