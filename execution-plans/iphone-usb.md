# The iPhone over the cable — design (W40.i-usb-design, 2026-10-29)

Owner, 2026-10-29: most users will want the USB route, so the iPhone gets one if practical, before the real-iPhone
pass (W40.i4). This reverses "USB is Android-only by design". This plan is the design; the build is the three
items in §8. Delete this file when `W40.i-usb-build` ships, folding what stays true into `ArchiveProcessor/REFERENCE.md`.

## 1. What exists today (read 2026-10-29)

- **Mac:** `CaptureServer` (`Net/CaptureServer.swift`) is plaintext HTTP/1.1 on `NWListener`, fixed port 48627
  (one fallback to a system port), Bonjour `_archivecap._tcp`, one request per connection (`Connection: close`),
  `Authorization: Bearer <lanToken>`. Every receiver behind the `CaptureReceiver` seam funnels into
  `CaptureSession.ingest`, and `/photo` acks only when ingest returns a URL.
- **Android's cable:** `Net/USBBridge.swift` runs `adb reverse tcp:P tcp:P`, re-asserted every 5 s. The phone's
  "Wired" mode keeps the QR's port and token and swaps the host for `127.0.0.1`. Same `MacClient`, same pipeline.
- **iPhone:** `MacClient` is `URLSession.shared` against `http://host:port`, behind the `SegmentTransport` seam. The
  outbox is `Application Support/capture`; an item is deleted only after a 2xx confirm; 3 tries per call, then the
  8 s auto-retry; stale replies are re-queued, not confirmed. No `UIBackgroundModes`: uploads stop when the app is
  suspended and resume on return (S-023).
- **QR:** `{host, port, token, name, relay?}`. `host` comes from en0/en1 only; with neither, the whole pairing box
  is hidden (S-037).

## 2. The route chosen: an `adb reverse` for the iPhone, built on usbmux

An iPhone cannot open a connection to the Mac over the cable. The Mac can open one *into* the phone: macOS's
`usbmuxd` (`/var/run/usbmuxd`, the service Xcode, Finder and libimobiledevice use) connects a Mac socket to a TCP
port the app listens on. The design rebuilds what `adb reverse` gives Android out of that one primitive, so the
iPhone's transport, pipeline and Mac server are untouched:

```
URLSession ──► 127.0.0.1:48629  (app: local relay listener)
                   │  spliced to an idle tunnel
                   ▼
               tunnel  ◄── usbmux Connect(device, 48628) ── Mac: USBMuxBridge (keeps idle tunnels open)
                                                                  │ on first byte, splice to
                                                                  ▼
                                                           127.0.0.1:<CaptureServer port>
```

- **The app** listens on two ports, both **bound explicitly to 127.0.0.1**. `NWListener` binds every interface
  unless it is given a local endpoint, and that would let a Wi-Fi peer in. **48628** is the tunnel port the Mac
  connects into. **48629** is the local relay `MacClient` uses as its host. Each connection URLSession opens on
  48629 is queued (first in, first out) until a **verified** idle tunnel is free, then spliced to it. The wait limit
  is 10 s, inside `MacClient`'s 30 s request timeout; past it the local connection is closed and the existing retry
  takes over. A splice forwards each side's end of stream to the other (`send(isComplete: true)`) and cancels a
  connection only after both directions have finished and the last send reports `.contentProcessed`. This matters
  because `CaptureServer` writes its reply and closes at once (`CaptureServer.swift:618`), and closing the other
  side as soon as one closes would cut that reply off.
- **The tunnel handshake: the phone proves it is talking to its Mac before any photo goes in.** Without it, any app
  on the phone could connect to 127.0.0.1:48628, be taken for an idle tunnel, and receive a photo plus the bearer
  token. If it answered `200`, the phone would delete its only copy. So on each new tunnel the phone sends `AC1`
  and a 16-byte random nonce. The Mac replies with HMAC-SHA256(lanToken, nonce), 32 bytes, and the phone compares
  it in constant time. Only a verified tunnel enters the pool. A tunnel that fails, or that says nothing within
  5 s, is closed. Before the phone is paired it has no token, so it holds unverified tunnels and verifies them once
  the QR is scanned. The Mac still never speaks first.
