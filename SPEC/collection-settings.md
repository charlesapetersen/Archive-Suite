# Archive Suite — the collection's settings document (`SPEC/collection-settings.md`)

## Purpose & status

The Processor writes this document. The Reader and Notes read it to show what produced a collection
(`W46.settings-reader-notes`; owner, 2026-11-06). The reader they share is `packages/ArchiveCore/Sources/ArchiveCore/Collections/CollectionSettingsRecord.swift`. It sits with the collection, in its output folder, so a
second Mac can read it too. Written by `W46.settings-layers`: the writer is
`ArchiveProcessor/macOS/Sources/ArchiveProcessor/Settings/SettingsLayerStore.swift` (`CollectionSettingsFile`) and the
types are in `Settings/SettingsLayers.swift`. When this file and the code disagree, fix one of them in the same commit.

There is no production material yet (owner, 2026-08-01), so the shape may change outright. `schemaVersion` exists so
that an older build leaves a newer document alone. It is not there to carry a migration.

## Where it is

`<output folder>/.archivesuite/collection-settings.json`, and one file per run in
`<output folder>/.archivesuite/runs/<yyyyMMdd-HHmmss UTC>-<run id>.json`. The output folder is the collection. Live
Capture files each collection into its own subfolder, so each of those is a collection and gets its own record. The
`.archivesuite` folder is hidden and holds only the Suite's own files about the collection. The W47 container file is to live beside
this one (`execution-plans/containers/00-plan.md`; not written yet).

## What it holds

UTF-8 JSON, sorted keys. Dates are ISO 8601, written in whole seconds and read with or without fractional seconds.
The document:

