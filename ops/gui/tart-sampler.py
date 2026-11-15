#!/usr/bin/env python3
"""Launch and stop only the VM load sampler's owned process group, in the caller's session."""
import os
import signal
import subprocess
import sys
import time


def processes():
    # A failed inspection never authorizes signalling. Bound ps as well as shutdown.
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,stat="],
                            check=True, capture_output=True, text=True, timeout=1)
    return {int(pid): (int(parent), int(group), state)
            for pid, parent, group, state in (line.split() for line in result.stdout.splitlines())}


def stop(pid, parent):
    if pid <= 1 or parent <= 1 or os.getppid() != parent:
        raise RuntimeError("invalid sampler owner")
    owned_group = False
    sent_term = False
    for sig in (signal.SIGTERM, signal.SIGKILL):
        deadline = time.monotonic() + 2
        while True:
            rows = processes()
            root = rows.get(pid)
            if root is not None:
                if root[0] != parent:
                    raise RuntimeError(f"sampler PID {pid} is not a child of {parent}; refusing signal")
                if root[1] == pid:
                    owned_group = True
                elif owned_group or root[1] != rows[parent][1]:
                    raise RuntimeError("sampler changed process group; refusing signal")
            elif not owned_group and any(group == pid and "Z" not in state
                                         for _, group, state in rows.values()):
                raise RuntimeError("sampler leader missing before ownership verified; refusing signal")
            live_group = owned_group and any(group == pid and "Z" not in state
                                             for _, group, state in rows.values())
            live_root = root is not None and "Z" not in root[2]
            if not live_root and not live_group:
                return
            # Before the bootstrap establishes its group, TERM may only target the direct child.
            # Once validated, retain group ownership through leader exit to reap stubborn descendants.
            if sig == signal.SIGKILL or not sent_term or owned_group:
                try:
                    if owned_group:
                        os.killpg(pid, sig)
                    elif live_root:
                        os.kill(pid, sig)
                except ProcessLookupError:
                    pass
                sent_term = True
            if time.monotonic() >= deadline:
                break
            time.sleep(.05)
        if sig == signal.SIGTERM:
            print(f"VM sampler {pid}: TERM grace expired; killing owned sampler processes", file=sys.stderr)
    raise RuntimeError(f"sampler {pid} survived bounded shutdown")


def main():
    if sys.argv[1] == "run":
        # Keep the heavy supervisor's session, but isolate signals from the VM/test runner. $! remains
        # the exec'd shell's PID. TERM can already be pending: establish the group before unblocking it.
        os.setpgid(0, 0)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
        os.execvp(sys.argv[2], sys.argv[2:])
    elif sys.argv[1] == "stop":
        stop(int(sys.argv[2]), int(sys.argv[3]))
    else:
        raise ValueError("expected run or stop")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"VM sampler: {error}", file=sys.stderr)
        sys.exit(1)
