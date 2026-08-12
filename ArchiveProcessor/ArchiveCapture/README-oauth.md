# Google OAuth setup for the Drive cloud relay

**You only need this if you want the Drive cloud relay.** The LAN and USB transports need no
accounts, no keys and no setup — if you're capturing on a network that allows device-to-device
traffic, skip this file entirely.

The relay exists for venues that enforce client isolation, where the phone cannot reach the Mac
directly at all. The phone uploads each captured page to *your own* Google Drive and the Mac pulls
it back down, deleting each object after a durable receipt.

## Why this isn't shipped configured

A Google OAuth client for an installed app is **bound to the app's package name and signing
certificate SHA-1**. That binding is the whole security model — there is no client secret on
Android, so Google refuses any authorization request that doesn't come from the exact
package + signature the client was registered with.

So a client ID cannot be shared. Whoever builds this app builds it with a different debug signing
key than the person before them, and the same client ID would simply be rejected. You have to
create your own. This is why `driveOAuthClientId` is read from the gitignored `local.properties`
rather than committed.

An unconfigured build is a working build: it compiles, and LAN + USB capture behave normally. Only
Drive sign-in is disabled, with a message pointing here.

## One-time setup

1. **Create a Google Cloud project** at [console.cloud.google.com](https://console.cloud.google.com).
   The project number in its URL is what the docs elsewhere in this repo refer to as *your* project.

2. **Enable the Google Drive API** for it (APIs & Services → Library → Drive API → Enable).

3. **Configure the OAuth consent screen.** External, and while it is in *Testing* you must add your
   own Google account under **Test users** or sign-in will be refused. The only scope needed is
   `https://www.googleapis.com/auth/drive.file` — per-file access to files this app creates, not
   your whole Drive.

4. **Create the Android OAuth client** (Credentials → Create credentials → OAuth client ID →
   Android):
   - Package name: `com.archiveprocessor.capture`
   - SHA-1: your debug signing certificate's fingerprint —
     ```sh
     keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey \
             -storepass android -keypass android | grep SHA1
     ```
   - ⚠️ **Open the client's *Advanced Settings* and enable "Custom URI scheme".** It is **off by
     default**, and with it off Google blocks the authorization request outright. This is the single
     most common way this setup fails.

5. **Put the client ID in `local.properties`** (this directory, gitignored):
   ```properties
   driveOAuthClientId=YOUR-PROJECT-1abc….apps.googleusercontent.com
   ```
   The reversed-client-ID redirect scheme is derived from it automatically in `app/build.gradle.kts`,
   so there is nothing else to keep in sync.

6. **Create a *Desktop* OAuth client in the same project** for the Mac side. It uses loopback PKCE
   *with* a client secret; enter both in the Processor's **Settings → Live Capture**, where the
   secret goes to the Keychain. Trailing whitespace on a pasted value reads as `invalid_client`.

7. **Sign in on both devices with the same Google account.** `drive.file` is scoped per client
   *project*, so Mac and phone see the same folder only if they are clients of one project and one
   account.

## iPhone companion

The iOS companion needs its own **iOS** OAuth client in the same project, registered against bundle
ID `com.archiveprocessor.capture.ios`, with the same "Custom URI scheme" toggle enabled. Its client
ID goes in `ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/DriveAuth.swift` and the matching
reversed scheme in `ArchiveCaptureiOS/project.yml`. The iOS companion is currently
[parked](../ArchiveCaptureiOS/PARKED.md) and its on-device OAuth flow is unverified.
