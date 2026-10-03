-- The log panel: builds the entry list (the working tree, then commits),
-- renders it, and owns the contiguous-selection keys.
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local selection = require('diffy.selection')
local hl = require('diffy.highlight')

local M = {}

local LOG_PRETTY = '--pretty=format:%H%x1f%P%x1f%s'

local function log_args(expr, limit)
  local args = { 'log', '-z', '--date-order', LOG_PRETTY }
  if limit then
    vim.list_extend(args, { '-n', tostring(limit) })
  end
  if expr then
    table.insert(args, expr)
  end
  return args
end

--- `:Diffy file`: commits touching `path`, tracked across renames.
local function file_log_args(path)
  return { 'log', '-z', '--follow', '--date-order', LOG_PRETTY, '--', path }
end

local function commit_entries(root, args, cb, session)
  run.git(args, {
    cwd = root,
    session = session,
    on_exit = run.parsed(function(stdout)
      local out = {}
      for _, c in ipairs(parse.log(stdout)) do
        table.insert(out, {
          kind = 'commit',
          sha = c.sha,
          parents = c.parents,
          subject = c.subject,
          merge = c.merge,
          rev = c.sha,
        })
      end
      return out
    end, cb),
  })
end

local function worktree_prefix(spec)
  if spec.kind == 'range' or spec.kind == 'file' then
    return {}
  end
  return { { kind = 'worktree', label = 'Working tree', rev = 'WORKTREE' } }
end

local function prefixed(prefix, commits)
  local out = vim.deepcopy(prefix)
  vim.list_extend(out, commits)
  return out
end

--- Branch/PR views: record the merge-base as `entries.base` and flag
--- the commits that contain it (`has_base`), i.e. those after a merge of
--- the base branch, so a selection down to the oldest commit diffs against
--- the merge-base like github.com instead of showing merged-in base changes.
local function with_base(root, mb, entries, cb, session)
  run.git({ 'rev-list', '--ancestry-path', mb .. '..HEAD' }, {
    cwd = root,
    session = session,
    on_exit = function(res)
      local contains = {}
      for sha in (res.stdout or ''):gmatch('%x+') do
        contains[sha] = true
      end
      for _, e in ipairs(entries) do
        if e.kind == 'commit' then
          e.has_base = contains[e.sha] or false
        end
      end
      entries.base = mb
      cb(entries, nil)
    end,
  })
end

--- Commits since the merge-base of `base` and HEAD, after `prefix`.
local function merge_base_entries(root, base, prefix, cb, session)
  repo.merge_base(root, base, 'HEAD', function(mb, err)
    if not mb then
      cb(nil, err)
      return
    end
    commit_entries(root, log_args(mb .. '..HEAD'), function(commits, err2)
      if not commits then
        cb(nil, err2)
        return
      end
      with_base(root, mb, prefixed(prefix, commits), cb, session)
    end, session)
  end, session)
end

--- Every name `path` has ever had (renames), sorted, so the tree's diff
--- calls can be pathspec-restricted to just this file while still letting
--- git detect a rename across adjacent commits.
local function follow_pathspec(root, path, cb, session)
  run.git({ 'log', '--follow', '-z', '--name-status', '--pretty=format:%H', '--', path }, {
    cwd = root,
    session = session,
    on_exit = function(res)
      local names = { [path] = true }
      if res.code == 0 then
        for _, rec in ipairs(parse.log_name_status(res.stdout or '')) do
          if rec.path then
            names[rec.path] = true
          end
          if rec.old_path then
            names[rec.old_path] = true
          end
        end
      end
      local pathspec = {}
      for name in pairs(names) do
        table.insert(pathspec, name)
      end
      table.sort(pathspec)
      cb(pathspec)
    end,
  })
end

