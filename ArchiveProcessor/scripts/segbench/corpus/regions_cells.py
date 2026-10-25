#!/usr/bin/env python3
"""W46.ocr-regions-cells: a frozen, oracle-box pilot, not a detector benchmark.

freeze --root PACK --truth DRAFT --routes PARENT/routes.json
check --root PACK
read --root PACK --route glm-ocr|qwen3.6-27b [--arm whole|table|cell]
score --root PACK --out REPORT.json

PACK/images already contains the exact parent-run JPEGs. DRAFT is a private JSON
object with audited pages/tables/cells; null is unknown, '' is a verified blank.
Freezing writes truth.json then freeze.json (checksums, geometry and protocol).
All three arms use the SAME field extraction prompt, with oracle field boxes and
no truth text or blank flags. These fresh whole-page controls are required: the
parent's native-OCR prose replies cannot support field-level accuracy. No paid
route, detector, subscription call or remote cluster command is implemented here.
Only the read command contacts a server, and it must be a loopback HTTP server.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import io
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlsplit

import regions_cluster as C

PROTOCOL = 'oracle-cells-v1'
ROUTES = ('glm-ocr', 'qwen3.6-27b')
ARMS = ('whole', 'table', 'cell')
MAX_TOKENS = 4096
REQUEST_TIMEOUT = 90
INSTRUCTION = (
    'Transcribe only the specified rectangular fields from this image. Coordinates '
    'are [left,top,right,bottom] fractions of this image. Each field id is arbitrary. '
    'Preserve visible spelling, punctuation, numbers and abbreviations; do not expand '
    'ditto marks or infer missing values. Ignore bleed-through from the reverse. '
    'Return exactly one JSON object mapping every requested id to its transcription '
    'as a string. Use an empty string for a blank field; use [illegible] for text you '
    'cannot read. No Markdown, explanation, extra keys or invented text. Fields: '
)


def encoded(obj):
    return (json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unique_pairs(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError(f'duplicate JSON key: {k}')
        out[k] = v
    return out


def loads(text):
    return json.loads(text, object_pairs_hook=unique_pairs,
                      parse_constant=lambda x: (_ for _ in ()).throw(ValueError(f'nonfinite JSON: {x}')))


def load(path):
    return loads(path.read_text())


def write_new(path, data):
    """An identical repeat is safe; never overwrite a frozen input or a receipt."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError(f'refusing changed existing file: {path}')
        return
    # Publish only a complete file, without replacing another writer's receipt.
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name, suffix='.part', delete=False) as f:
        tmp = Path(f.name)
        try:
            f.write(data); f.flush(); os.fsync(f.fileno())
            try:
                os.link(tmp, path)
            except FileExistsError:
                if path.read_bytes() != data:
                    raise ValueError(f'refusing changed existing file: {path}')
        finally:
            tmp.unlink(missing_ok=True)


def box_ok(box):
    return (isinstance(box, list) and len(box) == 4
            and all(type(v) in (int, float) and math.isfinite(v) for v in box)
            and 0 <= box[0] < box[2] <= 1 and 0 <= box[1] < box[3] <= 1)


def contains(outer, inner):
    return outer[0] <= inner[0] < inner[2] <= outer[2] and outer[1] <= inner[1] < inner[3] <= outer[3]


def safe_id(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_-]+', value) is not None


