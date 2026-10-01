-- The file tree panel: the diff between the current selection's
-- (left, right) as a nested directory tree (collapsible on
-- `za`, chains of single-child dirs flattened into one row), with rename
-- pairs, +n/-m counts and the staging keys (`s`/`u`/`-`/`S`/`U`). The
-- working tree alone shows as two sections, Unstaged and Staged, each file
-- row carrying its section's pair.
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local selection = require('diffy.selection')
local hl = require('diffy.highlight')

local M = {}

local function diff_cmd(session, pair, format_flag)
  local args = { 'diff', '-z', '-M', format_flag }
  vim.list_extend(args, repo.diff_args(pair.left, pair.right))
  if session.follow_pathspec then
    table.insert(args, '--')
    vim.list_extend(args, session.follow_pathspec)
  end
  return args
end

--- name-status entries annotated with their numstat +/- counts.
local function merge_counts(ns_list, numstat)
  local by_path = {}
  for _, e in ipairs(numstat) do
    by_path[e.path] = e
  end
  local entries = {}
  for _, e in ipairs(ns_list) do
    local n = by_path[e.path]
    table.insert(entries, {
      status = e.status,
      path = e.path,
      old_path = e.old_path,
      added = n and n.added or nil,
      removed = n and n.removed or nil,
    })
  end
  return entries
end

