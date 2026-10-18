# Public segmentation boxes — access audit, 2026-10-18

W43.seg-corpus-build, baseline `98d4a83e`. **Neither box is built or frozen. There are no scores.**
No image fetch succeeded, no model was called, no money was spent. The later hold on paid hosted
benchmarking supersedes the original Gemini run grant; those routes remain in W43.sweep's register.

## CIA CREST

Through the owner-approved host-limited `corpus/fetch.sh`, this [archive.org query](https://archive.org/advancedsearch.php?q=identifier%3Acia-readingroom-document-cia-rdp96-00788r0017*&fl%5B%5D=identifier&fl%5B%5D=title&rows=5000&output=json)
returned 282 of 282 records. Saved response: 51,181 bytes, SHA-256
`3243cf94977348f783f6bc4022105f1a1c21cf7d0a3393e21964ea10a68accb2`.
Group identifiers by box/folder after `cia-rdp96-00788r`, then read the next four digits as document
number. There are 37 folders; 27 contain exactly `1..max(document number)`, without duplicates.
This proves only a contiguous retrieved prefix, not absence of withheld tail documents/unfilmed sides.

The plan's example folder `00170021` has 70 documents numbered 1–86, missing
15, 18, 19, 20, 22, 28, 70, 72, 73, 74, 76, 77, 78, 80, 81 and 84. **Reject it.**
Candidate gap-free folder `00170027` has 22 documents numbered 1–22. Page counts have not been checked,
so it is not yet selected. Other gap-free folders are listed in the continuation instructions by method,
not treated as approved boxes.

The [first candidate item's metadata](https://archive.org/metadata/cia-readingroom-document-cia-rdp96-00788r001700270001-5)
reports *Orientation briefing — High Performance Task Force members*, 1983-01-26. Its original PDF is
`cia-rdp96-00788r001700270001-5.pdf`, 458,724 bytes, MD5 `074aa9f6715a13079155116042ca0db0`.
Original-PDF HEAD probes through the helper stopped with these refusals:

| requested URL | redirect host refused |
|---|---|
| `https://archive.org/download/cia-readingroom-document-cia-rdp96-00788r001700270001-5/cia-rdp96-00788r001700270001-5.pdf` | `dn721803.ca.archive.org` |
| `https://cia.gov/readingroom/docs/CIA-RDP96-00788R001700270001-5.pdf` | `www.cia.gov` |

The owner explicitly said to add `archive.org` and `cia.gov`, **no other host**. Exact names were added;
subdomains were not inferred to be covered. The fetch helper correctly refuses both redirects.
CREST includes third-party reports and clippings, so do not assert all contents are US-government
public domain. Keep images/PDFs local and publish metadata/truth/scores only under the owner's
scores-only decision. Separate PDFs still need page-by-page reconciliation with the document rules.

## Lincoln Papers

`fetch.sh --stdout https://loc.gov/item/mal0440500/manifest.json` returns HTTP 403; no manifest was saved.
The web read of the www.loc.gov manifest also failed. The collection-about page returned 403 as well.

Independently streamed the existing public export
`~/Library/Caches/ArchiveSuiteRehearsal/bench-corpus/raw/btp/2026395156_csv.zip`, member
`btp_comprehensive_2026-08-28.csv`, without changing it. Its Lincoln subset has **28,816 assets in
10,061 items**, all from `lincoln_2025-12-01.csv`, all `AssetStatus=completed`. Campaigns are *Letters
to Lincoln* (28,313 assets) and *Down to Raisins: The Remaining Letters to Lincoln* (503).
The CSV starts mal0043300, mal0043800, mal0043600: row order is not collection order.
Contiguous asset suffixes `1..max` within included items do not establish that final pages are present.
The export cannot stand in for a full catalogue sequence or complete IIIF manifests.

Example mal0043300 has two included assets, for the printed Kansas–Nebraska Bill (1854); its image URL is
`https://tile.loc.gov/image-services/iiif/service:mss:mal:004:0043300:001/full/pct:100/0/default.jpg`.
Reachable image URLs alone cannot establish which images/items are missing. Do not infer missing
pages from URL patterns or silently construct a completed-transcriptions-only box.

## What unblocks the build

Gate **W43.seg-corpus-fetch-owner-ok** asks whether the owner permits `www.cia.gov` and Archive.org's
file-delivery subdomains (a checked `.archive.org` suffix, never `archive.org.evil.com`), or will supply
the original files. Lincoln additionally needs a complete catalogue run and its IIIF manifests exported
through the owner's browser, or another approved reachable official inventory. Host expansion alone
does not resolve loc.gov's HTTP 403. No access control or host refusal was worked around.

After access: measure page counts, select complete consecutive runs, audit every page against the rules,
freeze, then score free routes; paid Gemini calls wait for W43.sweep. The build stays open meanwhile.
