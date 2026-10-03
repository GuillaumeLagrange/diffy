-- The file tree and the commit log sharing one column window: one buffer,
-- the first view's rows, a rule line naming the second view, the second
-- view's rows. While both fit, blank virt_lines above the rule keep the
-- second view at the window's bottom (each grows toward the other); once
-- they don't, the window scrolls as a whole and "peek" floats over its
-- edges say what's off screen (the selected commits pinned when they are).
--
-- `session.stack = { names, buf, counts = {name -> rows} }`. The views
-- reach their rows through this module only: `set_lines`, `cursor`,
-- `set_cursor`, `lnum` work on a view's own 1-based rows, in the shared
-- buffer or in a buffer of its own (a float, a column window to itself).
local session_mod = require('diffy.session')
local hl = require('diffy.highlight')

local M = {}

-- rows the peek floats cover at most (rule + 2 rows + "… more"), kept
-- clear of the cursor with 'scrolloff'
M.PEEK_ROWS = 4

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function spec(name)
  return require('diffy.layout').spec(name)
end

--- The stack when `name` is one of its views, else nil.
local function stack_of(session, name)
  local st = session.stack
  if st and session.bufs[name] == st.buf and vim.tbl_contains(st.names, name) then
    return st
  end
end

function M.shared(session, name)
  return stack_of(session, name) ~= nil
end

local function win_of(session)
  return session.wins[session.stack.names[1]]
end

--- 0-based buffer line of `name`'s first row.
function M.offset(session, name)
  local st = stack_of(session, name)
  if not st or name == st.names[1] then
    return 0
  end
  return st.counts[st.names[1]] + 1
end

-- 1-based line of the rule
local function rule_lnum(st)
  return st.counts[st.names[1]] + 1
end

--- `name`'s rows as (0-based first line, count) in its buffer.
function M.range(session, name)
  local st = stack_of(session, name)
  if st then
    return M.offset(session, name), st.counts[name]
  end
  return 0, vim.api.nvim_buf_line_count(session.bufs[name])
end

--- Buffer line of `name`'s row `rel`.
function M.lnum(session, name, rel)
  return M.offset(session, name) + rel
end

--- The row of `name` under its window's cursor, nil when the cursor is
--- elsewhere (the other view's rows, the rule) or `name` isn't shown.
function M.cursor(session, name)
  local win = session.wins[name]
  if not valid(win) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local st = stack_of(session, name)
  if not st then
    return lnum
  end
  local rel = lnum - M.offset(session, name)
  if rel < 1 or rel > st.counts[name] then
    return nil
  end
  return rel
end

function M.set_cursor(session, name, rel)
  local win = session.wins[name]
  if valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { M.lnum(session, name, rel), 0 })
  end
end

--- The view whose rows hold the stack window's cursor ('rule' on the rule).
local function view_at_cursor(session)
  local st = session.stack
  local win = win_of(session)
  if not valid(win) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  if lnum == rule_lnum(st) then
    return 'rule'
  end
  return lnum < rule_lnum(st) and st.names[1] or st.names[2]
end

--- `── Label ───…` across `width` cells, and its highlight spans (byte columns: `─` is 3 bytes).
local function rule(label, width)
  local lead = '── '
  local head = lead .. label .. ' '
  local text = head .. ('─'):rep(math.max(0, width - vim.fn.strdisplaywidth(head)))
  local s, e = #lead, #lead + #label
  return text, { { 0, s, 'DiffyPanelRule' }, { s, e, 'DiffyLabel' }, { e, #text, 'DiffyPanelRule' } }
end

local function label(name)
  return vim.trim(spec(name).label)
end

local function draw_spans(buf, ns, row, spans)
  for _, sp in ipairs(spans) do
    if sp[2] > sp[1] then
      vim.api.nvim_buf_set_extmark(buf, ns, row, sp[1], { end_col = sp[2], hl_group = sp[3] })
    end
  end
end

-- ---------------------------------------------------------------------
-- peek floats

function M.close_peeks(session)
  session_mod.close_overlay(session, 'peek_above')
  session_mod.close_overlay(session, 'peek_below')
end

--- Show `lines` (`{ text, spans?, line_hl? }`) over the stack window's
--- rows from `row` (0-based), reusing the float when it's there.
local function place_peek(session, key, row, lines)
  local host = win_of(session)
  local cfg = {
    relative = 'win',
    win = host,
    row = row,
    col = 0,
    width = vim.api.nvim_win_get_width(host),
    height = #lines,
    style = 'minimal',
    -- the user's 'winborder' would frame it off the rows it covers
    border = 'none',
    focusable = false,
    zindex = 40,
  }
  local texts = {}
  for i, l in ipairs(lines) do
    texts[i] = l.text
  end
  local buf = session_mod.overlay(session, key, cfg, texts, 'NormalFloat:DiffyPeek')
  local ns = session_mod.namespace(session, 'stack_peek')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, l in ipairs(lines) do
    if l.line_hl then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = l.line_hl })
    end
    draw_spans(buf, ns, i - 1, l.spans or {})
  end