-- An unmerged path's plain `git diff` (worktree vs index) reports it twice
-- ('U', then a spurious 'M' from git's own auto-merge attempt): keep only
-- the conflict status.
local function drop_unmerged_duplicates(entries)
  local unmerged_paths = {}
  for _, e in ipairs(entries) do
    if e.status == 'U' then
      unmerged_paths[e.path] = true
    end
  end
  if not next(unmerged_paths) then
    return entries
  end
  local deduped = {}
  for _, e in ipairs(entries) do
    if e.status == 'U' or not unmerged_paths[e.path] then
      table.insert(deduped, e)
    end
  end
  return deduped
end

--- name-status + numstat for `pair`, merged by path, plus untracked files
--- for the unstaged pair (index -> worktree).
local function build_diff_entries(session, pair, gen, cb)
  local ns_args = diff_cmd(session, pair, '--name-status')
  local num_args = diff_cmd(session, pair, '--numstat')

  run.git(ns_args, {
    cwd = session.root,
    session = session,
    gen = gen,
    on_exit = run.parsed(parse.name_status, function(ns_list, err)
      if not ns_list then
        cb(nil, err)
        return
      end
      run.git(num_args, {
        cwd = session.root,
        session = session,
        gen = gen,
        on_exit = run.parsed(parse.numstat, function(numstat, num_err)
          if not numstat then
            cb(nil, num_err)
            return
          end
          local entries = merge_counts(ns_list, numstat)
          if pair.left == 'INDEX' and pair.right == 'WORKTREE' then
            for _, s in ipairs(session.status_entries or {}) do
              if s.kind == 'untracked' then
                table.insert(entries, { status = '?', path = s.path })
              end
            end
          end
          entries = drop_unmerged_duplicates(entries)
          table.sort(entries, function(a, b)
            return a.path < b.path
          end)
          cb(entries, nil)
        end),
      })
    end),
  })
end

local function basename(path)
  return path:match('([^/]+)$') or path
end

--- Build a nested directory tree from a flat, path-sorted entry list:
--- `dirs`/`dir_order` hold immediate child directories, `files` the
--- entries whose parent directory is this node.
local function build_tree(entries)
  local root = { dirs = {}, dir_order = {}, files = {} }
  for _, e in ipairs(entries) do
    local node = root
    for seg in e.path:gmatch('([^/]+)/') do
      if not node.dirs[seg] then
        node.dirs[seg] = { dirs = {}, dir_order = {}, files = {} }
        table.insert(node.dir_order, seg)
      end
      node = node.dirs[seg]
    end
    table.insert(node.files, e)
  end
  return root
end

--- `node`'s direct children (files and subdirectories), ordered by name.
local function node_items(node)
  local items = {}
  for _, e in ipairs(node.files) do
    table.insert(items, { key = basename(e.path), kind = 'file', entry = e })
  end
  for _, name in ipairs(node.dir_order) do
    table.insert(items, { key = name, kind = 'dir', name = name, node = node.dirs[name] })
  end
  table.sort(items, function(a, b)
    return a.key < b.key
  end)
  return items
end

local function join(a, b)
  return a == '' and b or (a .. '/' .. b)
end

--- Lay `node` (full path `path`) out into display rows: a directory whose
--- only content is one subdirectory is merged into `chain` (no row of its
--- own); a directory whose only content is one file is skipped entirely (the
--- file is shown directly, with its path relative to the enclosing header);
--- everything else gets one collapsible header row for the accumulated
--- `chain` (empty at the root, so the root itself never gets a header)
--- followed by its children, one depth deeper - `foldmethod=indent` then
--- folds exactly that header's children on `za`, at every nesting level.
--- `base` is the full path of the nearest enclosing header ('' at root):
--- file rows display their path relative to it.
local function layout(node, path, chain, base, depth, rows)
  local items = node_items(node)
  if #items == 0 then
    return
  end
  if #items == 1 and items[1].kind == 'dir' then
    local it = items[1]
    layout(it.node, join(path, it.name), join(chain, it.name), base, depth, rows)
    return
  end
  if #items == 1 and items[1].kind == 'file' then
    table.insert(rows, { kind = 'file', entry = items[1].entry, depth = depth, base = base })
    return
  end
  local child_depth, child_base = depth, base
  if chain ~= '' then
    table.insert(rows, { kind = 'dir', name = chain, depth = depth })
    child_depth, child_base = depth + 1, path
  end
  for _, it in ipairs(items) do
    if it.kind == 'file' then
      table.insert(rows, { kind = 'file', entry = it.entry, depth = child_depth, base = child_base })
    else
      layout(it.node, join(path, it.name), it.name, child_base, child_depth, rows)
    end
  end
end

--- Group a flat, path-sorted entry list into display rows, `depth` deep,
--- file rows tagged with `pair` (a section's pair, or nil).
local function group_rows(entries, depth, pair, rows)
  rows = rows or {}
  local first = #rows + 1
  layout(build_tree(entries), '', '', '', depth or 0, rows)
  for i = first, #rows do
    rows[i].pair = rows[i].kind == 'file' and pair or nil
  end
  return rows
end

--- The two sections' rows: a header (`Unstaged (n)`/`Staged (n)`) then its
--- files one level deeper. Both headers stay even when one section is
--- empty; with no changes at all there are no rows.
local function section_rows(unstaged, staged)
  local rows = {}
  if #unstaged == 0 and #staged == 0 then
    return rows
  end
  for _, s in ipairs({
    { label = 'Unstaged', pair = selection.UNSTAGED, entries = unstaged },
    { label = 'Staged', pair = selection.STAGED, entries = staged },
  }) do
    table.insert(rows, { kind = 'section', label = s.label, count = #s.entries, pair = s.pair, depth = 0 })
    group_rows(s.entries, 1, s.pair, rows)
  end
  return rows
end

local function relative(path, base)
  if base ~= '' and path:sub(1, #base + 1) == base .. '/' then
    return path:sub(#base + 2)
  end
  return path
end

local function dirname(path)
  return path:match('^(.*)/[^/]*$') or ''
end

--- One display row fitted to `width` cells (untruncated without one):
--- `text`, highlight spans `{start_col, end_col, group}` (byte columns),
--- for a file the byte range of its name, and whether fitting cut anything.
local function row_line(row, width)
  local indent = ('  '):rep(row.depth)
  if row.kind == 'dir' then
    local name = width and hl.truncate_path(row.name, math.max(1, width - #indent - 1)) or row.name
    local text = indent .. name .. '/'
    return text, { { #indent, #text, 'DiffyDirectory' } }, nil, name ~= row.name
  end
  if row.kind == 'section' then
    local full = ('%s (%d)'):format(row.label, row.count)
    local text = width and hl.truncate(full, width) or full
    return text, { { 0, #text, 'DiffyLabel' } }, nil, text ~= full
  end
  local e = row.entry
  local counts = ''
  if e.added or e.removed then
    counts = ('+%d -%d'):format(e.added or 0, e.removed or 0)
  end
  local head = indent .. e.status .. ' '
  local avail = width and (width - vim.fn.strdisplaywidth(head) - (counts ~= '' and (#counts + 1) or 0)) or math.huge
  local new_rel = relative(e.path, row.base)
  local name = new_rel
  local moved = false
  if (e.status == 'R' or e.status == 'C') and e.old_path then
    if dirname(e.old_path) == dirname(e.path) then
      local dir = relative(dirname(e.path), row.base)
      dir = (dir == '' or dir == row.base) and '' or (dir .. '/')
      name = dir .. basename(e.old_path) .. ' → ' .. basename(e.path)
    else
      name, moved = relative(e.old_path, row.base) .. ' → ' .. new_rel, true
    end
  end
  local full_name = name
  if width then
    -- a move that doesn't fit shows its new path only
    if moved and vim.fn.strdisplaywidth(name) > avail then
      name = new_rel
    end
    name = hl.truncate_path(name, math.max(1, avail))
  end
  local left = head .. name
  local pad = width and math.max(1, width - vim.fn.strdisplaywidth(left) - #counts) or 1
  local text = counts ~= '' and (left .. (' '):rep(pad) .. counts) or left
  local spans = { { #indent, #indent + #e.status, hl.STATUS[e.status] or 'DiffyChanged' } }
  if counts ~= '' then
    local plus_end = #text - #counts + #tostring(e.added or 0) + 1
    table.insert(spans, { #text - #counts, plus_end, 'DiffyAdded' })
    table.insert(spans, { plus_end + 1, #text, 'DiffyRemoved' })
  end
  return text, spans, { #head, #left }, name ~= full_name
end

--- Per-file real-file/dirty context built from `session.status_entries`.
local function clean_ctx(session)
  local dirty = {}
  for _, s in ipairs(session.status_entries or {}) do
    if s.kind ~= 'untracked' and s.kind ~= 'ignored' then
      dirty[s.path] = true
      if s.old_path then
        dirty[s.old_path] = true
      end
    end
  end
  return {
    head_sha = session.head_sha,
    checkout_sha = session.checkout_sha,
    is_clean = function(path)
      return not dirty[path]
    end,
  }
end

--- Staging keys only work on the working tree selected alone.
local function require_split(session)
  if not (session.pair and session.pair.split) then
    vim.notify('diffy: staging needs the Working tree selection alone', vim.log.levels.WARN)
    return false
  end
  return true
end

--- Both paths of a rename/copy row, or the single path of any other row.
local function row_paths(row)
  local e = row.entry
  if e.status == 'R' or e.status == 'C' then
    return { e.old_path, e.path }
  end
  return { e.path }
end

--- The row under the tree cursor and its line number.
local function cursor_row(session)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.tree)[1]
  return (session.tree_rows or {})[lnum], lnum
end

--- The file row under the tree cursor and its line number, or nil.
local function row_at_cursor(session)
  local row, lnum = cursor_row(session)
  if row and row.kind == 'file' then
    return row, lnum
  end
  return nil
end

--- Run `git <args>` and refresh on success (which re-fires `DiffyReady`).
local function git_refresh(session, args)
  run.git(args, {
    cwd = session.root,
    session = session,
    on_exit = function(res)
      if res.code == 0 and session.refresh then
        session.refresh(session)
      end
    end,
  })
end

--- Paths of every file row of the section headed at `lnum`.
local function section_paths(session, lnum)
  local paths = {}
  for i = lnum + 1, #session.tree_rows do
    local row = session.tree_rows[i]
    if row.kind == 'section' then
      break
    end
    if row.kind == 'file' then
      vim.list_extend(paths, row_paths(row))
    end
  end
  return paths
end

--- `git <verb> -- <paths>` for the row at the cursor: its file, or every
--- file of its section on a header. `to` is the section the file lands in,
--- where the cursor follows it after the re-render.
local function stage_at_cursor(session, verb, to)
  local row, lnum = cursor_row(session)
  local paths
  if row and row.kind == 'file' then
    paths = row_paths(row)
    session.tree_keep = { path = row.entry.path, pair = to, lnum = lnum }
  elseif row and row.kind == 'section' then
    paths = section_paths(session, lnum)
    session.tree_keep = { section = row.pair, lnum = lnum }
  end
  if verb == 'add' then
    -- `git add` fails on a path with nothing to stage and missing from the
    -- worktree (a staged deletion or rename source)
    local unstaged = {}
    for _, r in ipairs(session.tree_rows) do
      if r.kind == 'file' and r.pair == selection.UNSTAGED then
        for _, p in ipairs(row_paths(r)) do
          unstaged[p] = true
        end
      end
    end
    paths = vim.tbl_filter(function(p)
      return unstaged[p]
    end, paths or {})
  end
  if not paths or #paths == 0 then
    session.tree_keep = nil
    return
  end
  local args = { verb, '--' }
  vim.list_extend(args, paths)
  git_refresh(session, args)
end

--- `s`: stage the file (or both paths of a rename pair) or section at the
--- cursor, or mark a conflicted ('U') row resolved (warns if markers remain).
function M.stage(session)
  local row = row_at_cursor(session)
  if row and row.entry.status == 'U' then
    require('diffy.conflict').resolve(session, row.entry.path)
    return
  end
  if require_split(session) then
    stage_at_cursor(session, 'add', selection.STAGED)
  end
end

--- `u`: unstage the file (or both paths of a rename pair) or section at the cursor.
function M.unstage(session)
  if require_split(session) then
    stage_at_cursor(session, 'reset', selection.UNSTAGED)
  end
end

--- `-`: stage in the Unstaged section, unstage in the Staged section.
function M.toggle(session)
  if not require_split(session) then
    return
  end
  local row = cursor_row(session)
  if not (row and row.pair) then
    return
  end
  if row.pair == selection.UNSTAGED then
    M.stage(session)
  else
    M.unstage(session)
  end
end

--- `S`: stage every change (tracked and untracked).
function M.stage_all(session)
  if require_split(session) then
    git_refresh(session, { 'add', '-A' })
  end
end

--- `U`: unstage every staged change.
function M.unstage_all(session)
  if require_split(session) then
    git_refresh(session, { 'reset' })
  end
end

--- Open the diff pair for tree row `row` (a `{kind='file', entry=...}`),
--- or the 4-window conflict view for an unmerged ('U') row.
function M.open_row(session, row, opts)
  if not row or row.kind ~= 'file' then
    return
  end
  local e = row.entry
  if e.status == 'U' then
    session.current_path = e.path
    session.file_pair = row.pair or session.pair
    M.mark_current(session)
    -- the conflict layout is built from both diff windows
    require('diffy.diffpair').restore(session)
    require('diffy.conflict').enter(session, e.path, opts)
    return
  end
  if session.conflict_active then
    require('diffy.conflict').leave(session)
  end
  local diffpair = require('diffy.diffpair')
  local pair = row.pair or session.pair

  local left_spec, right_spec
  if e.status ~= 'A' and e.status ~= '?' then
    left_spec = { rev = pair.left, path = e.old_path or e.path }
  end
  if e.status ~= 'D' then
    local right_rev = pair.right
    if not row.pair and selection.right_is_real(session.pair, e.path, clean_ctx(session)) then
      right_rev = 'WORKTREE'
    end
    right_spec = { rev = right_rev, path = e.path }
  end

  session.current_path = e.path
  -- the pair of the file shown, which is not `session.pair` in a section
  session.file_pair = pair
  M.mark_current(session)
  diffpair.show(session, left_spec, right_spec)
end

local function set_tree_cursor(session, lnum)
  if vim.api.nvim_win_is_valid(session.wins.tree) then
    pcall(vim.api.nvim_win_set_cursor, session.wins.tree, { lnum, 0 })
  end
end

--- Whether `path` is one of the files of the current selection.
function M.has_path(session, path)
  for _, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' and row.entry.path == path then
      return true
    end
  end
  return false
end

--- Locate the tree row for `path` and open its diff pair, updating the
--- tracked current-file line and cursor position. In the working tree's
--- sections a path can have two rows: `accept(pair)`, if given, picks one;
--- otherwise the section shown last wins (a jump back with `<C-t>` returns
--- to the pair it left), then the first.
--- Returns `true` if a row was opened, `false` otherwise.
function M.open_path(session, path, accept)
  local first
  for i, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' and row.entry.path == path then
      local pair = row.pair or session.pair
      if accept then
        if accept(pair) then
          first = i
          break
        end
      elseif pair == session.file_pair then
        first = i
        break
      else
        first = first or i
      end
    end
  end
  if not first then
    return false
  end
  session.current_file_line = first
  set_tree_cursor(session, first)
  M.open_row(session, session.tree_rows[first])
  return true
end

local function is_current(session, row)
  return row.kind == 'file'
    and row.entry.path == session.current_path
    and (not row.pair or row.pair == session.file_pair)
end

--- Highlight the row of the file shown in the diff pair.
function M.mark_current(session)
  local buf = session.bufs.tree
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local ns = require('diffy.session').namespace(session, 'tree_current')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, row in ipairs(session.tree_rows or {}) do
    if is_current(session, row) and row.name_col then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = 'DiffyCurrentFile' })
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, row.name_col[1], {
        end_col = row.name_col[2],
        hl_group = 'DiffyCurrentFileName',
      })
      return
    end
  end
end

local function tree_width(session)
  return hl.panel_width(session.wins.tree, session.tree_width)
end

--- The untruncated text of the tree cursor's row when the panel cuts it: a
--- one-line float laid over the row while the tree window is current.
local function hover(session)
  local session_mod = require('diffy.session')
  local win = session.wins.tree
  local row, lnum
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win then
    lnum = vim.api.nvim_win_get_cursor(win)[1]
    row = (session.tree_rows or {})[lnum]
  end
  local full = row and row.full
  local pos = full and vim.fn.screenpos(win, lnum, 1)
  local fwin = session.wins.tree_hover
  if not (pos and pos.row > 0) then
    session_mod.unregister_window(session, 'tree_hover')
    session.bufs.tree_hover = nil
    if fwin and vim.api.nvim_win_is_valid(fwin) then
      pcall(vim.api.nvim_win_close, fwin, true)
    end
    return
  end
  local cfg = {
    relative = 'editor',
    row = pos.row - 1,
    col = pos.col - 1,
    width = math.max(1, math.min(vim.fn.strdisplaywidth(full.text), vim.o.columns - pos.col + 1)),
    height = 1,
    style = 'minimal',
    focusable = false,
    zindex = 60,
  }
  local hbuf = session.bufs.tree_hover
  if not (fwin and vim.api.nvim_win_is_valid(fwin) and hbuf and vim.api.nvim_buf_is_valid(hbuf)) then
    hbuf = session_mod.scratch_buf(session, 'tree_hover')
    session_mod.register_buffer(session, 'tree_hover', hbuf)
    fwin = vim.api.nvim_open_win(hbuf, false, cfg)
    session_mod.register_window(session, 'tree_hover', fwin, { transient = true })
    session_mod.unbind(fwin)
    vim.wo[fwin].diff = false
    vim.wo[fwin].wrap = false
    -- it covers the cursor row
    vim.wo[fwin].winhighlight = 'NormalFloat:CursorLine'
  else
    vim.api.nvim_win_set_config(fwin, cfg)
  end
  vim.bo[hbuf].modifiable = true
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, { full.text })
  vim.bo[hbuf].modifiable = false
  local ns = session_mod.namespace(session, 'tree_hover')
  vim.api.nvim_buf_clear_namespace(hbuf, ns, 0, -1)
  local spans = vim.list_extend({}, full.spans)
  if is_current(session, row) and full.name_col then
    table.insert(spans, { full.name_col[1], full.name_col[2], 'DiffyCurrentFileName' })
  end
  for _, sp in ipairs(spans) do
    if sp[2] > sp[1] then
      vim.api.nvim_buf_set_extmark(hbuf, ns, 0, sp[1], { end_col = sp[2], hl_group = sp[3] })
    end
  end
end

--- Re-render the current rows fitted to the tree window's width (no git).
function M.redraw(session)
  local buf = session.bufs.tree
  local width = tree_width(session)
  session.tree_width = width
  local lines, all_spans = {}, {}
  for i, row in ipairs(session.tree_rows) do
    local text, spans, name_col, cut = row_line(row, width)
    lines[i], all_spans[i], row.name_col = text, spans, name_col
    row.full = nil
    if cut then
      local ftext, fspans, fname_col = row_line(row)
      row.full = { text = ftext, spans = fspans, name_col = fname_col }
    end
  end
  if #lines == 0 then
    lines = { '(no changes)' }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].shiftwidth = 2
  local ns = require('diffy.session').namespace(session, 'tree_render')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, spans in ipairs(all_spans) do
    for _, sp in ipairs(spans) do
      if sp[2] > sp[1] then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
      end
    end
  end
  local win = session.wins.tree
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].foldmethod = 'indent'
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 99
  end
  M.mark_current(session)
  hover(session)
end

local function file_rows(session)
  local out = {}
  for i, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' then
      table.insert(out, i)
    end
  end
  return out
end

--- The rows for the current selection: two sections for the working tree
--- alone, one tree otherwise. `cb(rows | nil, err)`.
local function build_rows(session, gen, cb)
  if not session.pair.split then
    build_diff_entries(session, session.pair, gen, function(entries, err)
      cb(entries and group_rows(entries), err)
    end)
    return
  end
  build_diff_entries(session, selection.UNSTAGED, gen, function(unstaged, err)
    if not unstaged then
      cb(nil, err)
      return
    end
    build_diff_entries(session, selection.STAGED, gen, function(staged, staged_err)
      cb(staged and section_rows(unstaged, staged), staged_err)
    end)
  end)
end

--- Where the cursor goes after a staging key (`session.tree_keep`): the same
--- file in the section it moved to, else anywhere, the same section header,
--- else the nearest row.
local function restore_cursor(session)
  local keep = session.tree_keep
  session.tree_keep = nil
  if not keep then
    return
  end
  local rows = session.tree_rows
  local found, anywhere
  for i, row in ipairs(rows) do
    if keep.path and row.kind == 'file' and row.entry.path == keep.path then
      anywhere = anywhere or i
      if row.pair == keep.pair then
        found = i
        break
      end
    elseif keep.section and row.kind == 'section' and row.pair == keep.section then
      found = i
      break
    end
  end
  set_tree_cursor(session, found or anywhere or math.max(1, math.min(keep.lnum, #rows)))
end

--- (Re)build and render the tree for the current selection, then open the
--- pair for whichever file was showing before (if still present) or the
--- first file, so the diff windows never sit on a stale render. `cb`, if
--- given, runs once rendering (including the diff pair) has finished -
--- callers that signal `DiffyReady` must wait for it, since this is async.
function M.render(session, cb)
  session.gen = (session.gen or 0) + 1
  local gen = session.gen
  build_rows(session, gen, function(rows, err)
    if not rows then
      vim.notify('diffy: ' .. tostring(err), vim.log.levels.ERROR)
      if cb then
        cb()
      end
      return
    end
    session.tree_rows = rows
    M.redraw(session)
    restore_cursor(session)

    local files = file_rows(session)
    local target, same_path
    for _, i in ipairs(files) do
      local row = session.tree_rows[i]
      if row.entry.path == session.current_path then
        same_path = same_path or i
        if not row.pair or row.pair == session.file_pair then
          target = i
          break
        end
      end
    end
    target = target or same_path or files[1]

    if target then
      session.current_file_line = target
      M.open_row(session, session.tree_rows[target])
    else
      require('diffy.diffpair').clear(session)
      session.current_path = nil
      M.mark_current(session)
    end
    if cb then
      cb()
    end
  end)
end

--- `<CR>`/`o`: open the pair for the entry at the cursor. `<CR>` passes
--- `opts.focus` to then move to the right diff window (the result window in
--- the conflict view); `o` keeps the cursor in the tree.
function M.select_at_cursor(session, opts)
  local row, lnum = row_at_cursor(session)
  if not row then
    return
  end
  session.current_file_line = lnum
  M.open_row(session, row, opts)
  -- an added or deleted file shows one side only
  local diff_win = session.wins.right or session.wins.left
  if opts and opts.focus and row.entry.status ~= 'U' and diff_win and vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_set_current_win(diff_win)
  end
  run.ready({ session = session.id, event = 'open_row' })
end

--- `]f`/`[f` (also from the diff windows): move to and open the
--- next/previous file entry.
function M.move_file(session, delta)
  local files = file_rows(session)
  if #files == 0 then
    return
  end
  local pos
  for i, lnum in ipairs(files) do
    if lnum == session.current_file_line then
      pos = i
      break
    end
  end
  local next_pos
  if pos then
    next_pos = pos + delta
  else
    next_pos = delta > 0 and 1 or #files
  end
  if next_pos < 1 or next_pos > #files then
    return
  end
  local lnum = files[next_pos]
  session.current_file_line = lnum
  set_tree_cursor(session, lnum)
  M.open_row(session, session.tree_rows[lnum])
  run.ready({ session = session.id, event = 'open_row' })
end

--- `gf`: open the real worktree file for the entry at the cursor in the
--- tab that was active before the diffy tab was opened.
function M.open_real_file(session)
  local row = row_at_cursor(session)
  if not row then
    return
  end
  if row.entry.status == 'D' then
    vim.notify('diffy: no worktree file for a deleted path', vim.log.levels.WARN)
    return
  end
  local abspath = session.root .. '/' .. row.entry.path
  if session.prev_tab and vim.api.nvim_tabpage_is_valid(session.prev_tab) then
    vim.api.nvim_set_current_tabpage(session.prev_tab)
  else
    vim.cmd('tabnew')
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
end

function M.setup(session)
  local map = require('diffy.session').map
  local buf = session.bufs.tree
  map(session, 'n', '<CR>', function()
    M.select_at_cursor(session, { focus = true })
  end, { buffer = buf, desc = 'open pair and focus it' })
  map(session, 'n', 'o', function()
    M.select_at_cursor(session)
  end, { buffer = buf, desc = 'open pair' })
  map(session, 'n', ']f', function()
    M.move_file(session, 1)
  end, { buffer = buf, desc = 'next file' })
  map(session, 'n', '[f', function()
    M.move_file(session, -1)
  end, { buffer = buf, desc = 'previous file' })
  map(session, 'n', ']r', function()
    require('diffy.panels.log').move_selection(session, 1)
  end, { buffer = buf, desc = 'next commit' })
  map(session, 'n', '[r', function()
    require('diffy.panels.log').move_selection(session, -1)
  end, { buffer = buf, desc = 'previous commit' })
  map(session, 'n', 'gf', function()
    M.open_real_file(session)
  end, { buffer = buf, desc = 'open real file' })
  map(session, 'n', 's', function()
    M.stage(session)
  end, { buffer = buf, desc = 'stage' })
  map(session, 'n', 'u', function()
    M.unstage(session)
  end, { buffer = buf, desc = 'unstage' })
  map(session, 'n', '-', function()
    M.toggle(session)
  end, { buffer = buf, desc = 'toggle stage' })
  map(session, 'n', 'S', function()
    M.stage_all(session)
  end, { buffer = buf, desc = 'stage all' })
  map(session, 'n', 'U', function()
    M.unstage_all(session)
  end, { buffer = buf, desc = 'unstage all' })
  require('diffy.layout').map_panel_keys(session, buf)
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      local win = session.wins.tree
      if session.tree_rows and win and vim.api.nvim_win_is_valid(win) and tree_width(session) ~= session.tree_width then
        M.redraw(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter' }, {
    group = session.augroup,
    buffer = buf,
    callback = function()
      hover(session)
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    group = session.augroup,
    buffer = buf,
    callback = function()
      -- the tree window is still current here
      vim.schedule(function()
        if not session.closed then
          hover(session)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      if session.wins.tree_hover then
        hover(session)
      end
    end,
  })
end

M.view = {
  label = ' Files',
  persistent = true,
  render = function(session)
    if session.tree_rows then
      M.redraw(session)
    end
  end,
}

return M
