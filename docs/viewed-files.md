# Viewed files — design draft

Status: implemented. Where the code differs from this text:

- A seen pair is only stored for a path that has marks: without marks there's no `●` to decide.
- `]f`/`[f` stop silently at the end of the list while other unviewed files remain; "no unviewed file left"
  only when there are none.
- `Unstaged (n)`/`Staged (n)` count viewed files too.
- An untracked directory (an embedded repository) takes its id from `rev-parse HEAD`, like a submodule.

## The ask

While reviewing, mark a file as "seen". It gets out of the way until its change changes, then comes back.
Every view works the same way, with or without a PR: marks are diffy's own, never GitHub's "Viewed" checkbox.

## What it looks like

- In the file tree, `m` toggles the file under the cursor. From a diff window, `<leader>dm` toggles the file
  shown. Both are configurable. `:Diffy viewed` toggles the file shown; `:Diffy viewed clear` drops its marks.
- On a folder, a section header or the Viewed group's header, `m` marks every file under it, unless they're
  all viewed already: then it unmarks them all.
- Viewed files move to a folded `Viewed (n)` group at the top of their section (Unstaged, Staged, or the
  whole tree when there are no sections). The group unfolds while it holds the file shown in the diff, and
  folds back once that file leaves it, unless you unfolded it yourself.
- `]f`/`[f` skip viewed files, and so does the file diffy opens first after a refresh. Marking the file shown
  moves to the next unviewed file, like ticking the box on GitHub collapses it.
- With no unviewed file left, `]f`/`[f` and marking the last one stay where they are and say so; after a
  refresh, the first file opens anyway.
- A file that was viewed and has changed since comes back to its normal place with `●` (`DiffyViewedChanged`)
  until you've seen the new version, so you can tell it's a return and not a new file.

## What "changed" means

A mark records the file's change as shown at that moment: the blob on the left and the blob on the right.
The file stays viewed as long as the view you're in shows exactly that pair again.

```
viewed  ⇔  (left blob, right blob) of the file in the current view  ∈  marks recorded for it
●       ⇔  not viewed, the path has marks, and the current pair isn't the one you last saw
```

"The one you last saw" is the pair recorded each time the file is shown in the diff: when you open it, and
again whenever it changes while shown. So the file you're looking at never gets `●`, and opening a returned
file deletes no mark: other views keep theirs.

What this gives, in the case from the report (`:Diffy branch`, working tree plus every commit selected,
merge-base → worktree):

