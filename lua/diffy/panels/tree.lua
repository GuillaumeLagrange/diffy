-- The file tree panel: the diff between the current selection's
-- (left, right) as a nested directory tree (`<CR>` on a folder collapses it,
-- chains of single-child dirs flattened into one row), with rename pairs,
-- +n/-m counts and the staging keys (`s`/`u`/`-`/`S`/`U`). The working tree
-- alone shows as two sections, Unstaged and Staged, each file row carrying
-- its section's pair.
--
-- `session.tree_all` holds every row; `session.tree_rows` the ones drawn,
-- indexed by the tree's own row (`panels/stack.lua`; rows under a collapsed
-- header are left out).
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local selection = require('diffy.selection')
local hl = require('diffy.highlight')
local viewed = require('diffy.viewed')
local stack = require('diffy.panels.stack')

local M = {}

local ZERO = ('0'):rep(40)

-- before a folder or section header: `▸` collapsed, `▾` expanded
local function chevron(row)
  if not row.foldable then
    return '  '
  end
  return row.collapsed and '▸ ' or '▾ '
end

local function diff_cmd(session, pair, ...)
  local args = { 'diff', '-z', '-M', ... }
  vim.list_extend(args, repo.diff_args(pair.left, pair.right))
  if session.follow_pathspec then
    table.insert(args, '--')
    vim.list_extend(args, session.follow_pathspec)
  end
  return args
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

--- Run `fns` (each `fn(done)`, `done(value, err)`) concurrently; `cb(values)`
--- once all succeeded, else `cb(nil, err)` with the first error.
local function concurrently(fns, cb)
  local values, pending, failed = {}, #fns, false
  for i, fn in ipairs(fns) do
    fn(function(value, err)
      if failed then
        return
      end
      if value == nil then
        failed = true
        cb(nil, err)
        return
      end
      values[i] = value
      pending = pending - 1
      if pending == 0 then
        cb(values)
      end
    end)
  end
end

--- raw + numstat for `pair` (one git call: rename detection runs once), plus
--- untracked files for the unstaged pair (index -> worktree).
local function build_diff_entries(session, pair, gen, cb)
  local args = diff_cmd(session, pair, '--raw', '--numstat', '--no-abbrev')
  run.git(args, { cwd = session.root, session = session, gen = gen, on_exit = run.parsed(parse.diff_files, function(entries, err)
    if not entries then
      cb(nil, err)
      return
    end
    if pair.left == 'INDEX' and pair.right == 'WORKTREE' then
      for _, s in ipairs(session.status_entries or {}) do
        if s.kind == 'untracked' then
          table.insert(entries, { status = '?', path = s.path, left_id = ZERO })
        end
      end
    end
    entries = drop_unmerged_duplicates(entries)
    table.sort(entries, function(a, b)
      return a.path < b.path
    end)
    cb(entries, nil)
  end) })
end