- **The Mac** (`USBMuxBridge`, beside `USBBridge`) holds a dedicated socket to usbmuxd for `Listen` (`Attached`,
  `Detached` and `Paired` events). For each attached device whose `ConnectionType` is `USB` (Wi-Fi-synced devices
  are ignored), it keeps **four** idle tunnels open. Each tunnel is a **fresh** Unix-socket connection that sends
  one `Connect`. After `Result 0` that socket *is* the raw pipe; a socket whose `Connect` failed is closed, never
  reused. `PortNumber` is in **network byte order**: 48628 is sent as `0xF4BD`, which read without the swap is
  62653, so the codec test pins it. The Mac answers the handshake, then opens TCP to its own server on the first
  byte after it, splices, and opens a replacement. **Refilling never depends on seeing an end of stream:** while
  the device is attached, a loop tops the pool up to four every 2 s, whatever the last `Connect` returned (Result 3
  means the app is not running or is suspended). An idle tunnel older than 20 s is closed and replaced, because a
  suspended phone leaves defunct sockets that never report EOF. A request that races an expiry fails once and is
  retried. The loop stops on `Detached`.
- **Concurrency.** The phone starts one `Task` per pending item (`CaptureViewModel.swift:491`, `:611`, `:628`), plus
  segment sends and the heartbeat. A burst after a reconnect can therefore open many local connections at once. The
  relay queues them, and the Mac replaces each tunnel as it is taken. The Cable `URLSession` sets
  `httpMaximumConnectionsPerHost` to 4, matching the pool, so the queue stays short. One request per connection on
  the Mac means one tunnel per request. Each replacement is a `Connect` to the device's TCP stack and a handshake,
  a few milliseconds over the cable; that is an estimate, which the real-iPhone pass measures.
- **Pairing is the same QR.** The phone gets a third connect mode, **Cable**, beside Wi-Fi and Cloud, as Android has
  Wired. It keeps the QR's token and name. Its `MacEndpoint` stores the **mode, not a port**: `MacClient` asks the
  relay for its bound port each time it builds a request. If 48629 is busy the relay takes a system port, and a
  stored endpoint keeps working. Cable is pre-selected when a tunnel is open into 48628. Before pairing that tunnel
  is unverified, so it only picks a default on the screen and grants nothing.
- **Security** is no weaker than today's. usbmux reaches only a phone that has trusted this Mac. The handshake stops
  an app on the phone posing as the Mac. A rogue app that sends requests through 48629 reaches the Mac's server and
  is refused without the token. **The auth throttle must not be shared with it:** `CaptureServer` keys its
  failed-auth throttle by peer address (`CaptureServer.swift:409-419`). Cable, `adb reverse` and any local process
  all arrive as `127.0.0.1`, so six bad tokens from a rogue app would put the real phone behind a 30 s backoff. The
  bridge's connections get their own throttle key, for example through a second loopback-only listener whose peers
  are keyed `cable:<device>`. LAN security stays the owner's accepted risk (`ArchiveProcessor/CLAUDE.md`).
