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


def bates_range(b):
    m = re.fullmatch(r"(\d+)(?:/(\d+))?", (b or "").strip())
    if not m:
        return None
    s = int(m.group(1))
    tail = m.group(2)
    return s, (int(str(s)[:len(str(s)) - len(tail)] + tail) if tail else s)


def cmd_neighbours(a):
    """Does a parent share its attachment's <ag>? AT records marked "Attached to a Responsive Document" are paired
    with the document just before them in Bates order, B&W letters and memos with the one just after, found through
    IDL; the neighbour's XML member is fetched (fetch-member) and its <ag> compared."""
    rows = [json.loads(l) for l in open(os.path.join(CACHE, "records.jsonl"))]
    path = os.path.join(CACHE, "neighbours.json")
    if a.lookup:
        import random
        random.seed(46)
        at = [x for x in rows if x["coll"] == "at" and x["tid"].startswith("z") and "Attached" in (x["rn"] or "")
              and ag_kind(x["ag"]) == "number" and bates_range(x["bates"])]
        bw = [x for x in rows if x["coll"] == "bw" and x["tid"].startswith("z") and re.search(r"LET|MEMO|Letter|Memo", x["dt"] or "")
              and ag_kind(x["ag"]) == "number" and bates_range(x["bates"])]
        out = []
        for d, x in [("prev", x) for x in random.sample(at, a.n)] + [("next", x) for x in random.sample(bw, a.n)]:
            s, e = bates_range(x["bates"])
            t = s - 1 if d == "prev" else e + 1
            docs = solr({"q": f"collectioncode:{x['coll']} AND (bn:{t} OR bn:{t}-* OR bn:*-{t})", "rows": 5,
                         "fl": "id,tid,bn,dd,ti,dt,pg"})["response"]["docs"]
            out.append(dict(dir=d, tid=x["tid"], coll=x["coll"], neighbours=[n["tid"] for n in docs if n.get("tid")]))
        json.dump(out, open(path, "w"), indent=1)
        need = sorted({f"{n[0]}.{n[1]}" for o in out for n in o["neighbours"]})
        print("members needed:", " ".join(need))
        return
    by_tid = {x["tid"]: x for x in rows}
    res = collections.Counter()
    cases = []
    for o in json.load(open(path)):
        x = by_tid[o["tid"]]
        found = [by_tid[n] for n in o["neighbours"] if n in by_tid]
        if not o["neighbours"]:
            k = "no neighbour in IDL"
        elif not found:
            k = "neighbour's member not fetched"
        elif ag_kind(x["ag"]) != "number":
            k = "own ag is 0"
        elif any(n["ag"] == x["ag"] for n in found):
            k = "same ag"
        elif any(ag_kind(n["ag"]) == "number" and abs(int(n["ag"]) - int(x["ag"])) == 1 for n in found):
            k = "ag differs by 1"
        else:
            k = "different ag"
        res[(o["coll"], k)] += 1
        cases.append(dict(tid=o["tid"], coll=o["coll"], dir=o["dir"], result=k,
                          neighbour=[dict(tid=n["tid"], ag_kind=ag_kind(n["ag"]),
                                          ag_delta=(int(n["ag"]) - int(x["ag"])) if ag_kind(n["ag"]) == "number" else None)
                                     for n in found]))
    out = dict(counts={f"{c} {k}": v for (c, k), v in sorted(res.items())}, cases=cases)
    json.dump(out, open(os.path.join(CACHE, "neighbour-test.json"), "w"), indent=1)
    print(json.dumps(out["counts"], indent=1))
    for c in cases:
        print(c)


STOP = set("the of and a an to in for on by with at from is are as or this that report list letter memo".split())


def words(s):
    return {w for w in re.findall(r"[a-z]{3,}", (s or "").lower()) if w not in STOP}


def cmd_rj_next(a):
    """RJ's text <ag> names attachments. Is the named attachment the next record in Bates order? IDL titles only."""
    import random
    rows = [json.loads(l) for l in open(os.path.join(CACHE, "records.jsonl"))]
    pool = [x for x in rows if x["coll"] == "rj" and x["tid"].startswith("z") and ag_kind(x["ag"]) == "text"
            and "FOOTNOTES" not in x["ag"].upper() and bates_range(x["bates"])]
    random.seed(46)
    res, cases = collections.Counter(), []
    for x in random.sample(pool, a.n):
        s, e = bates_range(x["bates"])
        docs = solr({"q": f"collectioncode:rj AND (bn:{e + 1} OR bn:{e + 1}-*)", "rows": 3, "fl": "tid,bn,ti,dt,dd"})["response"]["docs"]
        ov = max((len(words(x["ag"]) & words(d.get("ti"))) / max(1, len(words(x["ag"]))) for d in docs), default=None)
        k = "no next record" if ov is None else "next record is the named attachment" if ov >= 0.5 else "next record is something else"
        res[k] += 1
        cases.append(dict(tid=x["tid"], result=k, overlap=None if ov is None else round(ov, 2)))
    out = dict(pool=len(pool), counts=dict(res), cases=cases)
    json.dump(out, open(os.path.join(CACHE, "rj-next.json"), "w"), indent=1)
    print(json.dumps(out["counts"]), len(pool))


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
    for key, name in (("neighbour_test", "neighbour-test.json"), ("rj_next", "rj-next.json")):
        p = os.path.join(CACHE, name)
        stats[key] = json.load(open(p)) if os.path.exists(p) else None
    json.dump(stats, open(os.path.join(RESULTS, "date-iitcdip.json"), "w"), indent=1)
    write_md(stats)
    print(json.dumps({k: v for k, v in stats.items() if k not in ("judged", "neighbour_test", "rj_next")}, indent=1))


