# Archive Capture for Android

The phone companion to **Archive Processor**'s Live Capture: photograph each page of a document on the phone and
it arrives in the Processor on the Mac, which reads, tags and files it. The phone keeps every photo on disk until
the Mac confirms it has saved it, so a dropped connection loses nothing.

Version **1.0** (`versionName`, `versionCode 1` in `app/build.gradle.kts`), kept equal to the iPhone companion's
(`../ArchiveCaptureiOS/project.yml`). Bump both together.

## Build

Needs JDK 21 and the Android SDK (`ANDROID_HOME`, or `sdk.dir` in `local.properties`). No device is needed to build
or to run the unit tests.

```bash
cd ArchiveProcessor/ArchiveCapture
./gradlew assembleDebug testDebugUnitTest      # add --offline once the dependencies are cached
```

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`. A first release build fetches the lint tooling, so
run it online once.

## Install on a phone (sideload)

1. On the phone: Settings ▸ About phone ▸ tap **Build number** seven times, then Settings ▸ System ▸ Developer
   options ▸ turn on **USB debugging**.
2. Connect it by cable, accept the "Allow USB debugging?" prompt, and check `adb devices` lists it.
3. `adb install -r app/build/outputs/apk/debug/app-debug.apk`

Without a cable, copy the APK to the phone and open it; Android asks once to allow installs from that app.

## Pair with the Mac

1. On the Mac, open Archive Processor's **Live Capture** tab. The **Pair the phone** box shows a QR code.
2. In Archive Capture, choose how the phone is connected, then point the camera at the QR code:
   - **Wired (USB cable)** — the most reliable, and needs no shared network. Needs USB debugging on; the Processor
     keeps `adb reverse` in place itself.
   - **Wi-Fi (same network)** — phone and Mac on one network (port 48627). Use it only on a network you trust.
   - **Cloud (Google Drive)** — your own Google Drive, for when neither works. Optional, and needs a one-time
     Google setup: [`README-oauth.md`](README-oauth.md).

Pairing is by QR only. **Show QR** on the Mac pairs a new phone.

## Release builds for testers

A tester's phone takes any APK signed with a stable key; a debug APK works too, but a release build is the one to
hand out. Signing is configured from a gitignored file, so no key or password ever enters git.

1. Make a keystore once and keep it backed up — an update must be signed with the same key, or the phone refuses
   it until the old app is uninstalled:
   ```bash
   keytool -genkeypair -v -keystore ~/archive-capture-release.jks -alias archive-capture \
     -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Create `ArchiveCapture/keystore.properties` (gitignored, beside `local.properties`):
   ```properties
   storeFile=/Users/you/archive-capture-release.jks
   storePassword=…
   keyAlias=archive-capture
   keyPassword=…
   ```
   `storeFile` may also be relative to this folder.
3. `./gradlew assembleRelease` writes `app/build/outputs/apk/release/app-release.apk`; check it with
   `apksigner verify --print-certs`. Without `keystore.properties` the release build is unsigned
   (`app-release-unsigned.apk`), which no phone installs.
4. Send testers the APK and the sideload steps above (they need no USB debugging to install from a file).

**Drive relay and the release key:** Google binds the Android OAuth client to the signing certificate's SHA-1. A
release-signed APK has a different SHA-1 from your debug build, so testers who use Cloud need an OAuth client (or
an added fingerprint) registered for the release key's SHA-1
(`keytool -list -v -keystore ~/archive-capture-release.jks`). Wi-Fi and Wired are unaffected.

For a larger group, Google Play's internal testing track takes the same signed build (an `assembleBundleRelease`
AAB) and needs a Play Console account.
