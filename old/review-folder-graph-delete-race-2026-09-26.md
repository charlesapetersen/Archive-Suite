# Review finding: folder graph edits can race folder deletion

- Date: 2026-09-26
- Baseline: `74627e1`
- Severity: P2, folder-graph consistency / possible in-memory crash
- Status: queued as `W9.d2.review-folder-graph`

## Finding

`OrganizationStore.renameFolder` and `moveFolder` retain an index into `folders` across an awaited
`NotesIndex.updateFolder`. If `deleteFolder` removes the same folder while that write is suspended, the
continuation can subscript an invalid index or overwrite a different folder after the array shifts.

`OrganizationStore.createFolder(parent:)` does not validate or lock its parent. A child insert that crosses
`deleteFolder`'s awaited `NotesIndex.deleteFolderGraph` can leave a `parentId` that points to a deleted folder;
the schema has no parent foreign key.

Two independent Tier-2 reviewers confirmed these interleavings. They predate the membership-write drain added
for W9.d2 and remain a separate issue. No folder-structure changes were made for this finding.

## Symbols

- `OrganizationStore.renameFolder`
- `OrganizationStore.moveFolder`
- `OrganizationStore.createFolder`
- `OrganizationStore.deleteFolder`
- `NotesIndex.deleteFolderGraph`
