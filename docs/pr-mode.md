# PR layer — design draft

Status: draft for review, nothing implemented. Replaces `:Diffy pr` as a mode of its own.

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
  `pr`). No PR, no `gh`, offline: no layer, no warning.
- The base of `:Diffy branch` without an argument can't wait on the network either. Today
  `repo.resolve_base` waits on `gh pr view`, then `gh repo view`, before the first render. New order: the PR
  base cached in `.git/diffy/<branch>/pr.json` by the last session, else `origin/HEAD` (`git symbolic-ref
  refs/remotes/origin/HEAD`, local), else `gh repo view`. If the layer brings a different base, the session
  re-renders once and caches it. An explicit base is used as given, and the layer still attaches: threads
  are placed by tracking, not by base.
- Attaches to `:Diffy` and `:Diffy branch`, the sessions that have a review today. Not to ranges,
  `:Diffy file` or `:Diffy conflicts`.
- When a sync finds the PR merged or closed, the layer detaches: the PR row and the published threads go.
  Your drafts stay.

### The PR row

First row of the log, above `Working tree`, only while the PR is open:

```
#42 Retry failed uploads · 3 to answer · 2 unpushed
```

- Number and title.
- What's yours to do: threads to answer, addressed threads not sent, sync conflicts.
- Where the branch stands against the PR head: nothing when in sync, `2 unpushed`, `behind 1`, `diverged`.
- `offline` when the last sync failed.

It isn't a diff entry: `J`/`K` and selections skip it. Resting the cursor on it shows the description, the
reviewers' states (`alice ✗ changes requested`, `bob ✓`) and the conversation in the float beside the log,
the way a commit's message shows. `gP` stays.

### Review markers

A review is written on a commit (`PullRequestReview.commit`). Each submitted review shows as a dim row right
above that commit: `── alice ✗ 4 threads`. `<CR>` on it selects everything above it: what changed since
that review, which is what the reviewer will look at next.

## One set of threads

`.git/diffy/<branch>/threads.json` replaces `local.json` and `pr-<n>.json`. Both are merged into it on
first load and deleted; ids that collide are renumbered.

Each comment of yours has two independent states:

| | |
|---|---|
| GitHub | `local` (not mirrored) · `pending` (in your pending review) · `published` |
| Agent | not sent · `sent` (in `review.md`) |

Threads also carry local flags: `addressed`, `resolve_staged`, `for_agent`, `conflict`.

