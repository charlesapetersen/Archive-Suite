#!/usr/bin/env python3
"""A stand-in for macOS's usbmuxd, for the iPhone cable route's tests (W40.i-usb-mac).

Speaks usbmuxd's plist framing on a Unix socket: a 16-byte little-endian header (total length, version 1,
type 8, tag) and an XML plist. It answers `Listen` (then reports each attached device as `Attached`),
`ListDevices`, `ReadBUID` and `Connect`. A `Connect` is satisfied by connecting to 127.0.0.1 on the port it
decodes from `PortNumber` WITH the network-byte-order swap, so a bridge that sends the port unswapped
reaches the wrong port and fails its test instead of passing it. After `Result 0` the client socket is a
raw pipe to that port; each side's end of stream is forwarded as a half-close.

Test controls arrive on the same socket as extra message types, each answered with `Result 0`:
  FakeAttach {DeviceID, ConnectionType}   add a device (ConnectionType "USB" or "Network")
  FakeDetach {DeviceID}                   remove it, close its pipes, tell listeners
  FakeStats                               reply {ConnectsByDevice: {"<id>": n}, Refused: n, Pipes: n}

Usage: fake-usbmuxd.py SOCKET_PATH [--attach ID:USB ...]
Read-only on the Mac apart from its own socket file, which it removes on exit.
"""
import os
import plistlib
import signal
import socket
import struct
import sys
import threading

lock = threading.Lock()
devices = {}          # id -> connection type
listeners = []        # client sockets that sent Listen
pipes = {}            # id -> list of (client, upstream)
connects = {}         # id -> Connect count
refused = [0]


def frame(msg, tag):
    body = plistlib.dumps(msg, fmt=plistlib.FMT_XML)
    return struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_msg(sock):
    head = read_exact(sock, 16)
    if head is None:
        return None, 0
    length, version, kind, tag = struct.unpack("<IIII", head)
    if version != 1 or kind != 8 or length < 16 or length > 1 << 20:
        return None, 0
    body = read_exact(sock, length - 16)
    if body is None:
        return None, 0
    return plistlib.loads(body), tag


def attached_msg(dev_id, kind):
    return {"MessageType": "Attached", "DeviceID": dev_id,
            "Properties": {"ConnectionType": kind, "DeviceID": dev_id, "SerialNumber": "FAKE%04d" % dev_id}}


def notify(msg):
    with lock:
        targets = list(listeners)
    for s in targets:
        try:
            s.sendall(frame(msg, 0))
        except OSError:
            pass


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def attach(dev_id, kind):
    with lock:
        devices[dev_id] = kind
    notify(attached_msg(dev_id, kind))


def detach(dev_id):
    with lock:
        devices.pop(dev_id, None)
        dead = pipes.pop(dev_id, [])
    for a, b in dead:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
    notify({"MessageType": "Detached", "DeviceID": dev_id})


def serve(client):
    try:
        while True:
            msg, tag = read_msg(client)
            if msg is None:
                break
            kind = msg.get("MessageType")
            if kind == "Listen":
                client.sendall(frame({"MessageType": "Result", "Number": 0}, tag))
                with lock:
                    listeners.append(client)
                    current = list(devices.items())
                for dev_id, ctype in current:
                    client.sendall(frame(attached_msg(dev_id, ctype), 0))
                continue   # a Listen socket stays open for events
            if kind == "ListDevices":
                with lock:
                    current = list(devices.items())
                client.sendall(frame({"DeviceList": [attached_msg(i, k) for i, k in current]}, tag))
            elif kind == "ReadBUID":
                client.sendall(frame({"BUID": "FAKE-BUID"}, tag))
            elif kind == "Connect":
                dev_id = msg.get("DeviceID")
                port = socket.ntohs(int(msg.get("PortNumber", 0)) & 0xFFFF)
                with lock:
                    connects[dev_id] = connects.get(dev_id, 0) + 1
                    known = dev_id in devices
                if not known:
                    client.sendall(frame({"MessageType": "Result", "Number": 2}, tag))
                    break
                try:
                    upstream = socket.create_connection(("127.0.0.1", port), timeout=1)
                    upstream.settimeout(None)
                except OSError:
                    with lock:
                        refused[0] += 1
                    client.sendall(frame({"MessageType": "Result", "Number": 3}, tag))
                    break
                client.sendall(frame({"MessageType": "Result", "Number": 0}, tag))
                with lock:
                    pipes.setdefault(dev_id, []).append((client, upstream))
                t = threading.Thread(target=pump, args=(upstream, client), daemon=True)
                t.start()
                pump(client, upstream)
                t.join()
                upstream.close()
                with lock:
                    if (client, upstream) in pipes.get(dev_id, []):
                        pipes[dev_id].remove((client, upstream))
                return
            elif kind == "FakeAttach":
                attach(int(msg["DeviceID"]), msg.get("ConnectionType", "USB"))
                client.sendall(frame({"MessageType": "Result", "Number": 0}, tag))
            elif kind == "FakeDetach":
                detach(int(msg["DeviceID"]))
                client.sendall(frame({"MessageType": "Result", "Number": 0}, tag))
            elif kind == "FakeStats":
                with lock:
                    stats = {"ConnectsByDevice": {str(k): v for k, v in connects.items()},
                             "Refused": refused[0], "Pipes": sum(len(v) for v in pipes.values())}
                client.sendall(frame(stats, tag))
            else:
                client.sendall(frame({"MessageType": "Result", "Number": 1}, tag))
    except OSError:
        pass
    finally:
        with lock:
            if client in listeners:
                listeners.remove(client)
        try:
            client.close()
        except OSError:
            pass


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    args = sys.argv[2:]
    while args:
        if args[0] == "--attach" and len(args) > 1:
            dev, _, kind = args[1].partition(":")
            devices[int(dev)] = kind or "USB"
            args = args[2:]
        else:
            print("unknown argument: %s" % args[0], file=sys.stderr)
            return 2
    if os.path.exists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(64)

    def bye(*_):
        try:
            os.unlink(path)
        finally:
            os._exit(0)
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    print("FAKE_USBMUXD_READY %s" % path, flush=True)
    while True:
        client, _ = server.accept()
        threading.Thread(target=serve, args=(client,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
