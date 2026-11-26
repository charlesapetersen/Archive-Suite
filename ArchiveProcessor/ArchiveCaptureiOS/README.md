# Archive Capture for iPhone

The iPhone companion to **Archive Processor**'s Live Capture: photograph each page of a document on the phone and
it arrives in the Processor on the Mac, which reads, tags and files it. The phone keeps every photo on disk until
the Mac confirms it has saved it, so a dropped connection loses nothing.

Version **1.0** (`MARKETING_VERSION`, build `CURRENT_PROJECT_VERSION` 1 in `project.yml`), kept equal to the
Android companion's (`../ArchiveCapture/app/build.gradle.kts`). Bump both together. The app icon is drawn by
`swift release/make-app-icons.swift ios` from the repo root, the same tile as the Android launcher icon.

## Build

Needs Xcode and XcodeGen (`brew install xcodegen`). The `.xcodeproj` is generated and gitignored.

```bash
cd ArchiveProcessor/ArchiveCaptureiOS
xcodegen generate
xcodebuild -scheme ArchiveCaptureiOS -destination 'generic/platform=iOS Simulator' \
  -configuration Debug -derivedDataPath ./build/DD build
```

`project.yml` builds unsigned (`CODE_SIGN_IDENTITY: "-"`), which is what the Simulator and CI need. A phone needs a
signed build, below; the signing settings go on the command line so `project.yml` stays unsigned.

## Install on your own iPhone (free Apple ID)

1. Add your Apple ID in Xcode ▸ Settings ▸ Accounts. Connect the phone by cable, unlock it and tap **Trust**.
   `xcrun devicectl list devices` should show it as connected.
2. Build signed with your personal team, under a bundle id of your own (a free team cannot use
   `com.archiveprocessor.capture.ios`):
   ```bash
   TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier \
     | sed -n 's/.*teamID = \([A-Z0-9]*\);/\1/p' | head -1)
   xcodebuild -project ArchiveCaptureiOS.xcodeproj -scheme ArchiveCaptureiOS -configuration Debug \
     -destination 'generic/platform=iOS' -derivedDataPath build/device -allowProvisioningUpdates \
     PRODUCT_BUNDLE_IDENTIFIER=com.yourname.capture.ios DEVELOPMENT_TEAM="$TEAM" \
     CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_REQUIRED=YES build
   ```
3. Install and open it:
   ```bash
   xcrun devicectl device install app --device "<phone name>" build/device/Build/Products/Debug-iphoneos/ArchiveCaptureiOS.app
   xcrun devicectl device process launch --device "<phone name>" com.yourname.capture.ios
   ```
   If the phone says the developer is not trusted: Settings ▸ General ▸ VPN & Device Management ▸ your Apple ID ▸
   **Trust**. If it asks for Developer Mode, turn it on under Settings ▸ Privacy & Security.

A free Apple ID's install stops opening after seven days; steps 2 and 3 reinstall it. The full guided version is
`verification/sessions/iphone-1.md`.

## Pair with the Mac

1. On the Mac, open Archive Processor's **Live Capture** tab. The **Pair the phone** box shows a QR code.
2. In Archive Capture, pick how the phone is connected, then tap **Scan QR code** and point the camera at it.
   Allow Local Network access when asked.
   - **Wi-Fi** — phone and Mac on the same network. Use it only on a network you trust.
   - **Cable** — the USB cable, for networks that keep devices apart; the Mac reaches the phone through the cable
     itself, so nothing else needs setting up.
   - **Cloud** — your own Google Drive. Optional; it needs your own iOS OAuth client in the gitignored
     `Config/DriveLocal.xcconfig` (`Config/Drive.xcconfig` says how; steps in
     [`../ArchiveCapture/README-oauth.md`](../ArchiveCapture/README-oauth.md)). Without it, Drive sign-in is hidden.

Pairing is by QR only. **Show QR** on the Mac pairs a new phone.

## Builds for other testers

Installing on someone else's iPhone needs a paid **Apple Developer Program** membership (the owner's account; a
free Apple ID can only install on your own devices). Two routes:

- **TestFlight** (recommended): up to 10,000 testers by email or public link, no device list, builds last 90 days.
  Register the bundle id `com.archiveprocessor.capture.ios` (or your own) under your team, create the app in App
  Store Connect, then archive and upload:
  ```bash
  xcodebuild -project ArchiveCaptureiOS.xcodeproj -scheme ArchiveCaptureiOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/ArchiveCapture.xcarchive -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=<team id> CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Distribution" \
    CODE_SIGNING_REQUIRED=YES archive
  xcodebuild -exportArchive -archivePath build/ArchiveCapture.xcarchive -exportPath build/export \
    -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
  ```
  with an `ExportOptions.plist` whose `method` is `app-store-connect` and `destination` is `upload`. Each upload
  needs a higher `CURRENT_PROJECT_VERSION`. `Info.plist` already declares `ITSAppUsesNonExemptEncryption` so
  uploads skip the export-compliance question. External testers wait for Apple's beta review of the first build.
- **Ad hoc**: up to 100 registered devices per year. Add each tester's UDID in the developer portal, export with
  `method` `release-testing`, and send the `.ipa` (installed through Finder or Apple Configurator).

The Cloud relay's iOS OAuth client is bound to the bundle id, so a tester build under a different bundle id needs
its own client. Wi-Fi and Cable are unaffected.
