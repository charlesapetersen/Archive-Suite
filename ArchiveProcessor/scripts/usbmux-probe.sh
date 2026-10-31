#!/bin/bash
# usbmux-probe.sh — is macOS's usbmuxd still speaking the protocol the iPhone cable route relies on?
# (W40.i-usb-mac; execution-plans/iphone-usb.md §4.) Read-only, no phone needed, about 50 ms:
#   ListDevices → a DeviceList · ReadBUID → a BUID · Listen → Result 0 · Connect to a device that does not
#   exist → Result 2 (BadDevice).
# The protocol is private. If a macOS update changes it, only the cable route breaks (the pane says "Cable
# route unavailable"); this probe is how that is caught without a phone.
# Usage: usbmux-probe.sh [SOCKET]   (default /var/run/usbmuxd; a fake-usbmuxd.py socket works too)
set -euo pipefail
exec /usr/bin/python3 - "${1:-/var/run/usbmuxd}" <<'PY'
import plistlib, socket, struct, sys

path = sys.argv[1]

def ask(msg, tag):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(path)
    base = {"ClientVersionString": "usbmux-probe", "ProgName": "usbmux-probe", "kLibUSBMuxVersion": 3}
    body = plistlib.dumps({**base, **msg}, fmt=plistlib.FMT_XML)
    s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body)
    head = b""
    while len(head) < 16:
        chunk = s.recv(16 - len(head))
        if not chunk:
            raise RuntimeError("closed before a reply header")
        head += chunk
    length, version, kind, rtag = struct.unpack("<IIII", head)
    if version != 1 or kind != 8 or rtag != tag:
        raise RuntimeError("unexpected header: version %d type %d tag %d" % (version, kind, rtag))
    data = b""
    while len(data) < length - 16:
        chunk = s.recv(length - 16 - len(data))
        if not chunk:
            raise RuntimeError("closed mid-reply")
        data += chunk
    s.close()
    return plistlib.loads(data)

fails = []
def check(name, ok, detail=""):
    print("%s: %s%s" % ("PASS" if ok else "FAIL", name, (" — " + detail) if detail else ""))
    if not ok:
        fails.append(name)

try:
    r = ask({"MessageType": "ListDevices"}, 1)
    check("ListDevices returns a DeviceList", isinstance(r.get("DeviceList"), list),
          "%d device(s)" % len(r.get("DeviceList", [])))
    r = ask({"MessageType": "ReadBUID"}, 2)
    check("ReadBUID returns a BUID", isinstance(r.get("BUID"), str) and bool(r.get("BUID")))
    r = ask({"MessageType": "Listen"}, 3)
    check("Listen returns Result 0", r.get("MessageType") == "Result" and r.get("Number") == 0, str(r))
    r = ask({"MessageType": "Connect", "DeviceID": 0x7FFF0000, "PortNumber": socket.htons(48628)}, 4)
    check("Connect to no such device returns Result 2", r.get("MessageType") == "Result" and r.get("Number") == 2,
          str(r))
except (OSError, RuntimeError, plistlib.InvalidFileException) as e:
    check("usbmuxd answers at %s" % path, False, str(e))

print("ALL PASS" if not fails else "SOME FAILED")
sys.exit(1 if fails else 0)
PY
