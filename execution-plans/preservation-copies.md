# Keep the source behind a compressed reading PDF

**Owner choice, 2026-11-21 (call 31).** Keep the exact, full-resolution intake file in a visible
**Preservation** folder beside the reading PDFs, organized into one subfolder per document. Make this a
prominent decision in Processor's initial interview. Default to keeping originals and offer an explicit
opt-out. Tell the user that the originals take extra space, that Reader can show them, and that a PDF-only
copy leaves them behind. Show actual source bytes before filing when they are known.

## What the suite keeps today

The owner wants image-and-text pairs, which are mostly handwriting, to stay more legible than the compact
searchable form. The reading-quality experiment is tracked separately as W49.proc-pair-compress-hands. Even the
current pair uses a prepared JPEG. Scaling, re-encoding, automatic straightening, manual rotation and PDF
rasterization can all remove information from the intake file. The searchable form may additionally rebuild the
page as JBIG2 or mixed raster content. The preservation rule should cover both forms wherever the suite creates
a lossy image derivative, including when searchable compression falls back to the prepared JPEG.
[Owner call 21](processing-review/answers/17-accepted-review-answers-20261119.json) ·
[Reading copy](../ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/ReadingCopy.swift) ·
[PDF contract](../SPEC/tag-format.md) ·
[Searchable compression](../packages/VisionOCRKit/Sources/VisionOCRKit/CompressedPage.swift)

Process Files can export a sized JPEG. Its byte-copy shortcut applies to some JPEGs, and a PDF input's optional
JPEG is produced from a rasterized page. Live Capture stages the bytes received from the phone before acknowledging
the upload. Finish currently checks the filed PDFs before retiring that group's staging originals. Optional JPEGs
and transient recovery staging provide different guarantees from a permanent, verified source copy. Any existing
corpus PDF whose intake scan is gone can only be preserved from the earliest file still available.
[Process Files export](../ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+Tagging.swift) ·
[JPEG encoding](../ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/ImageEncoding.swift) ·
[Capture receipt and staging](../ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift) ·
[Live staging and filing](../ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/LiveCaptureProcessor.swift)

## What to preserve and what it costs

