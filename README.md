# Archive Suite

Three native macOS apps for turning shelves of historical documents into a searchable, readable,
triageable archive you can take notes from — built for historians and archivists working through tens
of thousands of scanned pages.

| App | Role | Does |
|-----|------|------|
| **Archive Processor** | *Capture · OCR · Tag* | Photograph or import document images, OCR them (Apple Vision, app-managed local MLX models, or bring-your-own Gemini/Mistral/OpenRouter/Claude keys), and write archival PDFs (searchable or 2‑page image + OCR text) with per-PDF `.archivesuite.json` catalogue companions and optional Finder tags (subject, date, quality `Q1`–`Q3`, color, read state). Includes iPhone + Android capture companions (Live Capture). |
| **Archive Reader** | *Find · Read · Triage* | Read and triage the PDFs the Processor produces: discovery walks your archive folder directly — **no Spotlight**, so a stale or dead index can never hide your files (~100k PDFs in ~10 s, instant warm start from a local cache, kept live by FSEvents) — chronological navigation, filter by subject/quality/read‑state/date, full‑text search, a two‑up image+OCR viewer, safe catalogue and Finder-tag editing, and one‑keystroke Read/Unread triage. |
| **Archive Notes** | *Note · Extract · Cite* | Provenance‑first Markdown note‑taking (`.archivenotes` libraries backed by a local SQLite FTS5 index) from the documents you read: notes and extracts keep **durable links** back to the exact source page (surviving moves), Zotero references, folders / smart folders / replication, and full‑text search — designed for 100k notes / 2M words. |

They are **three separate apps by design** — you can run any one alone — but they share one contract
and ship together. The Processor *writes* archival PDFs, catalogue records, and tags; the Reader *reads
and edits* them; Notes *builds on* the Reader's durable links to cite exactly where a note came from.
The shared contracts are documented in [`SPEC/tag-format.md`](SPEC/tag-format.md) and
[`SPEC/catalogue.md`](SPEC/catalogue.md).

```
   Archive Processor                         Archive Reader                        Archive Notes
   ┌───────────────────┐   archival PDFs    ┌───────────────────┐   durable links  ┌───────────────────┐
   │ capture / import  │   + catalogue /    │ find (folder walk)│  ──────────────▶ │ Markdown notes    │
   │ OCR (Vision / MLX │  ───────────────▶  │ read (image+OCR)  │   (archivereader │ extracts & quotes │
   │ / API gateways)   │    Finder tags     │ triage / filter   │    source URIs)  │ Zotero & search   │
   │ tag & classify    │                    │ edit safely       │                  │                   │
   └───────────────────┘                    └───────────────────┘                  └───────────────────┘
```

## Install

