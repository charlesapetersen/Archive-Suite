# Archive Suite

Three native macOS apps for turning shelves of historical documents into a searchable, readable,
triageable archive you can take notes from — built for historians and archivists working through tens
of thousands of scanned pages.

| App | Role | Does |
|-----|------|------|
| **Archive Processor** | *Capture · OCR · Tag* | Photograph or import document images, OCR them, and write a tagged 2‑page PDF (original image + selectable OCR text) with subject / date / priority / color / read‑state Finder tags. Includes iPhone + Android capture companions (Live Capture) and guided bring‑your‑own free Gemini/Mistral OCR keys. |
| **Archive Reader** | *Find · Read · Triage* | Read and triage the tagged PDFs the Processor produces: discovery walks your archive folder directly — **no Spotlight**, so a stale or dead index can never hide your files (~100k PDFs in ~10 s, instant warm start from a local cache, kept live by FSEvents) — chronological navigation, filter by subject/priority/read‑state, full‑text search, a two‑up image+OCR viewer, safe tag editing, and one‑keystroke Read/Unread triage. |
| **Archive Notes** | *Note · Extract · Cite* | Provenance‑first note‑taking from the documents you read: notes and extracts that keep a **durable link** back to the exact source page (survives a computer move), Zotero references, folders / smart folders / replication, and full‑text search — designed for 100k notes / 2M words. |

They are **three separate apps by design** — you can run any one alone — but they share one contract
and ship together. The Processor *writes* the tags; the Reader *reads and edits* them; Notes *builds
on* the Reader's durable links to cite exactly where a note came from. That shared tag/PDF contract is
documented once, authoritatively, in [`SPEC/tag-format.md`](SPEC/tag-format.md).

```
   Archive Processor                         Archive Reader
   ┌───────────────────┐   tagged 2-page    ┌───────────────────┐
   │ capture / import  │   PDFs on disk     │ find (folder walk)│
   │ OCR (Gemini/      │  ───────────────▶  │ read (image+OCR)  │
   │ Mistral)          │   (Finder tags +   │ triage / filter   │
   │ tag & classify    │    OCR text)       │ edit tags safely  │
   └───────────────────┘                    └───────────────────┘
```

## Install

**Build from source** — see [Build from source](#build-from-source) below. That is currently the only
route: the earlier DMGs were built for private use and have been withdrawn, and no public release is
posted yet. When one is, it will appear on the
[Releases page](https://github.com/charlesapetersen/Archive-Suite/releases) as a single DMG holding
all three apps.

A note for whenever that lands: the apps are signed with a **self‑signed certificate and are not
notarized**, so the first time you open each one you'll need to right‑click it in Applications →
**Open** → **Open**. After that they launch normally.

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
├── SPEC/tag-format.md          ← the shared tag/PDF contract all apps must honor identically
├── packages/ArchiveCore/       ← shared Swift package (tags, PDF, durable links, suite marker)
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

All three apps use [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` is authoritative;
the `.xcodeproj` is generated and gitignored — run `xcodegen generate` after cloning). From the repo
root:

```bash
./launch.sh reader        # regenerate-if-stale, build, and run Archive Reader
./launch.sh processor     # …or Archive Processor
./launch.sh notes         # …or Archive Notes
```

or per app: `cd ArchiveReader && ./bootstrap.sh && ./launch.sh`. Requires macOS 14+, Xcode 16,
`brew install xcodegen`. See [CLAUDE.md](CLAUDE.md) for conventions and the release process.

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
