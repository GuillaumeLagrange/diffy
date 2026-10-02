# Viewed files — design draft

Status: draft for review, nothing implemented.

## The ask

While reviewing, mark a file as "seen". It gets out of the way until its change changes, then comes back.
Every view works the same way, `:Diffy pr` included: marks are diffy's own, never GitHub's "Viewed" checkbox.

## What it looks like

- In the file tree, `m` toggles the file under the cursor (on a folder or section header: every file under
  it). From a diff window, `<leader>m` toggles the file shown. `:Diffy viewed` does the same.
- `]f`/`[f` skip viewed files, and so does the file diffy opens first after a refresh.
- Marking the file you're looking at moves you to the next unviewed file, like ticking the box on GitHub
  collapses it.
- A file that was viewed and has changed since comes back to its normal place with a marker (`●`, a
  `DiffyViewedChanged` highlight) until you open it, so you can tell it's a return and not a new file.

## What "changed" means

A mark records the file's change as shown at that moment: the blob on the left and the blob on the right.
The file stays viewed as long as the view you're in shows exactly that pair again.

```
viewed  ⇔  (left blob, right blob) of the file in the current view  ∈  marks recorded for it
```

What this gives, in the case from the report (`:Diffy branch`, working tree plus every commit selected,
merge-base → worktree):

| You do | Left | Right | Still viewed |
|---|---|---|---|
| commit, stage, amend, reword, squash the file's changes | same | same | yes |
| an agent edits another file | same | same | yes |
| an agent edits this file | same | new | no |
| edit it, then undo the edit | same | same | yes |
| rebase on a base that didn't touch the file | same | same | yes |
| rebase on a base that did touch it | new | new | no |
| rename without content change | same | same | yes, if marks are looked up by blobs and not by path (see open questions) |

A file marked in one view counts as viewed in another only if that view shows the same two blobs: a mark
made on a single commit won't hide the file in `:Diffy branch`, and the other way round. Marks made in
different views of the same path coexist, so going back to `:Diffy branch` finds its marks intact.

### Alternatives considered

- **Right blob only** ("I've seen this version"): survives a base rebase that touched the file, but also
  hides a file whose *base* changed under it, which is exactly the change you'd want to look at. Rejected.
- **Patch identity** (hunks without line numbers, like `git patch-id`): survives a base rebase that touched
  the file elsewhere. Costs the full patch text on every tree render. Measured on
  `~/codspeed/platform`: 34 files / 93 KB, 31 ms git + 14 ms hashing in Lua; 322 files / 5.5 MB, 332 ms +
  250 ms; 895 files / 8 MB, 833 ms + 274 ms. The hashing runs on the main thread. Not worth it for the
  first version; easy to add later as a second key.

### Getting the blobs

No extra git call for committed or staged content: `git diff --raw -z -M` gives both blob ids per file, plus
the status letter and paths that `--name-status` gives today, so the tree's name-status call switches to
`--raw`. Measured: the right blob is all zeros for a tracked file with unstaged changes (git hasn't hashed
that content); committed and staged sides always have their id.

Those zero ids, and untracked files, need `git hash-object --stdin-paths` (one call per render, dirty paths
only, after the `--raw` call in the same chain, with `opts.gen`).

## Storage

`.git/diffy/<branch>/viewed.json`, next to `local.json`, same `review/store.lua`, same branch rule
(`local_backend.branch`):

```json
{ "src/foo.lua": [{ "left": "f00c965…", "right": "e7d512f…", "at": "2026-10-01T06:07:31Z" }] }
```

Keep the last 5 marks per path: enough for a few views, and it can't grow without bound. Unmarking removes
the mark matching the current pair only. `:Diffy viewed clear` drops the file.

## Code touched

- `git/parse.lua`: a `--raw -z` parser (same token layout as name-status, with two ids in front).
- `panels/tree.lua`: `build_diff_entries` gets ids; a `Viewed` group in `group_rows`/`section_rows`; `m`;
  `move_file` and the initial file in `render` skip viewed rows.
- `diffpair.lua`: `<leader>m` (configurable, `keymaps.toggle_viewed`).
- New `viewed.lua`: load/save marks, `is_viewed(entry)`, toggle.
- `README.md`: tree keys, diff keys, the new highlights.

## With a PR

The PR layer (`docs/pr-mode.md`) doesn't change marks: they're local, like in every other session. GitHub's
"Viewed" checkbox is neither read nor written: it holds one state per path for the whole PR, nothing per
commit, and it can't represent what a mark means here.

What it does, measured on the sandbox (throwaway PR, closed), kept for reference:
`PullRequestChangedFile.viewerViewedState` is `VIEWED`, `UNVIEWED` or `DISMISSED`, set with
`markFileAsViewed` / `unmarkFileAsViewed(pullRequestId, path)`, and fails for a path outside the PR.

| After a push where | State |
|---|---|
| the file's content changed | `DISMISSED` |
| a whitespace-only change | `DISMISSED` |
| the file was changed then reverted, in the same push | still `VIEWED` |
| a force-push rewrote every sha, no content change | still `VIEWED` |
| an empty commit | still `VIEWED` |
| the file was renamed | new path `UNVIEWED` |

## Open questions

1. **Where viewed files go.** A folded `Viewed (n)` group (my pick), dimmed in place, or hidden entirely?
   The group keeps them reachable without `:Diffy viewed clear`.
2. **Keys.** `m` in the tree and `<leader>m` in the diff windows? `v` would match GitHub, but it's visual
   mode in the tree and the diff windows.
3. **Your own edits.** If you fix a typo in a viewed file from the diff and `:w`, its right blob changes and it
   comes back. Keep it (consistent, my pick), or re-mark a file automatically when diffy itself wrote it?
4. **Renames.** Look marks up by blob pair across paths, so a pure rename stays viewed (my pick, GitHub
   doesn't), or strictly per path?
5. **"What changed since I viewed it".** The mark has the right blob, so diffy could open a diff from it to
   the current file when a viewed file comes back. For worktree content that blob only exists if diffy wrote
   it (`git hash-object -w`), and an unreachable blob is pruned by `git gc` after two weeks. Worth a second
   step, or out of scope?
6. **Marks after a rebase that touched the base.** Rule above unmarks them. If that turns out to be noisy,
   patch identity is the fix, at the cost measured above.

## Not in scope

- The conflict view (`:Diffy conflicts`, `U` files): nothing to mark.
- Partial marks (per hunk).
- Any sync with GitHub's "Viewed" checkbox, either direction.
