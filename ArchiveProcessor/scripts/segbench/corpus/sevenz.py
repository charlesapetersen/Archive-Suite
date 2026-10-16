"""W43.corpus-build — read the start of a remote solid .7z's blocks with range requests.

A solid 7z cannot be read member by member: each block (folder) is one LZMA2 stream, so a member can be decoded
only from its block's start. What is cheap is the archive's header and each block's first few members:

- `probe(url, dest)` writes a SPARSE local file the archive's full size holding only the 32-byte start header and
  the (encoded) end header, which is all `7zz l -slt` needs to list every member with its size and block.
- `fill(...)` range-reads the first bytes of one block into the same sparse file; `7zz x` then decodes the block's
  leading members (CRC-checked) without touching the zero-filled rest.

The sparse file costs only the bytes written (APFS). Needs `7zz` (brew sevenzip).
"""
from __future__ import annotations

import dataclasses
from pathlib import Path
import struct
import subprocess
import zlib

import zretry

SEVENZ = '/opt/homebrew/bin/7zz'


def number(b: bytes, i: int) -> tuple[int, int]:
    """7z variable-length UINT64 at b[i]; returns (value, next index)."""
    first, i, mask, value = b[i], i + 1, 0x80, 0
    for k in range(8):
        if first & mask == 0:
            return value | ((first & (mask - 1)) << (8 * k)), i
        value |= b[i] << (8 * k)
        i, mask = i + 1, mask >> 1
    return value, i


def start_header(h: bytes) -> tuple[int, int]:
    """(next header offset from byte 32, its size) from the 32-byte signature header."""
    if h[:6] != b"7z\xbc\xaf'\x1c":
        raise IOError('not a 7z archive')
    off, size, _ = struct.unpack('<QQI', h[12:32])
    return off, size


def encoded_header_pack(t: bytes) -> tuple[int, int] | None:
    """For an EncodedHeader (0x17) next header: (pack position from byte 32, packed size). None for a plain one."""
    if t[0] != 0x17:
        return None
    if t[1] != 0x06:
        raise IOError('encoded header without PackInfo')
    pos, i = number(t, 2)
    _, i = number(t, i)          # number of pack streams (1)
    if t[i] != 0x09:
        raise IOError('encoded header without pack sizes')
    size, _ = number(t, i + 1)
    return pos, size


def probe(url: str, dest: Path, size: int) -> Path:
    """Write the sparse stand-in for the archive at `url` (`size` bytes) to dest; skip if present."""
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    head = zretry.get_range(url, 0, 31)
    off, nsize = start_header(head)
    nh = 32 + off
    tail = zretry.get_range(url, nh, nh + nsize - 1)
    pieces = [(0, head), (nh, tail)]
    packed = encoded_header_pack(tail)
    if packed:
        a = 32 + packed[0]
        pieces.append((a, zretry.get_range(url, a, a + packed[1] - 1)))
    part = dest.with_name(dest.name + '.part')
    with open(part, 'wb') as f:
        f.truncate(size)
        for at, data in pieces:
            f.seek(at)
            f.write(data)
    part.replace(dest)
    return dest


@dataclasses.dataclass
class Member:
    name: str
    size: int
    block: int
    crc: str = ''


def parse_slt(text: str) -> tuple[list[Member], dict[int, int]]:
    """Members in archive order and each block's packed size, from `7zz l -slt` output."""
    members, packed, rec = [], {}, {}
    body = text.split('\n----------\n', 1)[-1]
    for chunk in body.split('\n\n'):
        rec = dict(line.split(' = ', 1) for line in chunk.strip().splitlines() if ' = ' in line)
        if 'Path' not in rec or 'Block' not in rec or rec.get('Folder') == '+':
            continue
        m = Member(rec['Path'], int(rec['Size']), int(rec['Block']), rec.get('CRC', ''))
        members.append(m)
        if rec.get('Packed Size') and m.block not in packed:
            packed[m.block] = int(rec['Packed Size'])
    return members, packed


def listing(archive: Path) -> tuple[list[Member], dict[int, int]]:
    out = subprocess.run([SEVENZ, 'l', '-slt', str(archive)], check=True, capture_output=True, text=True).stdout
    return parse_slt(out)


def block_starts(packed: dict[int, int]) -> dict[int, int]:
    """Byte offset of each block's packed stream (blocks are stored in order from byte 32)."""
    out, at = {}, 32
    for b in sorted(packed):
        out[b] = at
        at += packed[b]
    return out


def leading(members: list[Member], block: int, k: int) -> list[Member]:
    return [m for m in members if m.block == block][:k]


def fill(url: str, archive: Path, start: int, nbytes: int) -> None:
    """Range-read bytes start..start+nbytes-1 of the remote archive into the sparse stand-in, 50 MB at a time."""
    step = 50_000_000
    with open(archive, 'r+b') as f:
        for a in range(start, start + nbytes, step):
            b = min(start + nbytes, a + step) - 1
            f.seek(a)
            f.write(zretry.get_range(url, a, b))


def intact(path: Path, m: Member) -> bool:
    """The extracted file has the listed size and CRC32."""
    if not path.exists() or path.stat().st_size != m.size:
        return False
    return not m.crc or f'{zlib.crc32(path.read_bytes()):08X}' == m.crc.upper()


def extract(archive: Path, members: list[Member], out_dir: Path) -> list[Path]:
    """Decode the members into out_dir (flat); return the ones that came out intact, deleting any that did not.
    7-Zip may complain past the last one, where the sparse file is zeros, so its exit code is not used."""
    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run([SEVENZ, 'e', '-y', f'-o{out_dir}', str(archive), *[m.name for m in members]],
                   capture_output=True)
    good = []
    for m in members:
        p = out_dir / m.name.rsplit('/', 1)[-1]
        if intact(p, m):
            good.append(p)
        elif p.exists():
            p.unlink()
    return good