def validate(truth, root):
    from PIL import Image
    if truth.get('protocol') != PROTOCOL or not truth.get('audit') or not truth.get('pages'):
        raise ValueError('missing protocol, audit or pages')
    ids = set()
    capability = []
    for p in truth['pages']:
        pid = p['id']
        if not safe_id(pid) or pid in ids:
            raise ValueError('unsafe/duplicate page id')
        ids.add(pid)
        if type(p.get('capability')) is not bool:
            raise ValueError('each page needs a frozen capability selection')
        if p['capability']:
            capability.append(p['set'])
        if p['set'] not in ('L4', 'owner96') or not p.get('tables'):
            raise ValueError(f'{pid}: missing set or tables')
        image = root / 'images' / (pid + '.jpg')
        if digest(image.read_bytes()) != p['sha256']:
            raise ValueError(f'{pid}: image hash mismatch')
        with Image.open(image) as im:
            if list(im.size) != p['size']:
                raise ValueError(f'{pid}: image dimensions mismatch')
        tids = set()
        for t in p['tables']:
            if not safe_id(t['id']) or t['id'] in tids or not box_ok(t['box']) or not t['cells']:
                raise ValueError(f'{pid}: invalid table')
            tids.add(t['id']); cids = set()
            for c in t['cells']:
                if (not safe_id(c['id']) or c['id'] in cids or not box_ok(c['box'])
                        or not contains(t['box'], c['box'])):
                    raise ValueError(f'{pid}/{t["id"]}: invalid cell')
                cids.add(c['id'])
                if c['id'] == 'all':
                    raise ValueError('all is a reserved output filename')
                if c['role'] not in ('heading', 'entry') or c['medium'] not in ('print', 'hand', 'unknown'):
                    raise ValueError('role and writing medium are independent required labels')
                if c['type'] not in ('free_text', 'formatted', 'discrete'):
                    raise ValueError('invalid field type')
                if c['value'] is not None and not isinstance(c['value'], str):
                    raise ValueError('truth value must be a string or null (unknown)')
                if c['value'] is None and not c.get('unknown_reason'):
                    raise ValueError('unknown truth needs a reason')
                if not c.get('reviewed'):
                    raise ValueError('every cell must be visually reviewed before freeze')
                pixel_box(c['box'], p['size'])
    if sorted(capability) != ['L4', 'owner96']:
        raise ValueError('capability pilot needs exactly one page from each set')
    return truth


def freeze(root, draft, routes):
    truth = validate(load(draft), root)
    spec = load(routes)
    spec = {r: {k: spec[r][k] for k in ('model', 'served', 'vllm_args')} for r in ROUTES}
    inputs = {}
    for arm in ARMS:
        for p, t, fields, box, key in tasks(truth, arm, 'all'):
            path, px = input_path(root, p, box)
            jpeg, size = C.jpeg_crop((root / 'images' / (p['id'] + '.jpg')).read_bytes(), px)
            write_new(path, jpeg)
            inputs[str(path.relative_to(root))] = digest(jpeg)
    receipt = {'protocol': PROTOCOL, 'truth_sha256': digest(encoded(truth)),
               'routes': spec, 'max_tokens': MAX_TOKENS, 'jpeg_quality': 95,
               'instruction_sha256': digest(INSTRUCTION.encode()), 'arms': list(ARMS),
               'request_timeout_s': REQUEST_TIMEOUT, 'code_sha256': code_hashes(), 'inputs_sha256': inputs}
    write_new(root / 'truth.json', encoded(truth))
    write_new(root / 'freeze.json', encoded(receipt))
    return receipt


def check(root):
    frozen = load(root / 'freeze.json')
    if (frozen['protocol'] != PROTOCOL or frozen['max_tokens'] != MAX_TOKENS
            or frozen['instruction_sha256'] != digest(INSTRUCTION.encode())
            or frozen['jpeg_quality'] != 95 or frozen['arms'] != list(ARMS)
            or frozen['request_timeout_s'] != REQUEST_TIMEOUT
            or set(frozen['routes']) != set(ROUTES) or frozen['code_sha256'] != code_hashes()):
        raise ValueError('frozen request protocol differs from this script')
    if digest((root / 'truth.json').read_bytes()) != frozen['truth_sha256']:
        raise ValueError('frozen truth changed')
    truth = validate(load(root / 'truth.json'), root)
    expected = {str(input_path(root, p, box)[0].relative_to(root))
                for arm in ARMS for p, t, fields, box, key in tasks(truth, arm, 'all')}
    if set(frozen['inputs_sha256']) != expected:
        raise ValueError('frozen input inventory differs from truth')
    for name in expected:
        if digest((root / name).read_bytes()) != frozen['inputs_sha256'][name]:
            raise ValueError(f'frozen JPEG input changed: {name}')
    return frozen, truth


def code_hashes():
    return {p.name: digest(p.read_bytes()) for p in (Path(__file__), Path(C.__file__))}


def pixel_box(box, size):
    # No padding/minimum-side expansion: a narrow cell must not acquire its neighbour's ink.
    w, h = size
    px = [round(box[0] * w), round(box[1] * h), round(box[2] * w), round(box[3] * h)]
    if px[0] >= px[2] or px[1] >= px[3]:
        raise ValueError('cell is smaller than one image pixel')
    return px


def tasks(truth, arm, phase='capability'):
    for p in truth['pages']:
        if phase == 'capability' and not p['capability']:
            continue
        for t in p['tables']:
            groups = [[c] for c in t['cells']] if arm == 'cell' else [t['cells']]
            for fields in groups:
                box = [0, 0, 1, 1] if arm == 'whole' else fields[0]['box'] if arm == 'cell' else t['box']
                key = fields[0]['id'] if arm == 'cell' else 'all'
                yield p, t, fields, box, key