--- Build the log entry list for range spec `spec` (`{kind='default'}`,
--- `{kind='branch', base=ref_or_nil}`, or `{kind='range', expr='A..B'}`).
--- `cb(entries, err)`. `session`, if given, is threaded to every git/gh call
--- so the whole chain no-ops once that session is torn down.
function M.build_entries(root, spec, cb, session)
  local prefix = worktree_prefix(spec)
  if spec.kind == 'range' then
    commit_entries(root, log_args(spec.expr), cb, session)
  elseif spec.kind == 'branch' then
    repo.resolve_base(root, spec.base, function(base, err)
      if not base then
        cb(nil, err)
        return
      end
      merge_base_entries(root, base, prefix, cb, session)
    end, session, spec.pr_base)
  elseif spec.kind == 'file' then
    commit_entries(root, file_log_args(spec.path), function(commits, err)
      if not commits then
        cb(nil, err)
        return
      end
      follow_pathspec(root, spec.path, function(pathspec)
        commits.follow_pathspec = pathspec
        cb(commits, nil)
      end, session)
    end, session)
  else
    repo.default_range(root, function(range_spec)
      commit_entries(root, log_args(range_spec.expr, range_spec.n), function(commits, err)
        if not commits then
          cb(nil, err)
          return
        end
        cb(prefixed(prefix, commits), nil)
      end, session)
    end, session)
  end
end

--- Default selection for `spec` over `entries`: the working tree
--- alone for `:Diffy`, everything (working tree included) for
--- `:Diffy branch` and an explicit range.
function M.default_selection(entries, spec)
  local top = selection.first_selectable(entries)
  if spec.kind == 'default' or spec.kind == 'file' then
    return top and { top = top, bottom = top } or nil
  end
  if not top then
    -- only merges: all of them, rather than nothing
    return #entries > 0 and { top = 1, bottom = #entries } or nil
  end
  return { top = top, bottom = selection.last_selectable(entries) }
end

local function short(sha)
  return sha:sub(1, 7)
end

local MARK = '▌'

-- the PR row's `M.sync_status` (github.lua), as an icon after the status
local SYNC_ICON = {
  syncing = { '↻', 'DiffySyncState' },
  offline = { '⊘', 'DiffySyncState' },
  ['sync failed'] = { '⚠', 'DiffySyncFailed' },
}

-- the PR row while the layer's first read loads (`entry.loading`)
local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

