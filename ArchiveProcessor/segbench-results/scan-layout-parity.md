# W47.wh-yolo-scans — the app's scanned-newspaper detector against the measured route, on the 15 L9 scans

Measured route: newspaper-ocr 0.11.0 (DocLayout-YOLO imgsz1280-2501, conf 0.2, PyTorch on the CPU), its
LayoutProcessor and the bench arm's keep_regions. App: `ScanNewspaperLayout` (the Core ML conversion,
`packages/VisionOCRKit/ops/convert-scan-layout.py`; the vendored LayoutProcessor in the shared runtime). $0.

- Raw detections: 1138 of 1138 paired at IoU 0.5 or more within their label, 0 unpaired, 0 extra in the app; paired IoU median 1.0000, 1st percentile 0.9960; score gap median 0.0001, 99th percentile 0.0077.
- Final regions in reading order: the same list (count, labels, order, each box IoU 0.9 or more) on 15 of 15 pages; worst box IoU on those 0.9792.

| page | raw (route / app) | unpaired / extra | regions (route / app) | same list | min IoU |
|---|---:|---:|---:|---|---:|
| newsbench__mss3413200223-28 | 75 / 75 | 0 / 0 | 56 / 56 | yes | 0.9983 |
| newsbench__mss3413201283-24 | 62 / 62 | 0 / 0 | 48 / 48 | yes | 0.9960 |
| newsbench__mss3413201309-4 | 93 / 93 | 0 / 0 | 58 / 58 | yes | 0.9955 |
| newsbench__mss3413201315-4 | 53 / 53 | 0 / 0 | 36 / 36 | yes | 0.9919 |
| newsbench__mss3413201322-4 | 56 / 56 | 0 / 0 | 37 / 37 | yes | 1.0000 |
| newsbench__mss3413201323-27 | 66 / 66 | 0 / 0 | 35 / 35 | yes | 0.9975 |
| newsbench__mss3413201417-17 | 62 / 62 | 0 / 0 | 51 / 51 | yes | 0.9979 |
| newsbench__mss3413201417-20 | 68 / 68 | 0 / 0 | 45 / 45 | yes | 0.9792 |
| newsbench__mss3413201417-25 | 124 / 124 | 0 / 0 | 62 / 62 | yes | 0.9960 |
| newsbench__mss3413201417-29 | 140 / 140 | 0 / 0 | 60 / 60 | yes | 0.9975 |
| newsbench__mss3413201573-36 | 78 / 78 | 0 / 0 | 42 / 42 | yes | 0.9983 |
| newsbench__mss3413201628-41 | 99 / 99 | 0 / 0 | 56 / 56 | yes | 0.9988 |
| newsbench__mss3413201819-6 | 76 / 76 | 0 / 0 | 58 / 58 | yes | 1.0000 |
| newsbench__mss3413201879-7 | 47 / 47 | 0 / 0 | 38 / 38 | yes | 1.0000 |
| newsbench__mss425490669-55 | 39 / 39 | 0 / 0 | 34 / 34 | yes | 1.0000 |

Time on this Mac (headless Debug Processor, the 15 pages one after another): Core ML detection median 2.05 s a page
(at most 2.47 s, pages 3,357-3,812 px wide), the layout processing in the shared runtime median 0.18 s; a second run
gave 2.02 s and 0.17 s. Memory: the whole Processor process's peak physical footprint (the kernel's ledger) was 350 MB
after the first page and 636 MB after the fifteenth, the model loaded once.

## Measurement card

- **Truth.** The measured route itself, run here (`scan_layout_parity.py oracle`): newspaper-ocr 0.11.0 at commit
  1d5c878, DocLayout-YOLO's imgsz1280-2501 checkpoint (revision 2ea5c2bf) in PyTorch 2.7.0 on the CPU, the library's
  LayoutProcessor and the bench arm's keep_regions. No reading and no text truth is involved.
- **Selection.** The 15 frozen L9 pages W46.ocr-regions read, by the bench's frozen draw; originals checked by sha256.
- **Comparison.** The same originals, decoded by PIL for the route and by ImageIO for the app; same checkpoint and
  settings. Raw boxes are paired by IoU within a label; final lists are compared position by position.
- **Noise.** Deterministic on both sides; the residual box differences (IoU 0.979 at worst) come from the two JPEG
  decoders and cv2 against Swift arithmetic in the resize, and change no count, label or order.
- **Scope.** This checks that the app reproduces the measured route's regions. It does not re-measure reading
  accuracy: the +4.6 is layout-pair-newspapers.md's, read on these regions as the library cut them, and the app reads
  them through its own partition (W46.layout-partition-fix), which that figure did not measure. Sherlock's run detected
  on the pack's copies of the pages; this one on the frozen originals.
