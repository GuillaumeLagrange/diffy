# diffy

A diff viewer for Neovim built on git and fugitive, with a review layer: comment on diffs, then either
hand the comments to an LLM agent or push them as a GitHub pull request review.

Each `:Diffy` session lives in its own tab: a column of views on the left (changed files on top, commits
below; `column` in `setup` picks which) and a side-by-side diff in native diff mode. A view that isn't in
the column (the review threads, by default) opens in a float over the diff. Closing the tab in any way
(`:tabclose`, `:q` in a diffy window, `:Diffy close`, quitting nvim) cleans everything up.

## Requirements

- Neovim ≥ 0.12, git ≥ 2.36
- [vim-fugitive](https://github.com/tpope/vim-fugitive): blob and index buffers
- [`gh`](https://cli.github.com), authenticated: `:Diffy pr`, and base-branch detection for `:Diffy branch`
- Optional, for GitHub avatars: a terminal with the kitty graphics protocol (kitty, ghostty, WezTerm; also
  inside zellij ≥ 0.45, not tmux), `curl` and ImageMagick

## Install

Put this repository on the runtimepath, e.g. `vim.opt.rtp:prepend('/path/to/diffy')`. `setup` is optional:

```lua
require('diffy').setup({
  panel_width = 40,               -- width of the left column
  -- views stacked in the left column, top to bottom: 'tree' (files), 'log' (commits),
  -- 'threads' (review threads, compact). The others open in a float.
  column = { 'tree', 'log' },
  keymaps = {
    toggle_panel = '<leader>e',   -- hide/show the panel column, in every diffy window
    focus_panel = '<leader>E',    -- go to the file tree, showing the column first if hidden
  },
  -- copied to `+` by `:Diffy review submit` (local review); %s is the absolute path of review.md
  review_prompt = 'Read %s and address each review comment. Reply per comment id with what you changed, and tick its "- [ ] resolved" box in that file once it is handled.',
  avatars = true,                 -- GitHub avatars in comment headers and summaries, when the terminal can draw them
})
```

## Commands

| Command | Shows | Selected at start |
|---|---|---|
| `:Diffy` | Working tree, commits `@{u}..HEAD` (or the last 20) | Working tree |
| `:Diffy branch [base]` | Working tree, commits since the merge-base with `base` | all commits |
| `:Diffy A..B`, `:Diffy A...B` | the commits of the range | all |
| `:Diffy pr` | the commits of the current branch's pull request | all |
| `:Diffy file [path]` | commits touching the file (default: current buffer), across renames | newest |
| `:Diffy conflicts` | conflicted files, in the conflict view | first file |
| `:Diffy panel` | hide/show the panel column | |
| `:Diffy threads [file] [author=… state=… review=…]` | the threads view: every review thread, grouped; `file`: those of the file in the diff (`state`: open, resolved, outdated, detached). See Review | |
| `:Diffy review submit\|clear` | local review, see below | |
| `:Diffy review submit [comment\|approve\|request_changes]\|push\|pull` | GitHub review, see below | |
| `:Diffy restore` | go back to your branch after an interrupted full checkout | |
| `:Diffy feedback` | describe what bothers you in the current session, see below | |
| `:Diffy close` | close the session | |

`<Tab>` completes subcommands and their arguments: the review subcommands and events the current session
offers, `:Diffy threads` filters, paths for `file`, branches for `branch`.

`:Diffy branch` without an argument uses the PR base of the current branch, then `origin`'s default branch.
Either is taken through the base branch's upstream (usually `origin/main`: the remote's tip as of your last
fetch, not a local `main` that may be behind), else the local branch, else the one remote-tracking branch
of that name. `:Diffy pr` resolves the PR's base the same way. An explicit `base` is used as given.

`:Diffy feedback` opens a box to describe something you don't like in the current session; `<C-s>` sends
it, `q` cancels. diffy doesn't store it: it fires `User DiffyFeedback` with `data.text`, right after the box
closes, so the handler sees the session as it was. With no such autocmd the command only warns. For
example, to record it like an error:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'DiffyFeedback',
  callback = function(ev)
    my_reporter.record('diffy feedback: ' .. ev.data.text, require('diffy').debug_state())
  end,
})
```

## The panels

**Commits** (bottom). The diff always shows one contiguous selection: left is the parent of the oldest
selected entry, right is the newest one. `Working tree` means HEAD → worktree, index included; selected
alone, the tree splits it into its unstaged and staged parts (see Files). With commits, it's one tree from
the oldest commit's parent to the worktree. `J`/`K` and `]r`/`[r` treat it like a commit.
Merge commits are dimmed and skipped. In branch and PR views, a selection reaching the oldest commit
compares against the merge-base, like github.com, so changes merged in from the base branch don't show up.

Resting the cursor on a commit shows its full message in a float beside the log: short sha, author, date,
then the message wrapped to fit. It closes on a non-commit row, when you leave the log, or on `<Esc>`
(until you move to another row).

| Key | |
|---|---|
| `<CR>` | select the entry under the cursor |
| `v`/`V` + motion, `<CR>` | select a range |
| `a` | select everything |
| `J` / `K` | select the next / previous entry |
| `X` | toggle checkout mode (see below) |
| `<Esc>` | close the commit message float |

**Files** (top): status letter, path relative to its folder, `+added -removed`. The file shown in the diff
is highlighted.

With `Working tree` selected alone, the files come in two sections, `Unstaged (n)` (index → worktree, plus
untracked files) then `Staged (n)` (HEAD → index). A file with both kinds of changes is listed in each, and
opens that section's diff: the real file on the right for Unstaged, the index on the right for Staged. Both
headers stay when a section is empty; with no changes at all the tree says `(no changes)`.

| Key | |
|---|---|
| `<CR>` | open the file and move to the diff |
| `o` | open the file, stay in the tree |
| `]f` / `[f` | next / previous file |
| `]r` / `[r` | next / previous commit |
| `za` | fold a folder or section |
| `gf` | open the real file in the previous tab |
| `-` | move the file to the other section (stage in Unstaged, unstage in Staged) |
| `s` / `u` | stage / unstage the file, whichever section it's in (a rename stages both paths) |
| `S` / `U` | stage / unstage everything |

On a section header, `-`, `s` and `u` apply to every file of that section. After staging, the cursor
follows the file into the section it moved to. Staging works only with `Working tree` selected alone. You
can also stage hunk by hunk: for an Unstaged file the left side is the index, so `do`/`dp` or editing it and
`:w` stages; for a Staged file the right side is the index.

## The diff

The right side is the real file (LSP, editable) when it shows the worktree, or HEAD for a file with no
uncommitted changes. Otherwise both sides are read-only fugitive blobs. An added or deleted file takes the
whole diff area on its own, coloured as added or deleted. Jumping to another file from the right side
(go-to-definition, `gf`, `:e`) loads that file's pair if it's part of the diff; otherwise diff mode turns
off until you come back (`<C-o>`, `<C-t>` or the tree). A jump from the left side opens in the right
window, so `<C-o>`/`<C-t>` there bring the pair back. `<C-o>` never goes back past the start of the
session.

| Key (in either diff window) | |
|---|---|
| `]f` / `[f` | next / previous file |
| `]r` / `[r` | next / previous commit |
| `R` | refresh everything: git state, panels, window sizes |
| `<leader>e` | hide / show the panel column |
| `<leader>E` | go to the file tree, bringing the column back first if it's hidden |

**Statusline.** A blob side's buffer name is a `fugitive://…/.git//<sha>/<path>` URI, which is what a
statusline shows. diffy sets `b:diffy_title` (`a1b2c3d: src/foo.lua`) on those buffers; with lualine:

```lua
lualine_c = { { 'filename', path = 1, fmt = function(name) return vim.b.diffy_title or name end } },
```

**Checkout mode.** `X` turns checkout mode on: the selected commit is checked out (detached; your branch
itself when it is the branch head) so the right side becomes real files with LSP. Moving the selection
(`<CR>`, `J`/`K`, `]r`/`[r`, threads) checks out the new commit; a range or the working tree puts your branch
back until you select a single commit again. The log's winbar shows `⎇ checkout <sha>` while it is on.
`X` again or closing the session checks your branch out again. Entering refuses when you have tracked
changes; if you edit a file while in the mode, moving the selection warns and keeps the current checkout.
If nvim dies in between, the next `:Diffy` offers `:Diffy restore`.

**Conflicts.** `:Diffy conflicts`, or opening a `U` file, shows ours, base and theirs on top and the
result (the real file) below. Works for merge, rebase, cherry-pick and stash pop.

| Key | |
|---|---|
| `gho` / `ghb` / `ght` (in the result) | take ours / base / theirs for the conflict under the cursor |
| `]x` / `[x` (in the result) | next / previous conflict marker |
| `s` (in the tree) | mark resolved (`git add`); asks first if markers remain |

## Review

Each comment draws a bar over its lines in the gutter, between the line numbers and the text, and a one-line
summary under its last line (avatar on GitHub, author, reply count, first line of the comment). The bar ends on its summary,
turning right across the bars still going on. A bar's colour comes from its thread's id, so it stays the
same across files and sessions; the summary's `●` and the thread float's frame take it too. Overlapping
ranges get bars side by side, the enclosing one on the left. The open thread's bar is heavy and its summary
bold in its colour; the other summaries under the cursor take their colour. A resolved thread's bar and
summary are dimmed, the summary marked ✓. The other side gets matching blank lines so the diff stays
aligned. Several summaries under one line are listed top to bottom by the line they end on, then oldest first.

Moving onto a commented line opens its leftmost thread; `<Tab>`/`<S-Tab>` cycle through the others covering
that line, left to right. `]t`/`[t` walk every thread of the side by the line its range starts on, then the
larger range first (the one drawn further left), then oldest first. `<Esc>` closes the card, and it stays
closed until the cursor leaves the line (or `<Tab>`, `K`, `]t` ask for it).

The bars take over the diff windows' `statuscolumn` (fold, sign and number columns, then the bars) while
the file has comments, and put your own back otherwise.

| Key (in a diff window) | |
|---|---|
| `gc` | comment on the line (visual mode: on the range); `<C-s>` or `:w` saves, `q` cancels |
| move onto a commented line | preview its leftmost thread, over the other diff window |
| `K` / `<CR>` | enter the thread float; `K` off a commented line is LSP hover (or `keywordprg`) as usual |
| `]t` / `[t` | next / previous thread, by first line, larger range first, oldest first |
| `<Tab>` / `<S-Tab>` | next / previous thread covering the cursor line, left to right, wrapping (also in the thread float) |
| `<Esc>` | close the thread card; no preview on this line until the cursor leaves it |
| `<leader>ds` | hide / show the summaries, keeping the bars (hover still previews) |
| `<leader>dr` | hide / show resolved threads |
| `<leader>dt` | hide / show comments inline altogether |
| `<leader>dC` / `<leader>dc` | the threads view: every thread / those of this file (`:Diffy threads`, `:Diffy threads file`) |
| `gP` | PR description and conversation (`:Diffy pr`) |

Threads open as a framed card over the other diff window; on an added or deleted file, where there is only
one, right under the commented lines (above them when there's more room there), so they stay visible;
there, the open thread's own summary is blanked while it's open, since it'd show past its right edge. A
card is at most 100 columns wide and centred over the window's text; it follows the diff when it scrolls
under it and is fitted again when the editor or the diff windows are resized. The
comment boxes are placed the same way; the `gP` card is centred on the editor and refitted too. Each comment gets a header strip: avatar, author (on
GitHub; "You" in a local review), age, and its state when it isn't published yet: `draft` (only in
diffy), `pending` (in your unsubmitted GitHub review), `sent` (exported to the agent). The first header
also says `outdated` or `✓ resolved`. Bodies render as markdown; suggestion blocks are labelled, empty
ones as "remove these lines". A preview taller than half the window is cut, with a hint to press `K`.

Bodies full of HTML, as bots like greptile write them, are shown as their markdown equivalent: HTML
comments dropped, `<h2>` as `## `, `<b>`/`<em>`/`<code>` as `**`/`_`/`` ` ``, `<br>`/`<li>` as line breaks
and items, entities (`&nbsp;`, `&amp;`, …) and backslash escapes decoded (an escape that would start a list
or emphasis stays). Code fences are shown as written. Tables are padded so their columns line up; long
lines wrap at words. This is display only: bodies are stored and sent as written.

- **Links** show their text only, underlined (`DiffyThreadLink`); a bare URL shows as its host (and last
  path part when short). The URLs stay behind the line: in a card, `<CR>` or `gx` opens the link under the
  cursor (`gx` falls back to the line's only link, else asks which one). With the mouse, `<C-LeftMouse>` or
  a double click on a link (or a badge, or an image marker) opens it, from any card, focused or not. HTML
  buttons (an `<a>` around an image, like "Open in CodSpeed") are one linked marker.
- **`<details>`** blocks are folds titled `▸ <summary>`, closed unless the HTML says `open`: `<CR>`, `za`
  (or any fold key) in the thread float or the `gP` card opens them, as does `<C-LeftMouse>`/a double click
  on the title.
- **Images** show as `[alt]`, opened by `gx`. Badges (SVG images, e.g. greptile's `P1`/`P2`, `Retrigger`,
  `Fix in Codex`) are drawn over their marker when the terminal can draw avatars (below; ImageMagick needs
  an SVG delegate, librsvg or its own MSVG) and they fit it; otherwise `[P0]`/`[P1]` are red, `[P2]`
  yellow, `[P3]` blue. A heading's `Confidence Score: N/5` is green from 4, yellow at 3, red below.

In the thread float, the footer lists the keys that apply: `r` reply, `e` edit the draft under the cursor,
`dd` delete the draft under the cursor, `x` resolve/unresolve, `]t`/`[t` switch thread, `q` close. A
reply or an edit is written in a box under the thread, which stays in view (a reply starts in insert
mode, an edit in normal mode at the end of the draft); saving or cancelling goes
back into the thread. Leaving a comment box or the thread for the diff puts the cursor back where it
was. In the compose float, `<C-g>s` inserts a GitHub suggestion block with the commented lines. `gP`
shows the PR description and its conversation the same way.

**The threads view** lists the review's threads grouped by where they stand: Open, Outdated (no longer
trackable to HEAD, not resolved), Detached (a local comment whose lines are gone), Resolved, and Resolved,
outdated. Headers carry the count; the resolved groups start folded. Each row gives the file and line, who
started the thread ("you" for yours), how many replies and who wrote the last one when it's someone else,
`draft`/`pending`, and the first line. A thread the selected range doesn't show has its location dimmed.

It opens in a float over the diff with a preview beside it (on a wide enough screen): which commits show
the thread (GitHub), the code it's on (its lines numbered and marked, up to 3 lines of context above, the
middle of a long range cut), then the thread. With `'threads'` in `column` it sits in the left column
instead, compact and without the preview, and `:Diffy threads` moves the cursor into it.

| Key (in the threads view) | |
|---|---|
| `<CR>` | go to the thread: its file, its line, into its float. An outdated thread opens in the view it was written in: its commit alone when that commit changes the file, else everything up to that commit. Otherwise, when the selected range doesn't show the thread, the selection switches to one that does first (the whole range, else the newest commit showing it). Resolved or hidden threads are shown again. On a header: fold / unfold |
| `<Tab>` | fold / unfold the group under the cursor |
| `x` | resolve / unresolve the thread under the cursor |
| `m` | only threads you started / everyone's (GitHub) |
| `<C-f>` / `<C-b>` | scroll the preview |
| `q` / `<Esc>` | close the float; leaving it for another window closes it too |

Avatars and badges need a terminal with the kitty graphics protocol, `curl` and ImageMagick. They're
downloaded once and cached in `stdpath('cache')/diffy/avatars` and `/images`; without them the headers,
summaries and badges are text only.

Local comments follow the code: after edits they're found again by their text within ±20 lines. When they
can't be, they're in the threads view as detached.

### Local review, for an LLM agent

Available in `:Diffy` and `:Diffy branch`. Drafts are saved in `.git/diffy/<branch>/local.json`.

`:Diffy review submit` opens a box for an overall message (may be left empty); `<C-s>` writes
`.git/diffy/<branch>/review.md` with that message and every comment not yet sent (location, side, commit,
the code with context, the diff hunk, the comment), marks them sent and copies the prompt to the `+`
register: paste it to your agent. A message alone is sent too. `:Diffy review clear` deletes the local
review.

Each comment's section starts with a `- [ ] resolved` box, and the prompt asks the agent to tick it once
the comment is handled. diffy reads the ticks when it opens the review, on `R`, and before the next submit
replaces the file: those threads become resolved (✓ inline, in the Resolved group of the threads view). A
tick counts once, so a thread you reopen with `x` stays open.

### GitHub review

`:Diffy pr` opens the pull request of the checked-out branch. It refuses unless your `HEAD` is the PR head
on GitHub and the tree is clean.

- Threads are placed like github.com's "Changes" view: in the full view and in each commit's view, at the
  line they track to, hidden where their lines changed. Outdated threads (not trackable to HEAD) are in
  the threads view with the others; `<CR>` there opens the commit they were written on.
- Your comments are local drafts (`.git/diffy/<branch>/pr-<number>.json`) until you push.
- `:Diffy review push` replaces your pending review on GitHub with your drafts. Each lands on the commit
  you wrote it in. Drafts GitHub would reject (outside the diff and its 3 lines of context) stay local
  with a warning.
- `:Diffy review pull` imports your pending review from GitHub (it asks before replacing local drafts).
- `:Diffy review submit` opens a box for the review message; `<C-s>` then asks `c` comment, `a` approve or
  `r` request changes (`q` goes back to the message). It pushes your drafts and submits; with no drafts,
  it submits the message alone (approving without comments). An argument picks the event and skips the
  question; on your own PR, where GitHub only allows a comment, there's no question either.
- `x` resolves or unresolves a thread on GitHub immediately.
- `R` refreshes from GitHub.

## Highlights

All set with `default = true`, so a colorscheme or your config can override any of them:

| Group | Default | |
|---|---|---|
| `DiffyAdded` / `DiffyChanged` / `DiffyRemoved` / `DiffyConflict` | `Added` / `Changed` / `Removed` / `DiagnosticError` | status letters, counts |
| `DiffyFileAdded` / `DiffyFileDeleted` | `DiffAdd` / `DiffDelete` | an added / deleted file shown on its own |
| `DiffyDirectory`, `DiffySha`, `DiffyLabel`, `DiffyMerge` | `Directory`, `Identifier`, `Title`, `Comment` | tree folders, log rows |
| `DiffySelection` | `Visual` | selected commits |
| `DiffyCurrentFile`, `DiffyCurrentFileName` | `Visual`, bold | the file shown in the diff |
| `DiffyThreadSummary` / `DiffyThreadCurrent` | `Comment` / bold | comment summaries / the weight of the open one's |
| `DiffyThreadStep` | `Normal`'s colour, bold | the `]t`/`[t` marks on summaries |
| `DiffyThreadSummaryResolved` | `NonText` | summaries and bars of resolved threads (their ✓ uses `DiffyThreadResolved`) |
| `DiffyThreadLane1`…`6` | `DiagnosticError` `DiagnosticWarn` `DiagnosticInfo` `DiagnosticHint` `DiagnosticOk` `Constant` | comment bars and summary dots, a colour per thread |
| `DiffyThreadRange` | `PmenuSel` | line numbers of the commented lines in `:Diffy threads` previews |
| `DiffyThread` / `DiffyThreadHeader` | background of `CursorLine` / `Pmenu` | comment cards / their header strips |
| `DiffyThreadBorder`, `DiffyThreadBorder1`…`6` | `WinSeparator`'s colour / the lane's, on the card background | card frames; an open thread's float in its colour |
| `DiffyThreadAuthor`, `DiffyThreadAuthor1`…`5` | bold, `Identifier` `DiagnosticHint` `Constant` `Title` `Function` | author names, a colour per login |
| `DiffyThreadTime` | `Comment` | comment age |
| `DiffyThreadDraft` / `DiffyThreadPending` / `DiffyThreadSent` | `DiagnosticWarn` / `DiagnosticInfo` / `Comment` | comment states |
| `DiffyThreadResolved` / `DiffyThreadOutdated` | `DiagnosticOk` / `DiagnosticWarn` | thread states |
| `DiffyThreadCodeBar` / `DiffyThreadSuggestion` | `Comment` / `Added` | code block bar / suggestion bar and label |
| `DiffyThreadLink` | `Underlined` | link text in cards |
| `DiffyThreadKey` / `DiffyThreadHint` | `Special` / `Comment` | footer keys / their labels |

## Tests

From this directory: `make test` (the whole suite, one nvim per test file in parallel, about 10 s; `JOBS=N`
caps the parallelism), `make test FILE=tests/test_staging.lua`.
`make test-gh` runs the GitHub tests against the real sandbox repository, opening and closing a throwaway
PR per test.