**Placement.** One rule for every thread, GitHub's: tracked across the branch's commits from where it was
written, then into the index and the worktree. Today a local thread only shows in the exact view it was
written in (`model.pair_side`); a GitHub thread shows in any view of the PR (`github.place_at`). A thread
anchored on the worktree or the index is re-anchored to HEAD once HEAD has its lines (`model.relocate`
against HEAD's blob): that's how a draft written on the worktree reaches GitHub after you commit and push.

## Submitting

`:Diffy review submit` opens the message box. `<C-s>`, then the destination when a PR is attached: `a`
agent, `g` GitHub (then the verdict, as today; on your own PR GitHub only allows a comment). Without a PR
there's no question: it goes to the agent.

- **Each comment goes to one destination.** Submitting to the agent writes the unsent drafts to
  `review.md`, marks them `sent` and takes them out of the pending review. Submitting to GitHub publishes the
  pending review.
- Threads flagged for the agent (`for_agent`, reviewers' threads included) go to `review.md` with their whole
  conversation; the flag clears.
- **Nothing anyone else can see changes before a GitHub submit.** The background sync only writes to your
  pending review, which only you see. Replies, new threads and resolves wait for the submit.
- GitHub submit runs the review first, then the staged resolves, so a resolution lands after its reply. A
  resolve that fails stays staged and the next sync retries it.
- Before a GitHub submit, the confirm float lists what won't go: drafts GitHub can't take, agent replies you
  haven't checked. It also lists unpushed commits.
- `:Diffy review clear` drops your drafts and deletes the pending review (it's yours and private).

## Background sync

**When.** On layer load, on `FocusGained`, every 60 s while the session's tab is current, on `R`, and 2 s
after the last local change to a draft that can be mirrored. One sync at a time; a trigger during a sync
queues one more.

**Reads.** The current read query, plus each review's commit and state.

**Writes.** Only to your pending review: create it with the first mirrored draft; add, edit and delete
pending comments. For each mirrored comment diffy keeps its GitHub id and the body and `updatedAt` it last
synced, which is how it tells which side changed.

Conflict rules:

| Case | Result |
|---|---|
| a comment of yours changed on both sides, or edited on one and deleted on the other | both versions kept, the thread flagged as a conflict until you delete one; an edit beats a delete |
| a pending review diffy didn't create (github.com, another machine) | adopted: its comments join your drafts and diffy keeps mirroring into it |
| a draft GitHub can't take (worktree, unpushed commit, outside the diff and its 3 lines of context) | stays local with a badge, mirrored once it becomes valid; a GitHub submit lists it as staying behind |
| a draft reply whose thread was deleted | dropped, its text in a notification |
| a draft reply whose thread was resolved, or went outdated | kept: GitHub accepts both |
| the agent ticks a GitHub thread | addressed, locally; nothing on GitHub |
| `x` on a GitHub thread | staged until the next GitHub submit; `x` again cancels |

Needs measuring before building it:

- What happens to pending comments whose commit a force-push removed from the PR.
- Mirroring drafts one by one: `addPullRequestReviewThread` anchors at head, so a draft on an older commit
  needs the legacy `addPullRequestReviewComment(commitOID, position)` with the pending review's id. Today
  `push` recreates the whole pending review instead. The legacy call on old-side lines is still unmeasured.
- Whether a pending comment edited on github.com gets a new `updatedAt`.

## Answering reviews on your own PR

The flow to design for: reviewers left threads. You go through them, fix things yourself or hand them to the
agent, answer, push, submit, and ask for another look.

### Whose turn

The idea that organizes the rest. An open thread is **yours** when its last comment isn't yours, or it has
comments you haven't seen. It's **theirs** when its last published comment is yours. The threads view, with
the layer attached, groups by turn:

- **To answer**: yours.
- **Addressed**: fixed (by you or the agent), the reply or resolve not sent yet.
- **Waiting**: theirs.
- **Resolved**, **Detached**, as today.

Outdated is a tag inside these groups, not a group of its own: on your own PR a thread usually goes outdated
because you changed its lines, and it's still yours to answer.

A comment counts as seen once its card has been open. New ones get `●` in the summary, the card and the
threads view: the same mark as a viewed file that changed (`docs/viewed-files.md`). Seen ids are stored
locally, per branch.

### Getting to a thread

- `]T`/`[T`: next/previous thread to answer, in any file. It switches the file, and the selection if needed,
  to one that shows the thread on the current code (the worktree, as the real file), since you're about to
  edit it. An outdated thread opens on the commit it was written on, like `<CR>` in the threads view does.
- The PR row's count and the To answer group are the overview.

### Acting on a thread

Keys in the thread card:

- `r`: reply. A draft reply, mirrored as pending.
- `x`: stage a resolve.
- `gs`: apply a reviewer's suggestion to the worktree file at the thread's tracked lines, only if those lines
  are still the ones the suggestion was written against. The thread becomes addressed. GitHub's "Commit
  suggestion" makes a commit on the remote branch that your local branch then lacks; applying locally keeps
  one history.
- `A`: flag for the agent.
- `m`: addressed. You fixed it and have nothing to say yet.

### With the agent

1. Flag threads (`A` on a card, or every To answer thread from the threads view), then submit to the agent.
2. `review.md` carries each flagged thread whole (who said what, the code at the thread, the diff hunk), a
   `- [ ] resolved` box, and a reply slot the prompt asks the agent to fill in for the reviewer.
3. When diffy reads `review.md` (load, `R`, sync), a tick makes the thread addressed. A filled reply slot
   becomes a draft reply on the thread, marked as from the agent. It isn't mirrored and won't be submitted
   until you accept it (open it, edit it or `<C-s>`).
4. You check: the files the agent touched come back as changed in the tree (viewed marks); the Addressed group
   lists the threads and their replies; `]T` also stops on addressed threads with a reply you haven't
   accepted.
5. Commit, push, submit.

### Sending

On your own PR, a GitHub submit is a comment review: replies, new threads, staged resolves. The confirm float
adds:

- Unpushed commits: your replies say "fixed" about code reviewers can't see yet.
- Re-request review (`requestReviews`) from the reviewers whose threads you answered, on by default for those
  who requested changes.

## Code touched

- `init.lua`: `dispatch.pr` loses its gate and becomes `:Diffy branch` on the PR base; `M.build` stops
  fetching GitHub; `completion_backend` and `review/ui.lua`'s `review_available`/`ensure` stop choosing a
  backend by kind.
- `git/repo.lua`: `resolve_base` with the cached PR base and `origin/HEAD`.
- `panels/log.lua`: the PR row and review markers; `worktree_prefix` loses its `pr` case.
- `panels/commitmsg.lua`: the PR row's float.
- `review/github.lua`: becomes the layer: PR lookup, read, sync loop, mirroring, submit. `push`, `pull`,
  `pr_readiness` and its own `load`/`save` go.
- `review/local.lua`: the agent destination: `review.md` with flagged threads and reply slots.
- `review/model.lua`: one placement for every thread (tracking out of `github.lua`), re-anchoring worktree
  and index anchors.
- `review/store.lua`: `threads.json`, merging the old files.
- `review/ui.lua`: card keys, `●`, the badges (local only, conflict, addressed, resolve staged, from the agent).
- `review/threads.lua`: turn groups.
- `tests/helpers/fake_github.lua`: editing and deleting pending comments, review commits, `requestReviews`.
- `README.md`: the commands table and the Review section.

## Open questions

1. **Replies on resolved or outdated threads.** You picked "drop" for a draft reply whose thread changed.
   I've applied it to deleted threads only. On your own PR a thread goes outdated precisely when you fix its
   lines, which is when you write "done": dropping the reply then would throw away the normal case. Drop on
   resolved and outdated too?
2. **Keys.** `]T`/`[T`, and `r`, `x`, `gs`, `A`, `m` in the card. `m` is also the viewed toggle in the tree:
   different buffers, but the same letter with two meanings.
3. **Unpushed commits at a GitHub submit.** Warn only, or offer to `git push` first? diffy has never pushed.
4. **Re-request review.** In the submit float, on by default for reviewers who requested changes?
5. **Review markers for force-pushed commits.** A review written on a commit no longer in the branch has no
   row to sit above. Under the PR row, or not shown?
6. **The reply slot in `review.md`.** Its format, and whether the prompt asks for a reply on every thread or
   only on GitHub threads.
7. **Sync every 60 s.** About 60 reads an hour per open session.
