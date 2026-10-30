-- The guide tab: the column's top part shows either the files (`panels/tree.lua`)
-- or the branch's guide (`guide.lua`), switched with `<Tab>`, the tabs in the
-- column window's winbar. The guide draws through the tree view's rows
-- (`stack.set_lines(session, 'tree', …)`), so the stack, its peeks and its keys
-- don't know there are two tabs; the tree hands its keys here while the guide
-- is shown.
--
-- Opening a guide item selects the whole branch (merge-base..HEAD, the diff
-- the guide describes) and "focuses" its section: in the diff, the changes of
-- other sections and the unchanged lines away from the section's are folded
-- (manual folds at counterpart ranges, so both windows stay aligned), and each
-- item's note is a virt_line above its first change.
local guide = require('diffy.guide')
local stack = require('diffy.panels.stack')
local hl = require('diffy.highlight')
local run = require('diffy.git.run')

local M = {}

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function ns(session, name)
  return require('diffy.session').namespace(session, name)
end

--- Whether the session has a guide tab: a guide file, or an agent to write one.
function M.available(session)
  local kind = session.range and session.range.kind
  return (kind == 'default' or kind == 'branch') and (session.guide ~= nil or guide.agent_cmd() ~= nil)
end

function M.shown(session)
  return session.column_tab == 'guide' and M.available(session)
end

local function resolved(session)
  return session.guide and session.guide.resolved
end

--- The guide was written for another HEAD or merge-base than the branch's now.
function M.stale(session)
  local g = session.guide and session.guide.guide
  if not g then
    return false
  end
  local base = session.entries and session.entries.base
  return g.head ~= session.head_sha or (base ~= nil and g.base ~= base)
end

--- The selection shows the diff the guide describes.
function M.on_pair(session)
  local g = session.guide and session.guide.guide
  local p = session.pair
  return g ~= nil and p ~= nil and not p.split and p.left == g.base and p.right == g.head
end

-- ---------------------------------------------------------------------
-- the winbar's tabs

--- `0:42` for `ms`.
local function clock(ms)
  local s = math.floor(ms / 1000)
  return ('%d:%02d'):format(math.floor(s / 60), s % 60)
end

local function progress(session)
  return session.gitdir and session.branch and guide.progress(session.gitdir, session.branch)
end

--- The column window's tab strip, nil without a guide tab.
function M.tabs(session)
  if not M.available(session) then
    return nil
  end
  local function tab(name, label)
    return (session.column_tab == name and '%#DiffyGuideTab#' or '%#DiffyGuideTabInactive#') .. label .. '%*'
  end
  local label = 'Guide'
  local p = progress(session)
  if p then
    label = 'Guide ↻ ' .. clock(vim.uv.now() - p.started)
  elseif M.stale(session) then
    label = 'Guide (stale)'
  end
  return ' ' .. tab('guide', label) .. '%#DiffyGuideTabInactive# · %*' .. tab('files', 'Files')
end

-- ---------------------------------------------------------------------
-- rows

local function viewed_paths(session)
  if not M.on_pair(session) then
    return nil
  end
  local out = {}
  for _, row in ipairs(session.tree_all or {}) do
    if row.kind == 'file' then
      out[row.entry.path] = row.viewed or false
    end
  end
  return out
end

local function basename(path)
  return path:match('([^/]+)$') or path
end

