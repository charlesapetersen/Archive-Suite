"""W43.corpus-build — list a GitHub directory without api.github.com.

api.github.com is not an allowed host, so the listing is read from the github.com HTML tree page, which embeds
a JSON payload (`tree.items`: name, path, contentType). Each listing is cached under CACHE/raw/<source>/ so a
second candidates() call makes no requests. Files are fetched from raw.githubusercontent.com (`raw_url`).
"""
from __future__ import annotations

import json
import re
from urllib.parse import quote

import common

LFS_MAGIC = b'version https://git-lfs'


def parse_tree(html: str) -> list[dict]:
    """The `tree.items` list of a github.com tree page (raises if the payload is missing)."""
    m = re.search(r'<script type="application/json" data-target="react-app\.embeddedData">(.*?)</script>', html, re.S)
    if not m:
        raise IOError('no embedded payload in tree page')
    found = []

    def walk(o):
        if isinstance(o, dict):
            t = o.get('tree')
            if isinstance(t, dict) and 'items' in t:
                found.append(t)
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(json.loads(m.group(1)))
    if not found:
        raise IOError('no tree.items in payload')
    t = found[0]
    if t.get('totalCount', len(t['items'])) > len(t['items']):
        raise IOError(f"listing truncated: {len(t['items'])} of {t['totalCount']}")
    return t['items']


def listing(source: str, owner: str, repo: str, branch: str, path: str = '') -> list[dict]:
    """Items of one directory, cached as CACHE/raw/<source>/<path with / as __>.json."""
    cache = common.CACHE / 'raw' / source / ((path.replace('/', '__') or '_root') + '.json')
    if cache.exists():
        return json.loads(cache.read_text())
    url = f'https://github.com/{owner}/{repo}/tree/{branch}/{quote(path)}'.rstrip('/')
    items = parse_tree(common.get(url).decode('utf-8'))
    common.cached(str(cache.relative_to(common.CACHE)), json.dumps(items).encode())
    return items


def raw_url(owner: str, repo: str, branch: str, path: str) -> str:
    return f'https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{quote(path)}'


def html_url(owner: str, repo: str, branch: str, path: str) -> str:
    return f'https://github.com/{owner}/{repo}/blob/{branch}/{quote(path)}'


def is_lfs_pointer(data: bytes) -> bool:
    return data[:len(LFS_MAGIC)] == LFS_MAGIC


def probe_not_lfs(url: str) -> bool:
    """True when the first bytes of url are not a Git LFS pointer (one 40-byte range request)."""
    return not is_lfs_pointer(common.get_range(url, 0, 39))
