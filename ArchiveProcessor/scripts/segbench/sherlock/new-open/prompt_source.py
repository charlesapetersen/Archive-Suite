#!/usr/bin/env python3
"""W46.ocr-new-open-sherlock: a candidate's prompt from its model's own package (setup-job.sh, before setup).

    python3 prompt_source.py CANDIDATES_JSON [--from ARCHIVE]

For each candidate with `prompt_source` ({"pypi", "file", "name"}), downloads the package from PyPI (no dependencies),
reads the named string variable from the named file without importing it, and compares it with the candidate's
`prompt`, which is a transcription made on the Mac. The package wins where they differ; `prompt_check` records the
archive, whether the two matched, and the transcription it replaced. If the package cannot be fetched or read, the
transcription stands and `prompt_check` says why. `--from` reads a local wheel or sdist instead (tests, a dry run).
"""
import ast
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import zipfile


def read_member(archive, rel):
    archive = pathlib.Path(archive)
    if archive.suffix == '.whl' or archive.suffix == '.zip':
        z = zipfile.ZipFile(archive)
        name = next(n for n in z.namelist() if n == rel or n.endswith('/' + rel))
        return z.read(name).decode()
    with tarfile.open(archive) as t:
        m = next(m for m in t.getmembers() if m.name == rel or m.name.endswith('/' + rel))
        return t.extractfile(m).read().decode()


def string_var(source, name):
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and any(getattr(t, 'id', None) == name for t in node.targets):
            value = ast.literal_eval(node.value)
            if isinstance(value, str):
                return value
    raise KeyError(name + ' is not a string assignment')


def fetch(package, dest):
    subprocess.run([sys.executable, '-m', 'pip', 'download', '--no-deps', '-d', str(dest), package], check=True)
    found = sorted(p for p in pathlib.Path(dest).iterdir() if p.suffix in ('.whl', '.gz', '.zip'))
    if len(found) != 1:
        raise RuntimeError('expected one archive, found %s' % [p.name for p in found])
    return found[0]


def check(candidate, archive):
    src = candidate['prompt_source']
    try:
        found = string_var(read_member(archive, src['file']), src['name'])
    except Exception as exc:
        candidate['prompt_check'] = {'error': repr(exc)[:500], 'used': 'the transcription'}
        return
    same = found == candidate.get('prompt')
    candidate['prompt_check'] = {'package': pathlib.Path(archive).name, 'same_as_transcription': same}
    if not same:
        candidate['prompt_check']['transcription'] = candidate.get('prompt')
        candidate['prompt'] = found


def main(argv):
    path = pathlib.Path(argv[0])
    local = argv[argv.index('--from') + 1] if '--from' in argv else None
    cands = json.loads(path.read_text())
    for c in cands:
        if not c.get('prompt_source'):
            continue
        if local:
            check(c, local)
        else:
            with tempfile.TemporaryDirectory() as d:
                try:
                    archive = fetch(c['prompt_source']['pypi'], d)
                except Exception as exc:
                    c['prompt_check'] = {'error': repr(exc)[:500], 'used': 'the transcription'}
                else:
                    check(c, archive)
        print(c['key'], json.dumps(c['prompt_check'])[:300], flush=True)
    path.write_text(json.dumps(cands, indent=1) + '\n')


if __name__ == '__main__':
    main(sys.argv[1:])
