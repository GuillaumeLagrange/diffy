# PR layer — design draft

Status: decided, nothing implemented. The measurements under Background sync come first.

## The ask

A PR isn't a different way to look at a branch. `:Diffy` and `:Diffy branch` show the branch as they do now.
When the checked-out branch has an open PR, a GitHub layer loads on top of the session: its threads, its
conversation, your pending review. Comments are one set per branch: the agent and GitHub are two places to
submit them. There's no push or pull: diffy keeps GitHub in sync in the background.

Never in scope: PRs of branches you haven't checked out (`:Diffy pr 123`). That's another tool.

## What goes away

- `kind = 'pr'` and its gate (`github.pr_readiness`: dirty tree, unpushed commits, behind the PR head).
- `pr-<number>.json` next to `local.json`: one store per branch.
- `:Diffy review push` and `:Diffy review pull`.
- `x` resolving on GitHub right away.
- The GitHub fetch on every rebuild: `M.build` calls `github.refresh`, and every `:w` rebuilds.

`:Diffy pr` stays as `:Diffy branch` on the PR's base, and warns when the branch has no open PR.

## The layer

### Loading

- The session renders as if there were no PR. The layer attaches when `gh` answers (`DiffyReady`, event
  `pr`). Offline or without `gh`, it attaches from the cache of the last read (see the store), the PR row
  saying `offline`; with no cache, there's no layer and no warning. `github = false` in `setup` turns the
  layer off everywhere.
- The PR is found with `gh pr view <branch> --json number,url,state,baseRefName,headRefOid`, `<branch>`
  being the session's branch (HEAD may be detached in checkout mode). gh follows the branch's upstream and
  picks the PR, forks included: every later read and write goes to the repository in `url`, not `origin`'s.
  This replaces `github.find_pr` (GraphQL by `headRefName` on `origin`'s repository, missing forks and
  renamed local branches). Only an `OPEN` PR attaches.
- The base of `:Diffy branch` without an argument can't wait on the network either. Today
  `repo.resolve_base` waits on `gh pr view`, then `gh repo view`, before the first render. New order: the PR
  base from the cache, else `origin/HEAD` (`git symbolic-ref refs/remotes/origin/HEAD`, local), else
  `gh repo view`. If the layer brings a different base, the session re-renders once, keeping the selected
  commits when they're still listed, else the default selection.
  An explicit base is used as given, and the layer still attaches: threads are placed by tracking, not by
  base.
- Attaches to `:Diffy` and `:Diffy branch`, the sessions that have a review today. Not to ranges,
  `:Diffy file` or `:Diffy conflicts`.
- When a sync finds the PR merged or closed, the layer detaches: the PR row and the published threads go,
  and so does the cache. Your drafts stay.

### The PR row

First row of the log, above `Working tree`, only while the PR is open:

```
#42 Retry failed uploads · 3 to answer · 2 unpushed
```

- Number and title.
- Sync conflicts waiting for you.
- Where the branch stands against the PR head: nothing when in sync, `2 unpushed`, `behind 1`, `diverged`
  (`git rev-list --left-right --count`). When the PR head isn't a local commit, `GitHub has newer commits`:
  diffy never fetches.
- `offline` when the last read failed.

It isn't a diff entry: `J`/`K` and selections skip it. Resting the cursor on it shows the description, the
reviewers' states (`alice ✗ changes requested`, `bob ✓`) and the conversation in the float beside the log,
the way a commit's message shows. `gP` stays.

### Review markers

A review is written on a commit (`PullRequestReview.commit`). Each submitted review on a commit listed in the
log shows as a dim row right above that commit: `── alice ✗ 4 threads`. `<CR>` on it selects everything
above it: what changed since that review, which is what the reviewer will look at next.

A review whose commit isn't listed has no marker: in `:Diffy`, which lists unpushed commits only, that's
almost every review; elsewhere, a commit a force-push removed. The PR row's float lists every review anyway,
with its short sha and `not in this log` or `no longer in the branch`.

### Reading

- When: on layer load, on `R`, on `FocusGained`, and every 5 minutes while the session's tab is current
  (configurable, 0 turns the timer off); entering the tab reads if the last read is older than that.
  Whether zellij passes focus events to nvim is unverified; the timer covers it either way.
