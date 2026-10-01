-- Where diffy's views are shown. A view (the file tree, the commit log, the
-- review threads) is a buffer diffy renders, reached as `session.bufs[name]`
-- and, while shown, `session.wins[name]`, whichever host shows it: the left
-- column stacks `session.column` (`config.column`), a float shows one view
-- in detail over the diff area. A view renders at its window's width and
-- asks `M.host` which of the two it's in.
--
-- A view module exposes `view = {
--   label               the column window's statusline
--   title(session)?     float title (default: label)
--   persistent?         the buffer lives as long as the session: created at
--                       open, wiping it ends the session
--   setup(session, buf)?  keys and buffer options, once per buffer
--   render(session)?    (re)draw into `session.bufs[name]`
--   height(session, room)?  rows wanted in the column; nil takes the rest
--   window(session, win)?   window options, each time it's shown
--   keys?               float footer hints `{ {key, label, drop = n} }`, or
--                       a function(session) returning them
--   preview(session, buf, win)?  float only: fill the pane beside the view
--                       for the row under the cursor
-- }`.
local session_mod = require('diffy.session')
local hl = require('diffy.highlight')

local M = {}

local MODULES = {
  tree = 'diffy.panels.tree',
  log = 'diffy.panels.log',
  threads = 'diffy.review.threads',
}

M.VIEWS = vim.tbl_keys(MODULES)
table.sort(M.VIEWS)

function M.spec(name)
  return require(MODULES[name]).view
end

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function panel_width()
  return require('diffy').config.panel_width
end

--- `config.column` without the names diffy doesn't know (with a warning).
function M.column_views()
  local out = {}
  for _, name in ipairs(require('diffy').config.column) do
    if MODULES[name] then
      table.insert(out, name)
    else
      vim.notify(('diffy: unknown view %q in config.column'):format(name), vim.log.levels.WARN)
    end
  end
  return out
end

--- `name`'s buffer, created and set up on first use. A view that isn't
--- persistent gets a new one each time it's shown after its last window
--- closed.
function M.buffer(session, name)
  local buf = session.bufs[name]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  local spec = M.spec(name)
  buf = session_mod.scratch_buf(session, name)
  session_mod.register_buffer(session, name, buf, { panel = spec.persistent })
  -- indentation is layout, not code scope (mini.indentscope)
  vim.b[buf].miniindentscope_disable = true
  if not spec.persistent then
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = session.augroup,
      buffer = buf,
      once = true,
      callback = function()
        if session.bufs[name] == buf then
          session.bufs[name] = nil
        end
      end,
    })
  end
  if spec.setup then
    spec.setup(session, buf)
  end
  return buf
end

