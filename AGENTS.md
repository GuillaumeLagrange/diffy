# diffy — agent guide

`doc/diffy.txt` (`:help diffy`) is the user-facing reference: every feature, command, key and option. Keep
it in sync with the code in the same change; `README.md` is only a short intro pointing at it. This file
is for whoever works on diffy: how the code is organised, how to test it, and the nvim/git/GitHub
behaviour we measured the hard way. `diff-plugin.md` is the original design document, being retired;
don't cite it (or this file) from code or tests.

## Working here

- The user's config (`~/dotfiles/nvim`, symlinked as `~/.config/nvim`) loads this checkout from
  `~/projects/diffy`: `nvim/plugin/diffy.lua` there prepends it to the runtimepath and sets the user's
  `<leader>dv*` maps. Edits are live.
- Run tests from the repo root: `make test` (~10 s, offline, test files in parallel, `JOBS=N` to cap),
  `make test FILE=tests/test_x.lua`, `make test-gh` (live GitHub, opt-in).
- Comments state the non-obvious why, invariants and gotchas; no narration of how the code came to be.
- A change that affects behaviour updates `doc/diffy.txt`, and `README.md` only when it touches what the
  README shows. The help file follows mini.nvim's layout: `tw=78`, tags right-aligned to column 78,
  `# Section ~` headings, `>lua`/`<` code blocks. `|word|` is a link, so never write `a|b` in prose;
  every link must resolve to a tag (`:helptags doc` fails on a duplicate tag). `doc/tags` is gitignored.

## Code map

