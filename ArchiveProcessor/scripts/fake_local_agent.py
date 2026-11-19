#!/usr/bin/python3
"""W40.d2 — a stand-in `claude` CLI for the Local Agent backend, so the review-dialog journey runs for $0 with no key.

The app spawns it as it spawns `claude -p --output-format json …` (`OCR/LocalAgentClient.swift`): the prompt arrives
on stdin and the reply goes to stdout as `{"result": …}`. The replies are fake_gateway.py's: an OCR prompt gets the
app's OCR format with every page classed FAKE_AGENT_CLASS (default `document_start`) and `[rotate_0]`, a tagging
prompt gets the tag JSON, anything else (the probe, dating, item fields) gets `ok`. So every choice the journey's
dialogs show is the stand-in's and every change to it is the test's hand. Each call is one line in FAKE_AGENT_LOG,
when set. The app passes its own environment on, which is how the UI test sets both. It runs in the VM guest only,
reads nothing but stdin and sends nothing anywhere.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from fake_gateway import answer  # noqa: E402

text = sys.stdin.read()
kind, reply = answer(text, os.environ.get('FAKE_AGENT_CLASS', 'document_start'), os.getpid())
log = os.environ.get('FAKE_AGENT_LOG')
if log:
    with open(log, 'a', encoding='utf-8') as f:
        f.write(f'{kind}\t{" ".join(text.split())[:90]}\n')
print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': reply}))
