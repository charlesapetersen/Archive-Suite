#!/usr/bin/env python3
"""W46.date-iitcdip: does IIT-CDIP's <ag> group a cover with its attachments, and is <dd> a usable date?

    python3 date_iitcdip.py idl                     # what the Industry Documents Library API serves (counts only)
    python3 date_iitcdip.py fetch-text [--part 6]   # one NIST text tar into the bench cache (resumable)
    python3 date_iitcdip.py fields                  # parse the cached text tars; records.jsonl (private) + stats
    python3 date_iitcdip.py fetch-images [--tar z.s] [--quota shared=14,rjtext=10,single=12]
    python3 date_iitcdip.py report                  # segbench-results/date-iitcdip.{json,md}

The item asked for about 30 documents with <ag> pulled through the IDL API and judged on page images before any
200 are drawn. What the session found (2026-10-22):

- IDL's Solr API does not carry <ag> at all. Its `attachment` field (Bates numbers of attachments) is filled only in
  the JUUL collection (born-digital email, 2015-2019); none of the 1990s MSA collections IIT-CDIP was built from has
  it. IDL's PDF downloads are behind CloudFront and refuse scripted requests (403).
- NIST now hosts IIT-CDIP openly (data.nist.gov mds2-2531, NIST open licence page; the README repeats that UCSF makes
  the documents available for research under fair use): six text tars of gzipped XML (4.7 GB each, the sixth 292 MB)
  and 648 image tars of TIFF pages (about 2 GB each). The text records keep the producers' metadata block
  <ucsf200507><A>, where <ag> lives. So the sample came from NIST, not IDL, and nothing is redistributed: the text
  tar, the parsed records and the page images stay in the bench cache, and only counts and case ids are committed.

Network only (urllib); $0. Nothing here touches the owner's corpus.
"""
import argparse
import collections
import gzip
import json
import os
import re
import sys
import tarfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "..", "..", "segbench-results")
CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/date-tagging/iitcdip")
NIST = "https://data.nist.gov/od/ds/ark:/88434/mds2-2531"
SOLR = "https://metadata.idl.ucsf.edu/solr/ltdl3/select"
TEXT_SIZES = {6: 292413440}  # the sixth text tar; the others are about 4.7 GB each


def solr(params):
    url = SOLR + "?" + urllib.parse.urlencode({**params, "wt": "json"}, doseq=True)
    return json.load(urllib.request.urlopen(url, timeout=120))


