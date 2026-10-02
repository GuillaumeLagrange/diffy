# Answering reviews on your own PR — design draft

Status: parked, open questions below unanswered, nothing implemented. Builds on the PR layer
(`docs/pr-mode.md`): one set of threads per branch, background sync, staged resolves, submit to the agent
or to GitHub.

## The ask

Reviewers left threads on your PR. You go through them, fix things yourself or hand them to the agent,
answer, push, submit, and ask for another look.

## Whose turn

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

The PR row (`docs/pr-mode.md`) adds what's yours to do: `3 to answer`, `2 addressed`.

## Getting to a thread

- `]T`/`[T`: next/previous thread to answer, in any file. It switches the file, and the selection if needed,
  to one that shows the thread on the current code (the worktree, as the real file), since you're about to
  edit it. An outdated thread opens on the commit it was written on, like `<CR>` in the threads view does.
- The PR row's count and the To answer group are the overview.

## Acting on a thread

Keys in the thread card:

- `r`: reply. A draft reply, mirrored as pending.
- `x`: stage a resolve (`docs/pr-mode.md`).
- `gs`: apply a reviewer's suggestion to the worktree file at the thread's tracked lines, only if those lines
  are still the ones the suggestion was written against. The thread becomes addressed. GitHub's "Commit
  suggestion" makes a commit on the remote branch that your local branch then lacks; applying locally keeps
  one history.
- `A`: flag for the agent (`for_agent`).
- `m`: addressed. You fixed it and have nothing to say yet.

## With the agent

1. Flag threads (`A` on a card, or every To answer thread from the threads view), then submit to the agent.
2. `review.md` carries each flagged thread whole (who said what, the code at the thread, the diff hunk), a
   `- [ ] resolved` box, and a reply slot the prompt asks the agent to fill in for the reviewer. The flag
   clears.
3. When diffy reads `review.md` (load, `R`, sync), a tick makes the thread addressed, locally: nothing goes
   to GitHub (decided). A filled reply slot becomes a draft reply on the thread, marked as from the agent. It
   isn't mirrored and won't be submitted until you accept it (open it, edit it or `<C-s>`).
4. You check: the files the agent touched come back as changed in the tree (viewed marks); the Addressed group
   lists the threads and their replies; `]T` also stops on addressed threads with a reply you haven't
   accepted.
5. Commit, push, submit.

## Sending

On your own PR, a GitHub submit is a comment review: replies, new threads, staged resolves. The confirm float
adds:

- Agent replies you haven't accepted: listed, not sent.
- Unpushed commits: your replies say "fixed" about code reviewers can't see yet.
- Re-request review (`requestReviews`) from the reviewers whose threads you answered, on by default for those
  who requested changes.

## Code touched

- `review/local.lua`: `review.md` with flagged threads and reply slots; reading replies back.
- `review/ui.lua`: card keys, `●`, the addressed and from-the-agent badges.
- `review/threads.lua`: turn groups.
- `review/store.lua`: seen ids.
- `tests/helpers/fake_github.lua`: `requestReviews`.
- `README.md`: the Review section.

## Open questions

1. **Keys.** `]T`/`[T`, and `r`, `x`, `gs`, `A`, `m` in the card. `m` is also the viewed toggle in the tree:
   different buffers, but the same letter with two meanings.
2. **Unpushed commits at a GitHub submit.** Warn only, or offer to `git push` first? diffy has never pushed.
3. **Re-request review.** In the submit float, on by default for reviewers who requested changes? Needs
   measuring: `requestReviews` on someone who already reviewed.
4. **The reply slot in `review.md`.** Its format, and whether the prompt asks for a reply on every thread or
   only on GitHub threads. The default `review_prompt` changes with it.
5. **What clears `addressed`.** A new comment from the reviewer? Your GitHub submit?
6. **A flagged thread holding your pending reply.** Does submitting to the agent use up that reply too (each
   comment goes to one destination)?
7. **What counts as seen.** The card only, or also the threads view's preview pane and the summaries?
8. **Outdated as a tag.** The threads view has an Outdated group today. Drop it only with the layer attached,
   or everywhere?
9. **⚠ Outdated, live.** `docs/pr-mode.md` judges outdatedness against the buffer as you type: a thread you're
   fixing goes outdated as soon as you touch its first or last line. Validate this first, on real reviews of
   your own PR; extmarks moving with your edits, judged on write, is the alternative.
