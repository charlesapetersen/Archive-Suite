# Execution plan — de-nest the `App/App` folders

Short-term execution plan (see root `CLAUDE.md` §Docs & backlog convention). Tracked from `SUITE_TODO.md`
§P3. **Delete this file once it ships.** Paths are repo-root-relative (`~/Desktop/Claude/Archive Suite`).

> **P3.1 (Processor Implementation Map) — DONE** (2026-07-07 doc-harmony pass; both apps' `CLAUDE.md` carry
> an Implementation Map). The **`ArchiveCore` shared-package extraction moved to
> `ArchiveProcessor/POTENTIAL_FEATURES.md`** (deferred, not near-term) on 2026-07-08 — so this plan now
> tracks only the de-nest. If ArchiveCore is ever revived, do it **before** the de-nest (both churn
> `project.yml` path refs, so sequence them — no parallel worktrees on the same files).

## De-nest the `App/App` folders  `[ ]`
The merge left `ArchiveReader/ArchiveReader/` and `ArchiveProcessor/ArchiveProcessor/` (outer = relocated
app dir, inner = that app's XcodeGen project dir). Purely cosmetic; **lowest value** — broad, error-prone
path churn. Do only if the nesting bothers; otherwise leave it.

**Approach (per app, one at a time, build-verified, its own commit):** rename the inner project dir to
`macOS`, keeping the Xcode **scheme / target / product name = `ArchiveReader` / `ArchiveProcessor`** (only
the folder changes → bundle IDs & schemes untouched).
```bash
git mv ArchiveReader/ArchiveReader ArchiveReader/macOS      # then the same for ArchiveProcessor
```
- [ ] Update EVERY path ref (grep each app subtree for the old `ArchiveReader/ArchiveReader` / `ArchiveProcessor/ArchiveProcessor` segment): the app's `launch.sh` (`APPDIR=`), `bootstrap.sh`, `.gitignore` path refs, `scripts/test-*.sh` (Processor), CLAUDE Implementation Map paths, **`release/build-suite-dmg.sh`** `APPS` entries, and root `CLAUDE.md`/`AGENTS.md`/`README.md` repo-map lines.
- [ ] Regenerate + build BOTH apps and run Reader's tests; rebuild the combined DMG to confirm the release path resolves.
- **Risk:** med (a missed ref silently breaks a script/the DMG). **Verify:** both build + Reader tests + a DMG build. **Backup:** tag before starting; pure rename, so reset is clean.
