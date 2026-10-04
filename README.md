# diffy

A diff viewer for Neovim built on git and fugitive, with a review layer: comment on diffs, then either
hand the comments to an LLM agent or submit them as a GitHub pull request review.

Each `:Diffy` session lives in its own tab: a column of views on the left (changed files on top, commits
at the bottom, in one window; `column` in `setup` picks which) and a side-by-side diff in native diff mode.
A view that isn't in the column (the review threads, by default) opens in a float over the diff. Closing the tab in any way
(`:tabclose`, `:q` in a diffy window, `:Diffy close`, quitting nvim) cleans everything up. `<C-w>o` (`:only`)
in a diff window ends the session too, but keeps that window: a plain one showing its file, out of diff mode,
with diffy's winbar and keys gone. `:tab split` of a diff window opens such a plain window, and the file's diffy
keys do what they do elsewhere outside the session's tab.

## Requirements

- Neovim ≥ 0.12, git ≥ 2.36
- [vim-fugitive](https://github.com/tpope/vim-fugitive): blob and index buffers
- [`gh`](https://cli.github.com), authenticated: the GitHub layer (see GitHub review), and base-branch
  detection for `:Diffy branch` when `origin/HEAD` isn't set
- Optional, for GitHub avatars: a terminal with the kitty graphics protocol (kitty, ghostty, WezTerm; also
  inside zellij ≥ 0.45, not tmux), `curl` and ImageMagick

## Install

Put this repository on the runtimepath, e.g. `vim.opt.rtp:prepend('/path/to/diffy')`. `setup` is optional:

```lua
require('diffy').setup({
  panel_width = 40,               -- width of the left column
  -- views stacked in the left column, top to bottom: 'tree' (files), 'log' (commits),
  -- 'threads' (review threads, compact). The tree and the log share one window when next to
  -- each other (see The panels). The others open in a float.
  column = { 'tree', 'log' },
  keymaps = {
    toggle_panel = '<leader>e',    -- in every diffy window: hide the panel column, or show it and go to the file tree
    toggle_viewed = '<leader>dm', -- in the diff windows: mark the file shown viewed, or unmark it
    tree_toggle_viewed = 'm',      -- in the file tree: the same for the file, folder or section at the cursor
    undo_viewed = '<leader>du',    -- in the diff windows and the file tree: undo the last mark or unmark, one more per press
  },
  -- copied to `+` by `:Diffy review submit` (local review); %s is the absolute path of review.md
  review_prompt = 'Read %s and address each review comment. Reply per comment id with what you changed, and tick its "- [ ] resolved" box in that file once it is handled.',
  avatars = true,                 -- GitHub avatars in comment headers and summaries, when the terminal can draw them
  -- the GitHub layer over :Diffy and :Diffy branch (false: off); read_interval: seconds between reads
  -- while the session's tab is current (0: no timer)
  github = { read_interval = 300 },
})
```

## Commands

| Command | Shows | Selected at start |
|---|---|---|
| `:Diffy` | Working tree, commits `@{u}..HEAD` (or the last 20) | Working tree |
| `:Diffy branch [base]` | Working tree, commits since the merge-base with `base` | all, working tree included |
| `:Diffy A..B`, `:Diffy A...B` | the commits of the range | all |
| `:Diffy pr` | `:Diffy branch` on the base of the current branch's open pull request; warns when there's none | all, working tree included |
| `:Diffy file [path]` | commits touching the file (default: current buffer), across renames | newest |
| `:Diffy conflicts` | conflicted files, in the conflict view | first file |
| `:Diffy panel` | hide/show the panel column | |
| `:Diffy viewed [clear]` | mark the file shown viewed, or unmark it; `clear` drops all its marks. See Viewed files | |
| `:Diffy threads [file] [author=… state=… review=…]` | the threads view: every review thread, grouped; `file`: those of the file in the diff (`state`: open, resolved, outdated, detached). See Review | |
| `:Diffy review submit [comment\|approve\|request_changes]` | to the agent, or to GitHub when the branch has an open PR (an argument means GitHub), see Review | |
| `:Diffy review clear` | drop your comments; with an open PR, also your staged changes and pending review (asks first) | |
| `:Diffy restore` | go back to your branch after an interrupted full checkout | |
| `:Diffy feedback` | describe what bothers you in the current session, see below | |
| `:Diffy close` | close the session | |

`<Tab>` completes subcommands and their arguments: the review subcommands and events the current session
offers, `:Diffy threads` filters, paths for `file`, branches for `branch`, `clear` for `viewed`.

`:Diffy branch` without an argument uses the PR base the GitHub layer read last time, else `origin/HEAD`
(local, no network), else `origin`'s default branch from `gh repo view`. A base name is taken through
the base branch's upstream (usually `origin/main`: the remote's tip as of your last fetch, not a local
`main` that may be behind), else the local branch, else the one remote-tracking branch of that name. When
the layer then finds the PR on another base, the session is rebuilt once on it, keeping the selected
commits when they're still listed. An explicit `base` is used as given.

`:Diffy branch` (and `:Diffy pr`) opens on the file you last looked at on the branch, kept in
`.git/diffy/<branch>/last_file.json`, if the view still has it and it isn't viewed; otherwise on the first
unviewed file as usual.

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

The files and the commits share the column's window: the files from the top, then a `── Commits ──` rule
and the commits at the bottom, blank rows between them while both fit. Once they don't, the window
scrolls as a whole, and what's past its edges shows over them: `↑ 12 files, 3 commits` / `↓ 31 commits`,
or, when none of the selected commits is in view, the rule and the selected rows pinned over the edge they
went past (`… n more selected` beyond two). Each part keeps its keys: `<CR>` on a file opens it, on a
commit selects it. A key only one part has works from the other too, so `J`/`K` and `a` select commits
from the files. With `column = { 'tree', 'threads', 'log' }` (or anything else between them), each gets
its own window again, and either one left out of `column` opens in a float.

| Key (in the column) | |
|---|---|
| `]]` | from the files, to the newest selected commit |
| `[[` | from the commits, to the file shown in the diff |

**Commits** (bottom). The diff always shows one contiguous selection: left is the parent of the oldest
selected entry, right is the newest one. `Working tree` means HEAD → worktree, index included; selected
alone, the tree splits it into its unstaged and staged parts (see Files). With commits, it's one tree from
the oldest commit's parent to the worktree. `J`/`K` and `]r`/`[r` treat it like a commit.
Merge commits are dimmed and skipped. In branch views, a selection reaching the oldest commit
compares against the merge-base, like github.com, so changes merged in from the base branch don't show up.

Resting the cursor on a commit shows its full message in a float beside the log: short sha, author, date,
then the message wrapped to fit. It closes on a non-commit row, when you leave the log, or on `<Esc>`
(until you move to another row).

With an open PR (see GitHub review), the log's first row is the PR: `#42 Retry failed uploads · 2 unpushed`.
After the number and title, the sync conflicts waiting for you (`1 conflict`, see GitHub review), then
where your branch stands against the PR head on GitHub: nothing when in sync,
`N unpushed`, `behind N`, `diverged`, or `GitHub has newer commits` when the PR head isn't a local commit
(diffy never fetches); then the sync's state as an icon, only when there's one: `↻` (a read or a mirror
running, or a draft about to be mirrored), `⊘` (offline: the last read failed) or `⚠` (the last sync
couldn't write something; it retries with the next one). Resting the cursor on it says the same in words:
syncing, when GitHub was last read, why the last sync failed if it did; then the PR's description, each
reviewer's state (`alice ✗ changes
requested`, `bob ✓ approved`), every review with its
commit (`not in this log` or `no longer in the branch` for a commit the log doesn't list) and the
conversation. A commit the log lists that has submitted reviews gets one dim row right above it: one
review shows its author and state (`── alice ✗ 4 threads`), several are summed up with their states and
the threads they started (`── 3 reviews ✗○ 4 threads`). `J`/`K`, `a` and ranges skip both kinds of rows;
`<CR>` on a review row selects everything above it, what changed since those reviews. `<CR>` on the PR row selects the whole PR:
everything in `:Diffy branch`; in `:Diffy`, the session becomes `:Diffy branch` on the PR's base (leaving
checkout mode first).

| Key | |
|---|---|
| `<CR>` | select the entry under the cursor |
| `v`/`V` + motion, `<CR>` | select a range |
| `a` | select everything |
| `<CR>` on a review row | select everything above it |
| `<CR>` on the PR row | the whole PR (`:Diffy` switches to `:Diffy branch`) |
| `J` / `K` | select the next / previous entry |
| `X` | toggle checkout mode (see below) |
| `<Esc>` | close the commit message float; with none shown, whatever `<Esc>` is mapped to outside diffy |

**Files** (top): status letter, path relative to its folder, `+added -removed`. The file shown in the diff
is highlighted. A path too long for the panel shortens its folders to their first letter, outermost first
(`l/d/panels/name.lua`), then cuts the end of the name (`l/d/p/a_long_na…`); only when that leaves almost
nothing of the name do the folders become `…/`. With the cursor on a cut row, the whole row is drawn over it,
past the panel's edge.

With `Working tree` selected alone, the files come in two sections, `Unstaged (n)` (index → worktree, plus
untracked files) then `Staged (n)` (HEAD → index). A file with both kinds of changes is listed in each, and
opens that section's diff: the real file on the right for Unstaged, the index on the right for Staged. Both
headers stay when a section is empty; with no changes at all the tree says `(no changes)`.

| Key | |
|---|---|
| `<CR>` | open the file and move to the diff; on a folder or section header, collapse / expand it |
| `o` | open the file, stay in the tree; on a header, collapse / expand it |
| `]f` / `[f` | next / previous file, skipping collapsed folders and viewed files |
| `]r` / `[r` | next / previous commit |
| `gf` | open the real file in the previous tab |
| `-` | move the file to the other section (stage in Unstaged, unstage in Staged) |
| `s` / `u` | stage / unstage the file, whichever section it's in (a rename stages both paths) |
| `S` / `U` | stage / unstage everything |
| `m` | mark the file viewed, or unmark it; on a folder, section or `Viewed` header, mark every file under it, or unmark them all when they all are viewed |
| `<leader>du` | undo the last mark or unmark (see Viewed files) |

Folder and section headers start with `▾` when expanded and `▸` when collapsed. A collapsed folder stays
collapsed as you change the selection; jumping to a file inside it from the diff expands it.

On a section header, collapsed or not, `-`, `s` and `u` apply to every file of that section. After staging, the cursor
follows the file into the section it moved to. A conflicted file is left alone by the header keys, `u` and `-` in
Staged: `s` (or `-` in Unstaged) on its own row marks it resolved, as in the conflict view. Staging works only with `Working tree` selected alone. You
can also stage hunk by hunk: for an Unstaged file the left side is the index, so `do`/`dp` or editing it and
`:w` stages; for a Staged file the right side is the index.

**Viewed files.** Marking a file viewed (`m` in the tree, `<leader>dm` in the diff, `:Diffy viewed`) moves it
to a folded `Viewed (n)` group at the top of its section (or of the tree, without sections), drawn grayed out
(`DiffyViewed`), folders and files included. The group
unfolds while it holds the file shown and folds back once that file leaves it, unless you unfolded it
yourself. `]f`/`[f` skip viewed files, and so does the file opened first after a refresh. Marking the file
shown opens the next unviewed one; with none left, the keys stay where they are and say so. `<leader>du`, in
the tree or the diff, undoes the last mark or unmark of the session (a whole folder at once if that's what
it was) and goes back to the file you were looking at when you marked it; press again to undo the one before.

A mark records the file's change as the view shows it: the blob on the left and the blob on the right. The
file stays viewed while the view shows that same pair: committing, staging, amending or rebasing on a base
that didn't touch it keep it; an edit to it, a base that changed it, a symlink retargeted or a submodule
moved bring it back. A file that comes back carries `●` until you open it (the file you're looking at never
gets one). Marks are per view: a file marked on one commit isn't hidden in the whole-branch view, and the
other way round; each view keeps its own marks (the last 5 per path). A rename (`R`) keeps the marks of
its old path. `:Diffy viewed clear` drops every mark of the file shown. Marks are stored in
`.git/diffy/<branch>/viewed.json`, shared live by every session on the branch, in any nvim.

## The diff

The right side is the real file (LSP, editable) when it shows the worktree, or HEAD for a file with no
uncommitted changes. Otherwise both sides are read-only fugitive blobs. Comment bars and summaries follow
your edits as you make them; `:w` on either side rebuilds like `R`, so the tree's counts and sections stay
current (without reading GitHub again).
An added or deleted file takes the
whole diff area on its own, coloured as added or deleted. Jumping to another file from the right side
(go-to-definition, `gf`, `:e`, a picker) loads that file's pair if it's part of the diff; otherwise diff mode turns
off until you come back (`<C-o>`, `<C-t>` or the tree). A jump from the left side opens in the right
window, so `<C-o>`/`<C-t>` there bring the pair back. `<C-o>` never goes back past the start of the
session.

| Key (in either diff window) | |
|---|---|
| `]f` / `[f` | next / previous file, skipping viewed files |
| `<leader>dm` | mark the file shown viewed (and open the next unviewed one), or unmark it |
| `<leader>du` | undo the last mark or unmark, back to the file shown when it was marked |
| `]r` / `[r` | next / previous commit |
| `R` | refresh everything: git state, panels, window sizes; and read the PR again (see GitHub review) |
| `<leader>e` | hide the panel column, the cursor staying where it is; or show it and go to the file tree |

The `]`/`[` keys (`]f`, `]r`, `]t`, `]x`, here and in the panels) take a count: `3]f` moves three files
down, `2[r` two commits back, stopping at the first/last one.

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
closed until the cursor leaves the line (or `<Tab>`, `<CR>`, `]t` ask for it).

The bars take over the diff windows' `statuscolumn` (fold, sign and number columns, then the bars) while
the file has comments, and put your own back otherwise.

| Key (in a diff window) | |
|---|---|
| `gc` | comment on the line (visual mode: on the range); `<C-s>` or `:w` saves, `q` cancels |
| move onto a commented line | preview its leftmost thread, over the other diff window |
| `<CR>` | enter the thread float (`K` stays LSP hover / `keywordprg`, commented line or not) |
| `]t` / `[t` | next / previous thread, by first line, larger range first, oldest first |
| `<Tab>` / `<S-Tab>` | next / previous thread covering the cursor line, left to right, wrapping (also in the thread float) |
| `<Esc>` | close the thread card; no preview on this line until the cursor leaves it. With no card open, whatever `<Esc>` is mapped to outside diffy (e.g. `:nohlsearch`) |
| `<leader>ds` | hide / show the summaries, keeping the bars (hover still previews) |
| `<leader>dr` | hide / show resolved threads |
| `<leader>dt` | hide / show comments inline altogether |
| `<leader>dc` | the threads view: every thread, the file in the diff first (`:Diffy threads`) |
| `gP` | PR description and conversation (when the branch has an open PR) |

Threads open as a framed card over the other diff window; on an added or deleted file, where there is only
one, right under the commented lines (above them when there's more room there), so they stay visible,
with the frame's left edge on the thread's bar in the status column (a new comment's box on the first
lane); there, the open thread's own summary is blanked while it's open, since it'd show past its right
edge. A card is at most 100 columns wide, centred over the other window's text; it follows the diff when
it scrolls under it and is fitted again when the editor or the diff windows are resized. The
comment boxes are placed the same way; the `gP` card is centred on the editor and refitted too. Each comment gets a header strip: avatar, author (on
GitHub; "You" in a local review), age, and its state when it isn't published yet: `draft` (only in
diffy), `pending` (in your unsubmitted GitHub review), `local only: <why>` (a draft GitHub can't take yet),
`sent` (exported to the agent), and with a PR `conflict`/`github.com` (both sides of a sync conflict),
`edit staged`, `deletion staged`, `edited on github.com`/`your edit` (see GitHub review). A rule in the
frame's colour separates consecutive comments, in the thread float and the `:Diffy threads` preview. The first header
also says `outdated`, `✓ resolved`, `resolve staged`. Summaries carry the same states, shortened (`conflict`,
`local only`, `edit staged`, …). Bodies render as markdown; suggestion blocks are labelled, empty
ones as "remove these lines". A preview taller than half the window is cut, with a hint to press `<CR>`.

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

In the thread float, the footer lists the keys that apply: `r` reply, `e` edit the comment under the
cursor (a draft, or with a PR your published comment), `dd` delete it, `x` resolve/unresolve, `]t`/`[t`
switch thread, `q` close. Entering a thread puts the cursor on its latest comment. A
reply or an edit is written in a box under the thread, which stays in view (a reply starts in insert
mode, an edit in normal mode at the end of the draft); saving goes back to the diff, cancelling goes
back into the thread. Leaving a comment box or the thread for the diff puts the cursor back where it
was. In the compose float, `<C-g>s` inserts a GitHub suggestion block with the commented lines. `gP`
shows the PR description and its conversation the same way.

**The threads view** lists the review's threads grouped by where they stand: Open, Outdated (its lines
changed in the worktree, not resolved), Detached (nothing left to place it from: its commit is gone, or a
worktree comment's text is), Resolved, and Resolved,
outdated; within a group, under a header per file, the file in the diff first (in bold). Group headers
carry the count; the resolved groups start folded, and the cursor starts on the first thread of the file in the
diff. Each row gives the line, who started the thread ("you" for yours), how many replies and who wrote
the last one when it's someone else, its states (`draft`, `pending`, `conflict`, …), and the first line. A thread the selected range
doesn't show has its line dimmed.

It opens in a float over the diff with a preview beside it (on a wide enough screen): which commits show
the thread (GitHub), for an outdated or detached thread the commit it was written on (`a commit no longer
in the branch` once a rebase or force-push replaced it), the code as it was written (its lines numbered and
marked, up to 3 lines of context above, the middle of a long range cut; GitHub's diff hunk for a published
thread), then the thread. With `'threads'` in `column` it sits in the left column
instead, compact and without the preview, and `:Diffy threads` moves the cursor into it.

| Key (in the threads view) | |
|---|---|
| `<CR>` | go to the thread: its file, the cursor on its first line, the thread hovered there (that one, when several share the line; `<CR>` enters it). An outdated thread opens in the view it was written in: its commit alone when that commit changes the file, else everything up to that commit. Otherwise, when the selected range doesn't show the thread, the selection switches to one that does first (the whole range, else the newest commit showing it). A thread written on a commit no longer in the branch that no view shows stays in the threads view with a warning: the preview has its code as written. Resolved or hidden threads are shown again. On a group header: fold / unfold; on a file header: its first thread |
| `<Tab>` | fold / unfold the group under the cursor |
| `x` | resolve / unresolve the thread under the cursor (with a PR, staged until you submit) |
| `m` | only threads you started / everyone's (GitHub) |
| `<C-f>` / `<C-b>` | scroll the preview |
| `q` / `<Esc>` | close the float; leaving it for another window closes it too |

Avatars and badges need a terminal with the kitty graphics protocol, `curl` and ImageMagick. They're
downloaded once and cached in `stdpath('cache')/diffy/avatars` and `/images`; without them the headers,
summaries and badges are text only.

Every thread is placed the same way, local or GitHub: from where it was written (a commit, the
merge-base for an old-side GitHub comment) it's tracked to whatever each view shows, through git's diff
between the two, and to the worktree through the buffer itself as you type. It shows in every view both
ends of its range reach through unchanged lines, renames included, and is hidden in the others. It's
outdated as soon as its first or last line changes in the worktree (in checkout mode, the checked-out
commit), and back if you undo; a comment on the old side, once it can't be tracked back to the merge-base
(HEAD without one). A comment written on the worktree or the index is found by its text within ±20 lines; once
HEAD has that text (you committed it), it becomes a comment on HEAD at those lines and is tracked like
any other. When its text is gone, it's detached.

Your comments are kept per branch in `.git/diffy/<branch>/threads.json`, whichever review you wrote them
in, next to what the GitHub layer read last (the PR, its published threads and reviews), replaced by each
read. Sessions on the same branch, in one nvim or several, share them: a comment written, edited or
deleted in one shows in the others right away (`local.json` and `pr-<number>.json` from older versions
are merged into it the first time).

### Local review, for an LLM agent

Available in `:Diffy` and `:Diffy branch`.

`:Diffy review submit` opens a box for an overall message (may be left empty); `<C-s>` writes
`.git/diffy/<branch>/review.md` with that message and every comment not yet sent, marks them sent and
copies the prompt to the `+` register: paste it to your agent. Each comment says where it is now (its
lines tracked to the worktree, the index for an index comment, with the code around them) and where it
was written (the commit and the diff hunk), then the comment. An outdated, detached or old-side comment
has no location now: it gets its commit, lines and code where it was written. A message alone is sent
too. `:Diffy review clear` deletes your comments on the branch.

Each comment's section starts with a `- [ ] resolved` box, and the prompt asks the agent to tick it once
the comment is handled. diffy reads the ticks when it opens the review, on `R`, and before the next submit
replaces the file: those threads become resolved (✓ inline, in the Resolved group of the threads view). A
tick counts once, so a thread you reopen with `x` stays open.

### GitHub review

When the session's branch has an open pull request on GitHub, a layer loads over `:Diffy` and
`:Diffy branch` (not ranges, `:Diffy file` or `:Diffy conflicts`): the PR row and review rows in the log
(see The panels), the published threads, `gP`, and GitHub as a place to submit. The session doesn't wait
for it: it renders first, and the layer attaches when `gh` answers. As soon as `gh pr view` finds the PR,
its row shows with a spinner (`#42 Retry failed uploads ⠹`) until the PR's read comes back. The PR is the one
`gh pr view <branch>` finds (it follows the branch's upstream, forks included); every read and write goes
to that PR's repository. Merged or closed PRs don't attach, and an attached layer goes when a read finds
the PR merged or closed: its row, its threads and what was read, not your drafts. `github = false` in
`setup` turns the layer off.

- **Reading**: when the session opens, on `R`, on `FocusGained`, and every `github.read_interval` seconds
  (5 minutes) while the session's tab is current; entering the tab reads when the last read is older than
  that. One read at a time, one more queued behind it. A read fetches everything, page after page. `:w` and
  other rebuilds don't read: they place the threads from the last read again.
- **Offline** (or without `gh`): the layer comes back from the last read, the PR row saying `offline`;
  with nothing read before, there's no layer and no warning.
- Threads are placed like every thread (see above), as github.com's "Changes" view does: in the full view
  and in each commit's view, at the line they track to, hidden where their lines changed. Outdated threads
  are in the threads view with the others; `<CR>` there opens the commit they were written on, and the
  preview shows their code as written, also for commits a force-push replaced.
- **Your pending review follows your drafts.** About 2 seconds after you write, edit or delete a draft,
  diffy mirrors it into your pending review on GitHub, which only you see: the review is created with the
  first draft, a draft lands on the commit you wrote it on (a removed line as a left-side comment), a
  reply in its thread. Offline, the next successful read does it; a change an nvim closed on before
  mirroring goes with the next sync of any session. Deleting your last pending comment deletes the review
  on GitHub; the next draft makes a new one. A pending review diffy didn't create (github.com, another
  machine) is adopted: its comments become your drafts. Nothing anyone else sees changes before a GitHub
  submit.
- A draft GitHub can't take stays in diffy, marked `local only: worktree` (written on the working tree or
  the index), `unpushed` (its commit isn't on GitHub) or `outside the diff` (beyond the changes and their
  3 lines of context): it's mirrored once that changes, e.g. after you commit and push.
