#!/usr/bin/env python3
"""cross_app_contract.py — W40.d11: what the Processor wrote, read without the suite's own parsers.

The other apps must read a Processor output folder exactly as written (SPEC/tag-format.md). This script states
"as written" independently of ArchiveCore: it decodes each PDF's Finder-tag xattr with plistlib, sorts the tokens
into facets by the SPEC's grammar (re-implemented here from the SPEC, not from `DocumentTags.parse`), reads page 2
with pypdf (not PDFKit) and splits off its header by the SPEC's header layout. The result is one JSON file the
Reader journey (`ContractJourneyUITests`) and ArchiveCore's `ProcessorOutputContractTests` compare against.

  python3 ops/verify/cross_app_contract.py expect <folder of Processor output> <expected.json>

Only the Processor's own output is read: every *.pdf in the folder. A file the script cannot decode is listed under
"errors" and fails the run (exit 1), so a checker never compares against a guess.
"""
import json
import plistlib
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

TAG_XATTR = "com.apple.metadata:_kMDItemUserTags"
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December"]
# Page-2 header fields after the provenance line, in the SPEC's order (§2-page PDF structure, "Page-2 header").
HEADER_FIELDS = ["Classification", "Kind", "Document date", "Sent with", "Date evidence", "Document kind", "Title",
                 "Byline", "Publication", "Publication date", "Recipient place", "Image straightened"]
CLASSIFICATIONS = {"Document Start", "Continuation", "Box", "Folder"}
# Finder's label colours by number, as their tokens are spelled (SPEC "Color label"; Finder's own numbering).
LABEL_NAMES = {1: "Gray", 2: "Green", 3: "Purple", 4: "Blue", 5: "Yellow", 6: "Red", 7: "Orange"}
# The fields a `Checked <Field>` token may name (SPEC "Field check"); any other `Checked …` is a subject.
CHECKABLE = {"date", "sent with", "document kind", "title", "byline", "publication", "publication date",
             "recipient place", "sender", "recipient", "sending place"}