```
plugin/diffy.lua        :Diffy command, nothing else at startup
lua/diffy/
  init.lua              setup/config, :Diffy dispatch + completion, M.start (open a session) / M.build (render pipeline),
                        M.debug_state (plain-data snapshot of sessions + recent commands, for bug reports),
                        :Diffy feedback (modal -> `User DiffyFeedback`)
  session.lua           one session per tab: registry, augroup, namespaces, keymap tracking, overlay floats, teardown
  layout.lua            views (tree, log, threads) and where they're shown: the left column, floats
  git/run.lua           every git/gh subprocess (vim.system), error notify, DiffyReady, M.recent (last 50)
  git/parse.lua         pure parsers for git's -z formats (log, name-status, raw+numstat, status v2, ls-files -u)
  git/repo.lua          root, merge-base, base resolution, status, default range, diff args
  selection.lua         log selection -> (left rev, right rev), a commit's parent rev; the real-file rule
  panels/stack.lua      the tree and the log sharing one column window/buffer: row ranges, rule, gap, peek
                        floats over the edges, per-row key dispatch, `]]`/`[[`
  panels/log.lua        commits view: entries per view kind (the `Working tree` entry, commits), the GitHub layer's
                        PR row and review markers, the throwaway push row (a rewritten commit's threads), selection keys
  panels/commitmsg.lua  float beside the column while the log cursor rests on a commit (its message) or the PR row
  panels/tree.lua       files view: tree rows (Unstaged/Staged sections for the working tree, Viewed groups), right blob
                        ids for worktree files, staging and viewed keys, file navigation
  viewed.lua            viewed marks (blob pair per path) in viewed.json: shared per nvim, watched across nvims
  diffpair.lua          the two diff windows: buffers, diff mode, winbars, b:diffy_title, shared keys,
                        edits (redecorate on change, rebuild on write)
  navigation.lua        BufWinEnter on the diff windows, reacted to on the next tick: swap the pair when you
                        jump to another file; a left-window jump is moved to the right window
  checkout.lua          X checkout mode (the selected commit stays checked out as you move), checkout.json, restore
  conflict.lua          :Diffy conflicts and the 4-window conflict view
  prompt.lua            key-driven yes/no, pick-one and checklist floats (vim.fn.confirm can't be driven in tests)
  highlight.lua         highlight groups (default links, card backgrounds) and width-fitting helpers
  avatar.lua            images over the terminal (kitty graphics): avatars, body badges; detect, fetch, place, clear
  review/model.lua      thread data, ids, excerpt relocation, the placement rule (source, line tracking),
                        GitHub anchor validity/position
  review/track.lua      placement: diffs from each thread's source to every rev a view shows (git, vim.diff
                        on loaded buffers), outdated/detached, worktree comments settling on HEAD
  review/ui.lua         signs, summaries, comment cards (thread float, gP), compose float, thread jumps
  review/render.lua     comment body -> card lines: HTML to markdown, link table (gx), <details> folds, badges
  review/threads.lua    the threads view (:Diffy threads): grouped rows, preview pane, jump keys
  review/store.lua      JSON in .git/diffy/<branch>/: atomic writes, read-apply-write updates, file watch
  review/drafts.lua     the branch's one store of your comments (threads.json), shared by sessions, migration;
                        the mirror's bookkeeping and staged changes
  review/local.lua      local backend + review.md export
  review/github.lua     the GitHub layer: `gh pr view` lookup, paginated read, cache in threads.json, attach/detach,
                        read cadence; gh transport; reconcile (a read against your drafts), the background sync
                        into your pending review, staged changes, submit, clear
```

Conventions the code relies on:

- **Sessions.** `session.open` builds the tab (`:tab sbuffer`, see below) and registers windows/buffers.
  Every buffer diffy creates goes through `session.register_buffer` (`bufhidden=wipe`; fugitive blobs
  `delete`, so jumplist/tag stack entries pointing at them survive); every buffer-local
  map through `session.map` (desc prefixed `diffy: `, removed on teardown or when a real file leaves a diffy
  window); every namespace through `session.namespace`. Window options are only set inside the session tab.
  A non-focusable float laid over other windows (peeks, the tree's hover, the commit message) goes through
  `session.overlay`, which unbinds it from the diff. `teardown` is idempotent and runs from every close path.
- **Views.** The file tree, the commit log and the threads list are views (`layout.lua`): a buffer at
  `session.bufs[name]`, shown at `session.wins[name]` in whichever host holds it, the left column
  (`session.column`, from `config.column`) or a float over the diff area. A view module exports `view`
  (render, height, keys, preview, …) and renders at its window's width, asking `layout.host` how much to
  show. Column windows end the session when closed; floats are registered `transient` and only closed by
  teardown. The tree and log buffers exist even when not shown: the diff navigation and the conflict list
  draw into them. Next to each other in the column, the tree and the log are one buffer and one window
  (`panels/stack.lua`, `session.bufs.tree == session.bufs.log`): a view reads and writes its rows only through
  `stack.set_lines`/`cursor`/`set_cursor`/`lnum` (its own 1-based rows, whichever buffer it's in), maps keys
  through `stack.map`, and clears only its own namespaces.
- **Async.** All git/gh calls go through `git/run.lua` with `opts.session` (callbacks no-op once the session
  is closed) and, for renders, `opts.gen` (`session.gen` is bumped by every tree render, so a stale render
  from an earlier selection is dropped). Chained calls start the next link from the previous callback, so
  dropping one link drops the chain.
- **DiffyReady.** `run.ready({ session, event })` fires `User DiffyReady` when something finished drawing.
  Events: `render`, `select`, `open_row`, `review`, `thread`, `threads`, `compose`, `choose`, `conflict`,
  `checkout`, `restore`, `pr` (a GitHub layer read finished, attached or not; `:Diffy pr` warning), `sync`
  (a background sync into the pending review finished, or had nothing to do), `confirm` (the GitHub submit's
  checklist is open), `close`, `commitmsg`, `feedback`, `viewed`. Tests wait on these; never sleep.
- **The GitHub layer.** `:Diffy` and `:Diffy branch` render without GitHub; `github.start` then reads
  (`session.layer`). Attaching swaps `session.review.backend` to `review/github.lua` and adds the
  published threads and `review.pr`; detaching swaps back to `review/local.lua`. The log's layer rows
  (`kind = 'pr'`/`'marker'`) are entries that `selection.selectable` refuses; `log.apply_layer` redoes
  them, keeping the selection by entry identity. The last read lives under `github` in threads.json;
  rebuilds (`M.build`, `:w`) never read GitHub, `R` does.
- **Review backends** expose `name`, `capabilities = {resolve, suggestions, people}`, `author`,
  `place(session, thread) -> {win, start_line, end_line} | nil` (in the open file), `view_place` (the same
  for any file of the current pair, or of a given pair: the threads view uses it to pick a selection that
  shows a thread), and for authoring `save(session, thread, comment?)`, `clear(session, cb)`,
  `submit` (local: to the agent; GitHub: the confirm float, then the pending review), and on GitHub the
  staging calls `toggle_resolve`/`stage_edit`/`drop_edit`/`toggle_delete`. Both place through `review/track.lua`,
  so a thread shows in every view it tracks to, whichever backend wrote it. `review/ui.lua` only draws what
  `place` returns and caches it on `thread._place`.
- **One store per branch.** Your comments live in `.git/diffy/<branch>/threads.json`, keyed by
  `session.branch` (the branch the session opened on). Every change goes through `review/drafts.lua`
  (`put`/`remove`/`change`): a fresh read of the file, one change, an atomic write; never write a session's
  whole thread list back. Sessions of one nvim on a branch share one entry and all redraw on a change; other
  nvims reload through the file watch, stopped when the last session on the branch tears down. Session
  threads are per-session objects brought in line by `drafts.apply`, matched by id; ids are time + random
  (`model.new_id`).
- **The background sync.** Every change through `drafts.update` (except the sync's own, `{ sync = true }`)
  schedules `github.mirror` `github.sync_delay` ms later in the nvim that made it; every successful read
  runs `github.reconcile` (the read against the store) then a sync, and so does a rebuild. One sync at a
  time per branch store in an nvim (`syncs[path]`), held during a submit or a clear. The sync's git calls
  don't pass `opts.session`: a sync started by a session that closes still finishes and releases
  `syncs[path]`. A mirrored draft is a `draft` with `gh = { id, body, updated_at }`; the read's copy of it
  is hidden (`mirrored_ids`), so the store is what shows. Deleting a mirrored draft leaves a tombstone in
  `mirror.deleted` for the sync. A published comment is stored only with a staged change
  (`staged_body`/`staged_delete`, `edited_at`);
  `drafts.apply` lays it over the live comment. GitHub ids of threads: `github = true` stored threads are
  published GitHub threads (their id is GitHub's), `gh_thread` the GitHub thread a draft thread became,
  valid while its first comment is mirrored.
- **One-sided files.** An added or deleted file closes the empty side's window (`session.hidden_side`,
  `session.wins[side] = nil`) until `diffpair.restore`; anything reaching for `session.wins.left/right`
  checks it exists. The conflict view restores both first.
- **Alignment.** Counterpart lines come from nvim's own diff: in each window `row(l) = l + Σ diff_filler(k)`
  for `k ≤ l`; equal rows are counterparts. Summaries under a row are padded with blank virt_lines to the
  busier side's count so both windows stay aligned.

## Testing

Harness: mini.test, one fresh child nvim per case started with `-u tests/minimal_init.lua` (diffy + fugitive
+ mini.nvim pinned in `.deps/`, never the user's config). `minimal_init.lua` also pins git config
(`GIT_CONFIG_GLOBAL=/dev/null`, no commit signing: the user's global config signs with a hardware key and
`git commit` hangs on it). Fixture repos come from `tests/helpers/repo.lua` with pinned names and dates, so
shas are stable; `Repo.standard()` is the shared history (edits, re-edit, merge from main, rename, delete,
add, line shift).

Rules for every test:

1. Named after a behaviour in user terms (`'writing the index buffer stages only the edited hunk'`).
2. Proven to fail: break the code it covers, see it red, restore. Say what you broke in the commit message
   (`Fails without: …`). Use a reversible `sed` on a copy, never `git checkout` a file with other work in it.
3. Assert what the user sees: buffer text, winbars (`ui.layout`), rendered extmarks (`ui.threads_visible`,
   `ui.rows_with`), floats (`ui.thread_float`), git state (`ui.git`), files on disk. Never session internals;
   `ui.wins` is only for addressing windows.
4. Input through real keys and commands (`child.type_keys`, `:Diffy …`). Calling diffy's Lua directly is only
   for pure logic (parsers, selection, line tracking, anchor validity, position).
5. No: module-loads tests, default-config tests, mocks echoing their input, only-doesn't-throw, length
   checks instead of content, near-duplicates of the same path, error-wording pins.
6. Boundaries and transitions over happy-path repeats. Regression tests come from real bugs.
7. Deterministic: wait on `DiffyReady` or `vim.wait` on an observable condition; no network outside
   `make test-gh`. `ui.wait_ready` fails the case when its event never fires: wait only for an event the
   action fires (a no-op key fires nothing). Proving something *doesn't* happen: wait for the end of the
   chain that would do it (a dropped result in `run.recent`, every started command exited), not a timeout.
   Git, fugitive and nvim are never mocked; the only fake is the `gh` transport.
   Test files run concurrently (one nvim each): anything outside `vim.fn.tempname()`, like the fixed
   `/tmp/diffy-*-fixture` screenshot dirs, needs a path no other file uses.
8. The leak check (`tests/helpers/leak.lua`, `post_case` of every UI file) fails a case that leaves a diffy
   augroup, `diffy://` buffer, diffy keymap, extmark, extra tab/window, changed option outside the tab, or a
   listed `[No Name]`/fugitive buffer.
9. Screenshots only for the layout, the mirrored comment alignment and the conflict view. Reference files in
   `tests/screenshots/` are named after the case: renaming a case means renaming its reference file.

GitHub tests: `review/github.lua` sends everything through `M.transport` and `M.pr_view` (`gh pr view`);
tests swap both with `fake_github.install(state)`, which implements the GitHub behaviour listed below.
`minimal_init.lua` installs one with no PRs, so no test reaches the network outside `make test-gh`. Read
responses are real GraphQL recorded from sandbox PRs #2–#4 (`tests/fixtures/github/pr*.json`), with git bundles of their
branches so shas match. `make test-gh` (`DIFFY_TESTGH=1`) runs the same test files against the real sandbox,
one fresh PR per case, closed afterwards; placement cases are fake-only because they depend on PR #2's
between-pushes state, and write cases needing a state only the fake can produce (a failing mutation, a
thread deleted under a draft) are fake-only too. When fake and GitHub disagree, fix the fake. The fake
also offers web-side actions (`edit_comment`, `delete_comment`, `push`), a ticking clock (`now`), mutation
failures (`state.fail`) and the mutations in order (`state.calls`). Write tests lower
`github.sync_delay` (ms) so the background sync runs soon after a change.

Harness gotchas:

- Opening a float from a key (`K`, `gc`) or a key whose handler spawns a subprocess can leave the child
  `blocking` until more input arrives; `child.lua`/`ui.wait_ready` then throw. Wait with raw `child.api`
  calls (`ui.wait_ready_raw`).
- `vim.fn.confirm()` returns its default immediately in the child; that's why `prompt.lua` exists.
- An error inside a `vim.schedule` callback lands in `vim.v.errmsg`, not reliably in `:messages`.
- To reproduce an async race, defer *issuing* the subprocess (queue the `run.git` call), not the delivery of
  its result: the staleness check runs when the real subprocess completes.
- `:0cquit` (mini.test's `child.stop()`) fires `VimLeavePre`. Simulate a killed nvim with `SIGKILL` on the
  child's pid.
- Under `--noplugin`, rtp entries added in the init still don't source `plugin/`; `minimal_init.lua` runs
  them explicitly.

Reproducing a bug under the user's real config (most real bugs only showed up there): a child with
`child.restart({ '--cmd', 'set rtp^=~/.config/nvim packpath^=~/.local/share/nvim/site', '-u',
vim.fn.expand('~/.config/nvim/init.lua') })`, then `set termguicolors`. `child.get_screenshot()` errors with their colorscheme; read the screen with
`vim.fn.screenstring(row, col)` and highlights with `vim.fn.screenattr`. Throwaway scripts go in `/tmp`.

Bug reports and `:Diffy feedback` can come with `debug_state()` as it was when the user hit them: sessions,
selection, shown file, recent git/gh commands. A feedback is the user's complaint about what the session
showed at that moment; it's not an error.

Seeing what the user sees (colours, avatars, floats): a headless compositor running kitty › zellij › nvim
with the real config and `--listen`, screenshotted with `grim`:

- `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 setsid -f sway -c conf`, where `conf` holds
  `output HEADLESS-1 resolution 1500x800` and `exec kitty -o background_opacity=1 zellij --config
  z.kdl -s NAME -n layout.kdl`. `z.kdl` is the user's zellij config plus `show_startup_tips false` (the tip
  popup covers the pane); the layout's pane runs `nvim --listen SOCK`. Unset `ZELLIJ*` first, or zellij
  treats it as a nested session.
- The user's config restores a session on start: `:cd` to the repo and `:%bwipe!` before `:Diffy`.
- Drive it with `nvim --server SOCK --remote-send '…'` / `--remote-expr`, shoot with
  `WAYLAND_DISPLAY=wayland-N grim shot.png`.
- Afterwards: kill sway, `zellij kill-session`/`delete-session NAME`, and restore the session environment
  (`systemctl --user set-environment WAYLAND_DISPLAY=wayland-1 DISPLAY=:0`, the same through
  `dbus-update-activation-environment --systemd`).

## The user's config

- diffchar.vim is active (their `diffopt` has no `inline:`). Its `BufWinEnter`/`OptionSet diff` handlers
  keep per-tab state and crash with `E716 Key not present` when a buffer is swapped into a window still in
  diff mode, so `diffpair.show` turns diff off before swapping.
- `diffopt` has `linematch:60`, which splits a conflict into one-line hunks: `gho`/`ght` pass the whole
  marker block as a range to `:diffget`.
- lualine rewrites every window's `statusline`; window-local statuslines don't show. mini.indentscope draws
  guides in indented panel rows unless `vim.b.miniindentscope_disable = true`.
- `<leader>` is space and `<leader>bb`/`bd`/`bo` exist, so a buffer-local `<leader>b` would wait for
  `timeoutlen`; the panel toggle is `<leader>e`.
- `nvim/ftplugin/rust.lua` refuses rust-analyzer on `fugitive://` buffers: blob sides never get LSP.
- Terminal: kitty 0.48 inside zellij 0.45.1. Kitty graphics *direct placements* (`a=p` at the cursor,
  `C=1`) work in both, follow nvim redraws, and are moved/deleted by id; zellij also answers the `a=q`
  support query. *Unicode placeholders* (`U=1`) don't work in zellij (zellij-org/zellij#5531), which is
  why snacks.nvim disables images there and why `avatar.lua` places images at screen cells instead.
- The colorscheme (gruvbox-material) leaves `Normal`/`NormalFloat` without a background: a float needs a
  background taken from another group (`CursorLine`, `Pmenu`) to stand out.

## nvim facts (0.12.5)

- `:tabnew` leaves a listed `[No Name]` buffer behind once its window shows something else; open the tab
  directly on a scratch buffer with `:tab sbuffer N`.
- `vim.api.nvim__ns_set(ns, { wins = {…} })` scopes a namespace's extmarks/signs/virt_lines to those windows
  (experimental API; `vim.fn.nvim__ns_set` raises). `nvim_win_add_ns` doesn't exist. The scope only holds
  for marks starting in the redrawn region: a multi-line range mark shows in every window of its buffer
  once a redraw starts below its first line (scrolled, cursorline moved), so `diffpair.lua` paints
  one-sided files from a decoration provider. An ephemeral `line_hl_group` isn't drawn; `hl_group` +
  `hl_eol` is.
- virt_lines on one side of a scrollbound diff shift that window only; the other side needs the same number
  of blank virt_lines on the counterpart line.
- Diff highlights (DiffAdd/DiffText) win over an extmark `line_hl_group`; mark ranges with
  `number_hl_group` instead.
- A float with `relative='win'` and `bufpos={w0, 0}` puts `col = 0` at the window's first text column, past
  its number/sign gutter.
- 'statuscolumn' also runs for virt_lines and diff filler rows (`v:virtnum` < 0, `v:lnum` = the line above
  them): the rows under a line count `-N..-1` top to bottom, virt_lines first, then filler. `%{}` items run
  with the drawn window current (`g:statusline_winid` isn't set), `%l` isn't padded to 'numberwidth'
  (right-align with `%=`), and an extmark's `number_hl_group` colours the whole status column.
  Ephemeral `inline` virt_text from a decoration provider isn't drawn.
- A window opened while a diff window is current, floats included (a snacks picker), copies its
  window-local options: `scrollbind`, `cursorbind`, `diff`. A bound picker prompt gets its cursor dragged
  back to column 0 as you type; `session.lua` unbinds every window of the tab diffy doesn't own on `WinNew`.
- cursorbind puts the other diff window's cursor on the counterpart line, past the filler for a line in an
  added/deleted block, so possibly below that window. nvim leaves it there until something validates that
  window's view (`line('w0')` inside `win_execute`, which diffchar.vim does on every `WinScrolled`); then
  the window scrolls to its cursor, out of alignment. `diffpair.keep_bound_cursor_visible` clamps it on
  `CursorMoved`, which runs before `WinScrolled`. Vim does the same.
- A buffer-local map that is a prefix of a global one waits 'timeoutlen' (1 s) for more keys unless it's
  `nowait`: fugitive maps `y<C-G>` globally, nvim `gcc`, `gr*`.
- `nvim_set_current_win`/`nvim_win_set_buf` don't fire `WinEnter`/`BufEnter`. `BufWinEnter` runs with the
  affected window current and only when the buffer actually changes.
- Autocmd callbacks don't nest: buffer swaps and option changes made inside a `BufWinEnter` callback fire
  no `BufWinEnter`/`OptionSet` for other plugins (diffchar.vim then keeps stale per-tab state), so
  `navigation.lua` reacts on the next tick. `bufload` fires `BufWinEnter` in a hidden autocmd window.
  Wiping a buffer drops its jumplist and tag stack entries; a new tab's diff windows inherit the previous
  window's jumplist and tag stack (`session.open` clears them).
- `WinClosed`/`BufWipeout` callbacks that close other windows of the same tab race `:tabclose`/`:qa`
  (spurious E444); defer them with `vim.schedule`.
- `:bwipeout!` on an unlisted scratch buffer closes its window too (firing `WinClosed`).
- `v:exiting` is already set in `VimLeavePre` on a normal quit: tells an exit apart from a tab close.
- `vim.system(cmd, { env })` merges `env` into the inherited environment.
- `vim.json.decode` turns JSON `null` into `vim.NIL`; pass `{ luanil = { object = true, array = true } }`.
  Comparing `vim.NIL` with a number inside a scheduled callback fails silently.
- `vim.fn.writefile` turns a `\n` inside one list item into a NUL byte; split lines first.
- `string.find(s, p, 1, true)` takes `p` literally, `%` escapes included.
- `FugitiveFind(object, dir)` wants the `.git` dir (`FugitiveExtractGitDir(root)`), not the worktree root.
- `nvim_win_get_height` counts the winbar; `getwininfo(win)[1].height` is the text rows only.
- A float's `title`/`footer` chunks are drawn with their own highlight only: without a background they show
  the terminal's default, not `FloatBorder`'s or `NormalFloat`'s. Chunk highlights can be lists, so stack a
  background group in (`{ 'DiffyThread', 'DiffyThreadKey' }`).
- The user's kitty has `background_opacity 0.95` over a wallpaper: backgrounds that are close in value
  (a tinted float on `Normal`) barely separate on their screen. A frame line does.
- A float anchored with `bufpos` only moves when its window scrolls, on the next redraw: `screenpos()`
  on it before that returns the old cells (avatars landed mid-text after a jump that scrolled the diff).
  `avatar.lua` placements are measured after a `:redraw`.
- Markdown treesitter highlighting conceals fence lines entirely (`conceal_lines`) at `conceallevel=2`, so
  a label for a fenced block has to hang off the line before the fence.
- `nvim_ui_send(data)` writes raw bytes to the TUI's terminal (the server's own stdout isn't the tty);
  `TermResponse` delivers APC replies, e.g. kitty graphics queries.

## git facts

- An unstaged rename is `D old` + `? new` until `git add -N new`; then `git diff -M` and porcelain v2 say `R`.
  diffy doesn't fake it. Staged rename plus an unstaged edit: porcelain v2 `2 RM`, the unstaged diff shows
  `M new`.
- `git status` needs `--untracked-files=all` to list files inside a new untracked directory.
- `git log -z` separates records with one NUL; `git diff -z --name-status`/`--numstat` terminate every token,
  and a rename's paths are two extra tokens.
- `--date-order` guarantees a merge is listed before its parents.
- A conflicted path appears twice in `git diff --name-status`: `U` and a spurious `M`. Keep the `U`.
- `git diff -M a b -- paths` pairs a rename only if both names are in the pathspec.
- After merging the base branch into a branch, the first commit's parent is no longer the merge-base:
  whole-branch diffs must use the merge-base (`git rev-list --ancestry-path mb..HEAD` finds the commits
  that contain it).
- Stable fixture shas: pin `GIT_{AUTHOR,COMMITTER}_{NAME,EMAIL,DATE}` and `GIT_CONFIG_GLOBAL=/dev/null`.
- `git bundle` carries only the named refs; recreate branches with `git fetch <bundle> refs/…:refs/heads/…`.
  A worktree can't check out a branch another worktree already has.

## GitHub facts (measured on the sandbox; the fake reproduces them)

Validation:
- Accepted: changed lines and up to 3 context lines around a hunk of `merge-base...commitOID`, both sides,
  multi-line ranges (even across hunks), renamed/added/deleted files, file-level threads.
- Rejected: anything else ("Line could not be resolved"), including lines brought in by merging the base;
  unknown path ("Path could not be resolved"). One invalid thread fails the whole `addPullRequestReview`,
  so validate locally first. `model.anchor_valid` takes `-U0` hunks (it adds the ±3 itself);
  `model.diff_position` needs the real `-U3` diff.
- Always send a renamed file's new path.

Pending reviews:
- One pending review per user per PR; `reviews(states: PENDING)` returns only the viewer's. While it exists,
  REST `POST pulls/{n}/comments` fails with 422.
- Threads in `addPullRequestReview` anchor at its `commitOID`. `addPullRequestReviewThread` has no commit and
  anchors at head; with `pullRequestReviewId` it joins that pending review (ranges too). Deprecated
  `addPullRequestReviewComment(pullRequestReviewId, commitOID, position)` still works and joins the review:
  `originalCommit` is that commit and GitHub moves `commit` to head right away when trackable. A `position`
  on a `-` line makes a LEFT thread whose line is merge-base-relative.
- A second `addPullRequestReview` while one is pending returns null with `UNPROCESSABLE` "User can only have
  one pending review per pull request", creating nothing.
- Deleting the last comment of a pending review deletes the review: the payload still says `PENDING` with 0
  comments, then the id is `NOT_FOUND`. A review created without threads stays; `deletePullRequestReview`
  removes it. `updatePullRequestReviewComment`/`deletePullRequestReviewComment` work on pending and
  published comments; deleting a thread's only comment removes the thread.
- Editing a pending comment only moves `updatedAt` (`lastEditedAt` stays null, even after submit; submit
  moves `updatedAt` of every comment). Editing a published one sets `lastEditedAt` and
  `includesCreatedEdit`.
- `position` = 1-based index of the line below the file's first `@@` in `merge-base...commitOID`, later `@@`
  headers counting as lines.
- `addPullRequestReview` returns no thread ids, and neither does the legacy `addPullRequestReviewComment`
  (a comment has no `thread` field): the sync finds the thread a legacy comment made in `reviewThreads(last:
  20)` by its first comment's id. `addPullRequestReviewThread` returns its thread.
- Replies with a pending review id become pending replies; resolve/unresolve is immediate. A submitted review
  keeps the `commit` it was created with. You can't approve or request changes on your own PR.

Where comments point:
- Between pushes nothing is remapped: `line == originalLine`, `commit` = the commit written on.
- On the next push (force-pushes too) trackable comments get `commit` = head and a shifted `line`;
  untrackable ones get `isOutdated = true` and `line = null` (published) or an unchanged `line` (a pending
  LEFT comment, measured on #36). Pending comments are remapped like published ones, and a pending review
  whose commit is gone still submits. diffy computes placement and outdatedness itself.
- `diffSide`/`startDiffSide` are thread-level fields; `line`/`originalLine`/`startLine`/
  `originalStartLine`/`commit`/`originalCommit`/`diffHunk` are comment-level. Thread-level `startLine` is
  already tracked to head while `line` isn't: use comment-level lines only.
- An old-side comment's line is always merge-base-relative, whatever its `commit`.
- github.com tracks both range endpoints, in both directions of history; a commit view's old side is the
  commit's parent; lines outside the viewed hunks get a context hunk.
- Bodies round-trip byte-identical (multi-line, fences, emoji).

API: `gh api graphql --input -` with `{query, variables}` on stdin avoids quoting multi-line bodies. An
introspection query may use the same introspection field at most twice.

Avatars: `avatarUrl(size: 64)` works on any `Actor` (bots too); the viewer's comes from `viewer { … }` in the
read query. Uploaded photos are served as JPEG, and kitty's protocol only takes PNG (`f=100`), hence
ImageMagick. The recorded fixtures have no `avatarUrl`, so tests never draw images (no TTY UI anyway).

## Sandbox

Private repo `GuillaumeLagrange/diffy-tests`, rebuilt by `sandbox/build.js` (Bun; about 5 minutes,
force-pushes every sandbox branch). Each PR has base `base/<name>`, head `sandbox/<name>`, and a description
listing every comment id (the first word of its body) and where it must show.

- **#2 Placement**: tracking across commits, force-push, merge, rename, delete, outdated, resolved. **Never
  push to `sandbox/placement`**: it would remap the between-pushes comments.
- **#3 Content**: multi-line bodies, nested fences, suggestions, reply chains, resolved threads, conversation.
- **#4 Pending**: an unsubmitted review with threads on three commits and a pending reply. **Never submit,
  delete or push over it.**
- **`example/*`** (no PR): branches off `main` (a ~80-file project) named `<label>-<N>-commits-<M>-files`, for
  exploring the left panel layout. Open with `:Diffy branch main` or plain `:Diffy branch` (origin/HEAD = main).
  `buildExamples()` rebuilds only these and main's project commit.

**With the GitHub layer on, never open a diffy session on `sandbox/pending` (nor on the branches of #2 and
#3) in the sandbox clone**: the session adopts your pending review and mirrors into it, and drafts already
in the store for that branch are mirrored on open; that would write into PR #4's pending review. Write-side
smoke tests use throwaway PRs (`tests/helpers/github_live.lua`-style branches, closed and deleted
afterwards), or `github = false`.

A local clone is at `~/projects/diffy-tests` for manual runs; never push from it, and use a separate
`git worktree` when several agents smoke-test at once. Write-side experiments go on a throwaway PR.

On github.com: `/pull/N/changes` (full) and `/pull/N/changes/<sha>` (one commit) render lazily; scroll while
collecting `document.body.innerText`. Thread headers read `Comment on line R15` / `… lines R13 to R15`.

## Open questions

- Whether the review's `commitOID` matters on github.com beyond anchoring.
- Bodies written in the web UI (CRLF?).