def write_md(st):
    bc = st["by_collection"]
    colls = [c for c in ("at", "bw", "rj", "pm", "ll", "ct", "ti") if c in bc]
    names = dict(at="American Tobacco", bw="Brown & Williamson", rj="R.J. Reynolds", pm="Philip Morris",
                 ll="Lorillard", ct="Council for Tobacco Research", ti="Tobacco Institute")
    L = ["# Dating: IIT-CDIP's <ag> and <dd> fields checked on a sample (W46.date-iitcdip)", "",
         "Written by `scripts/segbench/date_iitcdip.py report`. The question (B-dating.md test 7 and question 6): is "
         "IIT-CDIP's attachment-group element `<ag>` a cover-with-attachments relation, and is its document date "
         "`<dd>` usable, so that 200 of its documents can be a public relation and dating set? $0, network only. "
         "The text, records and page images stay in the bench cache (`date-tagging/iitcdip/`); this page carries "
         "counts and case ids only.", "",
         "## Verdict: one collection passes", "",
         "`<ag>` means three different things. At American Tobacco it is a family number: a document and the "
         "attachments filed behind it share it, so it is the cover-with-attachments relation the item hoped for. At "
         "Brown & Williamson it is a running record number, and at R.J. Reynolds a free-text list of attachment titles; "
         "neither links a cover to its attachments. `<dd>` holds up as a year label where the page carries a date. So "
         "the 200 are drawn from American Tobacco families only, and their pages are checked before they are used. "
         "The AT family reading rests so far on the records' types, titles and Bates order; the pages of a sample of "
         "families are the next check.", "",
         "## Where the data came from", "",
         f"The item said to use the Industry Documents Library API. IDL's Solr index has no `<ag>` field: its "
         f"`attachment` field is filled on {st['idl']['industry:Tobacco AND attachment:*']:,} tobacco records, every one "
         f"in the JUUL collection (born-digital email, 2015-2019), and on none of the MSA collections IIT-CDIP was "
         f"built from. IDL's PDF downloads refuse scripted requests (HTTP 403 from CloudFront). NIST now hosts "
         f"IIT-CDIP openly (data.nist.gov, mds2-2531: six text tars of gzipped XML and 648 image tars of TIFF pages). "
         f"Its README repeats that UCSF makes the documents available for research under fair use, so the "
         f"no-redistribution reading from W46.fix-date-truth-score stands. The text records keep the producers' "
         f"metadata block, where `<ag>` sits. {st['source']}, plus single members fetched by Range request, gave "
         f"{st['records']:,} records.", "",
         "## What <ag> holds, by producing company", "",
         "| collection | records | numeric `<ag>` | `0` | free-text `<ag>` | none |", "|---|---|---|---|---|---|"]
    for c in colls:
        b = bc[c]
        L.append(f"| {names[c]} ({c}) | {b['records']:,} | {b.get('ag number', 0):,} | {b.get('ag zero', 0):,} | "
                 f"{b.get('ag text', 0):,} | {b.get('ag none', 0):,} |")
    nt = st["neighbour_test"] or {"counts": {}}
    rj = st["rj_next"] or {"counts": {}}
    L += ["",
          f"- **Numeric (AT, B&W).** Almost every record has one, so it is not a flag for records that have attachments. "
          f"A family's members differ in the first or second letter of the tid, so they sit in different XML members "
          f"and a single member shows few shared values. "
          f"Of {st['numeric_ag_values']:,} distinct values, {st['shared_groups']} are shared by more than one record "
          f"(sizes {st['group_sizes']}). Members of a shared value differ only in a tid letter and lie 20 to 30 Bates "
          f"numbers apart. They are siblings filed together: a series of market snapshots, a run of magazine ads, six "
          f"patent abstracts, five 1963 letters each marked \"Attached to a Responsive Document\", the tabbed sections of "
          f"a binder. {st['shared_groups_mixed_doctype']} of the {st['shared_groups']} mix document types, and in "
          f"{st['shared_groups_year_span_ge_1']} of the {st['shared_groups_with_two_years']} with two dated members "
          f"the dates are a year or more apart.",
          "- **The Bates-neighbour test.** A B&W letter or memo and the document right after it in Bates order (found in "
          "IDL, its record fetched from NIST), and an AT record marked \"Attached to a Responsive Document\" and the "
          "document right before it: " + "; ".join(f"{k}: {v}" for k, v in nt["counts"].items()) + ". At AT the "
          "attachment and the document before it share the number in most pairs; the document before is the parent "
          "(a memo with its chart, a buck slip with its memo, a specification behind its project memo) or a sibling "
          "attachment of the same parent, and a value one apart is the next family. At B&W the next document's "
          "value is the letter's plus one, a running record number, so a B&W cover and its attachment never share it.",
          f"- **Free text (RJ).** A list of the attachments by title, author and date (\"CIGARETTE ANALYSIS REPORT, BY "
          f"SELLS RE, 771214.\"), or \"LIST OF FOOTNOTES.\". It names an enclosure but does not point to it. On "
          f"{sum(rj['counts'].values())} RJ records drawn at random (footnote lists excluded), the next record in "
          f"Bates order was the named attachment on {rj['counts'].get('next record is the named attachment', 0)}, "
          f"something else on {rj['counts'].get('next record is something else', 0)}, and absent from IDL on "
          f"{rj['counts'].get('no next record', 0)}.",
          "- **PM, Lorillard, CTR, TI.** Never present.", "",
          "## <dd> against the page", "",
          "| collection | records | full date | year and month | year only | none or dummy | dd year in the OCR text | two-digit year only | absent from the OCR |",
          "|---|---|---|---|---|---|---|---|---|"]
    for c in colls:
        b = bc[c]
        L.append(f"| {c} | {b['records']:,} | {b.get('dd full', 0):,} | {b.get('dd year+month', 0):,} | "
                 f"{b.get('dd year only', 0):,} | {b.get('dd none', 0) + b.get('dd out of range', 0):,} | "
                 f"{b.get('dd year in OCR: yyyy', 0):,} | {b.get('dd year in OCR: yy', 0):,} | "
                 f"{b.get('dd year in OCR: absent', 0):,} |")
    j = st["judged"]
    vs = collections.Counter(x["dd_vs_page"] for x in j)
    kinds = collections.Counter(x["kind"] for x in j)
    L += ["", f"First pages of {len(j)} documents with `<ag>` (14 from shared groups, 10 with free-text `<ag>`, 12 single "
          f"numeric), streamed from NIST's z.s image tar. 30 were read blind by a subagent (dates transcribed before "
          f"`<dd>` was shown) and 6 by the session. Each page's own date compared with `<dd>`: "
          + ", ".join(f"{k} {v}" for k, v in vs.most_common()) + ".", "",
          "Where the page carries a date and `<dd>` is set, the years agree on all but one. That one is a 1995 email "
          "whose table gives 1994 data. The two day-level misses are minutes dated a week after the meeting and a "
          "cover letter a day after its typed date. The month-level miss is a sheet of two pasted clippings, where "
          "`<dd>` is the earlier one. Where the page has no date (ads, charts, clippings), `<dd>` is the producer's "
          "date from elsewhere and cannot be checked on the page. `19000000` is one of the dummy values Lewis warns "
          "about. Page kinds: " + ", ".join(f"{k} {v}" for k, v in kinds.most_common()) + ".", "",
          "## What follows", "",
          "- The 200 come from AT families: a parent (`rn` a request code, not \"Attached to a Responsive Document\") "
          "and its attachments sharing `<ag>`, Bates-contiguous in IDL. Family members spread over tars paired by tid "
          "prefix, so the draw keeps families whose members all lie in one pair of image tars (`y.s` and `z.s` first) "
          "and checks each family's pages before it counts.",
          "- `<dd>` is a weak year label, not truth: 21% of records have none, and on undated pages it cannot be checked.",
          "- B&W and RJ give no relation. RJ's free text still names what a cover enclosed, a cue a relation classifier "
          "could use, but its attachment was the next record in only 2 of 40.", ""]
    open(os.path.join(RESULTS, "date-iitcdip.md"), "w").write("\n".join(L))


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
    n = s.add_parser("neighbours")
    n.add_argument("--lookup", action="store_true", help="draw the pairs and look the neighbours up in IDL")
    n.add_argument("--n", type=int, default=20)
    n.set_defaults(f=cmd_neighbours)
    j = s.add_parser("rj-next")
    j.add_argument("--n", type=int, default=40)
    j.set_defaults(f=cmd_rj_next)
    s.add_parser("report").set_defaults(f=cmd_report)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    sys.exit(main())
