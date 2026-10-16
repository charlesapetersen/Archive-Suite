"""W43.corpus-build — retry with backoff around common's network calls.

Zenodo answers HTTP 429 when several readers (or one tight loop of range requests) hit it at once; common.get_range
then fails or returns an error body. Every group-A converter reads through these wrappers instead.
"""
from __future__ import annotations

import subprocess
import time

import common

TRIES = 8


def retry(fn, *args, tries: int = TRIES, base: float = 4.0):
    """Call fn(*args); on a failed fetch wait 4, 8, 16 ... (capped 120) seconds and try again."""
    for i in range(tries):
        try:
            return fn(*args)
        except (subprocess.CalledProcessError, IOError, OSError):
            if i == tries - 1:
                raise
            time.sleep(min(120.0, base * 2 ** i))


def get(url: str) -> bytes:
    return retry(common.get, url)


def get_range(url: str, start: int, end: int) -> bytes:
    return retry(common.get_range, url, start, end)


def open_zip(url: str) -> common.RemoteZip:
    """RemoteZip whose every range read retries (a 429 in the middle of the directory read included)."""
    size = retry(common.size_of, url)
    return retry(lambda: common.RemoteZip(url, size, reader=lambda a, b: get_range(url, a, b)))


def member(z: common.RemoteZip, name: str) -> bytes:
    return retry(z.member, name)
