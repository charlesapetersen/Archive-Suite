#!/usr/bin/env python3
"""W46.truth-96-human-keyed: blind two-reader human keying, word-by-word dispute settlement,
versioned truth export, and replay-verified rescoring of the 96-page OCR truth set.

Privacy & safety invariants:
  - No model reading or existing truth text is ever sent to the blind keying sheet.
  - Settled human truth is ALWAYS written to a new versioned directory (``truth-<version>/``)
    beside the existing ``truth/`` directory, never overwriting ``truth/`` or ``pages.tsv``.
  - ``rescore`` replays the current drafted truth against the saved ``ocr-scorers.json`` baseline
    first and aborts if any route's NES drifts, before scoring the new human truth (no model calls, $0).
  - Ranking changes are reported (no decision) for the owner, never auto-applied to app picks.

Commands:
  ocr_truth_human.py init-work      --pages-dir DIR --work DIR [--manifest JSON]
  ocr_truth_human.py build-keying   --reader ID --work DIR [--out DIR]
  ocr_truth_human.py serve-keying   --reader ID --work DIR [--port 0]
  ocr_truth_human.py import-keying  --reader ID --work DIR BUNDLE.json
  ocr_truth_human.py compare        --work DIR --reader-a A --reader-b B [--boxes JSON]
  ocr_truth_human.py settle         --work DIR --answers ANSWERS.json --truth-root DIR --version human-v1
  ocr_truth_human.py rescore        --truth-root DIR --version human-v1 --baseline-json JSON --out-dir DIR
"""
from __future__ import annotations

import argparse
import collections
import csv
import html
import http.server
import json
import mimetypes
import os
import re
import shutil
import statistics
import sys
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
if str(HERE / "corpus") not in sys.path:
    sys.path.insert(0, str(HERE / "corpus"))

import ocr_truth as T  # noqa: E402

KINDS = ("typewritten", "printed", "handwritten", "mixed")
RULES_PATH = HERE / "human_truth_rules.md"
VALID_ID = re.compile(r"^[A-Za-z0-9._-]+$")
ASSUMED_WPM = {"typewritten": 25.0, "printed": 25.0, "handwritten": 10.0, "mixed": 15.0}
DRAFTER_FAMILIES = ("gemini", "claude")


def _check_id(value: str, label: str) -> str:
    if not value or not VALID_ID.match(value) or value in (".", ".."):
        raise ValueError(f"invalid {label}: {value!r}")
    return value


def _atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def _atomic_write_json(path: Path, obj) -> None:
    _atomic_write_text(path, json.dumps(obj, ensure_ascii=False, indent=1) + "\n")


# ---------------------------------------------------------------- manifest & keying storage

def discover_pages(pages_dir: Path) -> list[dict]:
    """List page images in pages_dir as [{'page': stem, 'file': name}] sorted by stem."""
    exts = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"}
    out = []
    for p in sorted(pages_dir.iterdir()):
        if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in exts:
            out.append({"page": p.stem, "file": p.name})
    return out


def init_work(pages_dir: Path, work_dir: Path, manifest_path: Path | None = None) -> dict:
    """Initialise a blind keying workspace pointing at page images (never reads or copies any text)."""
    work_dir.mkdir(parents=True, exist_ok=True)
    if manifest_path is not None:
        pages = json.loads(manifest_path.read_text(encoding="utf-8"))
        if isinstance(pages, dict) and "pages" in pages:
            pages = pages["pages"]
    else:
        pages = discover_pages(pages_dir)
    if not pages:
        raise ValueError(f"no page images found in {pages_dir}")
    clean = []
    for entry in pages:
        page = _check_id(str(entry["page"]), "page")
        fname = str(entry.get("file") or f"{page}.jpg")
        clean.append({
            "page": page,
            "file": fname,
            "img_rel": os.path.relpath(pages_dir / fname, work_dir / "keying-sheet"),
            "collection": str(entry.get("collection") or ""),
        })
    manifest = {
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "pages_dir": str(pages_dir.resolve()),
        "pages": clean,
    }
    _atomic_write_json(work_dir / "manifest.json", manifest)
    return manifest


def load_manifest(work_dir: Path) -> dict:
    return json.loads((work_dir / "manifest.json").read_text(encoding="utf-8"))


def keying_dir(work_dir: Path, reader: str) -> Path:
    return work_dir / "keyings" / _check_id(reader, "reader")


def keying_file(work_dir: Path, reader: str, page: str) -> Path:
    return keying_dir(work_dir, reader) / f"{_check_id(page, 'page')}.json"