end

local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

--- What lies outside buffer lines `top..bot`: per side, how many of each
--- view's counted rows; and the side the pinned rows (the selection) are
--- on when none of them is in view.
local function hidden(session, top, bot)
  local st = session.stack
  local h = { above = {}, below = {} }
  local pinned_side, pinned_visible = nil, false
  for _, name in ipairs(st.names) do
    local peek = spec(name).peek
    if peek then
      h.above[name], h.below[name] = 0, 0
      local off = M.offset(session, name)
      for rel = 1, st.counts[name] do
        local lnum = off + rel
        local side = lnum < top and 'above' or lnum > bot and 'below' or nil
        if side and peek.counts(session, rel) then
          h[side][name] = h[side][name] + 1
        end
        if peek.pinned and peek.pinned(session, rel) then
          if side then
            pinned_side = pinned_side or { name = name, side = side }
          else
            pinned_visible = true
          end
        end
      end
    end
  end
  h.pinned = not pinned_visible and pinned_side or nil
  return h
end

--- `↑ 3 files, 6 commits` for `side`, nil when nothing is off that side.
local function counts_line(session, h, side)
  local parts = {}
  for _, name in ipairs(session.stack.names) do
    local n = h[side][name]
    if n and n > 0 then
      table.insert(parts, plural(n, spec(name).peek.noun))
    end
  end
  if #parts == 0 then
    return nil
  end
  return { text = (side == 'above' and '↑ ' or '↓ ') .. table.concat(parts, ', '), spans = { { 0, 3, 'DiffyThreadHint' } } }
end

