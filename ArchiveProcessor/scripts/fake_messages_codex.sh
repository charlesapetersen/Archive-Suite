#!/bin/sh
# No network. The message journey gives this stand-in a private directory for its clock and call log.
set -eu
cd "$AP_MESSAGE_CLI_DIR"
/bin/cat >/dev/null
now=$(/bin/date +%s)
if [ ! -f reset ]; then
    echo "$((now + 90))" > reset
fi
reset=$(/bin/cat reset)
echo "$now" >> cli-calls
if [ "$now" -lt "$reset" ]; then
    echo "Error: usage limit reached|$reset" >&2
    exit 1
fi
printf 'A synthetic archival page.\n'