--- 'float' or 'column': where `name` is shown (nil when it isn't).
function M.host(session, name)
  if session.floats and session.floats[name] then
    return 'float'
  end
  return valid(session.wins[name]) and 'column' or nil
end

--- Draw `name` again if it's shown anywhere.
function M.refresh(session, name)
  if not M.host(session, name) then
    return
  end
  local spec = M.spec(name)
  if spec.render then
    spec.render(session)
  end
  local f = session.floats and session.floats[name]
  if f and f.preview and spec.preview then
    spec.preview(session, f.preview_buf, f.preview)
  end
end

-- ---------------------------------------------------------------------
-- the column

--- Window-local look of a column window: nothing but the rows.
local function column_window(session, win, name)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.statuscolumn = ''
  wo.wrap = false
  wo.list = false
  wo.colorcolumn = ''
  wo.spell = false
  wo.cursorline = true
  wo.winfixwidth = true
  local spec = M.spec(name)
  wo.statusline = spec.label
  if spec.window then
    spec.window(session, win)
  end
end

--- Split the column off the left edge of the tab, one window per view, top
--- to bottom; returns name -> window.
local function open_column_windows(session)
  local wins, prev = {}, nil
  for _, name in ipairs(session.column) do
    local buf = M.buffer(session, name)
    if prev then
      prev = vim.api.nvim_open_win(buf, false, { win = prev, split = 'below' })
    else
      prev = vim.api.nvim_open_win(buf, false, { win = -1, split = 'left', width = panel_width() })
    end
    wins[name] = prev
  end
  return wins
end

local function place_floats(session)
  for name in pairs(session.floats or {}) do
    M.place_float(session, name)
  end
end

--- Reset window sizes: the fixed-width column (each view's `height`, the
--- others sharing the rest), the diff area split evenly over what's left
--- (the full width while the column is hidden), floats over it. Called on
--- open, on `R`, on `VimResized` and on toggling the column.
function M.relayout(session)
  local w = session.wins
  local top = w[session.column[1]]
  local shown = valid(top)
  if not shown and not session.panel_hidden then
    return
  end
  local width = panel_width()
  if shown then
    vim.api.nvim_win_set_width(top, width)
  end
  local left, right = w.left, w.right
  if valid(left) and valid(right) then
    -- only the side-by-side pair; the conflict layout sizes its own windows
    if vim.fn.win_screenpos(left)[1] == vim.fn.win_screenpos(right)[1] then
      local diff_width = vim.o.columns - (shown and (width + 1) or 0)
      vim.api.nvim_win_set_width(left, math.floor((diff_width - 1) / 2))
    end
  end
  if shown then
    local room = 0
    for _, name in ipairs(session.column) do
      if valid(w[name]) then
        room = room + vim.api.nvim_win_get_height(w[name])
      end
    end
    -- sized views keep their height while the next one is sized, so only
    -- the views without one give up rows
    for _, name in ipairs(session.column) do
      local spec = M.spec(name)
      local want = spec.height and spec.height(session, room)
      if want and valid(w[name]) then
        vim.wo[w[name]].winfixheight = false
        vim.api.nvim_win_set_height(w[name], want)
        vim.wo[w[name]].winfixheight = true
      end
    end
  end
  place_floats(session)
end

--- Open the column for a new session.
function M.open_column(session)
  local wins = open_column_windows(session)
  for _, name in ipairs(session.column) do
    session_mod.register_window(session, name, wins[name])
    column_window(session, wins[name], name)
  end
  M.relayout(session)
end

--- Hide the column without ending the session: the windows' teardown
--- watchers are dropped first and the buffers kept (`bufhidden=hide`) so
--- they come back unchanged.
local function hide_column(session)
  if session.panel_hidden then
    return
  end
  session._panel_cursor = {}
  local to_close = {}
  for _, name in ipairs(session.column) do
    local win = session.wins[name]
    if valid(win) then
      session._panel_cursor[name] = vim.api.nvim_win_get_cursor(win)
      session_mod.unwatch_window(session, name)
      vim.bo[session.bufs[name]].bufhidden = 'hide'
      table.insert(to_close, win)
    end
  end
  session.panel_hidden = true
  for _, win in ipairs(to_close) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  M.relayout(session)
end

--- Re-open the column with the same buffers and cursors.
local function show_column(session)
  if not session.panel_hidden then
    return
  end
  session._nav_guard = (session._nav_guard or 0) + 1
  local wins = open_column_windows(session)
  session._nav_guard = session._nav_guard - 1
  for _, name in ipairs(session.column) do
    local win = wins[name]
    vim.bo[session.bufs[name]].bufhidden = 'wipe'
    session_mod.register_window(session, name, win)
    column_window(session, win, name)
    local cur = session._panel_cursor and session._panel_cursor[name]
    if cur then
      pcall(vim.api.nvim_win_set_cursor, win, cur)
    end
  end
  session.panel_hidden = false
  M.relayout(session)
  for _, name in ipairs(session.column) do
    local spec = M.spec(name)
    if spec.render then
      spec.render(session)
    end
  end
end

--- Hide the column, leaving the cursor where it is; or show it and put the
--- cursor in the file tree (else the column's first view).
function M.toggle_column(session)
  if not session.panel_hidden then
    hide_column(session)
    return
  end
  show_column(session)
  local win = session.wins.tree
  if not (vim.tbl_contains(session.column, 'tree') and valid(win)) then
    win = session.wins[session.column[1]]
  end
  if valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

--- The buffer-local column toggle (`config.keymaps.toggle_panel`) on `buf`.
function M.map_toggle(session, buf)
  local key = require('diffy').config.keymaps.toggle_panel
  if key and key ~= '' then
    session_mod.map(session, 'n', key, function()
      M.toggle_column(session)
    end, { buffer = buf, nowait = true, desc = 'toggle panels' })
  end
end

--- The keys every diffy buffer but the threads view has: `R` rebuilds, and
--- the column toggle (`map_toggle`).
function M.map_panel_keys(session, buf)
  session_mod.map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
  M.map_toggle(session, buf)
end

--- Config of an editor-relative float of `width` x `height` (text cells)
--- centred on the screen; `extra` is merged in.
function M.centered(width, height, extra)
  return vim.tbl_extend('force', {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  }, extra or {})
end

-- ---------------------------------------------------------------------
-- floats

-- the list's share of the width when the view has a preview pane
local LIST_SHARE = 0.55
local LIST_MIN_WIDTH = 40

--- Screen area of the diff windows (right of the column), 0-based.
local function diff_area(session)
  local row, col = 1, 0
  local height = vim.o.lines - vim.o.cmdheight - 2
  local anchor
  for _, name in ipairs({ 'left', 'right' }) do
    local win = session.wins[name]
    if valid(win) and not anchor then
      anchor = win
    end
  end
  if anchor then
    local pos = vim.fn.win_screenpos(anchor)
    row, col = pos[1] - 1, pos[2] - 1
    height = vim.api.nvim_win_get_height(anchor)
  end
  return { row = row, col = col, width = vim.o.columns - col, height = height }
end

--- Window configs of `name`'s float and its preview pane (nil without one).
local function float_configs(session, name)
  local spec = M.spec(name)
  local a = diff_area(session)
  -- a column of margin on each side, then the frames
  local inner = math.max(20, a.width - 2)
  local height = math.max(3, a.height - 2)
  local title = spec.title and spec.title(session) or spec.label
  local base = {
    relative = 'editor',
    row = a.row,
    col = a.col + 1,
    height = height,
    style = 'minimal',
    border = 'rounded',
    zindex = 45,
  }
  local keys = type(spec.keys) == 'function' and spec.keys(session) or vim.deepcopy(spec.keys or {})
  table.insert(keys, { 'q', 'close' })
  if not spec.preview or inner - 4 < LIST_MIN_WIDTH * 2 then
    return vim.tbl_extend('force', base, {
      width = inner - 2,
      title = { { ' ' .. vim.trim(title) .. ' ', 'DiffyThreadHeader' } },
      footer = hl.key_hints(keys, inner - 2),
    })
  end
  local list_w = math.max(LIST_MIN_WIDTH, math.floor((inner - 4) * LIST_SHARE))
  local main = vim.tbl_extend('force', base, {
    width = list_w,
    title = { { ' ' .. vim.trim(title) .. ' ', 'DiffyThreadHeader' } },
    footer = hl.key_hints(keys, list_w),
  })
  local preview = vim.tbl_extend('force', base, {
    col = a.col + 1 + list_w + 2,
    width = inner - 4 - list_w,
    focusable = false,
  })
  return main, preview
end

--- A float's own look: the card background and frame, never bound to the
--- diff it was opened from (a new window copies `diff` from the current one).
local function float_window(win)
  session_mod.unbind(win)
  vim.wo[win].diff = false
  vim.wo[win].winhighlight = hl.CARD_HL
  vim.wo[win].fillchars = 'eob: '
end

--- Move `name`'s float (and its preview) back over the diff area, keeping
--- the title and footer current.
function M.place_float(session, name)
  local f = session.floats and session.floats[name]
  if not (f and valid(f.win)) then
    return
  end
  local main, preview = float_configs(session, name)
  vim.api.nvim_win_set_config(f.win, main)
  if f.preview and valid(f.preview) then
    if preview then
      vim.api.nvim_win_set_config(f.preview, preview)
    else
      pcall(vim.api.nvim_win_close, f.preview, true)
    end
  end
end

--- Close `name`'s float and its preview; the view's buffer goes too unless
--- it's persistent.
function M.close_float(session, name)
  local f = session.floats and session.floats[name]
  if not f then
    return
  end
  session.floats[name] = nil
  local spec = M.spec(name)
  local buf = session.bufs[name]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    for _, lhs in ipairs({ 'q', '<Esc>' }) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
  end
  session_mod.unregister_window(session, name)
  session_mod.unregister_window(session, name .. '_preview')
  for _, win in ipairs({ f.preview, f.win }) do
    if valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if spec.persistent and buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].bufhidden = 'wipe'
  end
end

local function open_float(session, name)
  local spec = M.spec(name)
  local buf = M.buffer(session, name)
  if spec.persistent then
    vim.bo[buf].bufhidden = 'hide'
  end
  session.floats = session.floats or {}
  local main, preview_cfg = float_configs(session, name)
  local win = vim.api.nvim_open_win(buf, true, main)
  float_window(win)
  vim.wo[win].cursorline = true
  -- the card background is CursorLine's: the cursor row needs another
  vim.wo[win].winhighlight = hl.CARD_HL .. ',CursorLine:Visual'
  vim.wo[win].wrap = false
  local f = { win = win }
  session.floats[name] = f
  session_mod.register_window(session, name, win, { transient = true })
  if spec.window then
    spec.window(session, win)
  end
  if preview_cfg then
    f.preview_buf = session_mod.scratch_buf(session, name .. '_preview')
    session_mod.register_buffer(session, name .. '_preview', f.preview_buf)
    f.preview = vim.api.nvim_open_win(f.preview_buf, false, preview_cfg)
    float_window(f.preview)
    session_mod.register_window(session, name .. '_preview', f.preview, { transient = true })
  end

  local function close()
    if session.floats[name] == f then
      M.close_float(session, name)
    end
  end
  session_mod.map(session, 'n', 'q', close, { buffer = buf, nowait = true, desc = 'close' })
  session_mod.map(session, 'n', '<Esc>', close, { buffer = buf, nowait = true, desc = 'close' })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  -- like a picker: going anywhere else closes it
  vim.api.nvim_create_autocmd('WinLeave', {
    group = session.augroup,
    buffer = buf,
    callback = function()
      if session.floats[name] ~= f then
        return true
      end
      vim.schedule(function()
        if vim.api.nvim_get_current_win() ~= win then
          close()
        end
      end)
    end,
  })
  if f.preview then
    vim.api.nvim_create_autocmd('CursorMoved', {
      group = session.augroup,
      buffer = buf,
      callback = function()
        if session.floats[name] ~= f then
          return true
        end
        spec.preview(session, f.preview_buf, f.preview)
      end,
    })
  end
  M.refresh(session, name)
end

--- Show view `name`: in the column when it's one of the column's views
--- (showing the column first if hidden), else in a float over the diff
--- area; either way the cursor goes into it.
function M.show(session, name)
  if vim.tbl_contains(session.column, name) then
    show_column(session)
    M.refresh(session, name)
  elseif not (session.floats and session.floats[name]) then
    open_float(session, name)
  else
    M.refresh(session, name)
  end
  local win = session.wins[name]
  if valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

return M
