#!/bin/bash
# Key-free ($0) self-test of the Settings window's eight panels (W47.settings-panels) and its three levels
# (W47.settings-level-switch): runs SettingsPanelsTestDriver headless, which checks that every setting has exactly one
# owning panel (`SettingsPanelOwnership`) and one level (`SettingsLevels`), that every route row has a level and that a
# value changed from its default shows at every level. Then holds each panel's source to the owner table: a stored
# setting a panel's file writes (a `$binding`, an assignment or a toggle) must be one the table gives that panel, unless
# the line says `// side effect`; and holds the level table's defaults to every `@AppStorage` declaration of the same
# key with a literal default, so "changed from its default" means what the app means. No model call, no network, no
# Keychain read, no window, never the corpus.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    SETTINGS_PANELS_TEST=1 SETTINGS_PANELS_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1

for _ in $(seq 1 90); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Settings panels test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

grep -v '^OWNER \|^LEVEL \|^DEFAULT ' "$report"
grep -q '^ALL PASS$' "$report" || exit 1

# The source check: each file a panel draws, and the panel it belongs to.
python3 - "$report" "$PWD/macOS/Sources/ArchiveProcessor" <<'PY'
import re, sys
report, src = sys.argv[1], sys.argv[2]
owner = {}
for line in open(report):
    if line.startswith('OWNER '):
        key, panel = line[len('OWNER '):].rstrip('\n').rsplit(' ', 1)
        owner[key] = panel
defaults = {}
for m in re.finditer(r'static let (\w+) = "([^"]+)"', open(f'{src}/Models/DefaultsKeys.swift').read()):
    defaults[m.group(1)] = m.group(2)
files = {
    'Views/SettingsPanels/SettingsGeneralPanel.swift': 'general',
    'Views/SettingsPanels/SettingsCollectionPanel.swift': 'collection',
    'Views/CollectionSettingsSection.swift': 'collection',
    'Views/SettingsPanels/SettingsEstimateStrip.swift': None,   # reads only
    'Views/SettingsPanels/SettingsReadingPanel.swift': 'reading',
    'Views/LocalModelSettingsView.swift': 'reading',
    'Views/SettingsPanels/SettingsDocumentsPanel.swift': 'documents',
    'Views/SegmentationChooserView.swift': 'documents',
    'Views/SettingsPanels/SettingsDatesNamesPanel.swift': 'datesAndNames',
    'Views/SettingsPanels/SettingsPagesOutputPanel.swift': 'pagesAndOutput',
    'Views/SettingsPanels/SettingsCapturePanel.swift': 'capture',
    'Views/SettingsPanels/SettingsAccountsPanel.swift': 'accounts',
}
bad, checked = [], 0
for rel, panel in files.items():
    text = open(f'{src}/{rel}').read()
    for m in re.finditer(r'@AppStorage\((DefaultsKeys\.(\w+)|AppAppearance\.defaultsKey)\)\s+(?:private\s+)?var\s+(\w+)', text):
        key = defaults.get(m.group(2)) if m.group(2) else 'archiveAppearance'   # AppAppearance.defaultsKey
        name = m.group(3)
        writes = [l for l in text.split('\n')
                  if (re.search(r'\$' + name + r'\b', l) or re.search(r'(?<![\w.])' + name + r'\s*=(?!=)', l)
                      or re.search(r'(?<![\w.])' + name + r'\.toggle\(\)', l))
                  and '@AppStorage' not in l and '// side effect' not in l]
        if not writes:
            continue
        checked += 1
        if panel is None or owner.get(key) != panel:
            bad.append(f'{rel}: writes {key} (owned by {owner.get(key, "no panel")})')
if bad:
    print('FAIL source: a panel writes a setting it does not own'); print('\n'.join(bad)); sys.exit(1)
print(f'PASS source: the {checked} stored settings the panels write are each written by their owning panel only')

# The level table's defaults against the app's own declarations (W47.settings-level-switch).
import glob, json
table = {}
for line in open(report):
    if line.startswith('DEFAULT '):
        key, value = line[len('DEFAULT '):].rstrip('\n').split('\t', 1)
        try: table[key] = json.loads(value)
        except ValueError: sys.exit(f"FAIL levels: unreadable DEFAULT line {line!r}")
names = {v: k for k, v in defaults.items()}
wrong, compared = [], 0
for path in glob.glob(f'{src}/**/*.swift', recursive=True):
    text = open(path).read()
    for m in re.finditer(r'@AppStorage\(DefaultsKeys\.(\w+)\)\s+(?:private\s+)?var\s+\w+(?:\s*:\s*[\w.]+)?\s*=\s*([^\n]+)', text):
        key = defaults.get(m.group(1))
        expr = m.group(2).strip().split('//')[0].strip()
        if key not in table:
            continue
        if expr in ('true', 'false'):
            lit = expr == 'true'
        elif re.fullmatch(r'-?\d+(\.\d+)?', expr):
            lit = float(expr)
        elif re.fullmatch(r'"[^"]*"', expr):
            lit = expr[1:-1]
        else:
            continue   # an enum case or a constant: the driver's own checks cover the table's value
        compared += 1
        want = table[key]
        same = (abs(float(want) - lit) < 1e-9) if isinstance(lit, float) and not isinstance(want, (bool, str)) else want == lit
        if not same:
            wrong.append(f'{path[len(src)+1:]}: {key} defaults to {expr}, the level table says {want!r}')
if wrong:
    print('FAIL levels: a default differs from the level table'); print('\n'.join(wrong)); sys.exit(1)
print(f'PASS levels: the {compared} literal @AppStorage defaults of levelled settings match the level table')
PY