def input_path(root, page, box):
    px = pixel_box(box, page['size'])
    return root / 'inputs' / page['id'] / ('-'.join(str(x) for x in px) + '.jpg'), px


def request(root, task, served):
    p, t, fields, box, key = task
    path, px = input_path(root, p, box)
    jpeg = path.read_bytes()
    size = [px[2] - px[0], px[3] - px[1]]
    # Use actual rounded crop coordinates, not idealised fractions, for all remapped boxes.
    w, h = p['size']; x0, y0, x1, y1 = px
    locations = {}
    for c in fields:
        cx0, cy0, cx1, cy1 = pixel_box(c['box'], p['size'])
        locations[c['id']] = [round((cx0 - x0) / (x1 - x0), 6), round((cy0 - y0) / (y1 - y0), 6),
                              round((cx1 - x0) / (x1 - x0), 6), round((cy1 - y0) / (y1 - y0), 6)]
        if not box_ok(locations[c['id']]):
            raise ValueError('rounded field is outside its crop')
    # No roles, medium, value types, transcriptions, nulls or blank indicators leave the pack.
    prompt = INSTRUCTION + json.dumps(locations, separators=(',', ':'))
    body = C.body(prompt, jpeg, served)
    meta = {'page': p['id'], 'table': t['id'], 'key': key, 'image_sha256': p['sha256'],
            'px': px, 'sent_size': size, 'sent_sha256': digest(jpeg), 'prompt_sha256': digest(prompt.encode()),
            'request_sha256': digest(encoded(body)), 'fields': list(locations)}
    return body, meta


def parse_prediction(raw, expected):
    raw = raw.strip()
    if raw.startswith('```json\n') and raw.endswith('\n```'):
        raw = raw[8:-4]
    obj = loads(raw)
    if not isinstance(obj, dict) or any(not isinstance(v, str) for v in obj.values()):
        raise ValueError('expected an object of string field values')
    extra = set(obj) - set(expected)
    # Extra keys are counted separately, not silently dropped from the hallucination audit.
    return {k: obj.get(k) for k in expected}, {k: obj[k] for k in extra}


def server_url(value):
    u = urlsplit(value)
    if (u.scheme != 'http' or u.hostname not in ('127.0.0.1', 'localhost', '::1') or u.username
            or u.password or u.path or u.query or u.fragment or not u.port):
        raise ValueError('FS_URL must be a loopback HTTP server with an explicit port')
    return value


def runtime_check(runtime, route, frozen):
    spec = frozen['routes'][route]
    if (any(runtime.get(k) != spec[k] for k in ('model', 'served', 'vllm_args'))
            or not re.fullmatch(r'[0-9a-f]{40}', runtime.get('revision', ''))
            or not runtime.get('vllm_version') or not runtime.get('transformers_version')
            or runtime.get('code_sha256') != frozen['code_sha256']):
        raise ValueError('runtime does not establish frozen route, revision, versions and code')


def read(root, route, arm, url, runtime, phase='capability'):
    frozen, truth = check(root)
    url = server_url(url)
    spec = frozen['routes'][route]
    runtime_check(runtime, route, frozen)
    failures = 0; sent = 0; start = time.time()
    for task in tasks(truth, arm, phase):
        body, meta = request(root, task, spec['served'])
        dest = root / 'out' / route / arm / meta['page'] / meta['table'] / (meta['key'] + '.json')
        identity = {**meta, 'route': route, 'model': spec['model'], 'arm': arm,
                    'truth_sha256': frozen['truth_sha256'], 'protocol': PROTOCOL}
        if dest.exists():
            rec = load(dest)
            runtime_check(rec.get('runtime', {}), route, frozen)
            if (any(rec.get(k) != v for k, v in identity.items())
                    or stable_runtime(rec['runtime']) != stable_runtime(runtime)):
                raise ValueError(f'stale receipt: {dest}')
            failures += rec['status'] != 'ok'
            continue
        t0 = time.time()
        rec = {**identity, 'job': os.environ.get('SLURM_JOB_ID'), 'runtime': runtime}
        try:
            raw, finish, usage = C.post(url, body, timeout=REQUEST_TIMEOUT)
            rec.update(raw=raw, finish=finish, usage=usage, status='ok' if finish == 'stop' else 'cap')
            if finish == 'stop':
                try:
                    parse_prediction(raw, meta['fields'])
                except ValueError as e:
                    rec.update(status='parse', error=str(e))
        except (OSError, ValueError, http.client.HTTPException) as e:
            rec.update(raw='', finish=None, usage={}, status='error', error=str(e)[:500])
        rec['wall_s'] = round(time.time() - t0, 3)
        write_new(dest, encoded(rec)); sent += 1
        failures += rec['status'] != 'ok'
        print(route, arm, meta['page'], meta['table'], meta['key'], rec['status'], flush=True)
    summary = {'route': route, 'arm': arm, 'sent': sent, 'failures': failures,
               'wall_s': round(time.time() - start, 3), 'job': os.environ.get('SLURM_JOB_ID')}
    print(json.dumps(summary), flush=True)
    # Caps and malformed replies are outcomes: do not truncate the remaining arms in a shell set -e loop.
    return summary