- One read at a time; a trigger during a read queues one more.
- No read on rebuilds: `:w` re-places threads from the cache.
- The read query paginates everything it reads (today a thread's comments stop at 50, reviews at 100).

## One set of threads

### The store

`.git/diffy/<branch>/threads.json` replaces `local.json` and `pr-<n>.json`. The branch is the one the
session opened on: checkout mode detaches HEAD, and `local_backend.branch` would then return a sha.

- **Migration.** Both old files (every `pr-<n>.json`) are merged into it on first load, then deleted.
  `local.json`'s ids are kept, since `review.md` refers to them; ids from `pr-<n>.json` that collide are
  renumbered.
- **Ids** are unique across processes (time plus random), not the highest number plus one as in
  `model.next_id`: two nvims would both make `t5`.
- **Contents.** Your comments, their states and flags, and a cache of the last GitHub read (PR metadata,
  published threads, reviews), replaced as a whole by every read.

Each comment of yours has two independent states:

| | |
|---|---|
| GitHub | `local` (not mirrored) · `pending` (in your pending review) · `published`, possibly with a staged edit or deletion |
| Agent | not sent · `sent` (in `review.md`) |

Threads also carry local flags: `resolve_staged`, `conflict`.

### Several sessions

Not common, so kept simple: every session sees every change, nobody owns the store.

- In one nvim, sessions on the same branch share one in-memory store; a change redraws all of them.
- Across nvims, each change is applied to a fresh read of the file and written atomically (temporary file,
  rename). The other nvims watch the file (`vim.uv.new_fs_event`) and reload. Whole states are never merged:
  that would bring back what the other session deleted. The same comment edited in two nvims at once: the
  last write wins.
- The same rule covers everything in the branch's directory: `threads.json` and `viewed.json`.
- Two nvims running the background sync at once: see Background sync.

### Placement

One rule for every thread. Today a local thread only shows in the exact view it was written in
(`model.pair_side`), and a GitHub thread in any view of the PR (`github.place_at`).

- **Source**: where the comment was written. A local comment: the commit on its side of the view it was
  written in. A GitHub thread: its comment's `commit` (else `originalCommit`) on the new side, the merge-base
  on the old side (GitHub reports old-side lines relative to the merge-base).
- **Worktree and index comments** have no stable source. They're placed by excerpt search, as today
  (`model.relocate`, ±20 lines). Once HEAD's blob has the excerpt, the comment becomes a comment on HEAD at
  those lines and is tracked like any other: that's how a draft written on the worktree reaches GitHub after
  you commit and push.
- **Targets**: a commit, by `git diff -M -U0 <source> <target>` (one call per pair, shared by every thread
  with that source); the index, by `git diff --cached -U0 <source>`; the worktree, by `vim.diff` against the
  buffer when the file is loaded, else `git diff -U0 <source>`.
- **Shown** in a view when both ends of its range map through unchanged lines (`model.map_range`); hidden
  there otherwise.
- **Outdated** when it can't be mapped to the worktree, live: the buffer as you type, so a thread goes
  outdated as soon as you touch its first or last line, and comes back if you undo. ⚠ Validate this
  behaviour before building `docs/pr-answering.md`; extmarks moving with your edits, judged on write, is the
  alternative. In checkout mode the worktree is the checked-out commit, so threads written after it show as
  outdated until you leave (the simplest rule; revisit if it gets in the way).
- **Detached** when there's no source to map from: its commit is gone locally (force-pushed away, then
  pruned), or a worktree or index comment's excerpt isn't found any more.
- The threads view keeps its groups: Open, Outdated, Detached, Resolved.

**`review.md`** gives each comment's location now (tracked to the worktree: what the agent edits) and where
it was written (commit and hunk). An outdated comment only has the second.

## Submitting

`:Diffy review submit` opens the message box. `<C-s>`, then the destination when a PR is attached: `a`
agent, `g` GitHub (then the verdict, as today; on your own PR GitHub only allows a comment). Without a PR
there's no question: it goes to the agent.

- **Each comment goes to one destination.** Submitting to the agent writes the unsent drafts to
  `review.md`, marks them `sent` and takes them out of the pending review (deleted once empty). Submitting to
  GitHub publishes the pending review.
- **Nothing anyone else can see changes before a GitHub submit.** The background sync only writes to your
  pending review, which only you see. Replies, new threads, resolves, and edits and deletions of your
  published comments wait for the submit.
- **The confirm float lists everything going out**: new threads, replies, staged edits, deletions and
  resolves. Each can be excluded: an excluded draft leaves the pending review for this submit and goes back
  into a fresh one on the next sync. It also lists what can't go (drafts GitHub can't take) and unpushed
  commits.
- **Order**: excluded drafts out of the pending review, the review, the staged edits and deletions, then the
  staged resolves, so a resolution lands after its reply. A staged change that fails stays staged and the
  next sync retries it.
- `:Diffy review clear` drops your drafts and staged changes and deletes the pending review, adopted comments
  included; it asks first (`prompt.lua`), since it deletes on GitHub.

### Staged changes

Kept in the store only (GitHub has no pending edit, deletion or resolve), so another machine doesn't see
them.

- `x` on a thread stages a resolve or unresolve; `x` again cancels.
- `e` on one of your published comments stages an edit; `dd` stages its deletion; `dd` again cancels.

## Background sync

Reads are the layer's (see Reading). Writes go to your pending review only:

- **When**: 2 s after the last local change to a draft GitHub can take; offline, after the next successful
  read. A change is mirrored by the nvim that made it; changes left unmirrored (nvim closed within the 2 s)
  go with the next sync of any session.
- **What**: create the pending review with the first mirrored draft (if another nvim created it meanwhile,
  adopt that one); add, edit and delete pending comments.
