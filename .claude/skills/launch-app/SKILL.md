---
name: launch-app
description: >-
  Launch the Archive Processor macOS app (the app in this repo). Use whenever the user says
  "launch the app", "run the app", "open the app", "start the app", or "start/open Archive Processor".
  Launches the current Debug build if it is up to date; otherwise builds it first, then launches.
---

# Launch the app

Run the repo's launch script from the repo root:

```bash
./launch.sh
```

That's the whole routine. `launch.sh` is reproducible and self-contained:

1. **Freshness check** — is `ArchiveProcessor/build/DD/Build/Products/Debug/ArchiveProcessor.app` present and
   newer than every input under `ArchiveProcessor/Sources` + `ArchiveProcessor/project.yml`?
2. **Build if stale/missing** — `xcodegen generate` + `xcodebuild -scheme ArchiveProcessor -configuration Debug
   -derivedDataPath ./build/DD build`. On failure it prints the tail of `/tmp/ap-launch-build.log` and exits 1.
3. **Launch** — always puts the *current* build in front: `open` it, **relaunch** a stale instance that predates the current build (so you never see an old process after a rebuild), or just foreground the already-current one.

After running it, confirm the app came up and report:

```bash
pgrep -x ArchiveProcessor    # non-empty = running
```

Notes:
- It's a **native macOS SwiftUI GUI**, so there's no headless driver — the user drives the window. To verify a
  specific change, drive that flow in the app (e.g. a cheap live OCR run on a `Test Files/` image) rather than
  just confirming the process exists.
- Build prerequisite: XcodeGen (`brew install xcodegen`); `./bootstrap.sh` installs it if missing.
- The companions (iOS `ArchiveCaptureiOS/`, Android `ArchiveCapture/`) are separate targets — this skill is the
  macOS app only. "Launch the app" means the macOS Archive Processor.
