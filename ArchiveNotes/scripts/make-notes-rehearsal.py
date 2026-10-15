#!/usr/bin/env python3
"""Build the Archive Notes REHEARSAL store (W40.c1): larger and messier than AN-GUI-Fixture.

The GUI fixture (make-notes-fixture.sh) is four tidy notes the UITests assert on. A rehearsal
(W40.d9 writing session, W40.d10 integrations) needs a store that looks like a year of real use:
hundreds of items, deep and replicated folders, smart folders, every block kind, every date shape,
odd titles, odd line endings, dangling links, and a handful of deliberately damaged items. Each damaged
or unusual item is listed in hazards.tsv with what it is, so a journey can tell an expected oddity
from a bug.

Output (regenerable, never committed; rule in execution-plans/verification-phase/01-daemon-plan.md §C):

  ~/Library/Caches/ArchiveSuiteRehearsal/notes-store/
    MANIFEST.txt         what this is, how it was made, the counts
    hazards.tsv          one row per deliberately unusual item: id, dir, kind of hazard, expectation
    AN-GUI-Fixture/      THE STORE. Named like the GUI fixture on purpose: the DEBUG projector's
                         scratch guard (NotesTagProjector.isScratchPath) accepts only paths containing
                         /AN-GUI-Fixture/, and the VM's sandboxed UITest runner may write only
                         ~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture/. Its root marker
                         carries a DIFFERENT guid and name, so nothing mistakes it for the generated
                         fixture (NotesModel.isGeneratedNotesFixture checks both).
      .archive-suite-root.json, items/, Templates/, organization.json,
      reader-corpus/     an embedded scratch Reader root (generated text PDFs) the links point into

Stdlib only, no network, deterministic for a given --seed. Writes only under its destination, and
refuses a destination outside the rehearsal cache or the system temp dirs.

Usage:  python3 ArchiveNotes/scripts/make-notes-rehearsal.py [--items N] [--seed S] [--no-hazards]
                                                            [--dest DIR]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import plistlib
import random
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
import zlib
import struct

CACHE_ROOT = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal")
DEFAULT_DEST = os.path.join(CACHE_ROOT, "notes-store")
STORE_DIRNAME = "AN-GUI-Fixture"

NOTES_ROOT_GUID = "a11ce5e7-7e40-4c10-8000-00000000c101"   # NOT the fixture's …0001
CORPUS_ROOT_GUID = "c07b0700-7e40-4c10-8000-00000000c102"
MISSING_ROOT_GUID = "deadbeef-7e40-4c10-8000-00000000dead"  # a Reader root that exists nowhere
STORE_NAME = "AN-Rehearsal-Store"
NS = uuid.UUID("5e7c0a11-7e40-4c10-8000-0000000000c1")

SYS_ALLNOTES = "00000000-0000-0000-0000-000000000001"
SYS_INBOX = "00000000-0000-0000-0000-000000000002"
SYS_EXTRACTS = "00000000-0000-0000-0000-000000000003"

BASE = dt.datetime(2025, 9, 1, 9, 0, 0, tzinfo=dt.timezone.utc)

WORDS = (
    "memorandum budget director treasury bureau appropriation committee hearing testimony draft "
    "revision cabinet secretary deputy counsel staff paper briefing agenda minutes correspondence "
    "enclosure attachment carbon copy file folder box series accession finding aid ledger estimate "
    "deficit surplus revenue outlay ceiling authority program review proposal objection reply "
    "telegram cable dispatch annotation marginalia initials signature stamp received routed "
    "confidential declassified withdrawn sanitized redaction page fragment index summary"
).split()
SUBJECTS = [
    "fiscal policy", "Budget Bureau", "tax reform", "Council of Economic Advisers", "wage controls",
    "defense spending", "foreign aid", "Federal Reserve", "balance of payments", "gold policy",
    "urban renewal", "civil rights", "social security", "farm price supports", "highway program",
    "Intel", "intel", " INTEL ", "silicon valley", "Silicon Valley", "économie politique",
    "経済政策", "🗂 to sort", "follow up", "follow-up", "quotes", "a, b and c", "#hashtag", "x",
]
AUTHORS = [
    "Joel Dean", "Stanley S. Surrey", "Richard J. Herrnstein", "Michael K. Deaver",
    "O'Brien, Lawrence F.", "Hannaford, Peter", "\"Doc\" Holloway", "Anonymous", "李 明", "Ünal, Ayşe",
]
ODD_TITLES = [
    "Budget review: FY1966 / first draft", "...leading dots", "trailing dots...", "   padded   ",
    "Résumé — économie, 1964", "経済政策メモ", "📎 clipping with emoji", "Tab\there", "Quote \"inside\"",
    "back\\slash", "yes", "null", "#not a heading", "[bracketed]", "colon: in: title", "Untitled",
    "", "A" * 230, "Same title", "Same title", "same TITLE", "CON", "x",
]


def sanitized_title(title: str) -> str:
    """Mirror of NoteStore.sanitizedTitle (the on-disk filename the app itself would choose)."""
    s = title.replace("/", "-").replace(":", "-").replace("\n", " ").replace("\r", " ")
    s = s.strip(" \t.")
    if not s:
        s = "Untitled"
    units = s.encode("utf-16-le")
    if len(units) > 400:  # 200 UTF-16 units
        s = units[:400].decode("utf-16-le", errors="ignore")
    return s


def q(s: str) -> str:
    """Always double-quote a scalar (FrontMatterCodec.unquoteScalar reads this back exactly)."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def flow(items) -> str:
    return "[" + ", ".join(q(i) for i in items) + "]"


