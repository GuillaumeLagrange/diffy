-- Left/right diff windows: fugitive blob/index
-- buffers or the real worktree file, native diff mode with scrollbind/
-- cursorbind, winbars, and the navigation keymaps shared by both windows.
local session_mod = require('diffy.session')
local nav_guarded = require('diffy.navigation').guarded

local M = {}

local function short(rev)
  if rev == 'WORKTREE' then
    return 'worktree'
  elseif rev == 'INDEX' then
    return 'index'
  elseif rev == 'HEAD' then
    return 'HEAD'
  end
  local sha, rest = rev:match('^(%x+)(.*)$')
  if sha and #sha > 7 then
    return sha:sub(1, 7) .. rest
  end
  return rev
end

local function fugitive_object(rev, path)
  if rev == 'INDEX' then
    return ':0:' .. path
  end
  return rev .. ':' .. path
end

local SIDES = { 'left', 'right' }

local function other_side(name)
  return name == 'left' and 'right' or 'left'
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function load_buf(name)
  local buf = vim.fn.bufadd(name)
  vim.fn.bufload(buf)
  return buf
end

--- Stop managing the real worktree buffer shown in window `name`, if any.
local function drop_real(session, name)
  local real = session.real_bufs and session.real_bufs[name]
  if real and vim.api.nvim_buf_is_valid(real) then
    session_mod.unmap_buffer(session, real)
  end
  if session.real_bufs then
    session.real_bufs[name] = nil
  end
end

--- The diff windows' buffer-local keys (`]f`, `]r`, panel keys, review keys).
function M.set_nav_keymaps(session, buf)
  local map = session_mod.map
  map(session, 'n', ']r', function()
    require('diffy.panels.log').move_selection(session, vim.v.count1)
  end, { buffer = buf, desc = 'next commit' })
  map(session, 'n', '[r', function()
    require('diffy.panels.log').move_selection(session, -vim.v.count1)
  end, { buffer = buf, desc = 'previous commit' })
  map(session, 'n', ']f', function()
    require('diffy.panels.tree').move_file(session, vim.v.count1)
  end, { buffer = buf, desc = 'next file' })
  map(session, 'n', '[f', function()
    require('diffy.panels.tree').move_file(session, -vim.v.count1)
  end, { buffer = buf, desc = 'previous file' })
  local mark_key = require('diffy').config.keymaps.toggle_viewed
  if mark_key and mark_key ~= '' then
    map(session, 'n', mark_key, function()
      require('diffy.panels.tree').toggle_viewed_current(session)
    end, { buffer = buf, desc = 'toggle viewed' })
  end
  local undo_key = require('diffy').config.keymaps.undo_viewed
  if undo_key and undo_key ~= '' then
    map(session, 'n', undo_key, function()
      require('diffy.panels.tree').undo_viewed(session)
    end, { buffer = buf, desc = 'undo viewed' })
  end
  local since_key = require('diffy').config.keymaps.viewed_diff
  if since_key and since_key ~= '' then
    map(session, 'n', since_key, function()
      require('diffy.panels.tree').viewed_diff_current(session)
    end, { buffer = buf, desc = 'diff since last viewed' })
  end
  for _, key in ipairs({ 'zo', 'zO', 'za', 'zA' }) do
    map(session, 'n', key, function()
      require('diffy.folds').open(key)
    end, { buffer = buf, desc = 'open fold around the change' })
  end
  require('diffy.layout').map_panel_keys(session, buf)
  require('diffy.review.ui').setup_diff_keymaps(session, buf)
end