--- Fill the right ids git left at zero (worktree files) for every entry of
--- `lists`, then `cb()`. A deleted file keeps its zero id: `hash-object
--- --stdin-paths` fails the whole batch on a missing path. Symlinks hash
--- their target string (`--stdin-paths` would follow them), submodules
--- take their checked-out commit (`hash-object` refuses them).
local function fill_ids(session, lists, gen, cb)
  local files, by_path, links, subs = {}, {}, {}, {}
  local function want(tbl, path, e)
    if not tbl[path] then
      tbl[path] = {}
      if tbl == by_path then
        table.insert(files, path)
      end
    end
    table.insert(tbl[path], e)
  end
  for _, entries in ipairs(lists) do
    for _, e in ipairs(entries) do
      if e.status ~= 'D' and e.status ~= 'U' and (e.right_id == nil or e.right_id == ZERO) then
        e.right_id = nil
        local st = vim.uv.fs_lstat(session.root .. '/' .. e.path)
        local kind = st and st.type
        if e.right_mode == '120000' or kind == 'link' then
          want(links, e.path, e)
        elseif e.right_mode == '160000' or kind == 'directory' then
          want(subs, e.path, e)
        elseif kind == 'file' and not e.path:find('\n', 1, true) then
          want(by_path, e.path, e)
        end
      end
    end
  end
  local pending = 1
  local function done()
    pending = pending - 1
    if pending == 0 then
      cb()
    end
  end
  local function assign(entries, id)
    for _, e in ipairs(entries) do
      e.right_id = id
    end
  end
  local function call(args, stdin, on_ok)
    pending = pending + 1
    run.git(args, {
      cwd = session.root,
      session = session,
      gen = gen,
      stdin = stdin,
      notify_on_error = false,
      on_exit = function(res)
        if res.code == 0 then
          on_ok(res.stdout or '')
        end
        done()
      end,
    })
  end
  if #files > 0 then
    call({ 'hash-object', '--stdin-paths' }, table.concat(files, '\n') .. '\n', function(out)
      local ids = vim.split(vim.trim(out), '\n', { plain = true })
      for i, path in ipairs(files) do
        assign(by_path[path], ids[i])
      end
    end)
  end
  for path, entries in pairs(links) do
    local target = vim.uv.fs_readlink(session.root .. '/' .. path)
    if target then
      call({ 'hash-object', '--stdin' }, target, function(out)
        assign(entries, vim.trim(out))
      end)
    end
  end
  for path, entries in pairs(subs) do
    call({ '-C', path, 'rev-parse', 'HEAD' }, nil, function(out)
      assign(entries, vim.trim(out))
    end)
  end
  done()
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
--- everything else gets one header row for the accumulated `chain` (empty at
--- the root, so the root itself never gets a header) followed by its
--- children, one depth deeper. `base` is the full path of the nearest
--- enclosing header ('' at root): file rows display their path relative to it.
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
    table.insert(rows, { kind = 'dir', name = chain, path = path, depth = depth })
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

local function tag_rows(rows, first, pair, prefix)
  for i = first, #rows do
    local row = rows[i]
    row.pair = row.kind == 'file' and pair or nil
    if row.kind == 'dir' then
      row.key = prefix .. '/' .. row.path
    end
  end
end