def iso(t: dt.datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def png(width: int, height: int, shade: int) -> bytes:
    """A valid greyscale PNG (stdlib zlib), so asset thumbnails decode."""
    raw = b"".join(b"\x00" + bytes(((x + y + shade) % 256 for x in range(width))) for y in range(height))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def text_pdf(text: str, pages: int) -> bytes:
    """A small uncompressed text PDF of `pages` pages (same shape as make-notes-fixture.sh's)."""
    text = text.encode("ascii", "replace").decode().replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    n = pages
    kids = " ".join(f"{3 + i} 0 R" for i in range(n))
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", f"<< /Type /Pages /Kids [{kids}] /Count {n} >>".encode()]
    font = 3 + 2 * n
    for i in range(n):
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 {font} 0 R >> >> "
                    f"/Contents {3 + n + i} 0 R >>".encode())
    for i in range(n):
        s = f"BT\n/F1 18 Tf\n72 720 Td\n({text} - page {i + 1}) Tj\nET\n".encode()
        objs.append(b"<< /Length %d >>\nstream\n" % len(s) + s + b"endstream")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offs = []
    for k, o in enumerate(objs, 1):
        offs.append(len(out))
        out += f"{k} 0 obj\n".encode() + o + b"\nendobj\n"
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for o in offs:
        out += f"{o:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()
    return bytes(out)


def set_finder_tags(path: str, tags) -> bool:
    """Write com.apple.metadata:_kMDItemUserTags as a binary plist (what Finder and `tag` write)."""
    data = plistlib.dumps([f"{t}\n0" for t in tags], fmt=plistlib.FMT_BINARY)
    r = subprocess.run(["/usr/bin/xattr", "-wx", "com.apple.metadata:_kMDItemUserTags", data.hex(), path],
                       capture_output=True)
    return r.returncode == 0


def title_case(tag: str) -> str:
    return " ".join(w[:1].upper() + w[1:] for w in tag.strip().split())