def save_keying_page(work_dir: Path, reader: str, page: str, payload: dict) -> dict:
    """Atomically save one reader's keying for one page, preserving monotonic elapsed time."""
    path = keying_file(work_dir, reader, page)
    prior = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    kind = payload.get("kind") or ""
    if kind and kind not in KINDS:
        raise ValueError(f"unknown kind: {kind!r}")
    secs = float(payload.get("active_seconds", prior.get("active_seconds", 0.0)) or 0.0)
    if secs < 0:
        secs = 0.0
    # Never let a stale payload erase prior accumulated time unless explicitly reset.
    if not payload.get("reset_timer") and prior.get("active_seconds"):
        secs = max(secs, float(prior["active_seconds"]))
    rec = {
        "reader": _check_id(reader, "reader"),
        "page": _check_id(page, "page"),
        "text": str(payload.get("text", prior.get("text", ""))),
        "kind": kind,
        "table_form": bool(payload.get("table_form", prior.get("table_form", False))),
        "note": str(payload.get("note", prior.get("note", ""))),
        "done": bool(payload.get("done", prior.get("done", False))),
        "rotation": int(payload.get("rotation", prior.get("rotation", 0))) % 360,
        "active_seconds": round(secs, 2),
        "sittings": int(prior.get("sittings", 0)) + (1 if payload.get("new_sitting") else 0),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    if rec["sittings"] == 0:
        rec["sittings"] = 1
    _atomic_write_json(path, rec)
    return rec


def load_reader_keyings(work_dir: Path, reader: str) -> dict[str, dict]:
    d = keying_dir(work_dir, reader)
    out = {}
    if d.is_dir():
        for f in sorted(d.glob("*.json")):
            rec = json.loads(f.read_text(encoding="utf-8"))
            out[rec["page"]] = rec
    return out


def import_keying_bundle(work_dir: Path, reader: str, bundle_path: Path) -> int:
    """Split an exported offline keying JSON bundle into per-reader, per-page files."""
    data = json.loads(bundle_path.read_text(encoding="utf-8"))
    pages = data.get("pages") if isinstance(data, dict) and "pages" in data else data
    if not isinstance(pages, dict):
        raise ValueError("keying bundle must be an object mapping page id -> record (or {'pages': ...})")
    n = 0
    for page, rec in sorted(pages.items()):
        if not isinstance(rec, dict) or page.startswith("_"):
            continue
        save_keying_page(work_dir, reader, page, {**rec, "new_sitting": True})
        n += 1
    return n


# ---------------------------------------------------------------- blind keying sheet (HTML + local server)

def _rules_excerpt_html() -> str:
    if RULES_PATH.exists():
        raw = RULES_PATH.read_text(encoding="utf-8")
        # Show sections 1 and 2 concisely in the collapsible drawer.
        cut = raw.split("## 3. Worked examples")[0].strip()
        return html.escape(cut)
    return "Transcribe every word in natural reading order; mark unreadable words [illegible]; tables use ' | '."


def build_keying_sheet(work_dir: Path, reader: str, out_dir: Path | None = None,
                       live_server: bool = False) -> Path:
    """Write a blind keying HTML sheet for one reader. Contains NO model reading or other reader's text."""
    reader = _check_id(reader, "reader")
    manifest = load_manifest(work_dir)
    existing = load_reader_keyings(work_dir, reader)
    out = out_dir or (work_dir / "keying-sheet" / reader)
    out.mkdir(parents=True, exist_ok=True)
    pages_dir = Path(manifest["pages_dir"])
    items = []
    for i, entry in enumerate(manifest["pages"]):
        page = entry["page"]
        img = f"/pages/{urllib.parse.quote(entry['file'])}" if live_server else os.path.relpath(pages_dir / entry["file"], out)
        items.append({"page": page, "img": img, "index": i + 1})
    # Initial state includes ONLY this reader's own prior saved keyings (resume across sittings).
    state = {p: existing[p] for p in existing if any(it["page"] == p for it in items)}
    html_text = (
        KEYING_HTML
        .replace("__READER__", json.dumps(reader))
        .replace("__READER_ESC__", html.escape(reader))
        .replace("__PAGES__", json.dumps(items, ensure_ascii=False))
        .replace("__INITIAL__", json.dumps(state, ensure_ascii=False))
        .replace("__LIVE__", "true" if live_server else "false")
        .replace("__RULES__", _rules_excerpt_html())
    )
    target = out / "index.html"
    _atomic_write_text(target, html_text)
    return target


def make_keying_server(work_dir: Path, reader: str, host: str = "127.0.0.1", port: int = 0):
    """Create a local HTTP server persisting each page directly to keyings/<reader>/<page>.json."""
    reader = _check_id(reader, "reader")
    manifest = load_manifest(work_dir)
    pages_dir = Path(manifest["pages_dir"]).resolve()
    allowed_files = {entry["file"] for entry in manifest["pages"]}
    allowed_pages = {entry["page"] for entry in manifest["pages"]}
    sheet_path = build_keying_sheet(work_dir, reader, live_server=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # noqa: A002
            return

        def _send(self, code: int, body: bytes, ctype: str):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path in ("/", "/index.html"):
                # Rebuild with latest disk state so browser reload resumes seamlessly across sittings.
                build_keying_sheet(work_dir, reader, live_server=True)
                self._send(200, sheet_path.read_bytes(), "text/html; charset=utf-8")
                return
            if parsed.path == "/api/state":
                payload = {
                    "reader": reader,
                    "pages": [{"page": e["page"], "img": f"/pages/{urllib.parse.quote(e['file'])}"}
                              for e in manifest["pages"]],
                    "saved": load_reader_keyings(work_dir, reader),
                }
                self._send(200, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                           "application/json; charset=utf-8")
                return
            if parsed.path.startswith("/pages/"):
                fname = urllib.parse.unquote(parsed.path[len("/pages/"):])
                if fname not in allowed_files or "/" in fname or "\\" in fname:
                    self._send(404, b"not found", "text/plain")
                    return
                fpath = (pages_dir / fname).resolve()
                if fpath.parent != pages_dir or not fpath.is_file():
                    self._send(404, b"not found", "text/plain")
                    return
                ctype = mimetypes.guess_type(fpath.name)[0] or "application/octet-stream"
                self._send(200, fpath.read_bytes(), ctype)
                return
            self._send(404, b"not found", "text/plain")

        def do_POST(self):  # noqa: N802
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path.startswith("/api/save/"):
                page = urllib.parse.unquote(parsed.path[len("/api/save/"):])
                if page not in allowed_pages:
                    self._send(404, b'{"error":"unknown page"}', "application/json")
                    return
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                    saved = save_keying_page(work_dir, reader, page, body)
                except Exception as exc:  # noqa: BLE001
                    self._send(400, json.dumps({"error": str(exc)}).encode("utf-8"), "application/json")
                    return
                self._send(200, json.dumps({"ok": True, "record": saved}, ensure_ascii=False).encode("utf-8"),
                           "application/json; charset=utf-8")
                return
            self._send(404, b"not found", "text/plain")

    return http.server.ThreadingHTTPServer((host, port), Handler)


KEYING_HTML = r"""<!doctype html><meta charset="utf-8"><title>Blind transcription keying — __READER_ESC__</title>
<style>
*{box-sizing:border-box}
body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:8px 12px;z-index:5;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.pill{background:#f2f2f2;border:1px solid #ccc;border-radius:4px;padding:2px 8px;font-size:12px}
.pill.ok{background:#e6f6e6;border-color:#4a4;color:#060}
.main{display:flex;height:calc(100vh - 48px)}
.imgpane{flex:1 1 54%;border-right:2px solid #ccc;display:flex;flex-direction:column;background:#f7f7f7}
.imgbar{padding:6px 10px;border-bottom:1px solid #ddd;background:#fff;display:flex;gap:8px;align-items:center;font-size:12px}
.imgscroll{flex:1;overflow:auto;padding:10px}
.frame{display:inline-block;transform-origin:top left;cursor:zoom-in}
.frame img{display:block;max-width:none}
.workpane{flex:1 1 46%;display:flex;flex-direction:column;padding:10px 14px;gap:8px;overflow:auto}
textarea#txt{width:100%;flex:1 1 320px;min-height:240px;font:14px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;padding:10px;border:1px solid #999;border-radius:4px;resize:vertical}
textarea#note{width:100%;height:56px;font:13px/1.4 -apple-system,sans-serif;padding:6px 8px;border:1px solid #bbb;border-radius:4px}
.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.kinds label{margin-right:8px;cursor:pointer}
.status{font-size:12px;color:#555}
details.rules{background:#fafafa;border:1px solid #ddd;border-radius:4px;padding:6px 10px;font-size:12px}
details.rules pre{white-space:pre-wrap;font:12px/1.45 -apple-system,sans-serif;margin:6px 0 0;max-height:220px;overflow:auto}
button{padding:4px 10px;cursor:pointer}
button.primary{background:#06c;color:#fff;border:1px solid #05a;border-radius:4px}
select{padding:3px 6px}
</style>
<header>
  <b>Blind keying</b>
  <span class="pill">Reader: __READER_ESC__</span>
  <button id="prevBtn" type="button">← Prev</button>
  <select id="pageSel"></select>
  <button id="nextBtn" type="button">Next →</button>
  <span class="pill" id="prog">0 / 0 done</span>
  <span class="pill" id="timer">0:00 on page</span>
  <span class="status" id="saveStat">Ready</span>
  <button id="exportBtn" type="button" style="margin-left:auto">Export JSON</button>
</header>
<div class="main">
  <div class="imgpane">
    <div class="imgbar">
      <button id="zoomOut" type="button">−</button>
      <input id="zoomRange" type="range" min="60" max="300" step="10" value="100">
      <button id="zoomIn" type="button">+</button>
      <span id="zoomVal">100%</span>
      <button id="rotBtn" type="button">Rotate 90° (Alt+R)</button>
      <span id="rotVal">0°</span>
      <span class="status" style="margin-left:auto">Blind mode: no model text</span>
    </div>
    <div class="imgscroll" id="imgScroll">
      <div class="frame" id="imgFrame"><img id="pageImg" alt="Page image"></div>
    </div>
  </div>
  <div class="workpane">
    <details class="rules"><summary><b>Transcription rules</b> (click to expand)</summary><pre>__RULES__</pre></details>
    <div class="row">
      <b id="pageTitle"></b>
      <span class="status" id="wordCount">0 words</span>
      <label style="margin-left:auto"><input type="checkbox" id="doneBox"> Page finished</label>
      <button class="primary" id="saveBtn" type="button">Save now</button>
    </div>
    <textarea id="txt" spellcheck="false" placeholder="Type every word on the page in natural reading order. Write [illegible] for unreadable words. Separate table cells with &quot; | &quot;."></textarea>
    <div class="row kinds">
      <b>Kind:</b>
      <label><input type="radio" name="kind" value="typewritten"> typewritten</label>
      <label><input type="radio" name="kind" value="printed"> printed</label>
      <label><input type="radio" name="kind" value="handwritten"> handwritten</label>
      <label><input type="radio" name="kind" value="mixed"> mixed</label>
      <label style="margin-left:auto"><input type="checkbox" id="tableBox"> Mostly table / form</label>
    </div>
    <textarea id="note" placeholder="Optional page note (crossed-out words, rotated photo, cut-off edge, anything unusual)..."></textarea>
  </div>
</div>
<script>
const READER = __READER__;
const PAGES = __PAGES__;
const INITIAL = __INITIAL__;
const LIVE = __LIVE__;
const STORAGE_KEY = 'w46-truth96-keying:' + READER;
const IDLE_MS = 60000;

function loadStore() {
  let local = {};
  try { local = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}'); } catch (_) {}
  const merged = {};
  for (const p of PAGES) {
    const a = INITIAL[p.page] || null;
    const b = local[p.page] || null;
    if (a && b) {
      merged[p.page] = (b.updated_at || '') > (a.updated_at || '') ? b : a;
    } else if (a || b) {
      merged[p.page] = a || b;
    }
  }
  return merged;
}

const STORE = loadStore();
let cur = 0;
let zoomPct = 100;
let lastActivity = Date.now();
let dirty = false;
const newSittingSent = {};

function recOf(page) {
  if (!STORE[page]) {
    STORE[page] = {reader: READER, page, text: '', kind: '', table_form: false, note: '', done: false, rotation: 0, active_seconds: 0};
  }
  return STORE[page];
}

function fmtTime(sec) {
  const s = Math.floor(sec || 0);
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${r < 10 ? '0' : ''}${r}`;
}

function countWords(t) {
  const m = (t || '').trim();
  return m ? m.split(/\s+/).length : 0;
}

function updateProgress() {
  const done = PAGES.filter(p => (STORE[p.page] || {}).done).length;
  const el = document.getElementById('prog');
  el.textContent = `${done} / ${PAGES.length} done`;
  el.classList.toggle('ok', done === PAGES.length && PAGES.length > 0);
  const sel = document.getElementById('pageSel');
  for (let i = 0; i < sel.options.length; i++) {
    const p = PAGES[i].page;
    const d = (STORE[p] || {}).done ? '✓ ' : '';
    sel.options[i].textContent = `${d}${i + 1}. ${p}`;
  }
}

function applyImageTransform() {
  const img = document.getElementById('pageImg');
  const scroll = document.getElementById('imgScroll');
  const rec = recOf(PAGES[cur].page);
  const baseW = Math.max(300, scroll.clientWidth - 28);
  const targetW = Math.round(baseW * zoomPct / 100);
  img.style.width = targetW + 'px';
  img.style.transform = rec.rotation ? `rotate(${rec.rotation}deg)` : '';
  document.getElementById('zoomVal').textContent = `${zoomPct}%`;
  document.getElementById('zoomRange').value = String(zoomPct);
  document.getElementById('rotVal').textContent = `${rec.rotation || 0}°`;
}

function pullFormIntoStore() {
  if (!PAGES.length) return null;
  const p = PAGES[cur].page;
  const rec = recOf(p);
  rec.text = document.getElementById('txt').value;
  rec.note = document.getElementById('note').value;
  const checked = document.querySelector('input[name="kind"]:checked');
  rec.kind = checked ? checked.value : '';
  rec.table_form = document.getElementById('tableBox').checked;
  rec.done = document.getElementById('doneBox').checked;
  rec.updated_at = new Date().toISOString().slice(0, 19);
  document.getElementById('wordCount').textContent = `${countWords(rec.text)} words`;
  return rec;
}

async function persistCurrent(force) {
  if (!PAGES.length) return;
  const rec = pullFormIntoStore();
  if (!dirty && !force) return;
  dirty = false;
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(STORE)); } catch (_) {}
  updateProgress();
  if (!LIVE) {
    document.getElementById('saveStat').textContent = 'Saved in browser (click Export JSON to back up)';
    return;
  }
  const payload = Object.assign({}, rec, {new_sitting: !newSittingSent[rec.page]});
  newSittingSent[rec.page] = true;
  document.getElementById('saveStat').textContent = 'Saving…';
  try {
    const res = await fetch('/api/save/' + encodeURIComponent(rec.page), {
      method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(payload)
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const out = await res.json();
    if (out.record) STORE[rec.page] = out.record;
    document.getElementById('saveStat').textContent = `Saved ${rec.page} to disk`;
  } catch (err) {
    dirty = true;
    document.getElementById('saveStat').textContent = 'Save failed (kept locally): ' + err.message;
  }
}

async function showPage(index) {
  if (index < 0 || index >= PAGES.length) return;
  if (dirty) await persistCurrent(true);
  cur = index;
  const item = PAGES[cur];
  const rec = recOf(item.page);
  document.getElementById('pageSel').value = String(cur);
  document.getElementById('pageTitle').textContent = `${item.page} (${cur + 1} / ${PAGES.length})`;
  document.getElementById('pageImg').src = item.img;
  document.getElementById('txt').value = rec.text || '';
  document.getElementById('note').value = rec.note || '';
  document.querySelectorAll('input[name="kind"]').forEach(r => { r.checked = (r.value === rec.kind); });
  document.getElementById('tableBox').checked = !!rec.table_form;
  document.getElementById('doneBox').checked = !!rec.done;
  document.getElementById('wordCount').textContent = `${countWords(rec.text)} words`;
  document.getElementById('timer').textContent = `${fmtTime(rec.active_seconds)} on page`;
  applyImageTransform();
  updateProgress();
}

const sel = document.getElementById('pageSel');
PAGES.forEach((p, i) => {
  const opt = document.createElement('option');
  opt.value = String(i);
  opt.textContent = `${i + 1}. ${p.page}`;
  sel.appendChild(opt);
});

function markDirty() { dirty = true; lastActivity = Date.now(); pullFormIntoStore(); }
['txt', 'note'].forEach(id => document.getElementById(id).addEventListener('input', markDirty));
document.querySelectorAll('input[name="kind"]').forEach(r => r.addEventListener('change', () => { markDirty(); persistCurrent(true); }));
['tableBox', 'doneBox'].forEach(id => document.getElementById(id).addEventListener('change', () => { markDirty(); persistCurrent(true); }));
document.getElementById('saveBtn').addEventListener('click', () => persistCurrent(true));
document.getElementById('prevBtn').addEventListener('click', () => showPage(cur - 1));
document.getElementById('nextBtn').addEventListener('click', () => showPage(cur + 1));
sel.addEventListener('change', e => showPage(Number(e.target.value)));
document.getElementById('zoomRange').addEventListener('input', e => { zoomPct = Number(e.target.value); applyImageTransform(); });
document.getElementById('zoomIn').addEventListener('click', () => { zoomPct = Math.min(300, zoomPct + 25); applyImageTransform(); });
document.getElementById('zoomOut').addEventListener('click', () => { zoomPct = Math.max(60, zoomPct - 25); applyImageTransform(); });
document.getElementById('imgFrame').addEventListener('click', () => { zoomPct = zoomPct > 120 ? 100 : 200; applyImageTransform(); });
document.getElementById('rotBtn').addEventListener('click', () => {
  const rec = recOf(PAGES[cur].page);
  rec.rotation = ((rec.rotation || 0) + 90) % 360;
  dirty = true;
  applyImageTransform();
  persistCurrent(true);
});
document.getElementById('exportBtn').addEventListener('click', () => {
  pullFormIntoStore();
  const payload = {reader: READER, exported_at: new Date().toISOString(), pages: STORE};
  const blob = new Blob([JSON.stringify(payload, null, 1)], {type: 'application/json'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `truth96-keying-${READER}.json`;
  a.click();
});

// Active per-page timer: ticks only while page is visible and user was active within IDLE_MS.
['keydown', 'mousemove', 'mousedown', 'scroll'].forEach(ev => window.addEventListener(ev, () => { lastActivity = Date.now(); }, {passive: true}));
setInterval(() => {
  if (!PAGES.length || document.hidden || Date.now() - lastActivity > IDLE_MS) return;
  const rec = recOf(PAGES[cur].page);
  rec.active_seconds = Math.round(((rec.active_seconds || 0) + 1) * 100) / 100;
  dirty = true;
  document.getElementById('timer').textContent = `${fmtTime(rec.active_seconds)} on page`;
}, 1000);
setInterval(() => { if (dirty) persistCurrent(false); }, 10000);

// Keyboard shortcuts only with Alt modifier so typing in textareas never triggers shortcuts.
document.addEventListener('keydown', e => {
  if (e.altKey && e.key.toLowerCase() === 'r') { e.preventDefault(); document.getElementById('rotBtn').click(); }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') { e.preventDefault(); persistCurrent(true); }
});

// Resume at first unfinished page (or page 0).
const firstOpen = PAGES.findIndex(p => !(STORE[p.page] || {}).done);
if (PAGES.length) showPage(firstOpen >= 0 ? firstOpen : 0);
</script>
"""


# ---------------------------------------------------------------- compare two readers & dispute sheet

def _locate_span_box(words_a: list[str], span_start_word: int, span_end_word: int,
                     vision_words: list | None) -> list[float] | None:
    """Rough box around a disputed span from optional Vision word boxes [[word, x, y, w, h], ...]."""
    if not vision_words:
        return None
    import difflib
    v_tokens = [str(v[0]).lower() for v in vision_words]
    a_tokens = [w.lower() for w in words_a]
    at = {}
    for blk in difflib.SequenceMatcher(None, a_tokens, v_tokens, autojunk=False).get_matching_blocks():
        for n in range(blk.size):
            at.setdefault(blk.a + n, blk.b + n)
    want = range(span_start_word, span_end_word) if span_end_word > span_start_word else (span_start_word - 1, span_start_word)
    boxes = [vision_words[at[i]][1:5] for i in want if i in at and len(vision_words[at[i]]) >= 5]
    if not boxes:
        return None
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1 = max(b[1] + b[3] for b in boxes)
    return [round(v, 4) for v in (x0, y0, x1 - x0, y1 - y0)]


def compare_readers(work_dir: Path, reader_a: str, reader_b: str,
                    boxes_path: Path | None = None,
                    existing_pages_meta: dict[str, dict] | None = None) -> dict:
    """Align Reader A and Reader B word-by-word, compute pre-settling agreement & timing,
    and write compare.json + dispute/index.html."""
    reader_a = _check_id(reader_a, "reader-a")
    reader_b = _check_id(reader_b, "reader-b")
    manifest = load_manifest(work_dir)
    ka = load_reader_keyings(work_dir, reader_a)
    kb = load_reader_keyings(work_dir, reader_b)
    boxes = json.loads(boxes_path.read_text(encoding="utf-8")) if boxes_path and boxes_path.exists() else {}
    meta_by_page = existing_pages_meta or {}

    pages = []
    for entry in manifest["pages"]:
        p = entry["page"]
        ra, rb = ka.get(p), kb.get(p)
        if not (ra and rb and ra.get("text", "").strip() and rb.get("text", "").strip()):
            missing = []
            if not (ra and ra.get("text", "").strip()):
                missing.append(reader_a)
            if not (rb and rb.get("text", "").strip()):
                missing.append(reader_b)
            pages.append({**entry, "missing": missing})
            continue
        wa, wb = T.words(ra["text"]), T.words(rb["text"])
        sp = T.spans(wa, wb)
        # Attach approximate positions (fraction through page + optional box) for every disputed span.
        pos = 0
        total_a = max(1, len(wa))
        vwords = boxes.get(p)
        for s in sp:
            if "agreed" in s:
                pos += len(s["agreed"].split())
            else:
                n_a = len(s["a"].split()) if s["a"] else 0
                s["at"] = round(pos / total_a, 2)
                b = _locate_span_box(wa, pos, pos + n_a, vwords)
                if b:
                    s["box"] = b
                pos += n_a
        disputed = [s for s in sp if "agreed" not in s]
        agreed_words = sum(len(s["agreed"].split()) for s in sp if "agreed" in s)
        disputed_words = sum(max(len(s["a"].split()), len(s["b"].split())) for s in disputed)
        aligned_words = agreed_words + disputed_words
        ref_kind = (meta_by_page.get(p) or {}).get("kind") or (
            ra.get("kind") if ra.get("kind") and ra.get("kind") == rb.get("kind") else (ra.get("kind") or rb.get("kind") or "")
        )
        pages.append({
            **entry,
            "spans": sp,
            "kind": {"a": ra.get("kind") or "", "b": rb.get("kind") or "", "ref": ref_kind},
            "table": {"a": bool(ra.get("table_form")), "b": bool(rb.get("table_form"))},
            "notes": {"a": ra.get("note") or "", "b": rb.get("note") or ""},
            "words": {"a": len(wa), "b": len(wb)},
            "agreed_words": agreed_words,
            "disputed_words": disputed_words,
            "aligned_words": aligned_words,
            "word_agreement": (agreed_words / aligned_words) if aligned_words else 1.0,
            "n_disputes": len(disputed),
            "active_seconds": {"a": float(ra.get("active_seconds") or 0.0), "b": float(rb.get("active_seconds") or 0.0)},
            "rotation": int(ra.get("rotation") or rb.get("rotation") or 0) % 360,
        })

    stats = compute_agreement_and_timing(pages, reader_a, reader_b)
    compare = {
        "reader_a": reader_a,
        "reader_b": reader_b,
        "pages_dir": manifest["pages_dir"],
        "compared_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "stats": stats,
        "pages": pages,
    }
    _atomic_write_json(work_dir / "compare.json", compare)
    write_dispute_sheet(work_dir, compare)
    return compare


def compute_agreement_and_timing(pages: list[dict], reader_a: str, reader_b: str) -> dict:
    """Aggregate pre-settling inter-reader agreement and measured keying speed overall and by kind."""
    done = [p for p in pages if "spans" in p]
    def _agg(subset: list[dict]) -> dict:
        agreed = sum(p["agreed_words"] for p in subset)
        disputed = sum(p["disputed_words"] for p in subset)
        aligned = agreed + disputed
        n_pages = len(subset)
        exact_pages = sum(1 for p in subset if p["n_disputes"] == 0)
        n_disp = sum(p["n_disputes"] for p in subset)
        sec_a = sum(p["active_seconds"]["a"] for p in subset)
        sec_b = sum(p["active_seconds"]["b"] for p in subset)
        words_a = sum(p["words"]["a"] for p in subset)
        words_b = sum(p["words"]["b"] for p in subset)
        tot_sec = sec_a + sec_b
        tot_words = words_a + words_b
        return {
            "pages": n_pages,
            "exact_pages": exact_pages,
            "exact_page_rate": (exact_pages / n_pages) if n_pages else None,
            "agreed_words": agreed,
            "disputed_words": disputed,
            "aligned_words": aligned,
            "word_agreement_rate": (agreed / aligned) if aligned else None,
            "n_disputes": n_disp,
            "seconds_a": round(sec_a, 2),
            "seconds_b": round(sec_b, 2),
            "words_a": words_a,
            "words_b": words_b,
            "wpm_a": round(words_a / (sec_a / 60.0), 2) if sec_a > 0 else None,
            "wpm_b": round(words_b / (sec_b / 60.0), 2) if sec_b > 0 else None,
            "wpm_combined": round(tot_words / (tot_sec / 60.0), 2) if tot_sec > 0 else None,
            "median_sec_per_page": round(statistics.median(
                [p["active_seconds"]["a"] for p in subset if p["active_seconds"]["a"] > 0]
                + [p["active_seconds"]["b"] for p in subset if p["active_seconds"]["b"] > 0]
            ), 2) if any(p["active_seconds"]["a"] > 0 or p["active_seconds"]["b"] > 0 for p in subset) else None,
        }

    by_kind = {}
    for k in KINDS:
        sub = [p for p in done if p["kind"].get("ref") == k]
        if sub:
            by_kind[k] = _agg(sub)
    unclassified = [p for p in done if p["kind"].get("ref") not in KINDS]
    if unclassified:
        by_kind["unknown"] = _agg(unclassified)

    return {
        "reader_a": reader_a,
        "reader_b": reader_b,
        "total_pages": len(pages),
        "compared_pages": len(done),
        "missing_pages": len(pages) - len(done),
        "overall": _agg(done),
        "by_kind": by_kind,
        "assumed_wpm_reference": ASSUMED_WPM,
    }


def write_dispute_sheet(work_dir: Path, compare: dict) -> Path:
    """Write the third-person dispute settlement sheet (CLAUDE.md sheet rules: notes, unasked fields, upright turn, boxes)."""
    out = work_dir / "dispute"
    out.mkdir(parents=True, exist_ok=True)
    pages_dir = Path(compare["pages_dir"])
    done = [p for p in compare["pages"] if "spans" in p]
    data = []
    for p in done:
        img = os.path.relpath(pages_dir / p["file"], out)
        data.append({
            "page": p["page"],
            "img": img,
            "collection": p.get("collection") or "",
            "spans": p["spans"],
            "kind": p["kind"],
            "table": p["table"],
            "notes": p["notes"],
            "rotation": p.get("rotation", 0),
        })
    minutes = T.review_minutes(done)
    html_text = (
        DISPUTE_HTML
        .replace("__DATA__", json.dumps(data, ensure_ascii=False))
        .replace("__MINUTES__", f"{minutes:.0f}")
        .replace("__READER_A__", html.escape(compare["reader_a"]))
        .replace("__READER_B__", html.escape(compare["reader_b"]))
    )
    target = out / "index.html"
    _atomic_write_text(target, html_text)
    return target


DISPUTE_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 human-keyed truth dispute settlement</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:3;line-height:1.5}
.page{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh}
.imgcol{flex:1 1 50%;position:sticky;top:52px;height:86vh;display:flex;flex-direction:column}
.imgbar{font-size:12px;padding:3px 0;display:flex;gap:8px;align-items:center}
.imgwrap{flex:1;overflow:auto}
.frame{position:relative;display:inline-block;width:100%;cursor:zoom-in;transform-origin:center center}
.frame.zoom{width:250%;cursor:zoom-out}
.frame img{width:100%;display:block}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;box-shadow:0 0 0 2000px rgba(0,0,0,.10);pointer-events:none;display:none}
.txt{flex:1 1 50%;white-space:pre-wrap;line-height:1.6;font-family:Georgia,serif}
.meta{font-family:-apple-system,sans-serif;font-size:12px;background:#f7f7f7;border:1px solid #ddd;border-radius:4px;padding:6px 8px;margin-bottom:8px}
.d{border:1px solid #c80;border-radius:3px;padding:0 3px;background:#fff4dd;display:inline-block;margin:2px 0}
.d.cur{outline:3px solid #06f}.d.done{background:#e6f6e6;border-color:#4a4}
.opt{font-family:-apple-system,sans-serif;font-size:12px;display:block;margin:2px 0}
.opt.sel{font-weight:bold;color:#060}.k{color:#666}
.kind{font-family:-apple-system,sans-serif;margin-bottom:6px;padding:4px;border:1px solid #ccc;border-radius:4px}
.kind.cur{outline:3px solid #06f}.kind.done{background:#e6f6e6;border-color:#4a4}
.notebox{width:100%;font:12px -apple-system,sans-serif;margin-top:8px;padding:4px 6px;border:1px solid #bbb;border-radius:3px}
.where{font-family:-apple-system,sans-serif;font-size:11px;color:#a40;display:block}
</style>
<header><b>Human-keyed truth dispute settlement</b> (__READER_A__ vs __READER_B__, est. __MINUTES__ min).
Keys: <b>1</b> Reader A · <b>2</b> Reader B · <b>3</b> type correct text · <b>n/p</b> next/prev · <b>z</b> zoom · <b>r</b> rotate 90° ·
kind: <b>t</b>ypewritten · <b>k</b> printed · <b>h</b>andwritten · <b>m</b>ixed (<b>Enter</b> accepts agreed proposal).
Unasked agreed spans &amp; agreed fields go in as listed unless corrected in notes.
<button onclick="exportAnswers()">Export answers</button> <span id="prog"></span> <span id="timer">0:00</span></header>
<div id="root"></div>
<script>
const DATA = __DATA__;
const KEY = 'w46-truth96-human-dispute';
let A = JSON.parse(localStorage.getItem(KEY) || '{}');
if (!A._notes) A._notes = {};
if (!A._turns) A._turns = {};
if (!A._settling_seconds) A._settling_seconds = 0;
const items = [];
const pageViews = {};
let lastActivity = Date.now();

function esc(s) { return String(s || '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function save() { localStorage.setItem(KEY, JSON.stringify(A)); prog(); }
function ans(it) { return (A[it.page] || {})[it.key]; }
function set(it, v) { (A[it.page] = A[it.page] || {})[it.key] = v; save(); paint(it); }
function prog() {
  const d = items.filter(it => ans(it) !== undefined).length;
  document.getElementById('prog').textContent = ` ${d} / ${items.length} answered`;
}
function paint(it) {
  const el = it.el, v = ans(it);
  el.classList.toggle('done', v !== undefined);
  if (it.key === 'kind') {
    el.querySelector('.v').textContent = v || (it.proposal ? it.proposal + ' (agreed/proposed)' : 'choose');
    return;
  }
  el.querySelectorAll('.opt').forEach(o => o.classList.toggle('sel',
    o.dataset.v === v || (o.dataset.v === 'typed' && typeof v === 'string' && v.startsWith('='))));
  el.querySelector('.typed').textContent = typeof v === 'string' && v.startsWith('=') ? 'typed: ' + v.slice(1) : '';
}

function applyTurn(page) {
  const pv = pageViews[page];
  if (!pv) return;
  const deg = (A._turns[page] !== undefined ? A._turns[page] : pv.baseRot) % 360;
  pv.frame.style.transform = deg ? `rotate(${deg}deg)` : '';
  pv.rotLabel.textContent = `${deg}°`;
}

function showBox(it) {
  const pv = pageViews[it.page];
  if (!pv) return;
  if (it.box) {
    const [x, y, w, h] = it.box;
    pv.box.style.display = 'block';
    pv.box.style.left = (x * 100) + '%';
    pv.box.style.top = (y * 100) + '%';
    pv.box.style.width = (w * 100) + '%';
    pv.box.style.height = (h * 100) + '%';
  } else {
    pv.box.style.display = 'none';
  }
}

const root = document.getElementById('root');
for (const p of DATA) {
  const div = document.createElement('div');
  div.className = 'page';
  const prop = (p.kind.a && p.kind.a === p.kind.b) ? p.kind.a : (p.kind.ref || '');
  const tableSummary = (p.table.a === p.table.b)
    ? (p.table.a ? 'yes (agreed)' : 'no (agreed)')
    : `A:${p.table.a ? 'yes' : 'no'} / B:${p.table.b ? 'yes' : 'no'}`;
  const readerNotes = [p.notes.a ? 'Reader A note: ' + p.notes.a : '', p.notes.b ? 'Reader B note: ' + p.notes.b : ''].filter(Boolean).join(' · ');
  let h = `<div class="imgcol"><div class="imgbar"><b>${esc(p.page)}</b>`
    + `<button type="button" class="zbtn">Zoom (z)</button>`
    + `<button type="button" class="rbtn">Rotate 90° (r)</button><span class="rotv">0°</span></div>`
    + `<div class="imgwrap"><div class="frame"><img src="${p.img}"><div class="box"></div></div></div></div>`
    + `<div class="txt"><div class="meta"><b>Unasked fields (as listed unless corrected in note):</b> `
    + `table/form = ${esc(tableSummary)}${p.collection ? ' · collection = ' + esc(p.collection) : ''}`
    + `${readerNotes ? '<br>' + esc(readerNotes) : ''}</div>`
    + `<div class="kind" data-key="kind"><b>${esc(p.page)}</b> · kind of writing: <span class="v"></span> `
    + `<span class="k">(A: ${esc(p.kind.a || '?')}, B: ${esc(p.kind.b || '?')})</span> `
    + `<span class="k">[<button type="button" data-k="typewritten">typewritten</button> `
    + `<button type="button" data-k="printed">printed</button> `
    + `<button type="button" data-k="handwritten">handwritten</button> `
    + `<button type="button" data-k="mixed">mixed</button>]</span></div>`;
  p.spans.forEach((s, i) => {
    if ('agreed' in s) { h += esc(s.agreed) + ' '; return; }
    const where = s.box ? '' : `<span class="where">approx. ${Math.round((s.at || 0) * 100)}% down page (no box)</span>`;
    h += `<span class="d" data-key="${i}">${where}`
      + `<span class="opt" data-v="a"><span class="k">1 Reader A:</span> ${esc(s.a) || '<i>(nothing)</i>'}</span>`
      + `<span class="opt" data-v="b"><span class="k">2 Reader B:</span> ${esc(s.b) || '<i>(nothing)</i>'}</span>`
      + `<span class="opt typed" data-v="typed"></span></span> `;
  });
  h += `<div><textarea class="notebox" data-note="${esc(p.page)}" placeholder="Optional settler note for ${esc(p.page)} (correct unasked fields or flag issues)...">${esc(A._notes[p.page] || '')}</textarea></div></div>`;
  div.innerHTML = h;
  root.appendChild(div);
  const frame = div.querySelector('.frame');
  const box = div.querySelector('.box');
  const rotLabel = div.querySelector('.rotv');
  pageViews[p.page] = {frame, box, rotLabel, baseRot: p.rotation || 0};
  applyTurn(p.page);
  frame.addEventListener('click', () => frame.classList.toggle('zoom'));
  div.querySelector('.zbtn').addEventListener('click', () => frame.classList.toggle('zoom'));
  div.querySelector('.rbtn').addEventListener('click', () => {
    const curDeg = (A._turns[p.page] !== undefined ? A._turns[p.page] : (p.rotation || 0));
    A._turns[p.page] = (curDeg + 90) % 360;
    save();
    applyTurn(p.page);
  });
  div.querySelector('.notebox').addEventListener('input', e => {
    A._notes[p.page] = e.target.value;
    save();
  });
  div.querySelectorAll('[data-key]').forEach(el => {
    const k = el.dataset.key;
    const sp = k === 'kind' ? null : p.spans[Number(k)];
    const it = {page: p.page, key: k, el, proposal: prop, box: sp ? sp.box || null : null};
    items.push(it);
    paint(it);
    el.addEventListener('click', () => go(items.indexOf(it)));
    if (k === 'kind') {
      el.querySelectorAll('button[data-k]').forEach(btn => btn.addEventListener('click', ev => {
        ev.stopPropagation();
        set(it, btn.dataset.k);
        next();
      }));
    }
  });
}

let cur = 0;
function go(i) {
  if (i < 0 || i >= items.length) return;
  if (items[cur]) items[cur].el.classList.remove('cur');
  cur = i;
  const it = items[cur];
  it.el.classList.add('cur');
  it.el.scrollIntoView({block: 'center'});
  showBox(it);
}
function next() { go(cur + 1); }

document.addEventListener('keydown', e => {
  if (['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName)) return;
  if (!items.length) return;
  const it = items[cur];
  if (e.key === 'n') next();
  else if (e.key === 'p') go(cur - 1);
  else if (e.key === 'z') pageViews[it.page].frame.classList.toggle('zoom');
  else if (e.key === 'r') {
    const curDeg = (A._turns[it.page] !== undefined ? A._turns[it.page] : pageViews[it.page].baseRot);
    A._turns[it.page] = (curDeg + 90) % 360;
    save();
    applyTurn(it.page);
  } else if (it.key === 'kind') {
    const kmap = {t: 'typewritten', k: 'printed', h: 'handwritten', m: 'mixed'};
    if (kmap[e.key]) { set(it, kmap[e.key]); next(); }
    else if (e.key === 'Enter' && it.proposal) { set(it, it.proposal); next(); }
  } else if (e.key === '1') { set(it, 'a'); next(); }
  else if (e.key === '2') { set(it, 'b'); next(); }
  else if (e.key === '3') {
    const curText = it.el.querySelector('[data-v="a"]').textContent.replace(/^1 Reader A:\s*/, '');
    const typed = prompt('Correct text for this span (empty = nothing):', curText);
    if (typed !== null) { set(it, '=' + typed); next(); }
  }
});

['keydown', 'mousemove', 'mousedown'].forEach(ev => window.addEventListener(ev, () => { lastActivity = Date.now(); }, {passive: true}));
setInterval(() => {
  if (document.hidden || Date.now() - lastActivity > 60000) return;
  A._settling_seconds = Math.round(((A._settling_seconds || 0) + 1) * 100) / 100;
  const s = Math.floor(A._settling_seconds);
  document.getElementById('timer').textContent = `${Math.floor(s / 60)}:${s % 60 < 10 ? '0' : ''}${s % 60}`;
  save();
}, 1000);

function exportAnswers() {
  const b = new Blob([JSON.stringify(A, null, 1)], {type: 'application/json'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(b);
  a.download = 'truth96-human-dispute-answers.json';
  a.click();
}
prog();
if (items.length) go(0);
</script>
"""


# ---------------------------------------------------------------- settle into a NEW truth version (never overwrite)

def version_dir(truth_root: Path, version: str) -> Path:
    v = _check_id(version, "version")
    if v.lower() in ("truth", "current", "drafted"):
        raise ValueError(f"version name {v!r} is reserved so the current truth/ can never be overwritten")
    dest = (truth_root / f"truth-{v}").resolve()
    canonical = (truth_root / "truth").resolve()
    if dest == canonical or dest.parent != truth_root.resolve():
        raise ValueError(f"unsafe version directory: {dest}")
    return dest


def settle(work_dir: Path, answers_path: Path, truth_root: Path, version: str,
           existing_pages_tsv: Path | None = None) -> dict:
    """Apply dispute answers and emit a new truth version beside truth/ without ever overwriting truth/."""
    dest = version_dir(truth_root, version)
    if dest.exists():
        raise FileExistsError(f"target version directory already exists (refusing to overwrite): {dest}")
    compare = json.loads((work_dir / "compare.json").read_text(encoding="utf-8"))
    answers = json.loads(answers_path.read_text(encoding="utf-8"))
    prior_meta = {}
    tsv = existing_pages_tsv or (truth_root / "pages.tsv")
    if tsv.exists():
        with tsv.open(encoding="utf-8", newline="") as fh:
            for row in csv.DictReader(fh, delimiter="\t"):
                prior_meta[row["page"]] = row

    dest.mkdir(parents=True, exist_ok=False)
    settled_rows = []
    n_settled = 0
    n_open = 0
    notes_out = {}
    for p in compare["pages"]:
        pid = p["page"]
        if "spans" not in p:
            n_open += 1
            continue
        ans = answers.get(pid, {})
        text = T.merge(p["spans"], ans)
        kind = ans.get("kind") or (p["kind"]["a"] if p["kind"]["a"] and p["kind"]["a"] == p["kind"]["b"] else None)
        table_form = "yes" if (p["table"]["a"] and p["table"]["b"]) else ""
        status = "done" if (text is not None and kind) else "open"
        if status == "done":
            _atomic_write_text(dest / f"{pid}.txt", text + "\n")
            n_settled += 1
        else:
            n_open += 1
        note = (answers.get("_notes") or {}).get(pid, "")
        if note:
            notes_out[pid] = note
        base = prior_meta.get(pid, {})
        settled_rows.append({
            "page": pid,
            "collection": base.get("collection") or p.get("collection") or "",
            "kind": kind or "",
            "table_form": table_form or base.get("table_form", ""),
            "status": status,
            "disputes": p["n_disputes"],
            "word_agreement": f"{p['word_agreement']:.6f}",
            "seconds_a": p["active_seconds"]["a"],
            "seconds_b": p["active_seconds"]["b"],
            "note": note,
        })

    cols = ["page", "collection", "kind", "table_form", "status", "disputes",
            "word_agreement", "seconds_a", "seconds_b", "note"]
    with (dest / "pages.tsv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, delimiter="\t", lineterminator="\n")
        w.writeheader()
        w.writerows(settled_rows)

    settling_seconds = float(answers.get("_settling_seconds") or 0.0)
    meta = {
        "version": version,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "reader_a": compare["reader_a"],
        "reader_b": compare["reader_b"],
        "settled_pages": n_settled,
        "open_pages": n_open,
        "settling_seconds": round(settling_seconds, 2),
        "settling_minutes": round(settling_seconds / 60.0, 2),
        "pre_settling": compare["stats"],
        "notes_count": len(notes_out),
    }
    _atomic_write_json(dest / "metadata.json", meta)
    return meta


# ---------------------------------------------------------------- replay-verified rescore & delta report

def replay_check(replayed_summary: list[dict], baseline_summary: list[dict],
                 tol: float = 1e-6) -> list[str]:
    """Verify every route in replayed_summary matches baseline_summary on owner96 NES within tol."""
    base = {(r["route"], r["family"]): r for r in baseline_summary
            if r.get("set") == "owner96" and r.get("stratum") == "all"}
    got = {(r["route"], r["family"]): r for r in replayed_summary
           if r.get("set") == "owner96" and r.get("stratum") == "all"}
    errors = []
    for key, r in sorted(got.items()):
        if key not in base:
            errors.append(f"route {key} absent from saved baseline")
            continue
        b_nes, g_nes = base[key].get("nes"), r.get("nes")
        if b_nes is None or g_nes is None or abs(b_nes - g_nes) > tol:
            errors.append(f"route {key}: baseline NES={b_nes} vs replayed NES={g_nes}")
        if base[key].get("n") != r.get("n") or base[key].get("ok") != r.get("ok"):
            errors.append(f"route {key}: baseline n/ok={base[key].get('n')}/{base[key].get('ok')} "
                          f"vs replayed {r.get('n')}/{r.get('ok')}")
    return errors


def is_drafter_route(route: str) -> bool:
    low = route.lower()
    return any(fam in low for fam in DRAFTER_FAMILIES)


def compare_rankings(drafted_summary: list[dict], human_summary: list[dict]) -> dict:
    """Compute per-route NES movements and ranking shifts (Gemini & Claude rows highlighted first)."""
    d_rows = [r for r in drafted_summary if r.get("set") == "owner96" and r.get("stratum") == "all"]
    h_rows = [r for r in human_summary if r.get("set") == "owner96" and r.get("stratum") == "all"]
    d_sorted = sorted(d_rows, key=lambda r: (-(r["nes"] or 0.0), r["route"], r["family"]))
    h_sorted = sorted(h_rows, key=lambda r: (-(r["nes"] or 0.0), r["route"], r["family"]))
    d_rank = {(r["route"], r["family"]): i + 1 for i, r in enumerate(d_sorted)}
    h_rank = {(r["route"], r["family"]): i + 1 for i, r in enumerate(h_sorted)}
    d_by = {(r["route"], r["family"]): r for r in d_rows}
    h_by = {(r["route"], r["family"]): r for r in h_rows}

    deltas = []
    for key in sorted(set(d_by) & set(h_by)):
        dr, hr = d_by[key], h_by[key]
        d_nes, h_nes = dr["nes"], hr["nes"]
        deltas.append({
            "route": key[0],
            "family": key[1],
            "drafter_family": is_drafter_route(key[0]),
            "n": hr["n"],
            "ok": hr["ok"],
            "drafted_nes": d_nes,
            "human_nes": h_nes,
            "delta_nes": (h_nes - d_nes) if (h_nes is not None and d_nes is not None) else None,
            "drafted_rank": d_rank[key],
            "human_rank": h_rank[key],
            "rank_change": d_rank[key] - h_rank[key],  # positive = moved up on human truth
        })

    drafter_first = sorted(
        deltas,
        key=lambda r: (0 if r["drafter_family"] else 1, -(r["human_nes"] or 0.0), r["route"]),
    )
    rank_changed = [r for r in deltas if r["rank_change"] != 0]
    return {
        "routes": drafter_first,
        "ranking_changed": bool(rank_changed),
        "rank_changes": sorted(rank_changed, key=lambda r: r["human_rank"]),
        "policy": "reported (no decision) for owner review; app picks unchanged",
    }


def render_rescore_report(version: str, comparison: dict, metadata: dict | None,
                          replay_ok: bool) -> str:
    """Render Markdown summary of human-truth rescoring (aggregates only; zero page text)."""
    L = [
        f"# W46.truth-96-human-keyed — rescore on human truth (`{version}`)",
        "",
        "Generated by `ArchiveProcessor/scripts/segbench/ocr_truth_human.py rescore` from saved readings only: "
        "no new model calls, no network, $0.",
        f"Replay check against the drafted truth baseline before scoring `{version}`: "
        + ("**PASS** (exact match on every route)." if replay_ok else "**FAILED**."),
        "",
    ]
    if comparison["ranking_changed"]:
        L += [
            "**Ranking change reported (no decision):** One or more routes changed rank between the drafted truth "
            "and the human-keyed truth. Per `W46.truth-96-human-keyed`, this movement is reported for the owner "
            "and is **not** applied to the app's picks.",
            "",
        ]
    else:
        L += ["**Ranking:** No route changed rank between the drafted truth and the human-keyed truth.", ""]

    L += [
        "## Route NES movement (Gemini and Claude rows first)",
        "",
        "| route | family | pages | drafted NES | human NES | Δ NES (pts) | rank (drafted → human) |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for r in comparison["routes"]:
        dn = f"{100 * r['drafted_nes']:.2f}" if r["drafted_nes"] is not None else "–"
        hn = f"{100 * r['human_nes']:.2f}" if r["human_nes"] is not None else "–"
        dd = f"{100 * r['delta_nes']:+.2f}" if r["delta_nes"] is not None else "–"
        L.append(f"| {r['route']} | {r['family']} | {r['ok']}/{r['n']} | {dn} | {hn} | {dd} | "
                 f"{r['drafted_rank']} → {r['human_rank']} |")

    if metadata and metadata.get("pre_settling"):
        pre = metadata["pre_settling"]
        ov = pre.get("overall") or {}
        L += [
            "",
            "## Pre-settling inter-reader agreement and measured keying time",
            "",
            f"Readers: `{metadata.get('reader_a')}` and `{metadata.get('reader_b')}`. "
            f"Settled pages: {metadata.get('settled_pages', 0)} (open: {metadata.get('open_pages', 0)}). "
            f"Settling time: **{metadata.get('settling_minutes', 0.0):.1f} min** "
            f"({metadata.get('settling_seconds', 0.0):.0f} s).",
            "",
            "| kind | pages | exact pages | word agreement | disputes | measured wpm (combined) | assumed wpm |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
        for k, row in (pre.get("by_kind") or {}).items():
            wa = f"{100 * row['word_agreement_rate']:.1f}%" if row.get("word_agreement_rate") is not None else "–"
            wpm = f"{row['wpm_combined']:.1f}" if row.get("wpm_combined") is not None else "–"
            awpm = f"{ASSUMED_WPM[k]:.0f}" if k in ASSUMED_WPM else "–"
            L.append(f"| {k} | {row['pages']} | {row['exact_pages']} | {wa} | {row['n_disputes']} | {wpm} | {awpm} |")
        wa_all = f"{100 * ov['word_agreement_rate']:.1f}%" if ov.get("word_agreement_rate") is not None else "–"
        wpm_all = f"{ov['wpm_combined']:.1f}" if ov.get("wpm_combined") is not None else "–"
        L.append(f"| **all** | {ov.get('pages', 0)} | {ov.get('exact_pages', 0)} | {wa_all} | "
                 f"{ov.get('n_disputes', 0)} | {wpm_all} | – |")

    L += [
        "",
        "## Measurement card",
        "",
        f"- **Truth.** New independent human-keyed truth version `truth-{version}/` (two blind readers from the page "
        "image alone, differences settled by a third person against the image), stored beside the original drafted "
        "`truth/` without overwriting it.",
        "- **Selection.** Every saved reading of the 96-page truth set (no new model calls); same page list and "
        "exclusions as `ocr_rescore.py`.",
        "- **Comparison.** Drafted truth replay verified against `ocr-scorers.json` before scoring the human truth; "
        "identical scorer (`ocr_panel_score.score` on stratum `S0` + `ocr_scorers.py`).",
        "- **Noise.** Inter-reader agreement before settling measures the human transcription floor directly; "
        "route gaps still follow the bench's paired interval / tie rules.",
        "- **Scope.** Reports NES movement and any rank changes (Gemini and Claude rows first) for owner review only; "
        "no app pick is modified automatically.",
        "",
    ]
    return "\n".join(L)


def rescore_with_truth(sources: dict, pages: list[str], drafted_truth_dir: Path,
                       human_truth_dir: Path, baseline_summary: list[dict],
                       version: str, out_dir: Path,
                       metadata: dict | None = None, tol: float = 1e-6) -> dict:
    """Replay current drafted truth against baseline_summary, then rescore on human_truth_dir."""
    import ocr_rescore as RS

    drafted_rows = RS.score_set(
        "owner96", sources,
        lambda p: (drafted_truth_dir / f"{p}.txt").read_text(encoding="utf-8"),
        lambda p: "S0", lambda _t: pages,
    )
    drafted_summary = RS.summarise(drafted_rows)
    errors = replay_check(drafted_summary, baseline_summary, tol=tol)
    if errors:
        raise RuntimeError("drafted-truth replay check failed before human-truth rescore: " + "; ".join(errors[:5]))

    human_rows = RS.score_set(
        "owner96", sources,
        lambda p: (human_truth_dir / f"{p}.txt").read_text(encoding="utf-8"),
        lambda p: "S0", lambda _t: pages,
    )
    human_summary = RS.summarise(human_rows)
    comparison = compare_rankings(drafted_summary, human_summary)

    out_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": version,
        "replay_verified": True,
        "metadata": metadata,
        "comparison": comparison,
        "human_summary": human_summary,
    }
    _atomic_write_json(out_dir / f"ocr-truth-human-{version}.json", payload)
    _atomic_write_text(
        out_dir / f"ocr-truth-human-{version}.md",
        render_rescore_report(version, comparison, metadata, replay_ok=True),
    )
    return payload


# ---------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init-work")
    p_init.add_argument("--pages-dir", type=Path, required=True)
    p_init.add_argument("--work", type=Path, required=True)
    p_init.add_argument("--manifest", type=Path, default=None)

    p_build = sub.add_parser("build-keying")
    p_build.add_argument("--reader", required=True)
    p_build.add_argument("--work", type=Path, required=True)
    p_build.add_argument("--out", type=Path, default=None)

    p_serve = sub.add_parser("serve-keying")
    p_serve.add_argument("--reader", required=True)
    p_serve.add_argument("--work", type=Path, required=True)
    p_serve.add_argument("--host", default="127.0.0.1")
    p_serve.add_argument("--port", type=int, default=8765)

    p_imp = sub.add_parser("import-keying")
    p_imp.add_argument("--reader", required=True)
    p_imp.add_argument("--work", type=Path, required=True)
    p_imp.add_argument("bundle", type=Path)

    p_cmp = sub.add_parser("compare")
    p_cmp.add_argument("--work", type=Path, required=True)
    p_cmp.add_argument("--reader-a", required=True)
    p_cmp.add_argument("--reader-b", required=True)
    p_cmp.add_argument("--boxes", type=Path, default=None)

    p_set = sub.add_parser("settle")
    p_set.add_argument("--work", type=Path, required=True)
    p_set.add_argument("--answers", type=Path, required=True)
    p_set.add_argument("--truth-root", type=Path, default=T.CACHE)
    p_set.add_argument("--version", default="human-v1")

    p_res = sub.add_parser("rescore")
    p_res.add_argument("--truth-root", type=Path, default=T.CACHE)
    p_res.add_argument("--version", default="human-v1")
    p_res.add_argument("--baseline-json", type=Path, default=HERE.parents[1] / "segbench-results/ocr-scorers.json")
    p_res.add_argument("--out-dir", type=Path, default=HERE.parents[1] / "segbench-results")

    a = ap.parse_args(argv)
    if a.cmd == "init-work":
        m = init_work(a.pages_dir, a.work, a.manifest)
        print(f"initialised {len(m['pages'])} pages -> {a.work / 'manifest.json'}")
    elif a.cmd == "build-keying":
        target = build_keying_sheet(a.work, a.reader, a.out, live_server=False)
        print(f"blind keying sheet -> {target}")
    elif a.cmd == "serve-keying":
        srv = make_keying_server(a.work, a.reader, a.host, a.port)
        addr = srv.server_address
        print(f"serving blind keying sheet for {a.reader} at http://{addr[0]}:{addr[1]}/ (Ctrl-C to stop)", flush=True)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            srv.server_close()
    elif a.cmd == "import-keying":
        n = import_keying_bundle(a.work, a.reader, a.bundle)
        print(f"imported {n} pages for {a.reader} -> {keying_dir(a.work, a.reader)}")
    elif a.cmd == "compare":
        cmp_obj = compare_readers(a.work, a.reader_a, a.reader_b, a.boxes)
        ov = cmp_obj["stats"]["overall"]
        print(f"compared {ov['pages']} pages: {ov['n_disputes']} disputes, "
              f"word agreement {100 * (ov['word_agreement_rate'] or 0):.1f}% -> {a.work / 'dispute/index.html'}")
    elif a.cmd == "settle":
        meta = settle(a.work, a.answers, a.truth_root, a.version)
        print(f"settled {meta['settled_pages']} pages ({meta['open_pages']} open) -> "
              f"{version_dir(a.truth_root, a.version)}")
    elif a.cmd == "rescore":
        import ocr_panel as P
        import ocr_rescore as RS
        hdir = version_dir(a.truth_root, a.version)
        baseline = json.loads(a.baseline_json.read_text(encoding="utf-8"))["summary"]
        meta = json.loads((hdir / "metadata.json").read_text(encoding="utf-8")) if (hdir / "metadata.json").exists() else None
        keep = [r["page"] for r in P.rows() if r["page"] not in P.AGREEMENT]
        src = RS.owner_sources()
        rescore_with_truth(src, keep, a.truth_root / "truth", hdir, baseline, a.version, a.out_dir, metadata=meta)
        print(f"rescored {len(src)} routes against {hdir} -> {a.out_dir / f'ocr-truth-human-{a.version}.md'}")


if __name__ == "__main__":
    sys.exit(main())