--- Group a flat, path-sorted entry list into display rows, `depth` deep,
--- file rows tagged with `pair` (a section's pair, or nil), header rows with
--- a `key` naming them across renders (`section`'s label prefixed). Viewed
--- files go under a `Viewed (n)` header before the others, away from the log
--- below the tree.
local function group_rows(session, entries, depth, pair, rows, section)
  rows = rows or {}
  depth = depth or 0
  local shown, done = {}, {}
  for _, e in ipairs(entries) do
    table.insert(viewed.is_viewed(session, e) and done or shown, e)
  end
  if #done > 0 then
    local key = (section or '') .. '#viewed'
    table.insert(rows, { kind = 'viewed', label = 'Viewed', count = #done, depth = depth, key = key })
    local first = #rows + 1
    layout(build_tree(done), '', '', '', depth + 1, rows)
    tag_rows(rows, first, pair, key)
    for i = first, #rows do
      rows[i].viewed = true
    end
  end
  local first = #rows + 1
  layout(build_tree(shown), '', '', '', depth, rows)
  tag_rows(rows, first, pair, section or '')
  for i = first, #rows do
    if rows[i].kind == 'file' then
      rows[i].changed = viewed.changed(session, rows[i].entry) or nil
    end
  end
  return rows
end

--- The two sections' rows: a header (`Unstaged (n)`/`Staged (n)`) then its
--- files one level deeper. Both headers stay even when one section is
--- empty; with no changes at all there are no rows.
local function section_rows(session, unstaged, staged)
  local rows = {}
  if #unstaged == 0 and #staged == 0 then
    return rows
  end
  for _, s in ipairs({
    { label = 'Unstaged', pair = selection.UNSTAGED, entries = unstaged },
    { label = 'Staged', pair = selection.STAGED, entries = staged },
  }) do
    table.insert(rows, { kind = 'section', label = s.label, count = #s.entries, pair = s.pair, depth = 0, key = s.label })
    group_rows(session, s.entries, 1, s.pair, rows, s.label)
  end
  return rows
end

--- `session.tree_all` from the last git listing and the current marks.
local function make_rows(session)
  local lists = session.tree_lists
  if lists.split then
    return section_rows(session, lists[1], lists[2])
  end
  return group_rows(session, lists[1])
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
    local head = indent .. chevron(row)
    local avail = width and math.max(1, width - vim.fn.strdisplaywidth(head) - 1)
    local name = avail and hl.truncate_path(row.name, avail) or row.name
    local text = head .. name .. '/'
    return text, { { #indent, #text, row.viewed and 'DiffyViewed' or 'DiffyDirectory' } }, nil, name ~= row.name
  end
  if row.kind == 'section' or row.kind == 'viewed' then
    local full = indent .. chevron(row) .. ('%s (%d)'):format(row.label, row.count)
    local text = width and hl.truncate(full, math.max(1, width)) or full
    local group = row.kind == 'viewed' and 'DiffyViewed' or 'DiffyLabel'
    return text, { { #indent, #text, group } }, nil, text ~= full
  end
  local e = row.entry
  local counts = ''
  if e.added or e.removed then
    counts = ('+%d -%d'):format(e.added or 0, e.removed or 0)
  end
  local dot = row.changed and '● ' or ''
  local head = indent .. e.status .. ' ' .. dot
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
  if row.viewed then
    return text, { { #indent, #text, 'DiffyViewed' } }, { #head, #left }, name ~= full_name
  end
  local spans = { { #indent, #indent + #e.status, hl.STATUS[e.status] or 'DiffyChanged' } }
  if dot ~= '' then
    local at = #indent + #e.status + 1
    table.insert(spans, { at, at + #'●', 'DiffyViewedChanged' })
  end
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

--- The row under the tree cursor and its row number (nil off the tree's rows).
local function cursor_row(session)
  local lnum = stack.cursor(session, 'tree')
  if not lnum then
    return nil
  end
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

--- Paths of every file row of the section `header`, collapsed folders included.
local function section_paths(session, header)
  local paths, inside = {}, false
  for _, row in ipairs(session.tree_all) do
    if row.kind == 'section' then
      if inside then
        break
      end
      inside = row == header
    elseif inside and row.kind == 'file' then
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
    paths = section_paths(session, row)
    session.tree_keep = { section = row.pair, lnum = lnum }
  end
  -- `git add` fails on a path with nothing to stage and missing from the
  -- worktree (a staged deletion or rename source). A conflicted path is
  -- left alone: adding it skips the marker check of `s` on its row,
  -- resetting it drops its conflict stages.
  local ok, conflicted = {}, {}
  for _, r in ipairs(session.tree_all) do
    if r.kind == 'file' then
      for _, p in ipairs(row_paths(r)) do
        if r.entry.status == 'U' then
          conflicted[p] = true
        elseif verb ~= 'add' or r.pair == selection.UNSTAGED then
          ok[p] = true
        end
      end
    end
  end
  paths = vim.tbl_filter(function(p)
    return ok[p] and not conflicted[p]
  end, paths or {})
  if #paths == 0 then
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

local function is_current(session, row)
  return row.kind == 'file'
    and row.entry.path == session.current_path
    and (not row.pair or row.pair == session.file_pair)
end

--- A Viewed group unfolds while it holds the file shown and folds back once
--- that file leaves it, unless the user unfolded it (`'user'`). `false`: the
--- user folded it over the shown file. Returns whether any fold changed.
local function sync_viewed_folds(session)
  local all, changed = session.tree_all or {}, false
  session.viewed_open = session.viewed_open or {}
  local open = session.viewed_open
  for i, row in ipairs(all) do
    if row.kind == 'viewed' then
      local holds = false
      for j = i + 1, #all do
        if all[j].depth <= row.depth then
          break
        end
        holds = holds or is_current(session, all[j])
      end
      local state = open[row.key]
      if holds and state == nil then
        open[row.key], changed = 'auto', true
      elseif not holds and (state == 'auto' or state == false) then
        open[row.key], changed = nil, true
      end
    end
  end
  return changed
end

-- `:Diffy branch` sessions reopen the file last shown on their branch. Best effort: any failure
-- leaves the default pick.
local function last_file_store(session)
  if session.range and session.range.kind == 'branch' and session.gitdir and session.branch then
    return require('diffy.review.store').path(session.gitdir, session.branch, 'last_file.json')
  end
end

local function remember_file(session, path)
  local file = last_file_store(session)
  if file and session.last_file ~= path then
    session.last_file = path
    pcall(require('diffy.review.store').save, file, { path = path })
  end
end

--- Before the first render of a branch session: offer the file last shown on the branch, opened if
--- the selection still has it unviewed.
function M.restore_last_file(session)
  local file = last_file_store(session)
  if not file then
    return
  end
  local ok, data = pcall(require('diffy.review.store').load, file)
  if ok and type(data) == 'table' and type(data.path) == 'string' then
    session.restore_path = data.path
    session.last_file = data.path
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
    remember_file(session, e.path)
    session.file_pair = row.pair or session.pair
    M.mark_current(session)
    -- the conflict layout is built from both diff windows
    require('diffy.diffpair').restore(session)
    require('diffy.conflict').enter(session, e.path, opts)
    return
  end
  -- also drops a conflict view still being built for another row
  require('diffy.conflict').leave(session)
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
  remember_file(session, e.path)
  -- the pair of the file shown, which is not `session.pair` in a section
  session.file_pair = pair
  viewed.saw(session, e)
  if sync_viewed_folds(session) then
    M.redraw(session)
  else
    M.mark_current(session)
  end
  diffpair.show(session, left_spec, right_spec)
end

local function set_tree_cursor(session, lnum)
  stack.set_cursor(session, 'tree', lnum)
end

--- Whether `path` is one of the files of the current selection.
function M.has_path(session, path)
  for _, row in ipairs(session.tree_all or {}) do
    if row.kind == 'file' and row.entry.path == path then
      return true
    end
  end
  return false
end

--- Expand every collapsed folder or section holding `tree_all[index]`.
--- Returns whether one was collapsed.
local function reveal(session, index)
  local all, collapsed = session.tree_all, session.tree_collapsed or {}
  local depth, changed = all[index].depth, false
  for i = index - 1, 1, -1 do
    if depth == 0 then
      break
    end
    if all[i].depth < depth then
      depth = all[i].depth
      if all[i].kind == 'viewed' then
        session.viewed_open = session.viewed_open or {}
        if not session.viewed_open[all[i].key] then
          session.viewed_open[all[i].key], changed = 'auto', true
        end
      elseif collapsed[all[i].key] then
        collapsed[all[i].key], changed = nil, true
      end
    end
  end
  return changed
end

--- Locate the tree row for `path` and open its diff pair, updating the
--- tracked current-file line and cursor position, expanding the folders
--- hiding it. In the working tree's sections a path can have two rows:
--- `accept(pair)`, if given, picks one; otherwise the section shown last
--- wins (a jump back with `<C-t>` returns to the pair it left), then the first.
--- Returns `true` if a row was opened, `false` otherwise.
function M.open_path(session, path, accept)
  local first
  for i, row in ipairs(session.tree_all or {}) do
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
  local row = session.tree_all[first]
  if reveal(session, first) then
    M.redraw(session)
  end
  session.current_file_line = row.lnum
  set_tree_cursor(session, row.lnum)
  M.open_row(session, row)
  return true
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
      local line = stack.lnum(session, 'tree', i) - 1
      vim.api.nvim_buf_set_extmark(buf, ns, line, 0, { line_hl_group = 'DiffyCurrentFile' })
      vim.api.nvim_buf_set_extmark(buf, ns, line, row.name_col[1], {
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
    lnum = stack.cursor(session, 'tree')
    row = lnum and (session.tree_rows or {})[lnum]
  end
  local full = row and row.full
  local pos = full and vim.fn.screenpos(win, stack.lnum(session, 'tree', lnum), 1)
  if not (pos and pos.row > 0) then
    session_mod.close_overlay(session, 'tree_hover')
    return
  end
  local cfg = {
    relative = 'editor',
    row = pos.row - 1,
    col = pos.col - 1,
    width = math.max(1, math.min(vim.fn.strdisplaywidth(full.text), vim.o.columns - pos.col + 1)),
    height = 1,
    style = 'minimal',
    -- the user's 'winborder' would frame it a cell off the row it covers
    border = 'none',
    focusable = false,
    zindex = 60,
  }
  -- it covers the cursor row
  local hbuf = session_mod.overlay(session, 'tree_hover', cfg, { full.text }, 'NormalFloat:CursorLine')
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

--- `session.tree_rows`: the rows of `tree_all` not under a collapsed
--- header, each given its buffer line (`lnum`, nil when hidden). A header
--- with nothing under it (an empty section) isn't foldable.
local function visible_rows(session)
  local all, collapsed = session.tree_all, session.tree_collapsed or {}
  local rows, hide_below = {}, nil
  for i, row in ipairs(all) do
    if hide_below and row.depth > hide_below then
      row.lnum = nil
    else
      table.insert(rows, row)
      row.lnum = #rows
      local folded
      if row.kind == 'viewed' then
        folded = not (session.viewed_open or {})[row.key]
      else
        folded = row.key and collapsed[row.key]
      end
      row.foldable = row.key and all[i + 1] and all[i + 1].depth > row.depth or nil
      row.collapsed = folded and row.foldable or nil
      hide_below = row.collapsed and row.depth or nil
    end
  end
  session.tree_rows = rows
end

--- Re-render the current rows fitted to the tree window's width (no git).
function M.redraw(session)
  visible_rows(session)
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
  stack.set_lines(session, 'tree', lines)
  local ns = require('diffy.session').namespace(session, 'tree_render')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local off = stack.offset(session, 'tree')
  for i, spans in ipairs(all_spans) do
    for _, sp in ipairs(spans) do
      if sp[2] > sp[1] then
        vim.api.nvim_buf_set_extmark(buf, ns, off + i - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
      end
    end
  end
  M.mark_current(session)
  hover(session)
end

--- Collapse or expand the header `row`, keeping the cursor on it.
local function toggle_collapsed(session, row)
  if row.kind == 'viewed' then
    session.viewed_open = session.viewed_open or {}
    session.viewed_open[row.key] = row.collapsed and 'user' or false
  else
    session.tree_collapsed = session.tree_collapsed or {}
    session.tree_collapsed[row.key] = not session.tree_collapsed[row.key] or nil
  end
  M.redraw(session)
  set_tree_cursor(session, row.lnum)
end

--- The entry lists for the current selection, ids filled (`session.tree_lists`):
--- Unstaged and Staged for the working tree alone, one list otherwise.
--- `cb(lists | nil, err)`.
local function build_lists(session, gen, cb)
  local split = session.pair.split
  local sides = split and { selection.UNSTAGED, selection.STAGED } or { session.pair }
  local fns = {}
  for i, pair in ipairs(sides) do
    fns[i] = function(done)
      build_diff_entries(session, pair, gen, done)
    end
  end
  concurrently(fns, function(lists, err)
    if not lists then
      cb(nil, err)
      return
    end
    lists.split = split
    fill_ids(session, lists, gen, function()
      cb(lists)
    end)
  end)
end

--- Rebuild the rows after the marks changed (no git), keeping the cursor line.
function M.refresh_viewed(session)
  if not (session.tree_lists and session.bufs.tree and vim.api.nvim_buf_is_valid(session.bufs.tree)) then
    return
  end
  session.tree_all = make_rows(session)
  sync_viewed_folds(session)
  M.redraw(session)
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
  viewed.attach(session)
  build_lists(session, gen, function(lists, err)
    if not lists then
      vim.notify('diffy: ' .. tostring(err), vim.log.levels.ERROR)
      if cb then
        cb()
      end
      return
    end
    session.tree_lists = lists
    local rows = make_rows(session)
    session.tree_all = rows
    M.redraw(session)
    restore_cursor(session)

    -- the file shown before, viewed or collapsed or not, else the unviewed file last shown on the
    -- branch, else the first unviewed one in sight, else the first one
    local target, same_path, restored, first, first_shown, first_unviewed, first_unviewed_shown
    for _, row in ipairs(rows) do
      if row.kind == 'file' then
        first = first or row
        first_shown = first_shown or (row.lnum and row)
        if not row.viewed then
          first_unviewed = first_unviewed or row
          first_unviewed_shown = first_unviewed_shown or (row.lnum and row)
          if row.entry.path == session.restore_path then
            restored = restored or row
          end
        end
        if row.entry.path == session.current_path then
          same_path = same_path or row
          if not row.pair or row.pair == session.file_pair then
            target = row
            break
          end
        end
      end
    end
    session.restore_path = nil
    target = target or same_path or restored or first_unviewed_shown or first_unviewed or first_shown or first

    if target then
      session.current_file_line = target.lnum
      M.open_row(session, target)
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
--- the conflict view); `o` keeps the cursor in the tree. On a folder or
--- section header, both collapse/expand it instead.
function M.select_at_cursor(session, opts)
  local header = cursor_row(session)
  if header and header.key then
    toggle_collapsed(session, header)
    return
  end
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

local function say_none_left()
  vim.notify('diffy: no unviewed file left', vim.log.levels.INFO)
end

--- `]f`/`[f` (also from the diff windows): move `delta` file entries
--- (a count, signed), stopping at the first/last one, and open it. Files in
--- collapsed folders and viewed files are skipped.
function M.move_file(session, delta)
  local files, pos, any_viewed = {}, nil, false
  for _, row in ipairs(session.tree_all or {}) do
    if row.kind == 'file' then
      local skip = not row.lnum or row.viewed
      any_viewed = any_viewed or row.viewed
      if is_current(session, row) then
        -- a skipped current file sits between its shown neighbours
        pos = skip and #files + 0.5 or #files + 1
      end
      if not skip then
        table.insert(files, row)
      end
    end
  end
  if any_viewed and (#files == 0 or (#files == 1 and pos == 1)) then
    say_none_left()
    return
  end
  if #files == 0 then
    return
  end
  local from = pos and (delta > 0 and math.floor(pos) or math.ceil(pos)) or (delta > 0 and 0 or #files + 1)
  local next_pos = math.max(1, math.min(#files, from + delta))
  if next_pos == pos then
    return
  end
  local row = files[next_pos]
  session.current_file_line = row.lnum
  set_tree_cursor(session, row.lnum)
  M.open_row(session, row)
  run.ready({ session = session.id, event = 'open_row' })
end

--- Open `tree_all[index]`, expanding what hides it.
local function go_to_row(session, index)
  if reveal(session, index) then
    M.redraw(session)
  end
  local row = session.tree_all[index]
  session.current_file_line = row.lnum
  set_tree_cursor(session, row.lnum)
  M.open_row(session, row)
end

--- Mark `rows` (file rows) viewed, or unmark them when `on` is false. When
--- the file shown gets marked, the next unviewed file opens (else the
--- previous one); with none left the pair stays and says so. The change is
--- pushed on `session.viewed_undo` for `undo_viewed`.
local function set_viewed(session, rows, on)
  local entries = {}
  for _, row in ipairs(rows) do
    if viewed.markable(row.entry) then
      table.insert(entries, row.entry)
    end
  end
  if #entries == 0 then
    vim.notify('diffy: nothing to mark viewed here', vim.log.levels.WARN)
    run.ready({ session = session.id, event = 'viewed' })
    return
  end
  local before, cur = {}, nil
  for _, row in ipairs(session.tree_all) do
    if row.kind == 'file' then
      table.insert(before, row)
      if is_current(session, row) then
        cur = #before
      end
    end
  end
  local shown_marked = on and cur and vim.tbl_contains(entries, before[cur].entry)
  local changed = vim.tbl_filter(function(e)
    return viewed.is_viewed(session, e) ~= on
  end, entries)
  if session.viewed_file and #changed > 0 then
    session.viewed_undo = session.viewed_undo or {}
    table.insert(session.viewed_undo, { entries = changed, on = on, shown = shown_marked and before[cur].entry })
  end
  viewed.set(session, entries, on)
  if shown_marked then
    local index = {}
    for i, row in ipairs(session.tree_all) do
      if row.kind == 'file' then
        index[row.entry] = i
      end
    end
    local target
    local order = {}
    for i = cur + 1, #before do
      table.insert(order, before[i])
    end
    for i = cur - 1, 1, -1 do
      table.insert(order, before[i])
    end
    for _, old in ipairs(order) do
      local i = index[old.entry]
      if i and not session.tree_all[i].viewed then
        target = i
        break
      end
    end
    if target then
      go_to_row(session, target)
    else
      say_none_left()
    end
  end
  run.ready({ session = session.id, event = 'viewed' })
end

--- `<leader>du`: revert the last viewed change of the session (marking or
--- unmarking, the file or every file under a header) and reopen the file
--- shown when it was marked.
function M.undo_viewed(session)
  local last = table.remove(session.viewed_undo or {})
  if not last then
    vim.notify('diffy: no viewed change to undo', vim.log.levels.INFO)
    run.ready({ session = session.id, event = 'viewed' })
    return
  end
  viewed.set(session, last.entries, not last.on)
  local shown = last.shown
  if shown then
    for i, row in ipairs(session.tree_all or {}) do
      local e = row.entry
      if
        row.kind == 'file'
        and e.path == shown.path
        and e.left_id == shown.left_id
        and e.right_id == shown.right_id
      then
        go_to_row(session, i)
        break
      end
    end
  end
  run.ready({ session = session.id, event = 'viewed' })
end

--- The file rows under header `row` (a folder, section or Viewed group).
local function rows_under(session, header)
  local out, inside = {}, false
  for _, row in ipairs(session.tree_all) do
    if row == header then
      inside = true
    elseif inside then
      if row.depth <= header.depth then
        break
      end
      if row.kind == 'file' then
        table.insert(out, row)
      end
    end
  end
  return out
end

--- `m` in the tree: toggle the file at the cursor; on a header, mark every
--- file under it, or unmark them all when they all are viewed already.
function M.toggle_viewed_at_cursor(session)
  local row = cursor_row(session)
  if not row then
    return
  end
  if row.kind == 'file' then
    set_viewed(session, { row }, not row.viewed)
    return
  end
  local rows = rows_under(session, row)
  local all = #rows > 0
  for _, r in ipairs(rows) do
    all = all and r.viewed
  end
  set_viewed(session, rows, not all)
end

local function current_row(session)
  for _, row in ipairs(session.tree_all or {}) do
    if is_current(session, row) then
      return row
    end
  end
  vim.notify('diffy: no file shown', vim.log.levels.WARN)
  return nil
end

--- `<leader>dm` / `:Diffy viewed`: toggle the file shown.
function M.toggle_viewed_current(session)
  local row = current_row(session)
  if row then
    set_viewed(session, { row }, not row.viewed)
  end
end

--- `:Diffy viewed clear`: drop the shown file's marks and seen pair.
function M.clear_viewed_current(session)
  local row = current_row(session)
  if row then
    viewed.clear(session, row.entry)
    run.ready({ session = session.id, event = 'viewed' })
  end
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
  local function map(s, modes, lhs, rhs, opts)
    stack.map(s, 'tree', modes, lhs, rhs, opts)
  end
  local buf = session.bufs.tree
  map(session, 'n', '<CR>', function()
    M.select_at_cursor(session, { focus = true })
  end, { buffer = buf, desc = 'open pair and focus it, or collapse the folder' })
  map(session, 'n', 'o', function()
    M.select_at_cursor(session)
  end, { buffer = buf, desc = 'open pair, or collapse the folder' })
  map(session, 'n', ']f', function()
    M.move_file(session, vim.v.count1)
  end, { buffer = buf, desc = 'next file' })
  map(session, 'n', '[f', function()
    M.move_file(session, -vim.v.count1)
  end, { buffer = buf, desc = 'previous file' })
  map(session, 'n', ']r', function()
    require('diffy.panels.log').move_selection(session, vim.v.count1)
  end, { buffer = buf, desc = 'next commit' })
  map(session, 'n', '[r', function()
    require('diffy.panels.log').move_selection(session, -vim.v.count1)
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
  local mark_key = require('diffy').config.keymaps.tree_toggle_viewed
  if mark_key and mark_key ~= '' then
    map(session, 'n', mark_key, function()
      M.toggle_viewed_at_cursor(session)
    end, { buffer = buf, desc = 'toggle viewed' })
  end
  local undo_key = require('diffy').config.keymaps.undo_viewed
  if undo_key and undo_key ~= '' then
    map(session, 'n', undo_key, function()
      M.undo_viewed(session)
    end, { buffer = buf, desc = 'undo viewed' })
  end
  require('diffy.layout').map_panel_keys(session, buf)
  require('diffy.review.ui').map_last(session, buf)
  require('diffy.review.ui').map_threads(session, buf)
  require('diffy.review.ui').map_open_pr(session, buf)
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      local win = session.wins.tree
      if session.tree_all and win and vim.api.nvim_win_is_valid(win) and tree_width(session) ~= session.tree_width then
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
    if session.tree_all then
      M.redraw(session)
    end
  end,
  -- in the shared column window (panels/stack.lua)
  peek = {
    noun = 'file',
    counts = function(session, rel)
      local row = (session.tree_rows or {})[rel]
      return row ~= nil and row.kind == 'file'
    end,
  },
  --- `[[`: the file shown, else the first file
  anchor = function(session)
    local first
    for i, row in ipairs(session.tree_rows or {}) do
      if is_current(session, row) then
        return i
      end
      first = first or (row.kind == 'file' and i)
    end
    return first or 1
  end,
}

return M
