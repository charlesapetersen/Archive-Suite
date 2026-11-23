#!/usr/bin/env python3
"""Verify headless Finish waits for a delayed relay page and files it with the first.

Run outside the Codex sandbox under the suite heavy lock with a Debug build.
See verification/evidence/processor/W49.relay-suspects-check.md for the command.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

if os.environ.get('CODEX_SANDBOX'):
    sys.exit('Run the headless Processor check outside the Codex sandbox.')

root = Path(__file__).resolve().parents[2]
binary = root / 'ArchiveProcessor/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor'
fixtures = root / 'ArchiveProcessor/scripts/e2e-fixtures'
images = [(fixtures / name).read_bytes() for name in ('doc1_memo.jpg', 'doc2_letter.jpg')]
work = Path(tempfile.mkdtemp(prefix='w49-relay-scratch-'))
print(f'artifacts: {work}', flush=True)

def wait_for(label, check, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.1)
    raise RuntimeError(f'timed out: {label}')

def atomic(path, data):
    temporary = path.with_name(f'.{path.name}.part')
    temporary.write_bytes(data)
    temporary.replace(path)

def encode(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':')).encode()

def run(name, deliver_before_finish):
    folder = work / name
    folder.mkdir()
    out = folder / 'out'
    out.mkdir()
    env = os.environ | {
        'ARCHIVEPROC_HEADLESS': '1', 'ARCHIVEPROC_TEST_BACKUP_ROOT': str(folder / 'backup'),
        'LIVECAPTURE_AUTOSTART': '1', 'LIVECAPTURE_AUTOFINALIZE': '1',
        'LIVECAPTURE_TRANSPORT': 'fileRelay', 'LIVECAPTURE_RELAYDIR': str(folder / 'relay'),
        'LIVECAPTURE_TESTOUT': str(out), 'LIVECAPTURE_READYFILE': str(folder / 'ready'),
    }
    log = (folder / 'app.log').open('wb')
    app = subprocess.Popen([str(binary), '-useAppleVision', 'YES',
                            '-visionUseLLMJudgment', 'NO', '-useGateway', 'NO', '-useLocalAgent', 'NO',
                            '-taggingModeRaw', 'none', '-rotationModeRaw', 'off',
                            '-reviewRotation', 'NO', '-liveProcessingMode', 'live', '-mergeDocuments', 'YES',
                            '-outputDirectory', str(out), '-customOCRPrompt', '', '-tagVocabulary', ''],
                           env=env,
                           stdout=log, stderr=subprocess.STDOUT)
    try:
        epoch_path = wait_for('epoch marker', lambda: next((folder / 'relay').glob('*/_epoch.json'), None))
        relay = epoch_path.parent
        marker = json.loads(epoch_path.read_bytes())
        identity = {key: marker[key] for key in ('epoch', 'token')}
        group = 'relaycheck'
        fp = hashlib.sha256(encode({'type': 'document'})).hexdigest()[:16]

        def send(seq):
            base = f'{group}__{seq}'
            atomic(relay / f'{base}.jpg', images[seq - 1])
            atomic(relay / f'{base}.json', encode(identity | {
                'kind': 'photo', 'group': group, 'seq': str(seq), 'type': 'document', 'fp': fp,
            }))
            receipt = relay / f'{base}.receipt.json'
            wait_for(f'page {seq} receipt', receipt.exists)
            assert json.loads(receipt.read_bytes())['fp'] == fp

        sender = str(uuid.uuid4())
        revision = 0

        def status(count, **overrides):
            nonlocal revision
            revision += 1
            atomic(relay / f'_phone.{sender}.status.json', encode(identity | {
                'kind': 'phone-status', 'pending': str(count), 'sender': sender, 'rev': str(revision),
            } | overrides))

        def open_groups():
            return json.loads(manifest.read_bytes())['completedDocGroups']

        def assert_finish_held(seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                assert app.poll() is None, 'Processor stopped during Finish'
                assert group not in open_groups(), 'Finish completed a group with a pending page'
                assert not done.exists() and not list(out.rglob('*.pdf')), 'Finish filed a partial PDF'
                time.sleep(.2)

        send(1)
        if deliver_before_finish:
            send(2)
            seg = relay / f'{group}.segment.json'
            atomic(seg, encode(identity | {'kind': 'segment-complete', 'group': group, 'seqs': '1,2'}))
            wait_for('segment consumed', lambda: not seg.exists())
            status(0)
        else:
            status(1)
            wait_for('Mac relay count', lambda: b'LIVECAPTURE_RELAY_PENDING 1' in (folder / 'app.log').read_bytes())
        manifest = wait_for('manifest', lambda: next((folder / 'backup').rglob('manifest.json'), None))
        completed = open_groups()
        assert (group in completed) == deliver_before_finish
        start = time.monotonic()
        atomic(relay / '_session.complete.json', encode(identity | {'kind': 'session-complete'}))
        done = out / 'DONE.txt'
        if not deliver_before_finish:
            # No further valid status for longer than the direct heartbeat's 20 s expiry.
            # A previous session or an invalid count must not release a known pending page.
            status(0, epoch='old-epoch')
            assert_finish_held(22)
            status(-1)
            assert_finish_held(2)
            send(2)
            assert any(p['seq'] == 2 for p in json.loads(manifest.read_bytes())['photos'])
            assert_finish_held(2)
            # An ended-segment snapshot can still name a page explicitly removed from the queue.
            # It must not prevent Finish from using a valid zero to complete the two retained pages.
            atomic(relay / f'{group}.segment.json', encode(identity | {
                'kind': 'segment-complete', 'group': group, 'seqs': '1,2,3',
            }))
            status(0)
        wait_for('Finish done', done.exists, 90)
        print(f'{name}: finished in {time.monotonic() - start:.2f}s, completed before Finish={completed}, {done.read_text().strip()}', flush=True)
        assert done.read_text().startswith('Finalized')
        pdfs = sorted(out.rglob('*.pdf'))
        assert len(pdfs) == 1, pdfs
        info = subprocess.check_output(['pdfinfo', str(pdfs[0])], text=True)
        pages = int(next(line for line in info.splitlines() if line.startswith('Pages:')).split()[1])
        listing = subprocess.check_output(['pdfimages', '-list', str(pdfs[0])], text=True)
        image_pages = {line.split()[0] for line in listing.splitlines()[2:] if line.strip()}
        assert pages == 4 and len(image_pages) == 2, listing
        print(f'{name}: PDF pages={pages}, source image pages={len(image_pages)}', flush=True)
    finally:
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
        log.close()

run('all-pages-before-finish', True)
run('last-page-while-finish-waits', False)
