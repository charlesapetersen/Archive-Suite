# Archive Suite

Two native macOS apps for turning shelves of historical documents into a searchable, readable,
triageable archive — built for historians and archivists working through tens of thousands of
scanned pages.

| App | Role | Does |
|-----|------|------|
| **Archive Processor** | *Capture · OCR · Tag* | Photograph or import document images, OCR them, and write a tagged 2‑page PDF (original image + selectable OCR text) with subject / date / priority / color / read‑state Finder tags. Includes iPhone + Android capture companions (Live Capture) and guided bring‑your‑own free Gemini/Mistral OCR keys. |
| **Archive Reader** | *Find · Read · Triage* | Read and triage the tagged PDFs the Processor produces: Spotlight‑fast discovery at 150k+ files, chronological navigation, filter by subject/priority/read‑state, full‑text search, a two‑up image+OCR viewer, safe tag editing, and one‑keystroke Read/Unread triage. |

They are **two separate apps by design** — you can run either alone — but they share one contract and
ship together. The Processor *writes* the tags; the Reader *reads and edits* them. That shared
tag/PDF contract is documented once, authoritatively, in [`SPEC/tag-format.md`](SPEC/tag-format.md).

```
   Archive Processor                         Archive Reader
   ┌───────────────────┐   tagged 2-page    ┌───────────────────┐
   │ capture / import  │   PDFs on disk     │ find (Spotlight)  │
   │ OCR (Gemini/      │  ───────────────▶  │ read (image+OCR)  │
   │ Mistral)          │   (Finder tags +   │ triage / filter   │
   │ tag & classify    │    OCR text)       │ edit tags safely  │
   └───────────────────┘                    └───────────────────┘
```

## Install

1. Download the latest **Archive Suite** DMG from the [Releases page](https://github.com/charlesapetersen/Archive-Suite/releases).
2. Open the DMG and **drag *both* apps onto the Applications folder** (the DMG window shows both apps
   and an Applications shortcut side by side).
3. **First launch:** the apps are ad‑hoc signed (not notarized), so the first time you open each one,
   right‑click it in Applications → **Open** → **Open**. After that they launch normally.

You can install just one if you only need half the workflow, but the Suite is designed to be used
together.

## The irreplaceable-files guarantee

Archival images cannot be re‑shot and their tagging is enormously time‑consuming. **Archive Reader
never deletes, moves, renames, or alters any file's bytes or location** — the *only* thing it ever
changes is a file's macOS Finder tags, and only as a deliberate, verified, reversible action routed
through a single audited writer. See [`ArchiveReader/CLAUDE.md`](ArchiveReader/CLAUDE.md) → Core
Directive.

## Repository layout

This is a **monorepo** — one clone, one place to maintain both apps.

```
Archive-Suite/
├── README.md                  ← you are here
├── CLAUDE.md · AGENTS.md       ← umbrella dev guides (link to per-app docs, which stay authoritative)
├── SPEC/tag-format.md          ← the shared tag/PDF contract both apps must honor identically
├── release/build-suite-dmg.sh  ← builds both apps + the one combined DMG
├── launch.sh                   ← dispatcher: ./launch.sh reader | processor
├── ArchiveProcessor/           ← the Processor app (+ iOS & Android capture companions)
└── ArchiveReader/              ← the Reader app
```

Each app keeps its own authoritative `README.md`, `CLAUDE.md`, `AGENTS.md`, `launch.sh`, and
`bootstrap.sh` inside its subdirectory. Start there for app‑specific detail:
[Archive Processor](ArchiveProcessor/README.md) · [Archive Reader](ArchiveReader/README.md).

## Build from source

Both apps use [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` is authoritative; the
`.xcodeproj` is generated and gitignored — run `xcodegen generate` after cloning). From the repo root:

```bash
./launch.sh reader        # regenerate-if-stale, build, and run Archive Reader
./launch.sh processor     # …or Archive Processor
```

or per app: `cd ArchiveReader && ./bootstrap.sh && ./launch.sh`. Requires macOS 14+, Xcode 16,
`brew install xcodegen`. See [CLAUDE.md](CLAUDE.md) for conventions and the release process.