- **The pane and QR caption** gain a cable line ("iPhone on the cable: connected" once a tunnel is live, "plugged
  in, open Archive Capture" when attached with `Connect` refused). The Android hint at `LiveCaptureView.swift:363`
  and the iPhone's `ConnectScreen` copy ("USB isn't available on iPhone…") are rewritten.

### Rejected alternatives

- **The Mac pulls** (the app serves its outbox and the Mac fetches and acks). That is a second protocol and a
  second ack path on both ends, beside the one the never-lose-a-photo pipeline has been tested on. Rejected: it
  breaks the one transport seam for no gain over the relay.
- **A raw-socket `SegmentTransport`** (an HTTP client written over the tunnel, skipping the local relay). It is
  smaller on the wire, but it forks `MacClient` and leaves `/ping` and reachability, which are concrete `MacClient`,
  on a different path. The relay keeps the code that is already tested.
- **A documented Apple route.** None exists for third-party apps. CoreDevice and `devicectl` have no port forward,
  and the iOS 17 RemoteXPC tunnel needs root and the developer tools.
- **Pairing without the QR**, where the Mac sends the token down the first tunnel. It is attractive later. It needs
  framing on the tunnel and a decision that any app on the trusted phone may read the token. Not in this build.

## 3. Backgrounding and a locked phone

The app has no background mode, so iOS suspends it shortly after it leaves the screen, and always when the phone
locks. Its listening sockets become defunct (TN2277), and its idle tunnels close or stall. This is the same
behaviour the Wi-Fi route has today with `URLSession.shared`, so the cable is no worse:

- Nothing is lost. Photos are on disk in the outbox and are deleted only on a confirm. A request cut off by
  suspension is re-sent, and a reply that arrives after the app is suspended is re-queued (S-023).
- On return to the foreground (`scenePhase == .active`), the app tears down both listeners and every tunnel it
  holds, then re-creates the listeners. The Mac's top-up loop, together with its 20 s idle expiry, finds the new
  listener within a few seconds, and the 8 s auto-retry re-sends. Expected recovery is about 10 s after unlock.
- If the cable is pulled mid-request, the Mac gets the detach event and closes that device's tunnels. The phone's
  request fails, and the item stays pending until the cable or another route returns.
- The screen staying on while capturing is the normal use, so this is a pause, not a failure mode. A later
  `UIBackgroundModes` item would serve both routes and is not part of this build.

## 4. The undocumented service — the risk and how it is bounded

`usbmuxd`'s socket protocol is private (plist messages, 16-byte header: length, version 1, type 8, tag). It has been
stable for more than ten years, and libimobiledevice, Peertalk and many commercial tools depend on it.

**Measured 2026-10-29 on this Mac (macOS 26.6, Xcode 27.0), no phone attached:** `ListDevices` returned
`{DeviceList: []}`, `ReadBUID` returned a BUID, `Listen` returned `Result 0`, and `Connect` to a non-existent
device returned `Result 2` (BadDevice). The protocol is alive and understood here. The Processor is not sandboxed
(its entitlements carry no `app-sandbox`), so it can open the socket. If it were ever sandboxed, it would need a
temporary-exception entitlement for `/private/var/run/usbmuxd`.

How the risk is bounded:
1. Only the Mac uses anything private. The phone uses public `Network.framework` listeners, so there is no
   App Review or iOS-update exposure.
2. If a macOS update changes the protocol, only the cable route fails. Wi-Fi and Cloud are untouched, and the pane
   says "Cable route unavailable" instead of failing silently.
3. A host probe, `scripts/usbmux-probe.sh` (the measurement above, read-only, about 50 ms), runs in the
   Processor's script tests. It catches a protocol change without a phone.

## 5. What can be tested without a phone

- **Mac:** a fake usbmuxd, a Unix-socket server speaking the plist framing. It reports one USB device and
  satisfies `Connect` by connecting to `127.0.0.1` **on the port it decodes from `PortNumber` with the byte swap**,
  so a wrong byte order fails the test rather than passing it. The bridge reads its socket path from a DEBUG-only
  override (`ARCHIVE_USBMUX_SOCKET`). A test driver checks the framing codec (48628 → `0xF4BD`), attach and
  detach, the pool topping up to four, refused `Connect`, idle expiry with no EOF, the handshake (right and wrong
  HMAC, silence), the separate throttle key, and splicing to a stand-in server that writes and closes at once.
  The reply must arrive whole.
- **iPhone:** the relay code is Network-only, with no UIKit, so it compiles into the existing macOS host tests
  (`test-ios-capture-queue.sh` pattern). A fake Mac connects to 48628, a client sends through 48629, and the test
  checks that the bytes are spliced and an immediate close still delivers the reply. It also checks that a tunnel
  with a wrong HMAC or no answer is never used, and that queued requests drain as tunnels arrive and time out at
  10 s. It checks that the listeners re-create and accept only on 127.0.0.1. Finally, a stored Cable endpoint must
  follow the relay to a fallback port.
- **End to end in the simulator:** the simulator shares the Mac's loopback, so the real app's 48628 listener is
  reachable at `127.0.0.1:48628`. With the fake usbmuxd in front of the real Mac bridge, `e2e-phone-mac.sh --ios
  --cable` runs the whole route: real app, real `MacClient`, relay, tunnel, real bridge and real server with OCR.
  The only parts not exercised are the real usbmuxd's `Connect` forwarding and the device's network stack.
  `--cable` must use the port layout above, because 48627 is already the Mac's own port on the shared loopback.
  The existing Wi-Fi simulator E2E stays unchanged.
- **Needs the owner's iPhone** (attached, unlocked, app open): the real `Connect`, the trust prompt, recovery after
  a lock, and whether `http://127.0.0.1` passes ATS on a device. It is the same rule the Wi-Fi route relies on for
  a LAN IP, and an IP literal is exempt. These checks belong to the iPhone pack (`W40.i5-usb`, then `W40.i4`). No
  proof is needed before the build, because Peertalk-style apps have used this exact primitive on every iOS since 6.

## 6. The no-code fallback: Personal Hotspot over the cable

The phone shares its connection over the cable, the Mac gets an "iPhone USB" network service (172.20.10.x), and
the phone reaches the Mac at that address. Weighed and **kept only as a workaround**, not as the route:
- It needs a carrier plan that allows hotspot, and a managed phone (the owner's is Stanford-managed) may block it.
- The Mac may route its own traffic, including OCR and Drive uploads, over cellular.
- The interface is not en0/en1, so the QR disappears (S-037). The user has to type the address.
- `ArchiveProcessor/CLAUDE.md` lists personal hotspot as a rejected transport, and that stands for a built route.

**S-037 is fixed in this build anyway:** cable pairing needs no Wi-Fi address, so the QR must appear whenever the
server is listening. When en0/en1 have no address, the QR's `host` falls back to the first other non-loopback IPv4
(the hotspot or USB Ethernet case). When there is none, the QR carries the token with `host` empty, valid for
Cable and Cloud, and the phone refuses Wi-Fi mode with a clear message. **Android must accept that QR too.** Its
`MacEndpoint.kt:50` rejects a blank host today, and no Wi-Fi address is exactly when an Android user relies on
Wired. So the Android parser takes an empty host for Wired and Cloud, with a test in `MacEndpointQrTest`.

## 7. Ports and constants

| Port | Where | Owner | If busy |
|---|---|---|---|
| 48627 | Mac loopback/LAN | `CaptureServer` (unchanged) | system port (unchanged) |
| 48628 | phone, loopback | app tunnel listener; the Mac connects here | Cable unavailable, said on the Connect screen |
| 48629 | phone, loopback | app local relay; `MacClient`'s host in Cable mode | system port; the endpoint stores the mode, so it follows |

The handshake (`AC1` + 16-byte nonce → 32-byte HMAC-SHA256 keyed by `lanToken`) is the one new wire contract. It is
written into `ArchiveProcessor/REFERENCE.md` beside the HTTP routes when the build ships.

## 8. The build, split

1. **`W40.i-usb-mac` [M]** (Tier-2: `Net/`): `Net/USBMuxBridge.swift` (codec with the byte-swapped port, the
   dedicated Listen socket, one fresh socket per tunnel, the four-tunnel pool and its 2 s top-up, 20 s idle expiry,
   the handshake answer, a splice that forwards end of stream, detach), wired from
   `CaptureSession.serverDidStart`/`serverDidStop` beside `USBBridge`; the separate throttle key for bridged
   connections; the pane and caption cable line; the S-037 QR fix and the Android empty-host parse with its test;
   the fake usbmuxd, the test driver and its script; `scripts/usbmux-probe.sh`.
2. **`W40.i-usb-app` [M]** (Tier-2: the phone's `Net/`): `Net/USBRelay.swift` (both listeners bound to 127.0.0.1,
   the handshake, the FIFO of local connections with its 10 s limit, the end-of-stream splice, re-create on
   `.active`), the Cable `URLSession` (4 per host), `MacEndpoint` Cable mode storing the mode, not the port, with an
   empty-host QR, the Connect screen's Cable option and copy, host tests. Independent of item 1, but both follow
   §2's handshake exactly. **Shipped 2026-10-31** (`Net/USBRelay.swift`, `scripts/test-ios-usb-relay.sh`).
   Ages count from a tunnel's arrival (12 s), and data is sent as complete messages with the end of stream as an
   empty final one (an incomplete message followed by a final one carrying data stalls, measured).
3. **`W40.i-usb-build` [S]** (waits on both): `e2e-phone-mac.sh --ios --cable` against the fake usbmuxd, the
   Wi-Fi E2E re-run unchanged, and the docs: README (USB local relay, both phones), `REFERENCE.md`,
   `capture.md` C-43 row and count, KNOWN_ISSUES transport notes, S-037 and S-023 history in `SUSPECTS.md`.
   `W40.i5-usb` (the pack, USB first) follows it, unchanged.