--- The view's rule, then its pinned rows as drawn in the buffer (up to 2,
--- then `… n more`).
local function pinned_lines(session, name, width)
  local st = session.stack
  local text, spans = rule(label(name), width)
  local out = { { text = text, spans = spans } }
  local peek = spec(name).peek
  local rows = {}
  for rel = 1, st.counts[name] do
    if peek.pinned(session, rel) then
      table.insert(rows, rel)
    end
  end
  for i, rel in ipairs(rows) do
    if i == 3 and #rows > 3 then
      local more = ('  … %d more selected'):format(#rows - 2)
      table.insert(out, { text = more, spans = { { 0, #more, 'DiffyThreadHint' } } })
      break
    end
    local lnum = M.lnum(session, name, rel) - 1
    local line = { text = vim.api.nvim_buf_get_lines(st.buf, lnum, lnum + 1, false)[1] or '', spans = {} }
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, { lnum, 0 }, { lnum, -1 }, { details = true })) do
      local d = m[4]
      if d.line_hl_group then
        line.line_hl = d.line_hl_group
      elseif d.hl_group then
        table.insert(line.spans, { m[3], d.end_col or #line.text, d.hl_group })
      end
    end
    table.insert(out, line)
  end
  return out
end

--- Redraw the peek floats for the stack window's current view.
function M.peek(session)
  local st = session.stack
  local win = st and win_of(session)
  if not valid(win) then
    if st then
      M.close_peeks(session)
    end
    return
  end
  local top, bot = unpack(vim.api.nvim_win_call(win, function()
    return { vim.fn.line('w0'), vim.fn.line('w$') }
  end))
  local width = hl.panel_width(win, st.width)
  local function lines_for(h, side)
    if h.pinned and h.pinned.side == side then
      return pinned_lines(session, h.pinned.name, width)
    end
    local l = counts_line(session, h, side)
    return l and { l }
  end
  local h = hidden(session, top, bot)
  local above, below = lines_for(h, 'above'), lines_for(h, 'below')
  -- the floats cover rows: what they cover is off screen too
  if above or below then
    h = hidden(session, top + (above and #above or 0), bot - (below and #below or 0))
    above, below = lines_for(h, 'above'), lines_for(h, 'below')
  end
  local height = vim.fn.getwininfo(win)[1].height
  if above then
    place_peek(session, 'peek_above', 0, above)
  else
    session_mod.close_overlay(session, 'peek_above')
  end
  if below then
    place_peek(session, 'peek_below', height - #below, below)
  else
    session_mod.close_overlay(session, 'peek_below')
  end
end

local function schedule_peek(session)
  local st = session.stack
  if st.peek_pending then
    return
  end
  st.peek_pending = true
  vim.schedule(function()
    st.peek_pending = false
    if not session.closed then
      M.peek(session)
    end
  end)
end

-- ---------------------------------------------------------------------
-- layout of the buffer

--- Redraw the rule at the window's width and the gap above it: blank
--- virt_lines filling the rows the views leave free, so the second view
--- sits at the bottom. Then the peek floats.
function M.fit(session)
  local st = session.stack
  if not st or not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local win = win_of(session)
  local width = hl.panel_width(win, st.width)
  st.width = width
  local text, spans = rule(label(st.names[2]), width)
  local row = rule_lnum(st) - 1
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, row, row + 1, false, { text })
  vim.bo[st.buf].modifiable = false
  local ns = session_mod.namespace(session, 'stack')
  vim.api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
  draw_spans(st.buf, ns, row, spans)
  if not valid(win) then
    return
  end
  local gap = vim.fn.getwininfo(win)[1].height - vim.api.nvim_buf_line_count(st.buf)
  if gap > 0 then
    local virt = {}
    for i = 1, gap do
      virt[i] = { { '', '' } }
    end
    vim.api.nvim_buf_set_extmark(st.buf, ns, row, 0, { virt_lines = virt, virt_lines_above = true })
    -- everything fits: nothing to scroll past
    vim.api.nvim_win_call(win, function()
      if vim.fn.line('w0') > 1 then
        vim.fn.winrestview({ topline = 1 })
      end
    end)
  end
  schedule_peek(session)
end

--- Replace `name`'s rows with `lines`, wherever they live. A view's own
--- extmarks are its business; the other view's move with their lines.
function M.set_lines(session, name, lines)
  local buf = session.bufs[name]
  local st = stack_of(session, name)
  vim.bo[buf].modifiable = true
  if st then
    local off = M.offset(session, name)
    vim.api.nvim_buf_set_lines(buf, off, off + st.counts[name], false, lines)
    st.counts[name] = #lines
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  vim.bo[buf].modifiable = false
  if st then
    M.fit(session)
  end
end

--- Map `lhs` for view `name` on `opts.buffer`. On the shared buffer one
--- map serves both views: the handler of the view under the cursor, else
--- the other view's (`J` selects the next commit from the files too).
function M.map(session, name, modes, lhs, rhs, opts)
  local st = stack_of(session, name)
  if not (st and opts.buffer == st.buf) then
    session_mod.map(session, modes, lhs, rhs, opts)
    return
  end
  for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
    st.keys[mode] = st.keys[mode] or {}
    local handlers = st.keys[mode][lhs]
    local fresh = handlers == nil
    handlers = handlers or {}
    handlers[name] = rhs
    st.keys[mode][lhs] = handlers
    if fresh then
      session_mod.map(session, mode, lhs, function()
        local h = handlers[view_at_cursor(session)]
        for _, n in ipairs(st.names) do
          h = h or handlers[n]
        end
        return h()
      end, opts)
    end
  end
end

--- Put the cursor on view `name`'s anchor row (`spec.anchor`, else its first).
function M.jump(session, name)
  local st = session.stack
  local anchor = spec(name).anchor
  local rel = anchor and anchor(session) or 1
  if st.counts[name] == 0 then
    vim.api.nvim_win_set_cursor(win_of(session), { rule_lnum(st), 0 })
    return
  end
  M.set_cursor(session, name, math.max(1, math.min(rel, st.counts[name])))
end

--- Create the shared buffer for `names` (the column's tree and log, in
--- column order), register it under both and set both views up on it.
function M.create(session, names)
  local buf = session_mod.scratch_buf(session, 'panel')
  -- an empty first row holds the cursor: what the first view draws later
  -- replaces it, rather than pushing the cursor down into the second view
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', '' })
  session.stack = { names = names, buf = buf, counts = { [names[1]] = 1, [names[2]] = 0 }, keys = {} }
  for _, name in ipairs(names) do
    session_mod.register_buffer(session, name, buf, { panel = true })
  end
  vim.b[buf].miniindentscope_disable = true
  M.fit(session)
  local map = session_mod.map
  map(session, 'n', ']]', function()
    local here = view_at_cursor(session)
    if here == names[1] or here == 'rule' then
      M.jump(session, names[2])
    end
  end, { buffer = buf, desc = 'go to the ' .. label(names[2]):lower() })
  map(session, 'n', '[[', function()
    local here = view_at_cursor(session)
    if here == names[2] or here == 'rule' then
      M.jump(session, names[1])
    end
  end, { buffer = buf, desc = 'go to the ' .. label(names[1]):lower() })
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = session.augroup,
    callback = function()
      local win = win_of(session)
      if valid(win) and vim.v.event[tostring(win)] then
        schedule_peek(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      if valid(win_of(session)) then
        M.fit(session)
      end
    end,
  })
  for _, name in ipairs(names) do
    local s = spec(name)
    if s.setup then
      s.setup(session, buf)
    end
  end
  return buf
end

return M
