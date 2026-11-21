#!/usr/bin/env bash
# Prove the real prose checker catches missing safety disclosures and shared-guide links.
# All mutations are in a temporary git repo (including a space in its path); no app/engine/network.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/../../.." && pwd)" <<'PY'
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1])
checker = source / 'ops/autonomous/check-policy-coherence.sh'
with tempfile.TemporaryDirectory(prefix='root-marker-policy-') as tmp:
    repo = Path(tmp) / 'repo with space'
    repo.mkdir()
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    targets = re.search(r'TARGETS=\((.*?)\n\)', checker.read_text(), re.S).group(1)
    for name in shlex.split(targets):
        original = source / name
        if original.is_file():
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
    script = repo / checker.name
    shutil.copyfile(checker, script)
    guide = repo / 'ArchiveReader/CLAUDE.md'
    original = guide.read_text()

    def run(expect, label, check='reader-root-marker-disclosed'):
        result = subprocess.run(['bash', str(script)], cwd=repo, text=True, capture_output=True)
        assert result.returncode == expect, label + '\n' + result.stdout + result.stderr
        assert check in result.stdout, result.stdout
        if expect:
            assert re.search(r'✗.*' + re.escape(check), result.stdout), result.stdout
        print('PASS ' + label)

    run(0, 'current policy passes from a spaced scratch path')
    guide.write_text(original.replace('One named exception: choosing a folder', 'omitted disclosure'))
    run(1, 'removing the choosing-a-folder disclosure fails despite mentions in other files')
    guide.write_text(original.replace('`.archive-suite-root.json`', '`omitted filename`'))
    run(1, 'removing the exact identity filename fails')
    guide.write_text(original)
    run(0, 'restoring the directive restores green')

    guide.write_text(original.replace('@AGENTS.md\n', '', 1))
    run(1, 'missing app guide import fails', 'ArchiveReader shared guides')
    guide.write_text(original)
    preamble = repo / 'ops/autonomous/codex-preamble.txt'
    original = preamble.read_text()
    preamble.write_text(original.replace('For an independent check required by AGENTS.md', 'For an optional check'))
    run(1, 'missing Codex independent check instruction fails', 'shared-independent-verification')
    preamble.write_text(original)
    run(0, 'restoring shared-guide links restores green')
PY
