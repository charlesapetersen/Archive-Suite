# UITestSupport

Shared XCUITest and in-app UI-verification support files compiled directly into **Archive Reader**, **Archive Notes**, and **Archive Processor** test targets (via XcodeGen `project.yml` source references).

## Layout

- **`App/`** — compiled into the macOS apps (Debug/UI-test builds):
  - `LayoutLoopProbe.swift` — hooks AppKit scroll-view `tile()`/`layout()` to detect AppKit `Update Constraints` layout loops during UI tests
  - `TransientRecorder.swift` — samples watched accessibility-tree sections after committed main-run-loop passes to catch visual flicker and unintended intermediate states during UI transitions
  - `UITestAppearance.swift` — applies deterministic light/dark appearance overrides from the `-ArchiveUITestAppearance dark|light` process launch argument
- **`Runner/`** — compiled into `*UITests` runner targets:
  - `AccessibilityAudit.swift` — VoiceOver / accessibility identifier and label checks
  - `FixtureMissing.swift` — fail-fast helper when a required scratch fixture is absent
  - `LayoutGuard.swift` — verifies windows/controls stay within bounds without clipping or overlap
  - `TransientCheck.swift` — asserts recorded transient UI states
- **`Shared/`** — compiled into both app and runner targets:
  - `TransientAnalysis.swift` — shared codec and analysis for recorded transient events

All XCUITests run in the isolated Tart macOS VM (`ops/gui/vm-gui-runner.sh`) so they never hijack the host keyboard, mouse, or display.
