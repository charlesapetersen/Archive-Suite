#!/usr/bin/env python3
"""A plain TCP relay: listen on 127.0.0.1:<port>, forward each connection to <host>:<port>.

W40.d5: the Android emulator reaches the host's loopback as 10.0.2.2, but the Mac app under test runs in the
Tart GUI VM, on its own address. This bridges the two so the emulator's LAN pairing reaches the VM unchanged.
socat is not installed on this machine, and this is all of socat the journey needs.

The direct route to the VM's 192.168.64.x address fails here with "No route to host" (measured 2026-10-21:
macOS's Local Network privacy check refuses it for this process tree), so the target may instead be
`tart:<vm>`: each connection is then carried over the Tart guest agent by `tart exec -i <vm> nc 127.0.0.1
<port>`, which needs no network route to the guest at all.

Usage: tcp-relay.py <listen-port> <target-host | tart:VM> [<target-port>]   (runs until killed)
"""
import asyncio
import sys


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


async def main(listen_port, host, port):
    async def handle(cr, cw):
        if host.startswith("tart:"):
            proc = await asyncio.create_subprocess_exec(
                "tart", "exec", "-i", host[5:], "nc", "127.0.0.1", str(port),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
            await asyncio.gather(pipe(cr, proc.stdin), pipe(proc.stdout, cw))
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            await proc.wait()
            return
        try:
            tr, tw = await asyncio.open_connection(host, port)
        except OSError as e:
            print(f"[relay] cannot reach {host}:{port}: {e}", flush=True)
            cw.close()
            return
        await asyncio.gather(pipe(cr, tw), pipe(tr, cw))

    server = await asyncio.start_server(handle, "127.0.0.1", listen_port)
    print(f"[relay] 127.0.0.1:{listen_port} -> {host}:{port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    lp = int(sys.argv[1])
    asyncio.run(main(lp, sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else lp))
