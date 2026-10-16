"""W43.corpus-build — shared pieces of the corpus converters.

Every network read goes through fetch.sh (the owner's host list). Multi-GB archives are read member by
member (RemoteZip), because the disk had 24 GB free when this was written. Everything fetched lives under
CACHE; the repo gets only code and the manifest.

A converter yields Candidate pages. Listing is cheap (metadata, a zip's central directory); the image and
truth are fetched only for pages the sampler draws (`materialise`).
"""
from __future__ import annotations

import dataclasses
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import xml.etree.ElementTree as ET
import zlib

HERE = Path(__file__).resolve().parent
FETCH = HERE / 'fetch.sh'
CACHE = Path(os.environ.get('BENCH_CORPUS_CACHE',
                            Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/bench-corpus'))


# --- network, through fetch.sh only ---------------------------------------------------------------

def get(url: str) -> bytes:
    return subprocess.run([str(FETCH), '--stdout', url], check=True, capture_output=True).stdout


def _range_once(url: str, start: int, end: int) -> bytes:
    out = subprocess.run([str(FETCH), '--range', f'{start}-{end}', url], check=True, capture_output=True).stdout
    if len(out) != end - start + 1:
        raise IOError(f'range {start}-{end} of {url}: got {len(out)} bytes (server ignored the range?)')
    return out


# Zenodo closed range transfers after about three minutes on 2026-10-16 (6 MB of a 19 MB member at ~36 KB/s),
# so a large member never arrived in one request. Big ranges are read in chunks, each retried on its own.
CHUNK = 4 << 20
CHUNK_TRIES = 5


def get_range(url: str, start: int, end: int, sleep=None) -> bytes:
    """Bytes start..end inclusive."""
    import time
    sleep = sleep or time.sleep
    parts = []
    for a in range(start, end + 1, CHUNK):
        b = min(end, a + CHUNK - 1)
        for i in range(CHUNK_TRIES):
            try:
                parts.append(_range_once(url, a, b))
                break
            except (subprocess.CalledProcessError, IOError):
                if i == CHUNK_TRIES - 1:
                    raise
                sleep(min(60, 5 * 2 ** i))
    return b''.join(parts)


def size_of(url: str) -> int:
    head = subprocess.run([str(FETCH), '--head', url], check=True, capture_output=True, text=True).stdout
    m = re.search(r'(?im)^content-length:\s*(\d+)', head)
    if not m:
        raise IOError(f'no content-length for {url}')
    return int(m.group(1))


def download(url: str, dest: str) -> Path:
    """Whole-file download to CACHE/dest (small files only; skip if present)."""
    out = CACHE / dest
    if not out.exists():
        subprocess.run([str(FETCH), url, dest], check=True, capture_output=True)
    return out


def cached(dest: str, data: bytes) -> Path:
    out = CACHE / dest
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + '.part')
    tmp.write_bytes(data)
    tmp.replace(out)
    return out


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# --- a zip read over HTTP ranges ------------------------------------------------------------------

class RemoteZip:
    """Read a zip's central directory and single members with range requests.

    `reader(start, end)` returns bytes start..end inclusive; tests pass a local one."""

    def __init__(self, url: str | None = None, size: int | None = None, reader=None):
        self.url = url
        self.read = reader or (lambda a, b: get_range(url, a, b))
        self.size = size if size is not None else size_of(url)
        self.entries = self._directory()

    def _directory(self) -> dict[str, tuple[int, int, int, int]]:
        tail_len = min(self.size, 66_000)
        tail = self.read(self.size - tail_len, self.size - 1)
        i = tail.rfind(b'PK\x05\x06')
        if i < 0:
            raise IOError('no end-of-central-directory record')
        (_, _, _, _, count, cd_size, cd_off) = struct.unpack('<IHHHHII', tail[i:i + 20])
        if cd_off == 0xFFFFFFFF or count == 0xFFFF or cd_size == 0xFFFFFFFF:
            j = tail.rfind(b'PK\x06\x07')
            if j < 0:
                raise IOError('zip64 without a locator')
            (eocd64_off,) = struct.unpack('<Q', tail[j + 8:j + 16])
            rec = self.read(eocd64_off, eocd64_off + 55)
            if rec[:4] != b'PK\x06\x06':
                raise IOError('bad zip64 end record')
            (count, cd_size, cd_off) = struct.unpack('<QQQ', rec[32:56])
        cd = self.read(cd_off, cd_off + cd_size - 1)
        entries, p = {}, 0
        for _ in range(count):
            if cd[p:p + 4] != b'PK\x01\x02':
                raise IOError('bad central directory entry')
            method, = struct.unpack('<H', cd[p + 10:p + 12])
            csize, usize = struct.unpack('<II', cd[p + 20:p + 28])
            nlen, xlen, clen = struct.unpack('<HHH', cd[p + 28:p + 34])
            off, = struct.unpack('<I', cd[p + 42:p + 46])
            name = cd[p + 46:p + 46 + nlen].decode('utf-8', 'replace')
            extra = cd[p + 46 + nlen:p + 46 + nlen + xlen]
            if 0xFFFFFFFF in (csize, usize, off):
                csize, usize, off = self._zip64(extra, csize, usize, off)
            entries[name] = (method, csize, usize, off)
            p += 46 + nlen + xlen + clen
        return entries

    @staticmethod
    def _zip64(extra: bytes, csize: int, usize: int, off: int):
        q = 0
        while q + 4 <= len(extra):
            tag, ln = struct.unpack('<HH', extra[q:q + 4])
            if tag == 1:
                vals, r = list(struct.unpack(f'<{ln // 8}Q', extra[q + 4:q + 4 + ln - ln % 8])), 0
                if usize == 0xFFFFFFFF:
                    usize, r = vals[r], r + 1
                if csize == 0xFFFFFFFF:
                    csize, r = vals[r], r + 1
                if off == 0xFFFFFFFF:
                    off = vals[r]
                break
            q += 4 + ln
        return csize, usize, off

    def names(self) -> list[str]:
        return [n for n in self.entries if not n.endswith('/')]

    def member(self, name: str) -> bytes:
        method, csize, usize, off = self.entries[name]
        head = self.read(off, off + 29)
        if head[:4] != b'PK\x03\x04':
            raise IOError(f'bad local header for {name}')
        nlen, xlen = struct.unpack('<HH', head[26:30])
        start = off + 30 + nlen + xlen
        raw = self.read(start, start + csize - 1) if csize else b''
        if method == 0:
            data = raw
        elif method == 8:
            data = zlib.decompress(raw, -15)
        else:
            raise IOError(f'{name}: compression method {method} not supported')
        if len(data) != usize:
            raise IOError(f'{name}: {len(data)} bytes, expected {usize}')
        return data


# --- ground-truth formats -------------------------------------------------------------------------

def _local(tag: str) -> str:
    return tag.rsplit('}', 1)[-1]


def page_xml_text(data: bytes) -> str:
    """PAGE-XML page text: each TextLine's TextEquiv/Unicode, regions and lines in document order.

    Falls back to the region's own TextEquiv when a region has no line text. ReadingOrder, when present,
    orders the regions."""
    root = ET.fromstring(data)
    regions = [e for e in root.iter() if _local(e.tag) == 'TextRegion']
    order = []
    for e in root.iter():
        if _local(e.tag) in ('RegionRefIndexed',):
            order.append((int(e.get('index', 0)), e.get('regionRef')))
    if order:
        rank = {ref: i for i, (_, ref) in enumerate(sorted(order))}
        regions.sort(key=lambda r: rank.get(r.get('id'), len(rank)))

    def unicode_of(el) -> str | None:
        for child in el:
            if _local(child.tag) == 'TextEquiv':
                for u in child:
                    if _local(u.tag) == 'Unicode':
                        return u.text or ''
        return None

    seen, out = set(), []
    for reg in regions:
        if id(reg) in seen:
            continue
        lines = [ln for ln in reg.iter() if _local(ln.tag) == 'TextLine']
        texts = [t for t in (unicode_of(ln) for ln in lines) if t]
        if not texts:
            t = unicode_of(reg)
            texts = [t] if t else []
        for sub in reg.iter():
            seen.add(id(sub))
        if texts:
            out.append('\n'.join(texts))
    return '\n\n'.join(out).strip()


def alto_text(data: bytes) -> str:
    """ALTO page text: TextLine by TextLine, String CONTENT joined by spaces (HYP keeps its hyphen)."""
    root = ET.fromstring(data)
    blocks = []
    for blk in root.iter():
        if _local(blk.tag) != 'TextBlock':
            continue
        lines = []
        for ln in blk.iter():
            if _local(ln.tag) != 'TextLine':
                continue
            words = []
            for w in ln:
                t = _local(w.tag)
                if t == 'String':
                    words.append(w.get('CONTENT', ''))
                elif t == 'HYP':
                    words[-1:] = [(words[-1] if words else '') + w.get('CONTENT', '-')]
            if any(words):
                lines.append(' '.join(x for x in words if x))
        if lines:
            blocks.append('\n'.join(lines))
    return '\n\n'.join(blocks).strip()


# --- candidates -----------------------------------------------------------------------------------

@dataclasses.dataclass
class Candidate:
    source: str          # source family, e.g. 'read2017'
    collection: str      # sub-collection, for the quarter cap
    page_id: str         # unique within the source
    stratum: str         # L1..L9, N1..N6
    licence: str
    item_url: str        # citation URL for the page or its record
    convention: str      # truth convention, short
    contamination: str   # 'low' | 'medium' | 'high'
    publish_image: bool  # owner 2026-10-16: never on the published bench, whatever this says
    script: str = 'Latn'
    era: str = ''
    kind: str = ''       # handwritten | typed | print | ledger | newspaper
    fetch: dict = dataclasses.field(default_factory=dict)   # how materialise() gets it

    @property
    def key(self) -> str:
        return f'{self.source}:{self.page_id}'

    def row(self) -> dict:
        return dataclasses.asdict(self)


def write_jsonl(path: Path, rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.part')
    with tmp.open('w') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + '\n')
    tmp.replace(path)


def read_jsonl(path: Path) -> list[dict]:
    with path.open() as f:
        return [json.loads(line) for line in f if line.strip()]