def cmd_idl(_):
    """Which IDL records carry an attachment link, by collection. Counts only."""
    out = {}
    for q in ["industry:Tobacco", "industry:Tobacco AND attachment:*", "industry:Tobacco AND tid:*",
              "industry:Tobacco AND tid:* AND attachment:*"]:
        out[q] = solr({"q": q, "rows": 0})["response"]["numFound"]
    r = solr({"q": "industry:Tobacco AND attachment:*", "rows": 0, "facet": "true",
              "facet.field": "collectioncode", "facet.limit": 10, "facet.mincount": 1})
    f = r["facet_counts"]["facet_fields"]["collectioncode"]
    out["attachment by collection"] = dict(zip(f[::2], f[1::2]))
    # <ag> is not an IDL field: ag:* only matches the text "AG" in the default search field.
    out["ag:* (text match, not a field)"] = solr({"q": "ag:*", "rows": 0})["response"]["numFound"]
    os.makedirs(CACHE, exist_ok=True)
    json.dump(out, open(os.path.join(CACHE, "idl.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))


def fetch(url, path, total=None):
    """Resumable download with Range requests; the NIST link stalls and drops mid-file."""
    for attempt in range(60):
        have = os.path.getsize(path) if os.path.exists(path) else 0
        if total and have >= total:
            return
        try:
            req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
            with urllib.request.urlopen(req, timeout=120) as r, open(path, "ab") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            if not total:
                return
        except Exception as e:
            print("retry", attempt, have, e, flush=True)
            time.sleep(5)


def cmd_fetch_text(a):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, f"cdip-{a.part}.tar")
    fetch(f"{NIST}/cdip-text/cdip-{a.part}.tar", path, TEXT_SIZES.get(a.part))
    print(path, os.path.getsize(path))


def range_get(url, start, length):
    for attempt in range(8):
        try:
            req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start + length - 1}"})
            with urllib.request.urlopen(req, timeout=180) as r:
                return r.read()
        except Exception as e:
            print("retry", attempt, e, flush=True)
            time.sleep(5)
    raise RuntimeError(f"range {start}+{length} of {url}")


def cmd_index_text(a):
    """Walk the 512-byte headers of each text tar with Range requests: member name, data offset, size."""
    path = os.path.join(CACHE, "text-index.json")
    idx = json.load(open(path)) if os.path.exists(path) else {}
    for part in a.parts:
        if str(part) in idx:
            continue
        url, off, mem = f"{NIST}/cdip-text/cdip-{part}.tar", 0, []
        while True:
            b = range_get(url, off, 512)
            if len(b) < 512 or b == b"\0" * 512:
                break
            ti = tarfile.TarInfo.frombuf(b, "utf-8", "surrogateescape")
            mem.append((ti.name, off + 512, ti.size))
            off += 512 + (ti.size + 511) // 512 * 512
        idx[str(part)] = mem
        json.dump(idx, open(path, "w"))
        print(part, len(mem), mem[0][0], mem[-1][0], flush=True)


def cmd_fetch_member(a):
    """One gzipped XML member (one two-letter tid prefix, e.g. i.s) out of a text tar, by Range request."""
    idx = json.load(open(os.path.join(CACHE, "text-index.json")))
    os.makedirs(os.path.join(CACHE, "members"), exist_ok=True)
    for prefix in a.prefixes:
        name = f"iitcdip.{prefix}.xml.gz"
        dest = os.path.join(CACHE, "members", name)
        if os.path.exists(dest):
            continue
        part, off, size = next((p, o, s) for p, mem in idx.items() for n, o, s in mem if n == name)
        data = range_get(f"{NIST}/cdip-text/cdip-{part}.tar", off, size)
        open(dest + ".part", "wb").write(data)
        os.replace(dest + ".part", dest)
        print(name, size, flush=True)


def text_members():
    """Every complete gzipped XML member of every cached text tar (a partial tail is skipped), then members/."""
    mdir = os.path.join(CACHE, "members")
    for name in sorted(os.listdir(mdir)) if os.path.isdir(mdir) else []:
        if name.endswith(".xml.gz"):
            yield "members", name, gzip.decompress(open(os.path.join(mdir, name), "rb").read()).decode("latin-1")
    for name in sorted(os.listdir(CACHE)):
        if not re.fullmatch(r"cdip-\d\.tar", name):
            continue
        with open(os.path.join(CACHE, name), "rb") as fh:
            t = tarfile.open(fileobj=fh, mode="r|")
            try:
                for m in t:
                    try:
                        data = gzip.decompress(t.extractfile(m).read()).decode("latin-1")
                    except Exception:
                        return
                    yield name, m.name, data
            except tarfile.ReadError:
                return


def tag(block, t):
    m = re.search(rf"<{t}(?: [^>]*)?>(.*?)</{t}>", block, re.S)
    return m.group(1).strip() if m else None


def dd_kind(dd):
    if not dd or not re.fullmatch(r"\d{8}", dd) or dd[:4] == "0000":
        return "none"
    if not 1880 <= int(dd[:4]) <= 2003:
        return "out of range"
    return "full" if dd[4:6] != "00" and dd[6:] != "00" else ("year+month" if dd[4:6] != "00" else "year only")


def cmd_fields(_):
    rows, members = [], []
    for tarname, member, data in text_members():
        members.append(f"{tarname}:{member}")
        for r in re.findall(r"<record>.*?</record>", data, re.S):
            a = re.search(r"<A ID.*?</A>", r, re.S)
            b = a.group(0) if a else ""
            ot = tag(r, "ot") or ""
            rows.append(dict(tid=tag(r, "tid"), coll=(tag(b, "PV") or "? ").split()[0], ag=tag(b, "ag") or None,
                             bates=tag(b, "br"), dt=tag(b, "dt"), title=(tag(b, "K") or "")[:120], yr=tag(b, "YR"),
                             dd=tag(r, "dd"), rn=tag(b, "rn"), pages=tag(r, "pg"), ocr_chars=len(ot),
                             dd_year_in_ocr=None if dd_kind(tag(r, "dd")) in ("none", "out of range") or len(ot) < 50
                             else ("yyyy" if tag(r, "dd")[:4] in ot else
                                   "yy" if re.search(r"(?<!\d)" + tag(r, "dd")[2:4] + r"(?!\d)", ot) else "absent")))
    with open(os.path.join(CACHE, "records.jsonl"), "w") as f:
        for x in rows:
            f.write(json.dumps(x) + "\n")
    json.dump(members, open(os.path.join(CACHE, "members.json"), "w"))
    print(len(rows), "records from", len(members), "XML members")


def ag_kind(ag):
    return "none" if ag is None else "zero" if ag == "0" else "number" if ag.isdigit() else "text"


def groups(rows):
    g = collections.defaultdict(list)
    for x in rows:
        if ag_kind(x["ag"]) == "number":
            g[(x["coll"], x["ag"])].append(x)
    return g


def cmd_fetch_images(a):
    """Stream one NIST image tar (its members are NOT in id order) and keep the pages of a quota of wanted docs."""
    rows = [json.loads(l) for l in open(os.path.join(CACHE, "records.jsonl"))]
    prefix = a.tar.replace(".", "")
    shared = {x["tid"] for v in groups(rows).values() if len(v) > 1 for x in v}
    wanted = {}
    for x in rows:
        if x["tid"].startswith(prefix) and ag_kind(x["ag"]) in ("number", "text"):
            wanted[x["tid"]] = "shared" if x["tid"] in shared else ("rjtext" if ag_kind(x["ag"]) == "text" else "single")
    quota = {k: int(v) for k, v in (p.split("=") for p in a.quota.split(","))}
    out = os.path.join(CACHE, "images")
    got, kept, t0 = collections.Counter(), set(), time.time()
    t = tarfile.open(fileobj=urllib.request.urlopen(f"{NIST}/cdip-images/images.{a.tar}.tar", timeout=300), mode="r|")
    for m in t:
        parts = m.name.split("/")
        doc = parts[-2] if len(parts) >= 2 else ""
        k = wanted.get(doc)
        if k and m.isfile() and (doc in kept or got[k] < quota.get(k, 0)):
            if doc not in kept:
                kept.add(doc)
                got[k] += 1
                print(k, doc, dict(got), int(time.time() - t0), "s", flush=True)
            dest = os.path.join(out, doc, parts[-1])
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(t.extractfile(m).read())
        if all(got[q] >= quota[q] for q in quota) and doc not in kept:
            break
    json.dump(sorted(kept), open(os.path.join(CACHE, f"images-{a.tar}.json"), "w"))
    print("kept", dict(got))


def cmd_report(_):
    rows = [json.loads(l) for l in open(os.path.join(CACHE, "records.jsonl"))]
    idl = json.load(open(os.path.join(CACHE, "idl.json")))
    judged = json.load(open(os.path.join(CACHE, "judgements.json")))
    by = collections.defaultdict(collections.Counter)
    for x in rows:
        by[x["coll"]]["records"] += 1
        by[x["coll"]]["ag " + ag_kind(x["ag"])] += 1
        by[x["coll"]]["dd " + dd_kind(x["dd"])] += 1
        if x["dd_year_in_ocr"]:
            by[x["coll"]]["dd year in OCR: " + x["dd_year_in_ocr"]] += 1
    g = groups(rows)
    sizes = collections.Counter(min(len(v), 6) for v in g.values())
    shared = [v for v in g.values() if len(v) > 1]
    spans = sorted(max(ys) - min(ys) for v in shared
                   if len(ys := [int(x["yr"][:4]) for x in v if x["yr"] and x["yr"][:4].isdigit() and x["yr"][:4] != "0000"]) >= 2)
    stats = dict(
        source="NIST mds2-2531 cdip-text/cdip-6.tar (the only text tar fetched)",
        records=len(rows), by_collection={k: dict(v) for k, v in sorted(by.items())},
        numeric_ag_values=len(g), group_sizes={("6+" if k == 6 else str(k)): v for k, v in sorted(sizes.items())},
        shared_groups=len(shared), shared_groups_mixed_doctype=sum(len({x["dt"] for x in v}) > 1 for v in shared),
        shared_groups_year_span_ge_1=sum(s >= 1 for s in spans), shared_groups_with_two_years=len(spans),
        shared_groups_marked_attached=sum(any("Attached" in (x["rn"] or "") for x in v) for v in shared),
        idl=idl, judged=judged)
    json.dump(stats, open(os.path.join(RESULTS, "date-iitcdip.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in stats.items() if k not in ("judged",)}, indent=1))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    s = p.add_subparsers(dest="cmd", required=True)
    s.add_parser("idl").set_defaults(f=cmd_idl)
    t = s.add_parser("fetch-text")
    t.add_argument("--part", type=int, default=6)
    t.set_defaults(f=cmd_fetch_text)
    x = s.add_parser("index-text")
    x.add_argument("--parts", type=int, nargs="+", default=[1, 2, 3, 4, 5, 6])
    x.set_defaults(f=cmd_index_text)
    m = s.add_parser("fetch-member")
    m.add_argument("prefixes", nargs="+")
    m.set_defaults(f=cmd_fetch_member)
    s.add_parser("fields").set_defaults(f=cmd_fields)
    i = s.add_parser("fetch-images")
    i.add_argument("--tar", default="z.s")
    i.add_argument("--quota", default="shared=14,rjtext=10,single=12")
    i.set_defaults(f=cmd_fetch_images)
    s.add_parser("report").set_defaults(f=cmd_report)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    sys.exit(main())
