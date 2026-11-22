#!/usr/bin/env python3
"""Compare filed sheets when a relay page arrives before or after headless Finish.

Run outside the Codex sandbox under the suite heavy lock with a Debug build.
See verification/evidence/processor/W49.relay-suspects-check.md for the command.
This records the S-038 failure at the baseline. The fix should turn the late
case into a regression that waits before filing.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

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

        send(1)
        if deliver_before_finish:
            send(2)
            seg = relay / f'{group}.segment.json'
            atomic(seg, encode(identity | {'kind': 'segment-complete', 'group': group, 'seqs': '1,2'}))
            wait_for('segment consumed', lambda: not seg.exists())
        manifest = wait_for('manifest', lambda: next((folder / 'backup').rglob('manifest.json'), None))
        completed = json.loads(manifest.read_bytes())['completedDocGroups']
        assert (group in completed) == deliver_before_finish
        start = time.monotonic()
        atomic(relay / '_session.complete.json', encode(identity | {'kind': 'session-complete'}))
        done = out / 'DONE.txt'
        wait_for('Finish done', done.exists, 90)
        print(f'{name}: finished in {time.monotonic() - start:.2f}s, completed before Finish={completed}, {done.read_text().strip()}', flush=True)
        assert done.read_text().startswith('Finalized')
        pdfs = sorted(out.rglob('*.pdf'))
        assert len(pdfs) == 1, pdfs
        info = subprocess.check_output(['pdfinfo', str(pdfs[0])], text=True)
        pages = int(next(line for line in info.splitlines() if line.startswith('Pages:')).split()[1])
        listing = subprocess.check_output(['pdfimages', '-list', str(pdfs[0])], text=True)
        image_pages = {line.split()[0] for line in listing.splitlines()[2:] if line.strip()}
        assert len(image_pages) == (2 if deliver_before_finish else 1), listing
        print(f'{name}: PDF pages={pages}, source image pages={len(image_pages)}', flush=True)
        if not deliver_before_finish:
            before = pdfs[0].read_bytes()
            send(2)
            state = json.loads(manifest.read_bytes())
            late = [p for p in state['photos'] if p['seq'] == 2]
            assert late and group in state['filedGroupIds'], state
            backup_files = sorted(path.name for path in (folder / 'backup').rglob('*.jpg'))
            assert any(path.startswith('000002-') for path in backup_files), backup_files
            assert sorted(out.rglob('*.pdf')) == pdfs and pdfs[0].read_bytes() == before
            print(f'{name}: page 2 receipted; backup={backup_files}; filedGroupIds={state["filedGroupIds"]}; PDF unchanged', flush=True)
    finally:
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
        log.close()

run('all-pages-before-finish', True)
run('last-page-after-finish', False)
