# FarmShare access for queued work

Owner request, 2026-10-17: let managed sessions reuse the owner's existing FarmShare SSH login for
already-queued FarmShare work. A separate process successfully reused it on 2026-10-17 at about 18:04,
reaching `rice-01` as `cp1`; that observation is not a promise that the connection will remain alive.
This applies to W41.date-model, W41.seg-date-model, W43.script-specialists, W43.sweep-farmshare,
W43.corpus-build-more and W43.seg-corpus-build, within each item's existing scope and prerequisites.

## Reuse the existing login

The host is `cp1@login.farmshare.stanford.edu`; the local control socket is
`/Users/cp1/.ssh/cm-farmshare`. Select it explicitly: this Mac has no user SSH config that selects it
for an ordinary `ssh` or `scp`. Another session opens a separate remote shell through the authenticated
connection; it does not inherit the owner's terminal's working directory, variables or activated venv.
Read the kit's `ArchiveProcessor/scripts/segbench/institutional-compute/README.md` and load the existing job environment explicitly.

Run this bounded, read-only preflight before transferring data or submitting jobs:

```bash
/opt/homebrew/bin/gtimeout --foreground 15 /usr/bin/ssh \
  -S /Users/cp1/.ssh/cm-farmshare \
  -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=5 -o ProxyCommand=false \
  cp1@login.farmshare.stanford.edu 'hostname; id -un; pwd'
```

The outer timeout matters: `ConnectTimeout` alone did not bound a stalled multiplexed session here.
`ProxyCommand=false` makes a missing socket fail instead of falling back to a new network login;
`BatchMode=yes` prevents password and Duo prompts. A local `ssh -O check` only proves the master
process exists: it reported running while remote commands were stalled earlier today.

For subsequent commands, keep those same SSH options and choose an appropriate bounded timeout.
For `scp`, use `-o ControlPath=/Users/cp1/.ssh/cm-farmshare` (not SSH's `-S`, which means something
different to scp), plus `-o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=5 -o ProxyCommand=false`.
Stage only the inputs the item's existing plan calls for and retrieve its outputs. Check the existing
working directories and Slurm jobs first, so an interrupted session is resumed without duplicate jobs
or overwriting another session's work. Use Slurm for training/inference, not the login node.

If the preflight fails or times out, stop the probe, record a connection blocker for the item and
continue other eligible work. Only the owner can renew the login/Duo. Do not delete the socket,
terminate the master's process, change SSH configuration, create a new master or retry authentication
in a loop. Do not mark a dependent item complete merely because access is unavailable.

## Codex sandbox approval

The engine starts Codex with `--approve-for-me`; this project's Codex preamble still requires an
escalation for network access. Request `require_escalated` for socket access and SSH/scp operations,
with the item tag, exact host, existing socket, remote command and input/output paths in the reason.
For the preflight, explain: "Reuse the owner's existing FarmShare login for ITEM via cm-farmshare;
read only hostname, username and working directory, with no fresh-login fallback."

The owner's request supplies task context for the automatic approval reviewer. This note does not
install a persistent allow rule, guarantee approval or override a refusal. Accept the reviewer's result;
if refused, record the blocker rather than bypassing the sandbox. Do not grant blanket approval to
arbitrary SSH hosts or remote commands.

Successful socket reuse removes the need for another owner login for these queued tasks; it does not
remove another prerequisite or owner gate. Corpus safety, the hold on paid hosted benchmarking, the
spending limit, the weights-publication hold and the kit's cluster resource limits all still apply.

## Overnight availability

Owner request, 2026-10-17: keep this Mac awake so the existing SSH connection remains usable overnight.
A temporary `/usr/bin/caffeinate -is -t 57600 -w MASTER_PID` guard was started at about 18:08 on
2026-10-17, bound to the verified SSH master (then PID 56378). It ends when that master exits or after
16 hours; it does not change permanent power settings or keep the display awake. The manager's own
engine also holds a sleep assertion while it runs (currently including display sleep).

Before relying on overnight access, inspect `pmset -g assertions`, verify the live SSH master and run
the bounded remote preflight. Do not reuse a PID from this dated note: obtain it from a current
`ssh -S /Users/cp1/.ssh/cm-farmshare -O check cp1@login.farmshare.stanford.edu`.
Sleep prevention cannot preserve a broken network, renew an expired login or defeat the server's
connection policy. Keep the Mac on AC power and leave the lid open; closing it can still force sleep.
The SSH master itself may also have a finite ControlPersist interval. If access expires, record the
blocker and leave reauthentication to the owner. Submitted Slurm jobs run remotely and do not depend
on keeping a local interactive shell open; save their job IDs so the next session can find them.

## The engine's side (W46.engine-cluster)

The queue offers a `(cluster: farmshare)` item only while this preflight passes (cached five minutes), and asks the
owner to log in at most once a day when it does not. After submitting an item's jobs, record where they are:
`ops/autonomous/cluster-reach.py mark TAG submitted`, then `finished` when they end, `clear` when the item ships.
Detail: `ops/autonomous/README.md` §"Cluster items".