Keep the exact file bytes at intake with their original filename and format recorded. For Live Capture this is
the phone's capture file (typically JPEG), as received by the Mac. For Process Files it is the admitted JPEG,
HEIC, PNG, TIFF or PDF, including the complete input PDF when the suite derives pages from it. A lossless TIFF or
PNG can represent decoded pixels, but cannot restore pre-JPEG detail or guarantee retention of the source's
camera metadata, colour profile, auxiliary images, or PDF content. A normalized lossless copy could be another
output if a later access requirement warrants it. Preserve the native file first.
[iOS capture](../ArchiveProcessor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Camera/CameraController.swift) ·
[Library of Congress still-image format guidance](https://www.loc.gov/preservation/resources/rfs/stillimg.html)

The added payload is the sum of the distinct source file sizes retained for a document. Count a multi-page input
PDF once and map each derived image to its original page. Leave cross-document deduplication out of the initial
design so each document can be backed up, restored and transferred on its own.

- **Measured reading PDF sizes.** The published scratch run measured 288,394, 378,334 and 49,093 bytes for the
  three photographed searchable outputs. The earlier image-and-text sample was about 2.1–2.3 MB per photographed
  page. These are reading derivatives. Source-size distributions for phone JPEGs and imported files were not
  measured for this design. [Searchable measurements](../verification/evidence/processor/W42.int-s5-compress-verification.md) ·
  [Pair measurements](../ArchiveProcessor/KNOWN_ISSUES.md)
- **Planning example.** At an assumed average of 3 MB per source photo, 1,000 distinct photos add 3 GB of retained
  source payload in decimal units. Using the observed searchable range would make that roughly 3.05–3.38 GB
  total if each page had its own photo and PDF. The 3 MB figure is illustrative. A lossless raster can be much
  larger. A 12-megapixel, 8-bit RGB raster starts at 36 MB of pixel data before lossless compression. Actual
  TIFF/PNG size depends on the image.
- Processor should show the known source byte total and the added storage before filing, using actual intake
  sizes for Live Capture as they arrive. Once staged, show the actual additional bytes for the run. Source bytes
  incur storage and transfer costs in every layout. Only embedding puts them in every copy of the reading PDF.
  Peak disk use during filing also includes staging, and local free-space figures cannot confirm cloud quota.

## Where the source would go

| Choice | Routine reading and transfer | Preservation and recovery |
| --- | --- | --- |
| **A. Visible Preservation folder (recommended)** | The reading PDF stays PDF/A-2b and small. Each containing folder can have `Preservation/<document>/` with the original files and a page map. Reader resolves the map within the granted archive. | A full copy needs the PDF and its document's preservation folder. Moving a whole containing folder carries both. Copying only the PDF leaves the originals behind. Teach the owner what to include in a backup or handoff and let Reader reveal the matching folder. |
| **B. Loose originals beside the PDF** | The reading PDF stays PDF/A-2b and small. Single-image documents are simple to inspect in Finder. | A merged document may have many originals mixed with unrelated files in the same directory. It needs the same explicit page mapping and careful selection for transfer. Same stems can collide and do not prove identity. |
| **C. Original files inside the PDF** | Every PDF carries the full source size even for ordinary reading and sync. Exact JPEG, HEIC, TIFF and other arbitrary attachments require an attachment-capable profile such as PDF/A-3. | A copied PDF carries both the reading and the source files. Reader needs attachment access and page mapping. Verify exact extraction and preservation through merging, date rewrites, Improve OCR and ordinary external saves before promising portability. [ISO PDF/A-3](https://www.iso.org/standard/57229.html) · [PDF/A-2 attachment limits](https://pdfa.org/resource/iso-19005-2-pdf-a-2/) |

A far-away originals tree or second volume would make backup and mobile storage policies independent, but a
reassociation and a second grant would be needed when roots move. Start with the folder inside the existing
archive grant. Choices A and B can use a documented source map and a reference in whichever item record is chosen
under W49.storage-one-home, or a dedicated preservation association if that decision is still pending. Pairing
must have an explicit identity check in either case. The current catalogue choice concerns editable facts and
does not determine where the original pixels or source PDF live.
[Catalogue storage decision](storage-simplify.md)

## What Reader would show

Show one **Preservation copy** row on the reading PDF. On explicit **View original**, display the source for the
selected logical image page, with the source filename and an indication of its original orientation. A single
image-and-text pair maps both views to the same input image. A merged or mixed PDF maps each image page to the
right source file and, for PDFs, the source page number. **Show in Finder** can reveal a verified external source
or its folder. The viewer continues to use the reading PDF for OCR, search, notes and durable links. The original
gets no second search result or triage tags. Exclude preservation payloads from both full scans and live
discovery, even if an intake file already carries Read or Unread tags.

Reader already has a JPEG alternate-image control that can inform the UI. Its sibling-root and stem matching
has a different purpose, so use exact associations for preservation. Record document identity, derivative
page-to-source mapping, source filename and format, relative location (or attachment identifier), byte count and
SHA-256. The source digest proves the source bytes. Give the reading copy an identity that survives legitimate
OCR or metadata edits. Check that resolved locations stay within the existing grant, including symlinks. View or
verify the payload on request only. If only the PDF traveled, show **Preservation copy missing** where an association is
known. Distinguish this from **Not recorded**, **Available to download** and **Could not verify**. If the map
itself is absent, report that uncertainty. No automatic source download on search, selection or preview.
[Reader alternate image control](../ArchiveReader/macOS/Sources/ArchiveReader/Views/DocumentWindowView.swift) ·
[JPEG partner indexing](../ArchiveReader/macOS/Sources/ArchiveReader/Search/ArchiveLibrary.swift) ·
[Durable Reader links](../packages/ArchiveCore/Sources/ArchiveCore/Links/DurableLink.swift)

## Filing and the first proof

For new lossy outputs, recommend keeping the source by default. Preserve the exact bytes before conversion or
rotation. Associate each output with the correct source after final page ordering and final naming. On Live Capture,
a preservation-enabled file is filed only after the destination PDF, required source payloads and map are present
and the source byte count and digest read back correctly. Record that success durably before the existing staging
cleanup is eligible. On a short write, collision, interruption or unavailable destination, surface the affected
document as incomplete and keep its staged originals recoverable. A retry should recognize already verified copies
and avoid overwriting conflicts. Process Files should leave the admitted sources where it found them.
Keep this behavior independent of whether a run exports a sized JPEG for convenience.

After the decision, break implementation into Processor filing and Reader display, with a shared format and
scratch fixtures. Verify exact bytes with JPEG, HEIC, TIFF and multi-page PDF inputs. Verify mapping with rotations,
two same-stem inputs, mixed/merged pages and a dropped or retried output. Simulate disk-full and interrupted
filing at each boundary, then resume and prove the source still exists and is associated correctly. Verify
read-back and PDF/A conformance after derivative rewrites. Check moving an intact folder, copying a bare PDF,
receiving unavailable or tampered source files and opening an original without auto-downloading others. Local
verification proves local filing only. Claim cloud behavior after a round-trip on an authorized scratch account.
Existing documents with missing sources remain unverified. No recovery, migration or writes against the real
corpus are part of this proposal.
