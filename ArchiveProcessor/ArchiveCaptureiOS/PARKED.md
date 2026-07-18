# ArchiveCaptureiOS — PARKED (2026-07-18)

This iPhone capture companion is **parked**. The source is fully retained and tracked; it is simply
**out of the routine build-verify loop** so it doesn't get rebuilt on every Capture change while iOS
work is paused. We'll come back to it.

## What "parked" means here

- **Source stays in place and stays in sync.** The phone↔Mac protocol and the cloud-relay object
  format are shared contracts. When you change either (see the "Phone↔Mac protocol" hotspot in
  `../CLAUDE.md`), **still edit this app's mirror source** (`Sources/ArchiveCaptureiOS/Net/…`). Parity is
  still checked automatically — `../scripts/test-relay-golden.sh` host-compiles this app's
  `RelayObjectFormat.swift` with `swiftc` (no simulator runtime needed), and the relay/transport tests
  reference these sources too.
- **The full-app build is NOT run** as part of the per-change verify loop. `../CLAUDE.md` no longer lists
  the iOS `xcodebuild` in its build-verify block, and the autonomous daemon's `ops/autonomous/health-gate.sh`
  already never built iOS (it builds Reader, Notes, and Processor-macOS only). Nothing rebuilds this app
  automatically.

## Why it can't build right now

The iOS **simulator runtime** was removed on 2026-07-18 to reclaim ~18 GB (16 GB runtime image + 1.9 GB
simulator device data), since we're not doing iOS work. The compile SDK
(`iPhoneSimulator26.2.sdk`) is still bundled in Xcode, but a scheme-based `xcodebuild … build` needs at
least one installed iOS simulator runtime to resolve a destination — with zero runtimes installed it
fails with *"iOS … is not installed."* So this app cannot be built or run locally until a runtime is
reinstalled.

## How to revive it

1. Reinstall an iOS simulator runtime (re-downloads several GB):
   ```bash
   xcodebuild -downloadPlatform iOS
   # or: Xcode ▸ Settings ▸ Components ▸ iOS simulator runtime
   ```
2. Regenerate + build the app (the `.xcodeproj` is gitignored):
   ```bash
   cd ArchiveProcessor/ArchiveCaptureiOS
   xcodegen generate
   xcodebuild -scheme ArchiveCaptureiOS -sdk iphonesimulator -configuration Debug -derivedDataPath ./build/DD build
   ```
3. Put iOS back in the loop: restore the iOS build line in `../CLAUDE.md`'s build-verify block, un-mark
   the iPhone lane there, and delete this file.

Real capture testing still needs a **physical iPhone** (the simulator has no camera); the phone↔Mac
round-trip E2E gate uses the Android emulator, not iOS. See `../scripts/E2E-PHONE-MAC.md`.