**Build from source** — see [Build from source](#build-from-source) below. That is currently the only
route: the earlier DMGs were built for private use and have been withdrawn, and no public release is
posted yet. When one is, it will appear on the
[Releases page](https://github.com/charlesapetersen/Archive-Suite/releases) as a single DMG holding
all three apps.

A note for whenever that lands: unsigned / self‑signed builds are **not notarized**. On macOS 15+
(Sequoia and later), macOS removed the old Control‑click → Open shortcut; the first time you open each
app from Applications, dismiss the Gatekeeper alert and then go to
**System Settings ▸ Privacy & Security ▸ Open Anyway**. After that they launch normally.

You can build just the apps you need, but the Suite is designed to be used together.

## The irreplaceable-files guarantee

Archival images cannot be re‑shot and their tagging is enormously time‑consuming. **Archive Reader
never deletes, moves, renames, or alters any file's bytes or location** — the *only* thing it ever
changes is a file's macOS Finder tags, and only as a deliberate, verified, reversible action routed
through a single audited writer. See [`ArchiveReader/CLAUDE.md`](ArchiveReader/CLAUDE.md) → Core
Directive.

## Repository layout

This is a **monorepo** — one clone, one place to maintain all three apps.

```
Archive-Suite/
├── README.md                  ← you are here
├── CLAUDE.md · AGENTS.md       ← umbrella dev guides (link to per-app docs, which stay authoritative)
├── SPEC/                       ← shared contracts (`tag-format.md`, `catalogue.md`, `containers.md`, …)
├── packages/ArchiveCore/       ← shared Swift package (`ArchiveCore` + `ArchiveCoreUI`: tags, PDF, catalogue, links, containers)
├── packages/VisionOCRKit/      ← local OCR / text-layer / layout / compression Swift package used by Processor
├── packages/UITestSupport/     ← shared XCUITest layout, accessibility, and transient-UI harnesses
├── release/build-suite-dmg.sh  ← builds all three apps + the one combined DMG
├── launch.sh                   ← dispatcher: ./launch.sh reader | processor | notes
├── ArchiveProcessor/           ← the Processor app (+ iOS & Android capture companions)
├── ArchiveReader/              ← the Reader app
└── ArchiveNotes/               ← the Notes app
```

Each app keeps its own authoritative `README.md`, `CLAUDE.md`, `AGENTS.md`, `launch.sh`, and
`bootstrap.sh` inside its subdirectory. Start there for app‑specific detail:
[Archive Processor](ArchiveProcessor/README.md) · [Archive Reader](ArchiveReader/README.md) ·
[Archive Notes](ArchiveNotes/README.md).

## Build from source

Requires macOS 14+, Xcode 16+, and Homebrew tools:

```bash
brew install xcodegen jbig2enc qpdf                 # XcodeGen + Processor searchable-PDF compression tools
./ops/setup-signing-cert.sh                         # one-time local code-signing cert (keeps TCC grants across rebuilds)
./ArchiveProcessor/scripts/bootstrap-pdfium.sh --download   # pinned static PDFium for Archive Processor
```

All three apps use [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` is authoritative;
the `.xcodeproj` is generated and gitignored — run `xcodegen generate` after cloning). From the repo
root:

```bash
./launch.sh reader        # regenerate-if-stale, build, and run Archive Reader
./launch.sh processor     # …or Archive Processor
./launch.sh notes         # …or Archive Notes
```

or per app: `cd ArchiveReader && ./bootstrap.sh && ./launch.sh`. See [CLAUDE.md](CLAUDE.md) for
conventions and the release process.

## Test from source

The suite smoke dispatcher starts with the shared packages, then their app consumers:

```bash
./test-smoke.sh archivecore   # ArchiveCore + ArchiveCoreUI unit tests only; free and headless
./test-smoke.sh visionocrkit  # VisionOCRKit package checks; free and headless
./test-smoke.sh all           # ArchiveCore, VisionOCRKit, Reader, Notes, then the paid Processor OCR smoke
```

Use `reader`, `notes`, or `processor` to run one app lane instead. The Processor lane makes two small OCR
requests; all other lanes are free and do not use a corpus.

**Optional — the Drive cloud relay.** Live Capture's LAN and USB transports need no setup at all. The
Google Drive relay, for reading rooms whose Wi‑Fi blocks device‑to‑device traffic, needs an OAuth
client you create yourself: it is bound to your app's package name and signing key, so no shared one
can exist. Steps: [`ArchiveProcessor/ArchiveCapture/README-oauth.md`](ArchiveProcessor/ArchiveCapture/README-oauth.md).
Builds without it work fine — only Drive sign-in is disabled.

## Status and expectations

This is a working tool built for one historian's own archive, published because it may be useful to
others doing the same work — not a supported product. It is maintained by an AI agent under the
conventions in [CLAUDE.md](CLAUDE.md), with no CI. Known limitations are recorded honestly in each
app's `KNOWN_ISSUES.md`, including an
[accepted, unfixed weakness](ArchiveProcessor/KNOWN_ISSUES.md) in the Live Capture LAN transport —
read that before using Live Capture over untrusted Wi‑Fi.

## Licence

MIT — see [LICENSE](LICENSE).