--- Put `spec` (`{rev, path}` or `nil` for "no file on this side") into
--- window `name` ('left'|'right'): the real worktree file, a fugitive
--- index/blob buffer, or an empty placeholder.
local function open_side(session, name, spec)
  local win = session.wins[name]
  session.real_bufs = session.real_bufs or {}
  local prev_real = session.real_bufs[name]

  local buf, is_real
  if not spec or not spec.path then
    buf = session_mod.scratch_buf(session, name)
    is_real = false
  elseif spec.rev == 'WORKTREE' then
    buf = load_buf(session.root .. '/' .. spec.path)
    -- `bufadd` leaves it unlisted; list it like `:edit` so tools treat it as a file buffer
    vim.bo[buf].buflisted = true
    is_real = true
  else
    buf = load_buf(vim.fn.FugitiveFind(fugitive_object(spec.rev, spec.path), session.gitdir))
    is_real = false
  end

  if prev_real and prev_real ~= buf and vim.api.nvim_buf_is_valid(prev_real) then
    session_mod.unmap_buffer(session, prev_real)
  end

  nav_guarded(session, vim.api.nvim_win_set_buf, win, buf)

  if is_real then
    session.real_bufs[name] = buf
  else
    -- A blob is only unloaded when hidden: its number stays valid for
    -- diffchar.vim's BufWinEnter handler, which runs after the hide and
    -- still holds it, and for the jumplist/tag stack (`<C-o>`/`<C-t>` back).
    session_mod.register_buffer(session, name, buf, { bufhidden = spec and spec.path and 'delete' or nil })
    session.real_bufs[name] = nil
  end

  M.set_nav_keymaps(session, buf)

  vim.w[win].diffy_rev = spec and spec.rev or nil
  vim.w[win].diffy_path = spec and spec.path or nil
  vim.wo[win].winbar = (spec and spec.path) and ((spec.label or short(spec.rev)) .. '  ' .. spec.path) or '(no file)'
  vim.wo[win][0].foldtext = require('diffy.folds').FOLDTEXT
  -- Statuslines show the buffer name, a `fugitive://…/.git//<sha>/<path>` URI
  -- for blob sides: readable replacement, see `:help diffy-statusline`. Rev first:
  -- a narrow window truncates the left end.
  if spec and spec.path and not is_real then
    vim.b[buf].diffy_title = (spec.label or short(spec.rev)) .. ': ' .. spec.path
  end
end

--- Close diff window `name` for a one-sided file (added or deleted), until
--- `M.restore` brings it back. Unregistered first: closing a managed
--- window would end the session.
local function hide_side(session, name)
  local win = session.wins[name]
  if not valid_win(win) then
    return
  end
  drop_real(session, name)
  session_mod.unregister_window(session, name)
  session.hidden_side = name
  pcall(vim.api.nvim_win_close, win, true)
end

--- Bring back the diff window hidden for a one-sided file, beside the
--- other one, and split the width evenly again.
function M.restore(session)
  local name = session.hidden_side
  if not name then
    return
  end
  session.hidden_side = nil
  local other = session.wins[other_side(name)]
  local buf = session_mod.scratch_buf(session, name)
  session_mod.register_buffer(session, name, buf)
  local win = nav_guarded(session, vim.api.nvim_open_win, buf, false, { win = other, split = name })
  session_mod.register_window(session, name, win)
  require('diffy.layout').relayout(session)
end

