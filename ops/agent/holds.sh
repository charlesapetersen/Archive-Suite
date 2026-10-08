#!/usr/bin/env bash
# holds hook: pending owner items as JSON lines (HOLD QUEUE, [hold] items, unwalked Daemon Report). See hooks.py.
exec /usr/bin/python3 "$(dirname "${BASH_SOURCE[0]}")/hooks.py" holds