| key | meaning |
|---|---|
| `schemaVersion` | `1`. A reader that finds a larger number must not interpret the document, and a writer must not overwrite it. |
| `createdAt` | When the document was first written. |
| `collection` | The collection's own layer: `id` (a UUID, the collection's identity), `kind` (always `"collection"`), `name` (the output folder's name when it was created), and `entries`. |
| `projectID`, `projectName` | The project the collection belongs to, if any. Projects live in the Processor's own store, so the name is copied here for a Mac that does not have the project. |

A run record holds `schemaVersion` (`1`), `id` (the run's id, also `settings.runID`), `startedAt`, `kind`,
`fileCount` and `settings`. `kind` is `processFiles`, `batch`, `preOCRed`, `reOCR`, `mixed` (PDFs read again plus
images) or `liveCapture`. `fileCount` is the files the run was started with, or for Live Capture the documents filed
into that folder. When a run is recorded:

- An image run or a paid batch is recorded once its pending record is saved, so a start the app refused leaves no
  record.
- A run that only reads PDFs again, a mixed run, or a pre-OCRed run is recorded as its work begins. These keep no
  pending run record.
- A resumed run is not recorded again.
- A Live Capture session is recorded at Finalize, in each collection folder it filed documents into.

`entries` maps a setting's name (`SettingsKey`: `hours`, `mix`, `languages`, `priorities`, `staysOnMac`, …; a stage
card's override is `override.<stage>.<part>`) to `{ "value": V, "source": S }`. The collection holds only the values
it answered itself. Everything else is read from its project and then the general settings when a batch runs. A value
a collection may not hold, such as a cluster or a key, is ignored on reading, and so is an entry of a value kind or
source this build does not know. Adding a value kind therefore needs no schema bump. Changing the shape of a field
does. A build that drops such an entry also drops it when it next writes the collection's layer, so an older Mac that
edits a collection loses a newer build's entries of new kinds.

The collection interview (W46.settings-interviews) writes these entries; the Reader and Notes may show them. It writes
only what it answered, so every other value stays inherited. `mix`, `strata`, `scripts`, `period` and `languages` are
one group: a layer that answers any of them writes all five (an empty value included, which still overrides the layer
above), so a collection's mix is never read beside a project's `strata`.

| name | `V` | meaning |
|---|---|---|
| `mix` | `numbers` | Percent of the pages by kind: `typewritten`, `printed`, `handwritten`, `forms` (measured by the kind classifier on a sample, source `measured`, until the user corrects them), and `clippings`, `newspapers`, `registers`, `mixed` (given by the user, not measured). The solver reads `registers` as `forms`. Pages that moved to a public test set are in `strata` instead. |
| `strata` | `numbers` | Percent of the pages judged on a public test set (`L4`-`L9`, `N1`-`N6`, as in `execution-plans/benchmark-corpus/00-plan.md`), on the same scale as `mix`; with `mix` it adds to 100. Derived from the mix, period, languages and scripts. |
| `period` | `string` | `"<from>-<to>"` in years; either end may be missing. |
| `languages` | `strings` | Codes: `en`, `fr`, `de`, `nl`, `es`, `pt`, `it`, `la`, `other`. |
| `scripts` | `strings` | `kurrent` and `fraktur` as plain names; another script as `"<name>:<percent>"` (`greek`, `hebrew`, `arabic`, `cyrillic`, `chinese`, `devanagari`). The Latin alphabet is the rest. |
| `priorities` | `strings` | The ranked priorities, most important first: `reading`, `findingDocuments`, `dates`, `names`. One not listed is not ranked. |
| `weights` | `numbers` | Each ranked priority's weight by the same names. Absent means 45, 30, 15, 10 by position. |
| `batchCeilingUSD`, `hours`, `checkingMinutes` | `double` | This collection's batch limits. A ceiling has effect only when the general spending habit allows money. |
| `preference` | `string` | `bestMeasured`, `cheapestWithinPoint` or `fastestWithinPoint`. |
| `staysOnMac`, `straightenReadingCopy` | `bool` | The two switches. |

`V` is `{ "type": T, "value": … }`, with `T` one of `bool`, `int`, `double`, `string`, `strings` (a list) or `numbers`
(a name → number map, such as the document mix in percent).

`S` is how the layer came to hold the value. It is Swift's synthesized enum coding, one key naming the case:
`setByUser` (`_0`: the date), `measured` (`_0`: the date, `sample`: the number of photographs), `startingPoint`
(`_0`: the starting point's name, `_1`: the date), `detected` (`_0`: the date) or `follows` (`_0`: the label of the
answer it follows, `_1`: the date; the general layer's `staysOnMac` follows "Spending" until the user sets it).

`settings` in a run record is the resolution frozen when the run started (`ResolvedSettingsSnapshot`):

| key | meaning |
|---|---|
| `schemaVersion` | `1`. |
| `runID` | The run's id. |
| `resolvedAt` | When the run started. |
| `collectionID`, `projectID`, `projectName` | Whose layers were read. |
| `macMemoryGB` | The Mac's memory. |
| `values` | Every setting with its resolved `value`, the `layer` that answered (`general`, `project`, `collection`, or absent for the built-in default), its `source`, and `layerName` (the project's name). |
| `processing` | The app's processing settings as the run read them, by their `UserDefaults` names (provider, per-provider model ids, tagging, sizing, rotation…). Never an API key, and a gateway address only as scheme, host, port and path. |

The same snapshot is kept in the run's pending record (`pending_run.json` / `pending_batch.json`,
`resolvedSettings`), outside its fingerprint. It is a record. Nothing reads it to decide how a run goes. The pending
record encodes its dates as that file's other dates are (seconds since 2001), not as ISO 8601.

## How the Reader and Notes read it

Read-only, in ArchiveCore's `CollectionSettingsRecord`, shown by ArchiveCoreUI's `CollectionRecordView`:

- **Where.** The nearest folder at or above the file's own folder whose `.archivesuite` holds the document or a `runs`
  folder. The archive root bounds the walk, so a record above the root is not found. The Reader shows the record in
  its inspector when the selection is in one folder. Notes shows it on a note for the collections its linked PDFs
  come from, at most four. Notes reads only under Reader roots that have already been granted, and it never prompts.
- **Safety.** It never writes. It looks with `lstat` and opens with `O_NOFOLLOW`. A `.archivesuite`, `runs` or record
  file that is a link, or anything other than an ordinary folder or file, is not read. A file over 1 MB is not read.
  Only the 20 newest run records are read, newest by file name; any others are only counted.
- **Leniency.** An entry or value of a kind it does not know is dropped and the rest are shown. A document or run with a
  larger `schemaVersion` is not interpreted. The view says it was written by a newer Processor. A run's date and
  kind are still shown.
- **Words.** Each value is shown in the Processor's own Settings words (`CollectionSettingsVocabulary`). The
  Processor's settings-layers test driver reads the writer's output back through this reader. It checks that every
  catalog key's label and value words match, so a label changed on one side and not the other fails the test.

## How the Processor writes it

The document is written beside the output, so its writer is Tier-2 and guarded:

- It writes only into an output folder that already exists. It creates `.archivesuite` itself, one level only.
- It never writes through a link. A `.archivesuite` or `collection-settings.json` that is a symlink, or anything
  other than an ordinary folder or file, is left alone and nothing is written.
- The document is written atomically: a temporary file, then a rename in the same folder. A run record is a new file
  created exclusively (`O_EXCL`), so it can never replace a file or follow a link.
- Only "no such file" counts as missing. A document that was read in full but is not one this build understands is
  renamed aside to `collection-settings.unreadable-<yyyyMMdd-HHmmss>.json`, never deleted, and a fresh document is
  started. Any document is left unchanged if it cannot be opened, has a newer `schemaVersion`, or is over 1 MB.
- A failure to write never stops a run. The snapshot still goes into the pending record, and the problem is logged
  and shown in Settings.

The checks look before they write. A process swapping `.archivesuite` for a link in the moment between the check and
the write could still redirect one write. That needs a hostile local process, so it is accepted.