def read_tags(pdf: Path):
    """The raw xattr's tag entries as (name, colour number) pairs; None when the file has no tag xattr."""
    out = subprocess.run(["xattr", "-px", TAG_XATTR, str(pdf)], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    data = bytes.fromhex("".join(out.stdout.split()))
    entries = []
    for item in plistlib.loads(data):
        name, _, colour = item.partition("\n")
        entries.append((name, int(colour) if colour else 0))
    return entries


def facets(names, label=0):
    """The SPEC's facet grammar (§Tag facets): exact forms, last token wins, an earlier one is a subject.
    `label` is the file's Finder label number: the colour-name token that matches it is the label's own token."""
    f = {"year": None, "month": None, "day": None, "decade": None, "dateUncertain": False, "quality": None,
         "readState": None, "itemType": None, "sentWith": None, "sentWithUncertain": False, "subjects": []}
    winner = {}   # facet → the raw token currently holding it

    def take(facet, value, token):
        if facet in winner:
            f["subjects"].append(winner[facet])
        winner[facet] = token
        f[facet] = value

    for raw in names:
        t = raw.strip()
        low = t.lower()
        if low in ("read", "unread"):
            f["readState"] = "Read" if low == "read" else "Unread"   # 0-1; a second one replaces it
        elif re.fullmatch(r"Q[123]", t):
            take("quality", int(t[1]), t)
        elif re.fullmatch(r"P(7|8|9|10)", t):
            take("quality", {"P7": None, "P8": 1, "P9": 2, "P10": 3}[t], t)
        elif (m := re.fullmatch(r"([0-9]{1,2}) ([A-Za-z]+)", t)) and 1 <= int(m[1]) <= 12 \
                and m[2].lower() == MONTHS[int(m[1]) - 1].lower():
            take("month", int(m[1]), t)
        elif (m := re.fullmatch(r"Day ([0-9]{1,2})", t)) and 1 <= int(m[1]) <= 31:
            take("day", int(m[1]), t)
        elif re.fullmatch(r"[0-9]{3,4}", t) and int(t) > 0:
            take("year", int(t), t)
        elif re.fullmatch(r"[1-9][0-9]{1,2}0s", t):
            take("decade", int(t[:-1]), t)
        elif low == "date uncertain":
            f["dateUncertain"] = True
        elif t == "Sent With Date Uncertain":
            f["sentWithUncertain"] = True
        elif t.startswith("Sent With "):
            take("sentWith", t[len("Sent With "):], t)
        elif t in ("Box", "Folder"):
            take("itemType", t, t)
        elif low.startswith("checked ") and low[len("checked "):] in CHECKABLE:
            pass   # a person's field check; the Processor never writes one
        elif label and t == LABEL_NAMES.get(label):
            pass   # the file's own Finder label (the subject-collision rule keeps it otherwise)
        else:
            f["subjects"].append(raw)
    return f


def display_date(f):
    """The Reader's Document date cell for a file with no Sent With (SPEC §Chronological sort key display)."""
    if f["year"] is None:   # a Year supersedes a Decade (SPEC, Decade row)
        own = f"{f['decade']}s" if f["decade"] is not None else None
    elif f["month"] is None:
        own = str(f["year"])
    else:
        mon = MONTHS[f["month"] - 1][:3]
        own = f"{mon} {f['day']}, {f['year']}" if f["day"] is not None else f"{mon} {f['year']}"
    if f["sentWith"] is not None:
        return None   # not computed here: the Processor's dating route does not write Sent With on this box
    return own if own is not None else "—"


def page2_header(pdf: Path):
    """Page 2's header by the SPEC's layout, read with pypdf; None when page 2 does not start with the sentinel."""
    from pypdf import PdfReader
    reader = PdfReader(str(pdf))
    if len(reader.pages) < 2:
        return None, len(reader.pages)
    lines = [ln.rstrip() for ln in (reader.pages[1].extract_text() or "").splitlines()]
    if not lines or lines[0] != "Extracted text.":
        return None, len(reader.pages)
    h = {"originalFilename": None, "provenance": None}
    i = 1
    if i < len(lines) and " · " not in lines[i]:
        h["originalFilename"] = lines[i]
        i += 1
    if i < len(lines) and lines[i].count(" · ") == 2:
        h["provenance"] = lines[i]
        i += 1
    order = 0
    while i < len(lines):
        key, sep, value = lines[i].partition(": ")
        if not sep or key not in HEADER_FIELDS[order:]:
            break
        order = HEADER_FIELDS.index(key) + 1
        h[key] = value
        i += 1
    return h, len(reader.pages)


def expect(folder: Path, out: Path):
    files, errors = {}, []
    for pdf in sorted(folder.glob("*.pdf")):
        name = unicodedata.normalize("NFC", pdf.name)
        entries = read_tags(pdf)
        if entries is None:
            errors.append(f"{name}: no Finder-tag xattr")
            continue
        header, pages = page2_header(pdf)
        if header is None:
            errors.append(f"{name}: page 2 does not start with the header sentinel")
            continue
        names = [n for n, _ in entries]
        colours = [c for _, c in entries if c]
        f = facets(names, colours[-1] if colours else 0)
        if f["sentWith"] is not None:
            errors.append(f"{name}: carries Sent With; its Document date cell is not computed here")
        cls = header.get("Classification")
        if cls is not None and cls not in CLASSIFICATIONS:
            errors.append(f"{name}: page 2 Classification {cls!r} is not one of the SPEC's four")
        files[name] = {
            "tags": names,
            "colours": colours,
            "facets": f,
            "dateCell": display_date(f),
            "readCell": f["readState"] or "—",
            "qualityCell": f"Q{f['quality']}" if f["quality"] else "None",
            "classification": cls,
            "header": header,
            "pages": pages,
        }
    doc = {"source": str(folder), "count": len(files), "errors": errors, "files": files}
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    cls = {}
    for v in files.values():
        cls[v["classification"]] = cls.get(v["classification"], 0) + 1
    print(f"expected: {len(files)} PDFs, classifications {cls}, "
          f"{sum(1 for v in files.values() if v['facets']['year'])} with a year, "
          f"{sum(1 for v in files.values() if v['facets']['month'])} with a month, "
          f"{sum(1 for v in files.values() if v['facets']['day'])} with a day, "
          f"{sum(1 for v in files.values() if v['facets']['dateUncertain'])} Date Uncertain, "
          f"{sum(1 for v in files.values() if v['facets']['itemType'])} Box/Folder, "
          f"{sum(1 for v in files.values() if v['colours'])} with a colour; {len(errors)} errors")
    for e in errors:
        print("error:", e, file=sys.stderr)
    return 1 if errors or not files else 0


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "expect":
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        sys.exit(2)
    sys.exit(expect(Path(sys.argv[2]), Path(sys.argv[3])))