- **Sync conflicts.** Before changing a mirrored comment, diffy reads it again; it never overwrites a
  change made on github.com:
  - a pending comment changed on both sides: both versions show in the thread, the web one marked
    `github.com`, and the PR row counts the conflict; `dd` the version you drop (or `e` either). Edited on
    one side and deleted on the other: the edit wins.
  - a staged edit (below) of a comment edited on github.com: the live comment (`edited on github.com`)
    then `your edit`; `dd` on your edit drops it, `dd` on the live one stages its deletion, `e` on your edit
    keeps it over the web one.
  - a staged edit of a comment deleted on github.com becomes a draft reply in its thread; a staged deletion
    of a comment edited there is cancelled. A draft reply, or a staged edit, whose thread was deleted is
    dropped. Each comes with a notification holding your text.
- **Staged changes**, kept in diffy until a GitHub submit: `x` on a published thread stages resolving or
  unresolving it (`x` again cancels); `e` on your published comment stages an edit, `dd` its deletion
  (`dd` again cancels).
- `:Diffy review submit` opens a box for the review message; `<C-s>` then asks where it goes: `a` the agent
  (as without a PR, see above: your drafts, marked sent and taken out of your pending review) or `g`
  GitHub, which then asks `c` comment, `a` approve or `r` request changes (`q` goes back to the message).
  An argument picks the event and means GitHub, skipping both questions; on your own PR, where GitHub only
  allows a comment, there's no second question. Each comment goes to one place.