def norm(s):
    return ' '.join(s.casefold().split())


def stable_runtime(runtime):
    return {k: v for k, v in runtime.items() if k != 'job'}


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        new = [i]
        for j, y in enumerate(b, 1):
            new.append(min(row[j] + 1, new[j - 1] + 1, row[j - 1] + (x != y)))
        row = new
    return row[-1]


def metrics(cells, pred):
    known = [c for c in cells if c['value'] is not None]
    filled = [c for c in known if norm(c['value'])]
    blank = [c for c in known if not norm(c['value'])]
    exact = lambda cs: (sum(pred.get(c['id']) is not None and norm(pred[c['id']]) == norm(c['value']) for c in cs)
                        / len(cs) if cs else None)
    free = [c for c in filled if c['type'] == 'free_text']
    def err(words):
        refs = [norm(c['value']).split() if words else norm(c['value']) for c in free]
        hyps = [norm(pred.get(c['id']) or '').split() if words else norm(pred.get(c['id']) or '') for c in free]
        denom = sum(len(r) for r in refs)
        edits = sum(distance(r, h) for r, h in zip(refs, hyps))
        return {'edits': edits, 'reference': denom, 'rate': edits / denom if denom else None}
    return {'fields': len(cells), 'known': len(known), 'unknown': len(cells) - len(known),
            'filled': len(filled), 'blank': len(blank), 'exact': exact(known), 'filled_exact': exact(filled),
            'formatted_exact': exact([c for c in filled if c['type'] == 'formatted']),
            'discrete_exact': exact([c for c in filled if c['type'] == 'discrete']),
            'free_text_wer': err(True), 'free_text_cer': err(False), 'blank_exact': exact(blank),
            'blank_fabrication_rate': (sum(bool(norm(pred.get(c['id']) or '')) for c in blank) / len(blank)
                                       if blank else None),
            'blank_fabrication_among_responses': (sum(bool(norm(pred.get(c['id']) or '')) for c in blank)
                / sum(pred.get(c['id']) is not None for c in blank)
                if any(pred.get(c['id']) is not None for c in blank) else None),
            'blank_responded': sum(pred.get(c['id']) is not None for c in blank),
            'blank_fabricated': sum(bool(norm(pred.get(c['id']) or '')) for c in blank),
            'known_responded': sum(pred.get(c['id']) is not None for c in known),
            'missing': sum(pred.get(c['id']) is None for c in known)}