--- One log row fitted to `width` cells: `text` plus highlight spans.
local function entry_line(entry, selected, width)
  local head = (selected and MARK or ' ') .. ' '
  if entry.kind == 'pr' then
    -- the title gives way: the status after it matters more
    local icon = entry.loading and { SPINNER[entry.loading.frame % #SPINNER + 1], 'DiffySyncState' }
      or entry.sync and SYNC_ICON[entry.sync]
    local status = entry.status .. (icon and (' ' .. icon[1]) or '')
    local title = hl.truncate(entry.title, math.max(1, width - 2 - #entry.number - 1 - vim.fn.strdisplaywidth(status)))
    local text = '  ' .. entry.number .. ' ' .. title .. status
    local label_end = icon and #text - #icon[1] or #text
    local spans = { { 2, 2 + #entry.number, 'DiffySha' }, { 3 + #entry.number, label_end, 'DiffyLabel' } }
    if icon then
      table.insert(spans, { label_end, #text, icon[2] })
    end
    return text, spans
  elseif entry.kind == 'marker' then
    local text = '  ' .. hl.truncate(entry.label, width - 2)
    return text, { { 2, #text, 'DiffyThreadTime' } }
  elseif entry.kind ~= 'commit' then
    local text = head .. hl.truncate(entry.label, width - 2)
    return text, { { #head, #text, 'DiffyLabel' } }
  end
  local sha = short(entry.sha)
  local text = head .. sha .. ' ' .. hl.truncate(entry.subject, width - 2 - #sha - 1)
  if entry.merge then
    return text, {}
  end
  return text, { { #head, #head + #sha, 'DiffySha' } }
end

local function log_width(session)
  return hl.panel_width(session.wins.log, session.log_width)
end

local function is_merge(entry)
  return entry.kind == 'commit' and entry.merge
end

local skipped = function(entry)
  return not selection.selectable(entry)
end

local STATE_ICON = { APPROVED = '✓', CHANGES_REQUESTED = '✗', COMMENTED = '○', DISMISSED = '–' }
M.STATE_ICON = STATE_ICON
local STATE_ORDER = { 'CHANGES_REQUESTED', 'APPROVED', 'COMMENTED', 'DISMISSED' }

--- `entries` (the log as git lists it) with the GitHub layer's rows: when
--- it's attached, the PR row first, one row above each commit submitted
--- reviews were written on, summing them up; while its PR loads, a PR row
--- with a spinner.
function M.with_layer(session, entries)
  local l = session.layer
  if not (l and l.attached) then
    if not (l and l.loading) then
      return entries
    end
    local out = { base = entries.base, follow_pathspec = entries.follow_pathspec }
    local pr = l.loading
    table.insert(out, { kind = 'pr', loading = pr, number = '#' .. pr.number, title = pr.title or '', status = '' })
    vim.list_extend(out, entries)
    return out
  end
  local pr = l.cache.pr
  local out = { base = entries.base, follow_pathspec = entries.follow_pathspec }
  local status = {}
  local conflicts = 0
  for _, t in ipairs(type(session.review) == 'table' and session.review.threads or {}) do
    conflicts = conflicts + require('diffy.review.model').conflicts(t)
  end
  if conflicts > 0 then
    table.insert(status, (' · %d conflict%s'):format(conflicts, conflicts == 1 and '' or 's'))
  end
  if l.standing then
    table.insert(status, ' · ' .. l.standing)
  end
  table.insert(out, { kind = 'pr', number = '#' .. pr.number, title = pr.title or '', status = table.concat(status) })
  local per_review = {}
  for _, n in ipairs(l.cache.nodes or {}) do
    local first = n.comments.nodes[1]
    local id = first and first.pullRequestReview and first.pullRequestReview.id
    if id then
      per_review[id] = (per_review[id] or 0) + 1
    end
  end
  local by_commit = {}
  for _, rv in ipairs(pr.reviews or {}) do
    if rv.commit and rv.state ~= 'PENDING' then
      by_commit[rv.commit] = by_commit[rv.commit] or {}
      table.insert(by_commit[rv.commit], rv)
    end
  end
  for _, e in ipairs(entries) do
    local rvs = e.kind == 'commit' and by_commit[e.sha]
    if rvs then
      local n, present = 0, {}
      for _, rv in ipairs(rvs) do
        n = n + (per_review[rv.id] or 0)
        present[rv.state] = true
      end
      local label
      if #rvs == 1 then
        label = ('── %s %s'):format(rvs[1].author or 'unknown', STATE_ICON[rvs[1].state] or '○')
      else
        local icons = {}
        for _, s in ipairs(STATE_ORDER) do
          if present[s] then
            table.insert(icons, STATE_ICON[s])
          end
        end
        label = ('── %d reviews %s'):format(#rvs, #icons > 0 and table.concat(icons) or '○')
      end
      if n > 0 then
        label = label .. (' %d thread%s'):format(n, n == 1 and '' or 's')
      end
      table.insert(out, { kind = 'marker', reviews = rvs, label = label })
    end
    table.insert(out, e)
  end
  return out
end

--- Redo the layer's rows after it attached, re-read or detached, keeping
--- the selection on the same entries.
function M.apply_layer(session)
  local old = session.entries
  if not old then
    return
  end
  local plain = { base = old.base, follow_pathspec = old.follow_pathspec }
  for _, e in ipairs(old) do
    if e.kind ~= 'pr' and e.kind ~= 'marker' then
      table.insert(plain, e)
    end
  end
  local new = M.with_layer(session, plain)
  local sel = session.sel
  if sel then
    local top, bottom = old[sel.top], old[sel.bottom]
    for i, e in ipairs(new) do
      if e == top then
        sel.top = i
      end
      if e == bottom then
        sel.bottom = i
      end
    end
  end
  session.entries = new
  if sel then
    session.pair = selection.resolve(new, sel.top, sel.bottom)
  end
  M.render(session)
  -- the layer's rows change the log's height
  require('diffy.layout').fit_column(session)
end

--- Whether entry `i` is drawn as selected (the PR row and review markers
--- never are).
local function is_selected(session, i)
  local sel, e = session.sel, (session.entries or {})[i]
  return sel ~= nil and e ~= nil and i >= sel.top and i <= sel.bottom and e.kind ~= 'pr' and e.kind ~= 'marker'
end

--- (Re)render the full entry list: merges dimmed, the active
--- contiguous selection marked. Call after entries/selection change.
function M.render(session)
  local buf = session.bufs.log
  local width = log_width(session)
  session.log_width = width
  local function selected(i)
    return is_selected(session, i)
  end
  local lines, all_spans = {}, {}
  for i, e in ipairs(session.entries) do
    if e.kind == 'pr' and not e.loading then
      e.sync = require('diffy.review.github').sync_status(session)
    end
    lines[i], all_spans[i] = entry_line(e, selected(i), width)
  end
  local stack = require('diffy.panels.stack')
  stack.set_lines(session, 'log', lines)

  local ns = session.ns.log_render
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local off = stack.offset(session, 'log')
  for i, e in ipairs(session.entries) do
    if is_merge(e) then
      vim.api.nvim_buf_set_extmark(buf, ns, off + i - 1, 0, { line_hl_group = 'DiffyMerge' })
    end
    if selected(i) then
      vim.api.nvim_buf_set_extmark(buf, ns, off + i - 1, 0, { line_hl_group = 'DiffySelection' })
    end
    for _, sp in ipairs(all_spans[i]) do
      vim.api.nvim_buf_set_extmark(buf, ns, off + i - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
    end
  end
end

local function clamp_range(entries, top, bottom)
  top, bottom = math.max(1, top), math.min(#entries, bottom)
  while top <= bottom and skipped(entries[top]) do
    top = top + 1
  end
  while bottom >= top and skipped(entries[bottom]) do
    bottom = bottom - 1
  end
  return top, bottom
end

--- Select `top..bottom` trimmed of merge endpoints; no-op if nothing is left.
local function select_clamped(session, top, bottom)
  top, bottom = clamp_range(session.entries, top, bottom)
  if top > bottom then
    return
  end
  session.sel = { top = top, bottom = bottom }
  session.on_select(session)
end

--- In `:Diffy`, turn the session into `:Diffy branch` on the PR's base,
--- everything selected; checkout mode is left first.
local function open_branch(session)
  require('diffy.checkout').leave(session, function(ok)
    if not ok then
      return
    end
    session.range = { kind = 'branch', pr_base = session.layer.cache.pr.base }
    session.entries, session.sel = nil, nil
    require('diffy').build(session)
  end)
end

--- <CR> in normal mode: select the single entry under the cursor; on a
--- review marker, everything above it (what changed since that review); on
--- the PR row, the whole PR.
function M.select_line(session)
  local lnum = require('diffy.panels.stack').cursor(session, 'log')
  if not lnum then
    return
  end
  local e = session.entries[lnum]
  if e and e.kind == 'pr' and e.loading then
    return
  elseif e and e.kind == 'pr' then
    if session.range.kind == 'default' then
      open_branch(session)
    else
      M.select_all(session)
    end
    return
  end
  if e and e.kind == 'marker' then
    select_clamped(session, 1, lnum - 1)
  else
    select_clamped(session, lnum, lnum)
  end
end

--- `<CR>` in visual/visual-line mode: select the marked line range (the
--- part of it on the log's rows).
function M.select_visual(session)
  vim.cmd('normal! \27') -- <Esc>, leave visual mode so the marks settle
  local stack = require('diffy.panels.stack')
  local a = vim.api.nvim_buf_get_mark(session.bufs.log, '<')[1]
  local b = vim.api.nvim_buf_get_mark(session.bufs.log, '>')[1]
  local first, last = math.min(a, b), math.max(a, b)
  local off = stack.offset(session, 'log')
  local top, bottom = math.max(first - off, 1), math.min(last - off, #(session.entries or {}))
  if top <= bottom then
    select_clamped(session, top, bottom)
  end
end

--- `a`: select every selectable entry (first..last non-merge endpoint).
function M.select_all(session)
  select_clamped(session, 1, #session.entries)
end

--- Select entries `top..bottom` (no merge endpoints); `done()` runs once
--- the new selection is drawn (not if a full checkout refuses to leave).
function M.select(session, top, bottom, done)
  session.sel = { top = top, bottom = bottom }
  session.on_select(session, done)
end

--- `J`/`K` (also `]r`/`[r` from the diff windows): collapse the current
--- selection to a single entry and move it `delta` non-merge entries
--- (positive toward older commits, negative toward newer), stopping at the
--- first/last one.
function M.move_selection(session, delta)
  local sel = session.sel
  if not sel then
    return
  end
  local step = delta > 0 and 1 or -1
  local target
  local i = delta > 0 and sel.bottom or sel.top
  for _ = 1, math.abs(delta) do
    i = i + step
    while i >= 1 and i <= #session.entries and skipped(session.entries[i]) do
      i = i + step
    end
    if i < 1 or i > #session.entries then
      break
    end
    target = i
  end
  if not target then
    return
  end
  session.sel = { top = target, bottom = target }
  session.on_select(session)
end

function M.setup(session)
  session.ns.log_render = require('diffy.session').namespace(session, 'log_render')
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      local win = session.wins.log
      if session.entries and win and vim.api.nvim_win_is_valid(win) and log_width(session) ~= session.log_width then
        M.render(session)
      end
    end,
  })

  local buf = session.bufs.log
  local function map(s, modes, lhs, rhs, opts)
    require('diffy.panels.stack').map(s, 'log', modes, lhs, rhs, opts)
  end
  map(session, 'n', '<CR>', function()
    M.select_line(session)
  end, { buffer = buf, desc = 'select entry' })
  map(session, { 'v', 'x' }, '<CR>', function()
    M.select_visual(session)
  end, { buffer = buf, desc = 'select range' })
  map(session, 'n', 'a', function()
    M.select_all(session)
  end, { buffer = buf, desc = 'select all' })
  map(session, 'n', 'J', function()
    M.move_selection(session, 1)
  end, { buffer = buf, desc = 'select next commit' })
  map(session, 'n', 'K', function()
    M.move_selection(session, -1)
  end, { buffer = buf, desc = 'select previous commit' })
  map(session, 'n', 'X', function()
    require('diffy.checkout').toggle(session)
  end, { buffer = buf, desc = 'toggle checkout mode' })
  map(session, 'n', ']f', function()
    require('diffy.panels.tree').move_file(session, vim.v.count1)
  end, { buffer = buf, desc = 'next file' })
  map(session, 'n', '[f', function()
    require('diffy.panels.tree').move_file(session, -vim.v.count1)
  end, { buffer = buf, desc = 'previous file' })
  require('diffy.layout').map_panel_keys(session, buf)
  require('diffy.review.ui').map_last(session, buf)
  require('diffy.panels.commitmsg').setup(session)
end

-- rows before there are entries (and in `:Diffy conflicts`, which has none)
local EMPTY_HEIGHT = 10

M.view = {
  label = ' Commits',
  persistent = true,
  render = function(session)
    if session.entries then
      M.render(session)
    end
  end,
  height = function(session, room)
    if not (session.entries and #session.entries > 0) then
      return EMPTY_HEIGHT
    end
    -- checkout mode shows its marker in the log's winbar, one row of the height
    local winbar = session.checkout and 1 or 0
    return math.max(1, math.min(#session.entries, math.floor(room * 0.4))) + winbar
  end,
  -- in the shared column window (panels/stack.lua): the selection is
  -- pinned over the edge it went past
  peek = {
    noun = 'commit',
    counts = function(session, rel)
      local e = (session.entries or {})[rel]
      return e ~= nil and e.kind == 'commit'
    end,
    pinned = is_selected,
  },
  --- `]]`: the newest selected entry
  anchor = function(session)
    return session.sel and session.sel.top or 1
  end,
}

return M