- Before a GitHub submit, a float lists everything going out: new threads, replies, staged edits,
  deletions and resolves, each `[x]`; `x` leaves one out (a draft left out stays a draft and goes into a
  new pending review afterwards), `<CR>` sends, `q` cancels. It also lists the drafts that stay behind and
  unpushed commits. Sync conflicts must be settled first. Then: the drafts left out leave the pending
  review, the review is submitted (with no comment going, the message alone: approving without comments),
  then the staged edits and deletions, then the staged resolves. A staged change that fails stays staged
  and the next sync retries it.
- `:Diffy review clear` asks, then drops your drafts and staged changes and deletes your pending review on
  GitHub, adopted comments included.

## Highlights

All set with `default = true`, so a colorscheme or your config can override any of them:

| Group | Default | |
|---|---|---|
| `DiffyAdded` / `DiffyChanged` / `DiffyRemoved` / `DiffyConflict` | `Added` / `Changed` / `Removed` / `DiagnosticError` | status letters, counts |
| `DiffyFileAdded` / `DiffyFileDeleted` | `DiffAdd` / `DiffDelete` | an added / deleted file shown on its own |
| `DiffyDirectory`, `DiffySha`, `DiffyLabel`, `DiffyMerge` | `Directory`, `Identifier`, `Title`, `Comment` | tree folders, log rows |
| `DiffySelection` | `Visual` | selected commits |
| `DiffyCurrentFile`, `DiffyCurrentFileName` | `Visual`, bold | the file shown in the diff |
| `DiffyViewed` / `DiffyViewedChanged` | `Comment` / `DiagnosticWarn` | the Viewed group, its folders and files / the `●` of a viewed file that changed since |
| `DiffySyncState` / `DiffySyncFailed` | `Comment` / `DiagnosticWarn` | the PR row's `↻` and `⊘` / its `⚠` |
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
| `DiffyThreadConflict` / `DiffyThreadStaged` | `DiagnosticError` / `DiagnosticHint` | sync conflicts / staged changes |
| `DiffyThreadResolved` / `DiffyThreadOutdated` | `DiagnosticOk` / `DiagnosticWarn` | thread states |
| `DiffyThreadCodeBar` / `DiffyThreadSuggestion` | `Comment` / `Added` | code block bar / suggestion bar and label |
| `DiffyThreadLink` | `Underlined` | link text in cards |
| `DiffyThreadKey` / `DiffyThreadHint` | `Special` / `Comment` | footer keys / their labels |

## Tests

From this directory: `make test` (the whole suite, one nvim per test file in parallel, about 10 s; `JOBS=N`
caps the parallelism), `make test FILE=tests/test_staging.lua`.
`make test-gh` runs the GitHub tests against the real sandbox repository, opening and closing a throwaway
PR per test.