def score(root, phase='capability'):
    frozen, truth = check(root)
    rows = []; aggregates = {}; runtime_by_route = {}
    for route in ROUTES:
        for arm in ARMS:
            for p, t, fields, box, key in tasks(truth, arm, phase):
                body, meta = request(root, (p, t, fields, box, key), frozen['routes'][route]['served'])
                path = root / 'out' / route / arm / p['id'] / t['id'] / (key + '.json')
                if not path.exists():
                    raise ValueError(f'incomplete collection: {path}')
                rec = load(path)
                runtime_check(rec.get('runtime', {}), route, frozen)
                runtime = rec['runtime']
                # A resumed job can change its id; the actual model revision, args and versions may not drift.
                stable = stable_runtime(runtime)
                if runtime_by_route.setdefault(route, stable) != stable:
                    raise ValueError('mixed runtimes for one reader')
                expected = {**meta, 'route': route, 'model': frozen['routes'][route]['model'], 'arm': arm,
                            'truth_sha256': frozen['truth_sha256'], 'protocol': PROTOCOL}
                if any(rec.get(k) != v for k, v in expected.items()):
                    raise ValueError(f'receipt differs from frozen request: {path}')
                status = rec['status']
                if status not in ('ok', 'cap', 'error', 'parse'):
                    raise ValueError(f'unknown receipt status: {path}')
                if status == 'ok':
                    if rec.get('finish') != 'stop':
                        raise ValueError('successful receipt did not stop')
                    pred, extra = parse_prediction(rec['raw'], meta['fields'])
                else:
                    pred, extra = {}, {}
                    if status in ('cap', 'parse') and rec.get('finish') == 'stop' and status == 'cap':
                        raise ValueError('cap receipt has successful finish')
                # A failed request is missing, even on verified blanks (not a correct abstention).
                splits = {'all': fields}
                for name, role, medium in (('printed_headings', 'heading', 'print'),
                                           ('handwritten_entries', 'entry', 'hand')):
                    splits[name] = [c for c in fields if c['role'] == role and c['medium'] == medium]
                for axis in ('role', 'medium', 'type'):
                    for value in sorted({c[axis] for c in fields}):
                        splits[axis + ':' + value] = [c for c in fields if c[axis] == value]
                for group, cells in splits.items():
                    rows.append({'route': route, 'arm': arm, 'page': p['id'], 'set': p['set'],
                                 'table': t['id'], 'key': key, 'group': group, 'status': status,
                                 'extra_keys': len(extra) if group == 'all' else 0,
                                 **metrics(cells, pred)})
                    for set_name in (p['set'], 'both'):
                        agg = aggregates.setdefault((route, arm, set_name, group),
                                                    {'cells': [], 'pred': {}, 'extra_keys': 0})
                        for c in cells:
                            cid = p['id'] + '/' + t['id'] + '/' + c['id']
                            agg['cells'].append({**c, 'id': cid})
                            agg['pred'][cid] = pred.get(c['id'])
                        agg['extra_keys'] += len(extra) if group == 'all' else 0
    summary = [{'route': r, 'arm': a, 'set': s, 'group': g, 'extra_keys': v['extra_keys'],
                **metrics(v['cells'], v['pred'])} for (r, a, s, g), v in aggregates.items()]
    statuses = {r: {a: {status: sum(x['status'] == status for x in rows
                                   if x['route'] == r and x['arm'] == a and x['group'] == 'all')
                        for status in ('ok', 'cap', 'parse', 'error')} for a in ARMS} for r in ROUTES}
    gates = {}
    for route in ROUTES:
        relevant = [x for x in rows if x['route'] == route and x['group'] == 'all']
        gates[route] = {'schema_and_coverage_ok': all(x['status'] == 'ok' and x['missing'] == 0
                                                   and x['extra_keys'] == 0 for x in relevant),
                       'expansion': 'Manual review of raw replies, filled-field accuracy and measured timings required; '
                                    'valid JSON alone does not establish OCR or coordinate-following capability.'}
    return {'protocol': PROTOCOL, 'phase': phase, 'truth_sha256': frozen['truth_sha256'],
            'interpretation': 'Oracle-box structured field extraction; not parent native-OCR NES. '
                              'Parse/cap failure is not evidence that cropping harms native OCR. '
                              'Blank fabrication is only fabrication on verified blanks; inspect coverage.',
            'runtime': runtime_by_route, 'requests': statuses, 'capability': gates, 'summary': summary, 'rows': rows}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)
    for cmd in ('freeze', 'check', 'read', 'score'):
        p = sub.add_parser(cmd); p.add_argument('--root', required=True, type=Path)
        if cmd == 'freeze':
            p.add_argument('--truth', required=True, type=Path); p.add_argument('--routes', required=True, type=Path)
        if cmd == 'read':
            p.add_argument('--route', required=True, choices=ROUTES)
            p.add_argument('--arm', required=True, choices=ARMS)
            p.add_argument('--runtime', required=True, type=Path)
        if cmd in ('read', 'score', 'check'):
            p.add_argument('--phase', choices=('capability', 'all'), default='capability')
        if cmd == 'score':
            p.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    if a.command == 'freeze':
        print(json.dumps(freeze(a.root, a.truth, a.routes), indent=2))
    elif a.command == 'check':
        f, t = check(a.root)
        print(json.dumps({'pages': len(t['pages']), 'tables': sum(len(p['tables']) for p in t['pages']),
                          'phase': a.phase,
                          'requests_per_route': {arm: sum(1 for _ in tasks(t, arm, a.phase)) for arm in ARMS},
                          'truth_sha256': f['truth_sha256']}))
    elif a.command == 'read':
        read(a.root, a.route, a.arm, os.environ['FS_URL'], load(a.runtime), a.phase)
    else:
        write_new(a.out, encoded(score(a.root, a.phase)))


if __name__ == '__main__':
    main()