-- The whole file on one side, coloured like its lines would be in a diff.
-- Drawn per line by a decoration provider, only in the session's window: a
-- range extmark would also show in every other window of the buffer (a
-- `:tab split`) as soon as a redraw starts below its first line, window-
-- scoped namespace or not (nvim's `decor_redraw_start` skips the scope).
local one_sided_ns = vim.api.nvim_create_namespace('diffy/one_sided')
local painting

vim.api.nvim_set_decoration_provider(one_sided_ns, {
  on_win = function(_, win, buf)
    for _, s in pairs(session_mod.sessions) do
      local o = s.one_sided
      if o and o.win == win and o.buf == buf and not s.closed then
        painting = o.group
        return true
      end
    end
    return false
  end,
  on_line = function(_, _, buf, row)
    -- under syntax: the background only. An ephemeral `line_hl_group` isn't drawn.
    vim.api.nvim_buf_set_extmark(buf, one_sided_ns, row, 0, {
      end_row = row + 1,
      hl_group = painting,
      hl_eol = true,
      priority = 10,
      ephemeral = true,
      strict = false,
    })
  end,
})

--- `value`: `{ win, buf, group }`, or nil for none.
local function set_one_sided(session, value)
  local old = session.one_sided
  session.one_sided = value
  for _, o in ipairs({ old or false, value or false }) do
    if o and valid_win(o.win) then
      vim.api.nvim__redraw({ win = o.win, valid = false, flush = false })
    end
  end
end

local function paint_one_sided(session, name, group)
  local win = session.wins[name]
  set_one_sided(session, { win = win, buf = vim.api.nvim_win_get_buf(win), group = group })
end

--- Scroll the left diff window to the right one's view by nvim's diff
--- alignment (`row(l) = l + Σ diff_filler(k)` for `k ≤ l`). `:syncbind`
--- compares line numbers, ignoring the filler.
local function align_left(session)
  local target = vim.api.nvim_win_call(session.wins.right, function()
    -- the view of a buffer just put in the window is only computed on use
    vim.fn.line('w0')
    local view = vim.fn.winsaveview()
    local row = view.topline
    for k = 1, view.topline do
      row = row + vim.fn.diff_filler(k)
    end
    return row - view.topfill
  end)
  vim.api.nvim_win_call(session.wins.left, function()
    local row = 0
    for l = 1, vim.fn.line('$') do
      local filler = vim.fn.diff_filler(l)
      row = row + filler + 1
      if row >= target then
        vim.fn.winrestview({ topline = l, topfill = math.min(filler, row - target) })
        return
      end
    end
  end)
end

--- Show `left_spec`/`right_spec` in the session's diff windows and put both
--- into native diff mode with scrollbind/cursorbind. An added or deleted
--- file (one spec `nil`) takes the whole diff area, coloured as added or
--- deleted; both `nil` clears both sides.
function M.show(session, left_spec, right_spec)
  -- Swap buffers with diff off: a window still in diff mode diffs the new
  -- buffer against the old pair mid-swap, and diff plugins' BufWinEnter
  -- handlers (diffchar.vim) error on the half-updated state. `!` also drops
  -- hidden buffers from the diff: a real file a jump swapped out while in
  -- diff mode stays diffed, marking every line of the new pair as changed.
  for _, name in ipairs(SIDES) do
    local win = session.wins[name]
    if valid_win(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd('diffoff!')
      end)
      break
    end
  end
  set_one_sided(session, nil)

  local one = (left_spec == nil) ~= (right_spec == nil) and (left_spec and 'left' or 'right') or nil
  if one then
    local other = other_side(one)
    if session.hidden_side ~= other then
      M.restore(session)
      hide_side(session, other)
    end
    open_side(session, one, one == 'left' and left_spec or right_spec)
    session_mod.unbind(session.wins[one])
    paint_one_sided(session, one, one == 'left' and 'DiffyFileDeleted' or 'DiffyFileAdded')
  else
    M.restore(session)
    open_side(session, 'left', left_spec)
    open_side(session, 'right', right_spec)
    for _, name in ipairs(SIDES) do
      local win = session.wins[name]
      vim.wo[win].scrollbind = true
      vim.wo[win].cursorbind = true
      vim.api.nvim_win_call(win, function()
        vim.cmd('diffthis')
      end)
    end
    -- The right window can come back to a file at the view it was left at
    -- (a real file remembers its cursor per window) while the left blob is
    -- fresh at the top: scrollbind only follows the next scroll.
    align_left(session)
  end

  require('diffy.review.ui').decorate(session)
end

--- No files in the current selection: clear both sides to placeholders.
function M.clear(session)
  M.show(session, nil, nil)
end

local OUTSIDE = '(outside diff)'

--- Leave diff mode because the right window navigated outside the current
--- file list: the right window keeps whatever buffer it now shows, alone
--- like a one-sided file, with only the column toggle of diffy's keys (the
--- column stays reachable with it hidden). Selecting a listed file again
--- (`M.show`) restores the pair.
function M.leave(session)
  local right = session.wins.right
  if not valid_win(right) then
    return
  end
  set_one_sided(session, nil)
  session_mod.unbind(right)
  require('diffy.review.ui').fit_gutter(right, nil)
  vim.api.nvim_win_call(right, function()
    pcall(vim.cmd, 'diffoff!')
  end)
  vim.w[right].diffy_rev = nil
  vim.w[right].diffy_path = nil
  vim.wo[right].winbar = OUTSIDE
  drop_real(session, 'right')
  hide_side(session, 'left')

  local buf = vim.api.nvim_win_get_buf(right)
  session.real_bufs = session.real_bufs or {}
  session.real_bufs.right = buf
  require('diffy.layout').map_toggle(session, buf)

  session.current_path = nil
  require('diffy.panels.tree').mark_current(session)