| You do | Left | Right | Still viewed |
|---|---|---|---|
| commit, stage, amend, reword, squash the file's changes | same | same | yes |
| an agent edits another file | same | same | yes |
| an agent edits this file | same | new | no, `●` |
| edit it from the diff and `:w` | same | new | no, no `●` (you're looking at it) |
| edit it, then undo the edit | same | same | yes |
| rebase on a base that didn't touch the file | same | same | yes |
| rebase on a base that did touch it | new | new | no, `●` |
| rename without content change (`R` entry) | same | same | yes: the old path's marks count |
| `mv` without `git add -N` (shows as `D` + `?`) | — | — | no: two new entries, nothing marked |
| move a submodule to another commit | same | new | no, `●` |

A file marked in one view counts as viewed in another only if that view shows the same two blobs: a mark
made on a single commit won't hide the file in `:Diffy branch`, and the other way round. Marks made in
different views of the same path coexist, so going back to `:Diffy branch` finds its marks intact.

### Alternatives considered

- **Right blob only** ("I've seen this version"): survives a base rebase that touched the file, but also
  hides a file whose *base* changed under it, which is exactly the change you'd want to look at. Rejected.
- **Blob pair across paths** (so a rename finds its marks anywhere): identical files share a pair, so marking
  one deleted copy or one new empty file (`0000000` → `e69de29`) marks all of them. Rejected for the old-path
  lookup above.
- **Patch identity** (hunks without line numbers, like `git patch-id`): survives a base rebase that touched
  the file elsewhere. Costs the full patch text on every tree render. Measured on
  `~/codspeed/platform`: 34 files / 93 KB, 31 ms git + 14 ms hashing in Lua; 322 files / 5.5 MB, 332 ms +
  250 ms; 895 files / 8 MB, 833 ms + 274 ms. The hashing runs on the main thread. Later, as a second key, if
  base rebases turn out to be noisy.

### Getting the blobs

No extra git call for committed or staged content: `git diff --raw -z -M` gives both blob ids per file, plus
the status letter and paths that `--name-status` gives today, so the tree's name-status call switches to
`--raw`. Committed and staged sides always have their id; so do intent-to-add files and worktree renames.

The rest, one batch per render, after the `--raw` call in the same chain, with `opts.gen`:

| Entry | Right id |
|---|---|
| `D` | all zeros, and stays so: the file is gone. Never hashed: a missing path fails the whole `hash-object --stdin-paths` call (exit 128) |
| modified, right id all zeros, regular file | `git hash-object --stdin-paths` |
| untracked regular file | same call |
| symlink (mode `120000`; untracked: `fs_lstat`) | `readlink`, then `git hash-object --stdin`: `--stdin-paths` follows the link and hashes the target's content (measured `9bc7ad0` instead of the link's `3b7781e`) |
| submodule (mode `160000`) | `git -C <path> rev-parse HEAD`: `hash-object` fails on it (`Unable to hash`) |

## Storage

`viewed.json` in the branch's diffy directory (`.git/diffy/<branch>/`, `review/store.lua`). The branch is the
one the session opened on: checkout mode detaches HEAD, and `local_backend.branch` would then return a sha.

```json
{
  "src/foo.lua": {
    "marks": [{ "left": "f00c965…", "right": "e7d512f…", "at": "2026-10-01T06:07:31Z" }],
    "seen": { "left": "f00c965…", "right": "9a1b2c3…" }
  }
}
```

- Keep the last 5 marks per path: enough for a few views, and it can't grow without bound.
- Unmarking removes the mark matching the current pair only. `:Diffy viewed clear` drops the path's marks
  and seen pair.
- A rename is stored under its new path. An `R` entry also matches the marks and seen pair of its old path.
- Several sessions on the branch: each change is applied to a fresh read of the file and the others reload
  (`docs/pr-mode.md`, Several sessions).

## Code touched

- `git/parse.lua`: a `--raw -z` parser (same token layout as name-status, with modes and ids in front).
- `panels/tree.lua`: `build_diff_entries` gets ids and modes; the hashing batch; a `Viewed` group in
  `group_rows`/`section_rows`, unfolding with the shown file; `m`; `move_file` and the initial file in
  `render` skip viewed rows.
- `diffpair.lua`: `<leader>dm`; recording the seen pair when the shown file opens or changes.
- New `viewed.lua`: load/save marks, `is_viewed(entry)`, `changed(entry)`, toggle.
- `init.lua`: `:Diffy viewed [clear]`, its completion; `keymaps.toggle_viewed` and the tree key in config.
- `git/run.lua`: `DiffyReady` event `viewed` after a toggle has redrawn the tree.
- `README.md`: tree keys, diff keys, the command, the new highlight.

## GitHub's checkbox

Not used, with or without the PR layer (`docs/pr-mode.md`): it holds one state per path for the whole PR,
nothing per commit, and it can't represent what a mark means here.

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

## Not in scope

- The conflict view (`:Diffy conflicts`, `U` files): nothing to mark.
- Partial marks (per hunk).
- "What changed since I viewed it" (a diff from the marked right blob to the current file): later. Worktree
  blobs only exist if diffy writes them (`git hash-object -w`), and `git gc` prunes unreachable ones after two
  weeks.
- Any sync with GitHub's "Viewed" checkbox, either direction.