- **Bookkeeping**: for each mirrored comment, its GitHub id and the body and `updatedAt` it last synced.
  Before editing or deleting a mirrored comment, diffy reads it again: changed since means a conflict, not an
  overwrite. Two mirrored copies of one draft (same anchor and body, two nvims racing) are merged on read.

Conflict rules:

| Case | Result |
|---|---|
| a pending comment changed on both sides, or edited on one and deleted on the other | both versions in the thread, the web one labelled `github.com`; `dd` deletes one, the conflict ends when one is left; an edit beats a delete |
| a staged edit to a published comment, which was edited on github.com meanwhile | your staged edit next to the live comment; `dd` on the edit drops it, `dd` on the live one stages its deletion |
| a staged edit to a published comment deleted on github.com | becomes a draft reply in its thread; if the thread is gone, dropped with its text in a notification |
| a staged deletion of a published comment edited on github.com | cancelled, with a notification (an edit beats a delete) |
| a pending review diffy didn't create (github.com, another machine) | adopted: its comments join your drafts and diffy keeps mirroring into it |
| a draft GitHub can't take (worktree, unpushed commit, outside the diff and its 3 lines of context) | stays local with a badge, mirrored once it becomes valid; a GitHub submit lists it as staying behind |
| a draft reply whose thread was deleted | dropped, its text in a notification |
| a draft reply whose thread was resolved, or went outdated | kept: GitHub accepts both |

Measured on a throwaway sandbox PR (#36), and what it means here:

- **One comment at a time.** `addPullRequestReviewComment(pullRequestReviewId, commitOID, position)` joins
  the pending review, on any commit and on either side (a `position` on a `-` line makes a LEFT thread).
  `addPullRequestReviewThread(pullRequestReviewId, …)` also joins it, at head, ranges included. Mirroring
  uses the first for drafts on older commits, the second for drafts on head.
- **Edits and deletions** work on pending and published comments alike; deleting a thread's only comment
  removes the thread. Deleting the last pending comment deletes the pending review itself (the payload still
  says `PENDING`, any later use of its id is `NOT_FOUND`): the mirror then forgets the review's id and
  creates a new one with the next draft. "Deleted once empty" after an agent submit is therefore automatic.
- **Change signal.** A pending comment's edit only moves `updatedAt` (`lastEditedAt` stays null, even after
  submit); a published comment's edit sets `lastEditedAt`. The bookkeeping compares `updatedAt` for pending
  comments, `lastEditedAt` for published ones. The read query fetches neither today.
- **Racing creation.** A second `addPullRequestReview` while one is pending returns null with `UNPROCESSABLE`
  "User can only have one pending review per pull request" and creates nothing: read
  `reviews(states: PENDING)` and adopt it.
- **Force-push.** Pending comments are remapped like published ones; an untrackable one keeps its old
  `commit` and becomes outdated, its `line` unchanged. The pending review still submits. diffy places and
  judges outdatedness itself, so nothing depends on `line`.
- **Pagination.** A thread's `comments` take `after` and have `pageInfo`.

## Code touched

- `init.lua`: `dispatch.pr` loses its gate and becomes `:Diffy branch` on the PR base; `M.build` stops
  fetching GitHub; `completion_backend` and `review/ui.lua`'s `review_available`/`ensure` stop choosing a
  backend by kind.
- `git/repo.lua`: `resolve_base` with the cached PR base and `origin/HEAD`; the PR lookup (`gh pr view`).
- `panels/log.lua`: the PR row and review markers; `worktree_prefix` loses its `pr` case.
- `panels/commitmsg.lua`: the PR row's float.
- `review/github.lua`: becomes the layer: read (paginated, on the PR's own repository), cadence, mirroring,
  staged changes, submit. `find_pr`, `owner_repo`, `push`, `pull`, `pr_readiness` and its own `load`/`save`
  go.
- `review/local.lua`: the agent destination, on the one store; `review.md` with the location now and where
  each comment was written.
- `review/model.lua`: one placement for every thread (tracking out of `github.lua`), the worktree target
  (`vim.diff` on the buffer), re-anchoring worktree and index comments; unique ids.
- `review/store.lua`: `threads.json`, merging the old files; read-apply-write per change, atomic writes, the
  file watch shared with `viewed.json`.
- `review/ui.lua`: the badges (local only, conflict, staged edit, deletion, resolve); `e`/`dd` on published
  comments.
- `tests/helpers/fake_github.lua`: editing and deleting pending and published comments, adopting a pending
  review, `updatedAt`.
- `README.md`: the commands table and the Review section.
- `AGENTS.md`: the sandbox rule: with the layer on, never open a session on `sandbox/pending` in the sandbox
  clone. Adoption and mirroring would write into PR #4's pending review, and drafts already in the store for
  that branch are mirrored on open. Write-side smoke tests use throwaway PRs, or `github = false`.

Answering reviews on your own PR (turns, seen comments, card keys, the agent loop) is its own spec:
`docs/pr-answering.md`.