end

--- Follow edits to the files the pair shows: the review decorations move
--- with the text as it changes, and a write rebuilds like `R` (the tree's
--- counts and sections). The conflict view manages its own windows.
function M.track_edits(session)
  local function shown(buf)
    if session.conflict_active then
      return false
    end
    for _, name in ipairs(SIDES) do
      local win = session.wins[name]
      if valid_win(win) and vim.w[win].diffy_path and vim.api.nvim_win_get_buf(win) == buf then
        return true
      end
    end
    return false
  end
  -- TextChanged doesn't fire for what insert mode typed
  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = session.augroup,
    callback = function(args)
      if shown(args.buf) then
        require('diffy.review.ui').decorate(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = session.augroup,
    callback = function(args)
      if shown(args.buf) and session.refresh then
        session.refresh(session)
      end
    end,
  })
end

--- cursorbind puts the other window's cursor on the counterpart line, which
--- for a line in an added or deleted block is past the filler, possibly below
--- the window. Whatever validates that window's view next (`line('w0')` in
--- `win_execute`, as diffchar.vim does on WinScrolled) scrolls it to that
--- cursor and breaks the alignment. Keep the bound cursor inside the view.
function M.keep_bound_cursor_visible(session)
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = session.augroup,
    callback = function()
      local cur = vim.api.nvim_get_current_win()
      local name = (cur == session.wins.left and 'left') or (cur == session.wins.right and 'right')
      if not name or not vim.wo[cur].cursorbind then
        return
      end
      local other = session.wins[other_side(name)]
      if not valid_win(other) or not vim.wo[other].cursorbind then
        return
      end
      -- getwininfo computes botline from the current topline without scrolling
      local info = vim.fn.getwininfo(other)[1]
      local so = vim.wo[other].scrolloff
      if so < 0 then
        so = vim.go.scrolloff
      end
      so = math.min(so, math.floor((info.height - 1) / 2))
      local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(other))
      local top = info.topline + (info.topline > 1 and so or 0)
      local bottom = info.botline - (info.botline < last and so or 0)
      local pos = vim.api.nvim_win_get_cursor(other)
      local lnum = math.max(top, math.min(pos[1], bottom))
      if top <= bottom and lnum ~= pos[1] then
        vim.api.nvim_win_set_cursor(other, { lnum, pos[2] })
      end
    end,
  })
end

--- Toggling 'wrap' in one diff window applies it to the others: lines
--- wrapped on one side only would push its rows out of line with the other.
function M.sync_wrap(session)
  vim.api.nvim_create_autocmd('OptionSet', {
    group = session.augroup,
    pattern = 'wrap',
    callback = function()
      local cur = vim.api.nvim_get_current_win()
      if vim.v.option_command == 'setglobal' or not vim.wo[cur].diff then
        return
      end
      local wins = {}
      for _, win in pairs(session.wins) do
        wins[win] = true
      end
      if not wins[cur] then
        return
      end
      local wrap = vim.wo[cur].wrap
      for win in pairs(wins) do
        if win ~= cur and valid_win(win) and vim.wo[win].diff then
          vim.wo[win][0].wrap = wrap
        end
      end
    end,
  })
end

return M