class Builder:
    def __init__(self, store: str, rng: random.Random, n_items: int, hazards: bool):
        self.store, self.rng, self.n, self.with_hazards = store, rng, n_items, hazards
        self.items = []        # dicts: id, title, kind, dir, md
        self.hazards = []      # (id, dir, hazard, expectation)
        self.pdfs = []         # (rel, pages)
        self.counts = {}
        self.tagged = 0

    def uid(self, label: str) -> str:
        return str(uuid.uuid5(NS, label))

    def bump(self, key: str, by: int = 1):
        self.counts[key] = self.counts.get(key, 0) + by

    def prose(self, sentences: int) -> str:
        r = self.rng
        out = []
        for _ in range(sentences):
            w = [r.choice(WORDS) for _ in range(r.randint(6, 22))]
            out.append(w[0].capitalize() + " " + " ".join(w[1:]) + r.choice([".", ".", ".", ";", "?", " —"]))
        return " ".join(out)

    # --- the embedded Reader root the links point into --------------------------------------
    def build_corpus(self):
        root = os.path.join(self.store, "reader-corpus")
        os.makedirs(root)
        with open(os.path.join(root, ".archive-suite-root.json"), "w") as f:
            json.dump({"guid": CORPUS_ROOT_GUID, "name": "AN-Rehearsal Corpus", "kind": "reader",
                       "createdAt": iso(BASE)}, f)
        folders = ["Dean Papers/Box 3", "Dean Papers/Box 3/Folder 12 — Budget", "Surrey Papers",
                   "RG 165 — War Department/Entry 79", "Résumés & drafts", "経済"]
        for i in range(40):
            folder = folders[i % len(folders)]
            name = f"{i + 1:05d} — {folder.split('/')[0]}.pdf"
            rel = f"{folder}/{name}"
            pages = 2 if i % 7 else 6
            os.makedirs(os.path.join(root, folder), exist_ok=True)
            with open(os.path.join(root, rel), "wb") as f:
                f.write(text_pdf(f"Rehearsal corpus document {i + 1}", pages))
            self.pdfs.append((rel, pages))
        with open(os.path.join(root, "sample.pdf"), "wb") as f:
            f.write(text_pdf("Rehearsal sample", 2))
        self.pdfs.append(("sample.pdf", 2))
        self.bump("corpus PDFs", len(self.pdfs))

    # --- blocks ------------------------------------------------------------------------------
    def link(self, rel: str, page, root=CORPUS_ROOT_GUID) -> str:
        qs = f"root={root}&rel={urllib.parse.quote(rel, safe='/')}&jpeg="
        if page is not None:
            qs += f"&page={page}"
        return "archivereader://reveal?" + qs

    def block(self, item_dir: str, idx: int, prior_ids):
        r = self.rng
        roll = r.random()
        if roll < 0.40:
            rel, pages = r.choice(self.pdfs)
            page = r.randint(1, pages)
            dangling = r.random() < 0.08
            if dangling:
                rel, root = rel.replace(".pdf", " (moved).pdf"), CORPUS_ROOT_GUID
                self.bump("reader-page blocks, dangling rel")
            else:
                root = MISSING_ROOT_GUID if r.random() < 0.04 else CORPUS_ROOT_GUID
                if root == MISSING_ROOT_GUID:
                    self.bump("reader-page blocks, unknown root")
            if r.random() < 0.05:
                page = pages + 3
                self.bump("reader-page blocks, page past the end")
            thumb = f"assets/p{idx}-thumb.png"
            missing_thumb = r.random() < 0.06
            if missing_thumb:
                self.bump("thumbnails referenced but missing")
            else:
                with open(os.path.join(item_dir, thumb), "wb") as f:
                    f.write(png(r.choice([24, 64, 160]), r.choice([32, 90, 220]), idx * 17))
            disp = f"{os.path.basename(rel)} — p. {page}"
            self.bump("reader-page blocks")
            return (f"<!-- block: reader-page\n     link: {self.link(rel, page, root)}\n     display: {q(disp)}\n"
                    f"     page: {page}\n     thumb: {thumb} -->\n![{disp}]({thumb})\n\n{self.prose(r.randint(1, 4))}\n")
        if roll < 0.52:
            rel, _ = r.choice(self.pdfs)
            self.bump("reader-doc blocks")
            return (f"<!-- block: reader-doc\n     link: {self.link(rel, None)}\n     display: {q(os.path.basename(rel))} -->\n"
                    f"{self.prose(r.randint(1, 3))}\n")
        if roll < 0.62:
            key = "".join(r.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))
            self.bump("zotero-item blocks")
            return (f"<!-- block: zotero-item\n     display: {q(r.choice(AUTHORS) + ', ' + str(r.randint(1940, 1990)))}\n"
                    f"     zotero: zotero://select/library/items/{key} -->\n{self.prose(r.randint(1, 3))}\n")
        if roll < 0.68:
            key = "".join(r.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))
            self.bump("zotero-attachment blocks")
            return (f"<!-- block: zotero-attachment\n     display: \"attachment.pdf\"\n"
                    f"     zotero: zotero://open-pdf/library/items/{key}?page={r.randint(1, 30)} -->\n"
                    f"{self.prose(1)}\n")
        if roll < 0.80 and prior_ids:
            target = r.choice(prior_ids)
            if r.random() < 0.1:
                target = self.uid(f"never-existed-{idx}")
                self.bump("note-passage blocks to a missing note")
            self.bump("note-passage blocks")
            return (f"<!-- block: note-passage\n     display: \"earlier note\"\n"
                    f"     note: archivenotes://open?id={target}#block-{r.randint(0, 3)} -->\n{self.prose(r.randint(1, 2))}\n")
        self.bump("plain markdown sections")
        extra = r.choice([
            "", "\n- a list item\n- another, with **bold** and _italic_\n  - nested\n",
            "\n| col | col |\n| --- | --- |\n| 1 | 2 |\n", "\n```\ncode fence <!-- block: reader-page -->\n```\n",
            "\n> quoted passage from the file\n", "\n<!-- an ordinary HTML comment, not a block -->\n",
        ])
        if r.random() < 0.03:
            extra = "\n<!-- block: reader-page\n     link: broken header with no close\n"
        if "no close" in extra:
            self.bump("unterminated block headers")
        return f"## {self.prose(1)[:60]}\n\n{self.prose(r.randint(2, 9))}{extra}\n"

    # --- items -------------------------------------------------------------------------------
    def front_matter(self, iid: str, kind: str, title: str, created: dt.datetime, modified: dt.datetime):
        r = self.rng
        fm = ["---", "schema: 1", f"id: {iid}", f"kind: {kind}", f"title: {q(title)}"]
        if r.random() < 0.7:
            fm.append(f"authors: {flow(r.sample(AUTHORS, r.randint(1, 3)))}")
        roll = r.random()
        if roll < 0.75:
            prec = r.choice(["decade", "year", "month", "day", "day", "year"])
            y = r.randint(1938, 1989)
            val = {"decade": f"{y // 10 * 10}", "year": f"{y}", "month": f"{y}-{r.randint(1, 12):02d}",
                   "day": f"{y}-{r.randint(1, 12):02d}-{r.randint(1, 28):02d}"}[prec]
            fm += [f"date: {q(val)}", f"date_precision: {prec}",
                   f"date_uncertain: {'true' if r.random() < 0.2 else 'false'}"]
            self.bump(f"dated ({prec})")
            if r.random() < 0.12:
                fm += ["additional_dates:", "  - role: sent_with", f"    date: \"{y + 1}\"", "    precision: year",
                       "    uncertain: false"]
                self.bump("sent_with dates")
            if r.random() < 0.05:
                fm.append(f"display_calendar: {r.choice(['julian', 'julian-1752'])}")
                self.bump("display_calendar set")
        else:
            self.bump("undated")
        if r.random() < 0.6:
            fm.append(f"quality: {r.randint(1, 5)}")
        tags = r.sample(SUBJECTS, r.randint(0, 6))
        if tags:
            fm.append(f"tags: {flow(tags)}")
        fm.append(f"roundup: {'true' if r.random() < 0.1 else 'false'}")
        if r.random() < 0.08:
            fm += ["zotero:", f"  - selectLink: \"zotero://select/library/items/Z{r.randint(1000, 9999)}\"",
                   f"    itemKey: \"Z{r.randint(1000, 9999)}\"",
                   f"    library: {q(r.choice(['library', '4711']))}", "    kind: item",
                   f"    citation: {q(r.choice(AUTHORS) + ' (1962)')}"]
            self.bump("front-matter zotero refs")
        if r.random() < 0.04:
            fm.append("x_custom_key: kept verbatim by the codec")
            self.bump("unknown front-matter keys")
        fm += [f"created: {iso(created)}", f"modified: {iso(modified)}", "---"]
        return fm, tags

    def write_item(self, i: int, kind: str):
        r = self.rng
        iid = self.uid(f"item-{i}")
        title = ODD_TITLES[i] if i < len(ODD_TITLES) else (
            f"{r.choice(['Notes on', 'Memo:', 'Re', 'Draft —', ''])} {self.prose(1)[:r.randint(12, 70)]}".strip())
        created = BASE + dt.timedelta(hours=r.randint(0, 24 * 400))
        modified = created + dt.timedelta(minutes=r.randint(0, 60 * 24 * 60))
        fm, tags = self.front_matter(iid, kind, title, created, modified)
        prior = [it["id"] for it in self.items]
        d = os.path.join(self.store, "items", iid)
        os.makedirs(os.path.join(d, "assets"))
        nblocks = r.choice([0, 1, 1, 2, 3, 4, 6, 9, 15])
        body = "".join(self.block(d, k, prior) + "\n" for k in range(nblocks))
        if not body:
            body = self.prose(r.randint(0, 5)) + "\n"
        if i == 30:
            body = (self.prose(40) + "\n\n") * 250      # a ~1 MB note
            self.hazard(iid, d, "very large body (~1 MB)", "opens, scrolls and autosaves without a stall")
        text = "\n".join(fm) + "\n" + body
        endings = r.random()
        if i in (31, 32, 33) or endings < 0.03:
            sep = {31: "\r\n", 32: "\r", 33: None}.get(i, "\r\n")
            if sep is None:   # mixed
                text = text.replace("\n\n", "\r\r\n", 3)
                self.hazard(iid, d, "mixed line endings in the body", "body line breaks survive a save")
            else:
                text = text.replace("\n", sep)
                if i in (31, 32):
                    self.hazard(iid, d, f"{'CRLF' if sep == chr(13) + chr(10) else 'lone-CR'} line endings",
                                "loads; a save keeps the body's own endings")
            self.bump("non-LF line endings")
        fname = sanitized_title(title) + ".md"
        if i == 34:
            fname = "renamed in Finder.md"
            self.hazard(iid, d, "filename does not match the title", "loads by id; title shown from front matter")
        md = os.path.join(d, fname)
        with open(md, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        self.items.append({"id": iid, "title": title, "kind": kind, "dir": d, "md": md, "tags": tags})
        if r.random() < 0.15:
            with open(os.path.join(d, "assets", "pasted image.png"), "wb") as f:
                f.write(png(48, 48, i))
            self.bump("unreferenced assets")
        self.bump(f"items ({kind})")

    def hazard(self, iid, d, what, expect):
        rel = os.path.relpath(d, self.store) if os.path.isabs(d) else d
        self.hazards.append((iid, rel, what, expect))

    def build_hazards(self):
        """Damaged or unusual on-disk shapes a long-lived store collects. Each is listed in hazards.tsv."""
        items = os.path.join(self.store, "items")

        def mk(label, files, what, expect):
            iid = self.uid(label)
            d = os.path.join(items, iid)
            os.makedirs(d)
            for name, content in files.items():
                with open(os.path.join(d, name), "w", encoding="utf-8") as f:
                    f.write(content)
            self.hazard(iid, d, what, expect)
            return iid

        good = lambda iid, t: (f"---\nschema: 1\nid: {iid}\nkind: note\ntitle: {q(t)}\nroundup: false\n"
                               f"created: {iso(BASE)}\nmodified: {iso(BASE)}\n---\nBody of {t}.\n")
        mk("hz-no-fm", {"No front matter.md": "Just text, no front matter at all.\n"},
           "no front matter", "skipped or reported, never crashes the list, never rewritten")
        mk("hz-unterminated", {"Unterminated.md": "---\nschema: 1\nid: x\ntitle: never closed\n"},
           "unterminated front matter", "skipped or reported, never rewritten")
        mk("hz-no-id", {"No id.md": "---\nschema: 1\nkind: note\ntitle: \"No id\"\n---\nbody\n"},
           "front matter without an id", "skipped or reported")
        iid = self.uid("hz-id-mismatch")
        mk("hz-id-mismatch", {"Wrong id.md": good(self.uid("some-other-id"), "Id differs from folder")},
           "front-matter id differs from its folder name", "one consistent identity; no duplicate on save")
        iid = self.uid("hz-two-md")
        mk("hz-two-md", {"A copy.md": good(self.uid("unrelated"), "Stray copy"),
                         "Real one.md": good(iid, "Two md files, real one")},
           "two .md files in one item folder", "the one whose id matches is used (NoteStore.mdURL)")
        mk("hz-schema2", {"Future schema.md": good(self.uid("hz-schema2"), "Schema two").replace("schema: 1", "schema: 2")},
           "schema: 2 (a future version)", "opens read-only or refuses clearly; never downgraded silently")
        d = os.path.join(items, self.uid("hz-latin1"))
        os.makedirs(d)
        with open(os.path.join(d, "Latin-1.md"), "wb") as f:
            f.write(good(self.uid("hz-latin1"), "Latin one").encode() + "caf\xe9 cr\xe8me\n".encode("latin-1"))
        self.hazard(self.uid("hz-latin1"), d, "not valid UTF-8 (Latin-1 bytes in the body)",
                    "reported, never rewritten as mojibake")
        os.makedirs(os.path.join(items, self.uid("hz-empty-dir")))
        self.hazard(self.uid("hz-empty-dir"), os.path.join(items, self.uid("hz-empty-dir")),
                    "empty item folder", "ignored")
        os.makedirs(os.path.join(items, "not-a-uuid"))
        with open(os.path.join(items, "not-a-uuid", "Orphan.md"), "w") as f:
            f.write(good(self.uid("hz-orphan"), "Folder name is not a UUID"))
        self.hazard("-", "items/not-a-uuid", "item folder whose name is not a UUID", "ignored, never deleted")
        upper = self.uid("hz-upper").upper()
        mk_dir = os.path.join(items, upper)
        os.makedirs(mk_dir)
        with open(os.path.join(mk_dir, "Upper.md"), "w") as f:
            f.write(good(upper.lower(), "Upper-case folder name"))
        self.hazard(upper.lower(), mk_dir, "item folder name in upper case", "loads; saves land in the same folder")
        with open(os.path.join(items, ".DS_Store"), "wb") as f:
            f.write(b"\x00\x00\x00\x01Bud1")
        self.hazard("-", "items/.DS_Store", "Finder litter in items/", "ignored")

    def build_templates(self):
        for k, (name, body) in enumerate([("Archive visit", "## Box\n\n## Folder\n\n## What I found\n"),
                                          ("Document summary", "**Date:** \n\n**Summary:** \n")]):
            tid = self.uid(f"template-{k}")
            d = os.path.join(self.store, "Templates", tid)
            os.makedirs(os.path.join(d, "assets"))
            with open(os.path.join(d, sanitized_title(name) + ".md"), "w") as f:
                f.write(f"---\nschema: 1\nid: {tid}\nkind: note\ntitle: {q(name)}\nroundup: false\n"
                        f"created: {iso(BASE)}\nmodified: {iso(BASE)}\n---\n{body}")
        self.bump("templates", 2)

    def build_organization(self):
        r = self.rng
        epoch = int(BASE.timestamp())
        folders = [
            {"id": SYS_ALLNOTES, "kind": "smart", "name": "All Notes", "sortOrder": 0},
            {"id": SYS_INBOX, "kind": "normal", "name": "Inbox", "sortOrder": 1},
            {"id": SYS_EXTRACTS, "kind": "normal", "name": "Extracts", "sortOrder": 2},
        ]
        normal = []
        tree = [("Dean papers", None), ("Box 3", 0), ("Folder 12 — Budget", 1), ("Drafts", 2), ("Superseded", 3),
                ("Surrey papers", None), ("Drafts", 5), ("Reading", None), ("To file", None), ("経済", None),
                ("Very long folder name " + "x" * 120, None), ("Drafts", None), ("Chapter 1", None),
                ("Chapter 2", None), ("Sources", 12), ("Sources", 13), ("Empty folder", None), ("Ideas", None)]
        for k, (name, parent) in enumerate(tree):
            fid = self.uid(f"folder-{k}")
            f = {"id": fid, "kind": "normal", "name": name, "sortOrder": 3 + k}
            if parent is not None:
                f["parentId"] = self.uid(f"folder-{parent}")
            folders.append(f)
            if name != "Empty folder":
                normal.append(fid)

        def smart(name, **flt):
            q_ = {"searchText": "", "tags": [], "tagCombine": "all", "kind": "both", "qualities": [],
                  "matchesNothing": False}
            q_.update(flt)
            folders.append({"id": self.uid(f"smart-{name}"), "kind": "smart", "name": name,
                            "sortOrder": len(folders), "queryJSON": json.dumps(q_, ensure_ascii=False)})
        smart("Fiscal, any", tags=["Fiscal Policy", "Tax Reform"], tagCombine="any")
        smart("Best extracts", kind="extracts", qualities=[4, 5])
        smart("1960s", dateFrom=1960, dateTo=1969)
        smart("Roundup", roundup=True)
        smart("Search: budget", searchText="budget")
        smart("Nothing", matchesNothing=True)
        self.bump("folders (normal)", len(tree))
        self.bump("folders (smart, besides All Notes)", 6)

        memberships = []
        for it in self.items:
            if it["kind"] == "extract":
                memberships.append({"addedAt": epoch, "folderId": SYS_EXTRACTS, "itemId": it["id"]})
            roll = r.random()
            n = 0 if roll < 0.12 else 1 if roll < 0.75 else r.randint(2, 5)
            if n == 0:
                self.bump("items in no folder")
            if n >= 2:
                self.bump("items replicated into 2-5 folders")
            for fid in r.sample(normal, n):
                memberships.append({"addedAt": epoch + r.randint(0, 9_000_000), "folderId": fid, "itemId": it["id"]})
        for k in range(3):
            memberships.append({"addedAt": epoch, "folderId": normal[k], "itemId": self.uid(f"ghost-{k}")})
        self.hazard("-", "organization.json", "3 memberships naming items that do not exist",
                    "swept or ignored (sweepGhostMembershipsOnce), never shown as items")
        assignments = [{"folderId": normal[0], "templateId": self.uid("template-0")},
                       {"folderId": normal[12], "templateId": self.uid("template-1")}]
        with open(os.path.join(self.store, "organization.json"), "w", encoding="utf-8") as f:
            json.dump({"schema": 1, "assignments": assignments, "folders": folders, "memberships": memberships},
                      f, indent=2, ensure_ascii=False)
        self.bump("memberships", len(memberships))

    def project_tags(self):
        """Initial Finder-tag projection, deliberately out of step on some notes (stale/missing/extra)."""
        r = self.rng
        for it in self.items:
            want = sorted({title_case(t) for t in it["tags"] if t.strip()})
            roll = r.random()
            if roll < 0.08:
                want = want[1:]
                self.bump("tag projections missing a subject")
            elif roll < 0.14:
                want = want + ["Stale Subject"]
                self.bump("tag projections with a stale subject")
            elif roll < 0.18:
                want = want + ["Red"]  # a colour label the projector must leave alone
                self.bump("tag projections with an unrelated colour tag")
            if want and set_finder_tags(it["md"], want):
                self.tagged += 1

    def build(self):
        os.makedirs(os.path.join(self.store, "items"))
        os.makedirs(os.path.join(self.store, "Templates"))
        with open(os.path.join(self.store, ".archive-suite-root.json"), "w") as f:
            json.dump({"guid": NOTES_ROOT_GUID, "name": STORE_NAME, "kind": "notes", "createdAt": iso(BASE)}, f)
        self.build_corpus()
        for i in range(self.n):
            self.write_item(i, "extract" if self.rng.random() < 0.18 else "note")
        if self.with_hazards:
            self.build_hazards()
        self.build_templates()
        self.build_organization()
        self.project_tags()


def safe_dest(dest: str) -> str:
    real = os.path.realpath(dest)
    allowed = [os.path.realpath(CACHE_ROOT), os.path.realpath(tempfile.gettempdir()), "/private/tmp"]
    if not any(real == a or real.startswith(a + os.sep) for a in allowed) or real in allowed:
        sys.exit(f"make-notes-rehearsal: REFUSING — destination must be a subfolder of the rehearsal cache "
                 f"({CACHE_ROOT}) or a temp dir: {dest}")
    if "/Desktop/" in real or real.endswith("/ArchiveNotes/Store"):
        sys.exit(f"make-notes-rehearsal: REFUSING — protected location: {dest}")
    return real


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dest", default=DEFAULT_DEST)
    ap.add_argument("--items", type=int, default=400)
    ap.add_argument("--seed", type=int, default=40)
    ap.add_argument("--no-hazards", action="store_true", help="omit the deliberately damaged items")
    a = ap.parse_args()
    if a.items < len(ODD_TITLES) + 15:
        sys.exit(f"make-notes-rehearsal: --items must be at least {len(ODD_TITLES) + 15}")
    dest = safe_dest(a.dest)
    store = os.path.join(dest, STORE_DIRNAME)
    if os.path.exists(store):
        shutil.rmtree(store)
    os.makedirs(dest, exist_ok=True)
    b = Builder(store, random.Random(a.seed), a.items, not a.no_hazards)
    b.build()

    with open(os.path.join(dest, "hazards.tsv"), "w", encoding="utf-8") as f:
        f.write("id\tpath\thazard\texpected behaviour\n")
        for row in b.hazards:
            f.write("\t".join(row) + "\n")
    size = sum(os.path.getsize(os.path.join(p, n)) for p, _, ns in os.walk(store) for n in ns)
    now = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    lines = [
        "Archive Suite rehearsal set: Archive Notes store (W40.c1)",
        "",
        "What: a generated Notes store, larger and messier than AN-GUI-Fixture, for the Notes rehearsals",
        "W40.d9 (writing session) and W40.d10 (integrations). Synthetic text only; no archival material.",
        f"Store: {store}",
        f"       root marker guid {NOTES_ROOT_GUID}, name {STORE_NAME} (deliberately NOT the GUI fixture's).",
        "       Named AN-GUI-Fixture because the DEBUG projector's scratch guard and the VM UITest sandbox",
        "       exception both key on that path component. See verification/rehearsal.md for how to use it.",
        "",
        f"Made: {now} by ArchiveNotes/scripts/make-notes-rehearsal.py --items {a.items} --seed {a.seed}"
        + (" --no-hazards" if a.no_hazards else ""),
        "      Deterministic: the same arguments rebuild the same store byte for byte (except Finder-tag",
        "      xattrs, which are written by /usr/bin/xattr and are themselves deterministic).",
        f"Size: {size / 1048576:.1f} MiB; {b.tagged} notes carry a Finder-tag projection.",
        "",
        "Counts:",
    ] + [f"  {k}: {v}" for k, v in sorted(b.counts.items())] + [
        "",
        f"Hazards: {len(b.hazards)} deliberately unusual items, listed with the expected behaviour in",
        "         hazards.tsv beside this file. A journey that meets one of them is not finding a bug unless",
        "         the app does something other than what that row expects.",
    ]
    with open(os.path.join(dest, "MANIFEST.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(store)


if __name__ == "__main__":
    main()