--- The rows: `{ kind = 'info'|'section'|'item', text, spans, si, ii }`.
local function build_rows(session, width)
  local rows = {}
  local function info(text, group)
    text = hl.truncate(text, width)
    table.insert(rows, { kind = 'info', text = text, spans = { { 0, #text, group or 'DiffyThreadHint' } } })
  end
  local st = session.guide
  local p = progress(session)
  local running = p ~= nil
  if p then
    local steps = p.steps > 0 and (' · %d step%s'):format(p.steps, p.steps == 1 and '' or 's') or ''
    info(('↻ writing the guide · %s%s'):format(clock(vim.uv.now() - p.started), steps))
    if p.activity then
      info('  ' .. p.activity)
    end
  end
  if st and st.error then
    info('⚠ ' .. st.error, 'DiffyGuideStale')
  end
  if M.stale(session) then
    info(('⚠ written for %s%s'):format(st.guide.head:sub(1, 7), guide.agent_cmd() and ' · gG rewrites it' or ''), 'DiffyGuideStale')
  end
  local r = resolved(session)
  if not r then
    if not (st or running) then
      info(guide.agent_cmd() and 'No guide yet · gG writes one' or 'No guide')
    end
    return rows
  end
  local seen = viewed_paths(session)
  local collapsed = session.guide_collapsed or {}
  for si, sec in ipairs(r.sections) do
    local done = 0
    for _, it in ipairs(sec.hunks) do
      if seen and seen[it.path] then
        done = done + 1
      end
    end
    local count = seen and ('%d/%d'):format(done, #sec.hunks) or tostring(#sec.hunks)
    local key = sec.unguided and 'unguided' or tostring(si)
    local folded = collapsed[key]
    local head = (folded and '▸ ' or '▾ ') .. (sec.unguided and '' or (si .. ' '))
    local title = hl.truncate(sec.title, math.max(1, width - #head - #count - 1))
    local text = head .. title
    text = text .. (' '):rep(math.max(1, width - vim.fn.strdisplaywidth(text) - #count)) .. count
    table.insert(rows, {
      kind = 'section',
      si = si,
      key = key,
      text = text,
      spans = {
        { #head, #head + #title, sec.unguided and 'DiffyThreadHint' or 'DiffyLabel' },
        { #text - #count, #text, 'DiffyThreadTime' },
      },
    })
    if not folded then
      for ii, it in ipairs(sec.hunks) do
        local counts = ('+%d -%d'):format(it.added, it.removed)
        local h = it.git[1]
        local name = basename(it.path) .. (h and (':' .. (h.new_count > 0 and h.new_start or h.old_start)) or '')
        local lead = '    '
        local room = math.max(1, width - #lead - #counts - 1)
        name = hl.truncate(name, room)
        local scope = it.header and it.header ~= '' and hl.truncate(it.header, math.max(0, room - vim.fn.strdisplaywidth(name) - 2)) or ''
        local left = lead .. name .. (scope ~= '' and '  ' .. scope or '')
        local line = left .. (' '):rep(math.max(1, width - vim.fn.strdisplaywidth(left) - #counts)) .. counts
        local viewed = seen and seen[it.path]
        local plus_end = #line - #counts + #tostring(it.added) + 1
        local spans = {
          { #lead, #lead + #name, viewed and 'DiffyViewed' or 'Normal' },
          { #lead + #name, #left, viewed and 'DiffyViewed' or 'DiffyGuideScope' },
          { #line - #counts, plus_end, 'DiffyAdded' },
          { plus_end + 1, #line, 'DiffyRemoved' },
        }
        table.insert(rows, { kind = 'item', si = si, ii = ii, text = line, spans = spans })
      end
    end
  end
  return rows
end

local function width(session)
  return hl.panel_width(session.wins.tree, session.tree_width)
end

--- Drop what the files tab drew in the shared rows (and the reverse in `M.clear`).
local function clear_files(session, buf)
  for _, name in ipairs({ 'tree_render', 'tree_current' }) do
    vim.api.nvim_buf_clear_namespace(buf, ns(session, name), 0, -1)
  end
  require('diffy.session').close_overlay(session, 'tree_hover')
end

function M.clear(session)
  local buf = session.bufs.tree
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns(session, 'guide_render'), 0, -1)
  end
end

--- Highlight the item shown in the diff.
function M.mark_current(session)
  local buf = session.bufs.tree
  if not (buf and vim.api.nvim_buf_is_valid(buf) and M.shown(session)) then
    return
  end
  local n = ns(session, 'tree_current')
  vim.api.nvim_buf_clear_namespace(buf, n, 0, -1)
  local cur = session.guide_current
  if not (cur and cur.path == session.current_path) then
    return
  end
  for i, row in ipairs(session.guide_rows or {}) do
    if row.kind == 'item' and row.si == cur.si and row.ii == cur.ii then
      vim.api.nvim_buf_set_extmark(buf, n, stack.lnum(session, 'tree', i) - 1, 0, { line_hl_group = 'DiffyCurrentFile' })
      return
    end
  end
end

function M.redraw(session)
  local buf = session.bufs.tree
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local w = width(session)
  session.tree_width = w
  local rows = build_rows(session, w)
  session.guide_rows = rows
  local lines = {}
  for i, row in ipairs(rows) do
    lines[i] = row.text
  end
  if #lines == 0 then
    lines = { '' }
  end
  clear_files(session, buf)
  stack.set_lines(session, 'tree', lines)
  local n = ns(session, 'guide_render')
  vim.api.nvim_buf_clear_namespace(buf, n, 0, -1)
  local off = stack.offset(session, 'tree')
  for i, row in ipairs(rows) do
    for _, sp in ipairs(row.spans) do
      if sp[2] > sp[1] then
        vim.api.nvim_buf_set_extmark(buf, n, off + i - 1, sp[1], { end_col = math.min(sp[2], #row.text), hl_group = sp[3] })
      end
    end
  end
  M.mark_current(session)
end

--- Redraw the winbars and the top part, whichever tab it shows.
local function refresh(session)
  require('diffy.layout').winbars(session)
  require('diffy.panels.tree').redraw(session)
end

-- ---------------------------------------------------------------------
-- loading and writing

--- Read the branch's guide again (`M.build`, after the agent wrote it).
--- Picks the tab the first time: the guide when there is one.
function M.load(session, cb)
  if not (session.gitdir and session.branch) then
    cb()
    return
  end
  guide.load(session.root, session.gitdir, session.branch, function(st)
    session.guide = st
    if session.column_tab == nil then
      session.column_tab = st and st.resolved and 'guide' or 'files'
    end
    cb()
  end, session)
end

local function sessions_on_branch(session)
  local out = {}
  for _, s in pairs(require('diffy.session').sessions) do
    if not s.closed and s.gitdir == session.gitdir and s.branch == session.branch then
      table.insert(out, s)
    end
  end
  return out
end

--- The merge-base and head the guide is written for: the branch view's,
--- else the pull request's (attached layer), else the default base's
--- (`:Diffy branch` without an argument).
local function branch_range(session, cb)
  local review = type(session.review) == 'table' and session.review or {}
  local base = session.range.kind == 'branch' and session.entries and session.entries.base or (review.pr and review.merge_base)
  if base then
    cb(base)
    return
  end
  local repo = require('diffy.git.repo')
  repo.resolve_base(session.root, nil, function(ref, err)
    if not ref then
      cb(nil, err)
      return
    end
    repo.merge_base(session.root, ref, 'HEAD', cb, session)
  end, session)
end

--- `gG` / `:Diffy guide`: have the agent write the branch's guide, showing
--- the guide tab unless `opts.stay` (`guide.auto`: the files stay shown).
function M.generate(session, opts)
  local switch = not (opts and opts.stay)
  local kind = session.range and session.range.kind
  if kind ~= 'default' and kind ~= 'branch' then
    vim.notify('diffy: the guide is for :Diffy and :Diffy branch', vim.log.levels.WARN)
    return
  end
  if not guide.agent_cmd() then
    vim.notify('diffy: no agent configured to write the guide (`guide.agent`, :help diffy-guide)', vim.log.levels.WARN)
    return
  end
  if guide.running(session.gitdir, session.branch) then
    vim.notify('diffy: the agent is already writing this guide', vim.log.levels.INFO)
    return
  end
  branch_range(session, function(base, err)
    if not base then
      vim.notify('diffy: no base to write a guide against (' .. tostring(err) .. ')', vim.log.levels.WARN)
      return
    end
    local head = session.head_sha
    local function redraw_all()
      for _, s in ipairs(sessions_on_branch(session)) do
        require('diffy.layout').winbars(s)
        if M.shown(s) then
          M.redraw(s)
        end
      end
    end
    -- the elapsed time in the winbar and the first row
    local timer = vim.uv.new_timer()
    timer:start(1000, 1000, vim.schedule_wrap(redraw_all))
    guide.generate(session.root, session.gitdir, session.branch, base, head, function(ok, gerr, ms)
      timer:stop()
      timer:close()
      if ok then
        vim.notify(('diffy: the guide is written (%s)'):format(clock(ms)))
      else
        vim.notify('diffy: ' .. gerr, vim.log.levels.ERROR)
      end
      for _, s in ipairs(sessions_on_branch(session)) do
        M.load(s, function()
          if ok and switch then
            s.column_tab = 'guide'
          end
          refresh(s)
          run.ready({ session = s.id, event = 'guide' })
        end)
      end
    end, redraw_all)
    if switch then
      session.column_tab = 'guide'
    end
    redraw_all()
    run.ready({ session = session.id, event = 'guide' })
  end)
end

-- guide paths auto-generation was started for in this nvim: a failed run
-- isn't retried on every read
local auto_started = {}

--- `guide.auto`: the pull request was just read and the branch has no guide
--- yet: have the agent write one. `gG` writes it again later.
function M.auto(session)
  local cfg = require('diffy').config.guide or {}
  if not (cfg.auto and guide.agent_cmd() and session.gitdir and session.branch) then
    return
  end
  local kind = session.range and session.range.kind
  local path = guide.path(session.gitdir, session.branch)
  if (kind ~= 'default' and kind ~= 'branch') or auto_started[path] or guide.running(session.gitdir, session.branch) then
    return
  end
  if vim.fn.filereadable(path) == 1 then
    return
  end
  auto_started[path] = true
  M.generate(session, { stay = true })
end

-- ---------------------------------------------------------------------
-- the diff: notes and the focused section's folds

local function diffopt_context()
  return tonumber(vim.o.diffopt:match('context:(%d+)')) or 6
end

--- The resolved file `path` of the guide, when the diff shows the guide's pair.
local function guide_file(session, path)
  local r = resolved(session)
  return r and path and M.on_pair(session) and r.files[path] or nil
end

local function other(name)
  return name == 'left' and 'right' or 'left'
end

local function set_fold_state(win, list)
  vim.w[win].diffy_guide_folds = list
end

--- Back to diff mode's own folds.
local function unfold(win)
  if vim.w[win].diffy_guide_folds then
    set_fold_state(win, nil)
    vim.api.nvim_win_call(win, function()
      if vim.wo.foldmethod == 'manual' then
        vim.cmd('normal! zE')
      end
      vim.cmd('setlocal foldmethod=diff foldminlines<')
    end)
  end
end

--- Fold everything but the focused section's changes in `file`, both windows.
local function fold_to_focus(session, file)
  local left, right = session.wins.left, session.wins.right
  local focus = session.guide_focus
  local set, any = {}, false
  for _, h in ipairs(file.hunks) do
    if vim.tbl_contains(h.owners, focus) then
      set[h], any = true, true
    end
  end
  if not (any and valid(left) and valid(right)) then
    return false
  end
  local lbuf, rbuf = vim.api.nvim_win_get_buf(left), vim.api.nvim_win_get_buf(right)
  local folds = guide.regions(file.hunks, set, diffopt_context(), vim.api.nvim_buf_line_count(lbuf), vim.api.nvim_buf_line_count(rbuf))
  local r = resolved(session)
  local lists = { left = {}, right = {} }
  for _, f in ipairs(folds) do
    local label
    for _, h in ipairs(f.hunks) do
      local sec = r.sections[h.owners[1]]
      if sec then
        label = sec.unguided and sec.title or (h.owners[1] .. ' ' .. sec.title)
        break
      end
    end
    table.insert(lists.left, { f.old[1], f.old[2], label })
    table.insert(lists.right, { f.new[1], f.new[2], label })
  end
  for _, name in ipairs({ 'left', 'right' }) do
    local win = session.wins[name]
    -- before 'foldmethod': navigation.lua puts back diff folds on windows without it
    set_fold_state(win, lists[name])
    vim.api.nvim_win_call(win, function()
      -- a one-line fold must close like its counterpart, or the rows drift apart
      vim.cmd('setlocal foldmethod=manual foldminlines=0')
      vim.cmd('normal! zE')
      for _, f in ipairs(lists[name]) do
        vim.cmd(('%d,%dfold'):format(f[1], f[2]))
      end
    end)
  end
  return true
end

--- One note above git hunk `h`, and a blank row at the counterpart in the
--- other window so both stay aligned.
local function place_note(session, n, h, text)
  local note = { { { '┊ ' .. text, 'DiffyGuideNote' } } }
  local blank = { { { '', '' } } }
  for _, name in ipairs({ 'right', 'left' }) do
    local win = session.wins[name]
    if valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local side = name == 'right' and 'new' or 'old'
      local start, count = h[side .. '_start'], h[side .. '_count']
      -- the note goes on the side with lines, the new one when both have
      local shows = not valid(session.wins[other(name)]) or (name == 'right') == (h.new_count > 0)
      -- an empty side: under the line before the filler, which comes after virt_lines
      local row, above = start - 1, true
      if count == 0 then
        row, above = start - 1, false
        if row < 0 then
          row, above = 0, true
        end
      end
      if row < vim.api.nvim_buf_line_count(buf) then
        vim.api.nvim_buf_set_extmark(buf, n, row, 0, { virt_lines = shows and note or blank, virt_lines_above = above })
      end
    end
  end
end

--- Notes and focus folds for the file the diff shows (after `diffpair.show`).
function M.decorate(session)
  local n = ns(session, 'guide_notes')
  local wins = {}
  for _, name in ipairs({ 'left', 'right' }) do
    local win = session.wins[name]
    if valid(win) then
      table.insert(wins, win)
      vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(win), n, 0, -1)
    end
  end
  pcall(vim.api.nvim__ns_set, n, { wins = wins })
  local file = guide_file(session, session.current_path)
  local focused = file and session.guide_focus and fold_to_focus(session, file)
  if not focused then
    for _, win in ipairs(wins) do
      unfold(win)
    end
  end
  if not file then
    return
  end
  local r = resolved(session)
  for _, sec in ipairs(r.sections) do
    for _, it in ipairs(sec.hunks) do
      if it.path == file.path then
        for _, note in ipairs(it.notes) do
          if note.git[1] then
            place_note(session, n, note.git[1], note.text)
          end
        end
      end
    end
  end
end

--- Leave the focused section: diff mode's folds again.
function M.unfocus(session)
  session.guide_focus = nil
  M.decorate(session)
end

--- `zo`/`za`… on a guide fold opened or closed it in window `win`: the same
--- for its counterpart in the other diff window.
function M.sync_fold(win, lnum)
  local session = require('diffy.session').current()
  local list = vim.w[win].diffy_guide_folds
  if not (session and list) then
    return
  end
  local name = session.wins.left == win and 'left' or session.wins.right == win and 'right' or nil
  local twin = name and session.wins[other(name)]
  local tlist = twin and valid(twin) and vim.w[twin].diffy_guide_folds
  if not tlist then
    return
  end
  for i, f in ipairs(list) do
    if lnum >= f[1] and lnum <= f[2] and tlist[i] then
      local closed = vim.fn.foldclosed(f[1]) ~= -1
      local t = tlist[i]
      vim.api.nvim_win_call(twin, function()
        vim.cmd(('%d,%d%s'):format(t[1], t[2], closed and 'foldclose' or 'foldopen'))
      end)
      return
    end
  end
end

-- ---------------------------------------------------------------------
-- opening items

local function first_commit(entries)
  for i, e in ipairs(entries or {}) do
    if e.kind == 'commit' and not e.merge then
      return i
    end
  end
end

--- Select merge-base..HEAD (every commit, not the working tree), turning a
--- `:Diffy` session into `:Diffy branch` first; then `cb()`.
local function select_branch(session, cb)
  if session.range.kind ~= 'branch' then
    require('diffy.checkout').leave(session, function(ok)
      if not ok then
        return
      end
      session.range = { kind = 'branch', pr_base = session.layer and session.layer.cache and session.layer.cache.pr and session.layer.cache.pr.base }
      session.entries, session.sel = nil, nil
      require('diffy').build(session, function()
        select_branch(session, cb)
      end)
    end)
    return
  end
  local top = first_commit(session.entries)
  local bottom = require('diffy.selection').last_selectable(session.entries)
  if not (top and bottom) then
    vim.notify('diffy: the branch has no commits to guide', vim.log.levels.WARN)
    return
  end
  if session.sel and session.sel.top == top and session.sel.bottom == bottom then
    cb()
    return
  end
  require('diffy.panels.log').select(session, top, bottom, cb)
end

--- Flat list of every item, in guide order: `{ si, ii }`.
local function items(session)
  local out = {}
  for si, sec in ipairs(resolved(session).sections) do
    for ii in ipairs(sec.hunks) do
      table.insert(out, { si = si, ii = ii })
    end
  end
  return out
end

local function set_cursor_to_row(session, si, ii)
  for i, row in ipairs(session.guide_rows or {}) do
    if row.si == si and (ii == nil and row.kind == 'section' or row.ii == ii) then
      stack.set_cursor(session, 'tree', i)
      return
    end
  end
end

--- Open item `ii` of section `si`: the whole branch selected, its file shown
--- with the section focused, the cursor on its first change. `opts.focus`
--- moves to the diff.
function M.open_item(session, si, ii, opts)
  local r = resolved(session)
  local it = r and r.sections[si] and r.sections[si].hunks[ii]
  if not it then
    return
  end
  select_branch(session, function()
    session.guide_focus = si
    session.guide_current = { si = si, ii = ii, path = it.path }
    if (session.guide_collapsed or {})[r.sections[si].unguided and 'unguided' or tostring(si)] then
      session.guide_collapsed[r.sections[si].unguided and 'unguided' or tostring(si)] = nil
    end
    local tree = require('diffy.panels.tree')
    if not tree.open_path(session, it.path) then
      vim.notify('diffy: ' .. it.path .. ' is not in the diff', vim.log.levels.WARN)
      run.ready({ session = session.id, event = 'open_row' })
      return
    end
    if M.shown(session) then
      M.redraw(session)
      set_cursor_to_row(session, si, ii)
    end
    local h = it.git[1]
    local name = h and (h.new_count > 0 and 'right' or 'left')
    local win = name and (valid(session.wins[name]) and session.wins[name] or session.wins[other(name)])
    if h and valid(win) then
      local lnum = name == 'right' and h.new_start or math.max(1, h.old_start)
      lnum = math.min(lnum, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))
      vim.api.nvim_win_set_cursor(win, { math.max(1, lnum), 0 })
      vim.api.nvim_win_call(win, function()
        vim.cmd('normal! zz')
      end)
    end
    local diff_win = session.wins.right or session.wins.left
    if opts and opts.focus and valid(diff_win) then
      vim.api.nvim_set_current_win(win or diff_win)
    end
    run.ready({ session = session.id, event = 'open_row' })
  end)
end

--- `]g`/`[g`: the next/previous item in guide order (a count: that many).
function M.move(session, delta)
  if not resolved(session) then
    return
  end
  local list = items(session)
  if #list == 0 then
    return
  end
  local cur, pos = session.guide_current, nil
  for i, x in ipairs(list) do
    if cur and x.si == cur.si and x.ii == cur.ii then
      pos = i
    end
  end
  local target = pos and math.max(1, math.min(#list, pos + delta)) or (delta > 0 and 1 or #list)
  if pos == target then
    return
  end
  M.open_item(session, list[target].si, list[target].ii)
end

--- `]h`/`[h` in a diff window: the next/previous change of the focused
--- section in the file shown, from the cursor (a count: that many, stopping at
--- the last one). False when the file has no change of a focused section.
function M.move_hunk(session, delta)
  local focus = session.guide_focus
  local file = focus and guide_file(session, session.current_path)
  local win = vim.api.nvim_get_current_win()
  local name = session.wins.left == win and 'left' or session.wins.right == win and 'right' or nil
  if not (file and name) then
    return false
  end
  local side = name == 'right' and 'new' or 'old'
  local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local stops = {}
  for _, h in ipairs(file.hunks) do
    if vim.tbl_contains(h.owners, focus) then
      -- no lines on this side: the line below the filler, where `]c` lands
      local lnum = h[side .. '_count'] > 0 and h[side .. '_start'] or h[side .. '_start'] + 1
      table.insert(stops, { lnum = math.max(1, math.min(last, lnum)), hunk = h })
    end
  end
  if #stops == 0 then
    return false
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local ahead = {}
  for _, s in ipairs(stops) do
    if delta > 0 and s.lnum > cur then
      table.insert(ahead, s)
    elseif delta < 0 and s.lnum < cur then
      table.insert(ahead, 1, s)
    end
  end
  local target = ahead[math.min(#ahead, math.abs(delta))]
  if not target then
    return true
  end
  vim.api.nvim_win_set_cursor(win, { target.lnum, 0 })
  for ii, it in ipairs(resolved(session).sections[focus].hunks) do
    if vim.tbl_contains(it.git, target.hunk) then
      session.guide_current = { si = focus, ii = ii, path = it.path }
      M.mark_current(session)
      if M.shown(session) then
        set_cursor_to_row(session, focus, ii)
      end
      break
    end
  end
  return true
end

--- The guide's sections whose changes touch lines `first`..`last` of the
--- `side` ('old'|'new') of `path`, when the diff shows the guide's pair:
--- `{ { index, title, body, notes } }`, `notes` those of the items touched.
function M.sections_at(session, path, side, first, last)
  local file = guide_file(session, path)
  if not file then
    return {}
  end
  local hit = {}
  for _, h in ipairs(file.hunks) do
    local s, c = h[side .. '_start'], h[side .. '_count']
    -- no lines on this side: the change sits between line s and s + 1
    if s <= last and (c > 0 and s + c - 1 or s + 1) >= first then
      hit[h] = true
    end
  end
  local out = {}
  for si, sec in ipairs(resolved(session).sections) do
    local notes, touched = {}, false
    for _, it in ipairs(sec.hunks) do
      for _, gh in ipairs(it.git) do
        touched = touched or hit[gh] or false
      end
      for _, note in ipairs(it.notes) do
        for _, gh in ipairs(note.git) do
          if hit[gh] and not vim.tbl_contains(notes, note.text) then
            table.insert(notes, note.text)
          end
        end
      end
    end
    if touched and not sec.unguided then
      table.insert(out, { index = si, title = sec.title, body = vim.trim(sec.body), notes = notes })
    end
  end
  return out
end

local function row_at_cursor(session)
  local rel = stack.cursor(session, 'tree')
  return rel and (session.guide_rows or {})[rel]
end

local function toggle_section(session, row)
  session.guide_collapsed = session.guide_collapsed or {}
  session.guide_collapsed[row.key] = not session.guide_collapsed[row.key] or nil
  M.redraw(session)
  set_cursor_to_row(session, row.si)
end

--- `m`: mark the item's file viewed (a section: all its files), or unmark.
local function toggle_viewed(session)
  local row = row_at_cursor(session)
  if not (row and row.si) then
    return
  end
  if not M.on_pair(session) then
    vim.notify('diffy: viewed marks in the guide are for the whole branch: open one of its items first', vim.log.levels.WARN)
    return
  end
  local sec = resolved(session).sections[row.si]
  local paths = {}
  for ii, it in ipairs(sec.hunks) do
    if row.kind == 'section' or ii == row.ii then
      paths[it.path] = true
    end
  end
  require('diffy.panels.tree').toggle_viewed_paths(session, paths)
  M.redraw(session)
end

--- Switch the top part between the guide and the files.
function M.toggle_tab(session)
  if not M.available(session) then
    return
  end
  session.column_tab = session.column_tab == 'guide' and 'files' or 'guide'
  if session.column_tab == 'files' and session.guide_focus then
    M.unfocus(session)
  end
  refresh(session)
  if session.column_tab == 'guide' then
    local cur = session.guide_current
    if cur and cur.path == session.current_path then
      set_cursor_to_row(session, cur.si, cur.ii)
    else
      stack.set_cursor(session, 'tree', 1)
    end
  else
    stack.jump(session, 'tree')
  end
  run.ready({ session = session.id, event = 'guide' })
end

local function open_at_cursor(session, opts)
  local row = row_at_cursor(session)
  if not row then
    return
  end
  if row.kind == 'section' then
    toggle_section(session, row)
  elseif row.kind == 'item' then
    M.open_item(session, row.si, row.ii, opts)
  end
end

-- the tree's keys that do something else in the guide, by lhs; any other
-- tree key but these is the files' only
M.KEYS = {
  ['<CR>'] = function(session)
    open_at_cursor(session, { focus = true })
  end,
  o = function(session)
    open_at_cursor(session)
  end,
  m = toggle_viewed,
}
M.PASS = { [']r'] = true, ['[r'] = true, [']f'] = true, ['[f'] = true }

--- The tree's handler for `lhs` while the guide is shown: the guide's own,
--- the files' for the keys both share, else nothing.
function M.key(session, lhs, files_handler)
  local mark = require('diffy').config.keymaps.tree_toggle_viewed
  local own = M.KEYS[lhs] or (lhs == mark and M.KEYS.m) or nil
  if own then
    return own(session)
  elseif M.PASS[lhs] or lhs == require('diffy').config.keymaps.undo_viewed then
    return files_handler()
  end
  vim.notify('diffy: that key is for the files (<Tab>)', vim.log.levels.INFO)
end

--- The guide's keys in the column (`stack.map` on the tree's rows).
function M.setup(session, buf)
  local function map(lhs, fn, desc)
    stack.map(session, 'tree', 'n', lhs, fn, { buffer = buf, desc = desc })
  end
  map('<Tab>', function()
    M.toggle_tab(session)
  end, 'switch between the guide and the files')
  map('gG', function()
    M.generate(session)
  end, 'have the agent write the guide')
  map(']g', function()
    M.move(session, vim.v.count1)
  end, 'next guide item')
  map('[g', function()
    M.move(session, -vim.v.count1)
  end, 'previous guide item')
  local send = require('diffy').config.keymaps.send_to_agent
  if send and send ~= '' then
    map(send, function()
      local row = M.shown(session) and row_at_cursor(session)
      local r = resolved(session)
      local sec = row and row.si and r and r.sections[row.si]
      if not sec or sec.unguided then
        vim.notify('diffy: not on a guide section', vim.log.levels.WARN)
        return
      end
      require('diffy.agent').guide(session, { index = row.si, title = sec.title, body = vim.trim(sec.body), hunks = sec.hunks }, row.kind == 'item' and sec.hunks[row.ii] or nil)
    end, 'send the guide section to the agent')
  end
end

--- Width of markdown text once the float conceals code spans' backticks and
--- bold's asterisks.
local function shown_width(s)
  return vim.fn.strdisplaywidth((s:gsub('`', ''):gsub('%*%*', '')))
end

--- Hard-wrap markdown `text` at `width` shown cells into `out`: list items
--- hang under their text, fenced blocks are kept as they are.
local function wrap_markdown(text, width, out)
  local wrap = require('diffy.panels.commitmsg').wrap
  local fenced = false
  for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
    local fence = l:match('^%s*```') or l:match('^%s*~~~')
    if fenced or fence then
      table.insert(out, l)
      fenced = fenced ~= (fence ~= nil)
    else
      local lead = l:match('^%s*[-*+]%s+') or l:match('^%s*%d+[.)]%s+') or l:match('^%s*')
      local wrapped = {}
      wrap(l:sub(#lead + 1), math.max(10, width - #lead), wrapped, shown_width)
      for i, w in ipairs(wrapped) do
        table.insert(out, (i == 1 and lead or (' '):rep(#lead)) .. w)
      end
    end
  end
end

--- What the float beside the column shows for the guide row under the
--- cursor: `{ key, lines, spans, width }` (markdown, `width` its widest
--- line once concealed), or nil.
function M.float_content(session, room)
  if not M.shown(session) then
    return nil
  end
  local row = row_at_cursor(session)
  local r = resolved(session)
  if not (row and row.si and r) then
    return nil
  end
  local sec = r.sections[row.si]
  local header = sec.unguided and sec.title or (row.si .. ' ' .. sec.title)
  local lines, spans = {}, {}
  wrap_markdown(header, room, lines)
  for l = 0, #lines - 1 do
    table.insert(spans, { l, 0, #lines[l + 1], 'DiffyLabel' })
  end
  local body = sec.unguided and 'Changes no section of the guide covers.' or vim.trim(sec.body)
  if body ~= '' then
    table.insert(lines, '')
    wrap_markdown(body, room, lines)
  end
  local it = row.kind == 'item' and sec.hunks[row.ii]
  if it then
    table.insert(lines, '')
    local where = it.path .. (it.git[1] and (':' .. (it.git[1].new_count > 0 and it.git[1].new_start or it.git[1].old_start)) or '')
    -- a code span: a path's underscores and asterisks aren't markup
    table.insert(lines, '`' .. where .. '`')
    table.insert(spans, { #lines - 1, 0, #where + 2, 'DiffyDirectory' })
    for _, note in ipairs(it.notes) do
      local first = #lines
      wrap_markdown(note.text, room, lines)
      for l = first, #lines - 1 do
        table.insert(spans, { l, 0, #lines[l + 1], 'DiffyGuideNote' })
      end
    end
  end
  local width = 1
  for _, l in ipairs(lines) do
    width = math.max(width, shown_width(l))
  end
  return { key = row.si .. ':' .. (row.ii or ''), lines = lines, spans = spans, width = width }
end

return M
