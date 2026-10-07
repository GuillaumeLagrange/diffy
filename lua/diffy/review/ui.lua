-- Review UI shared by every backend: range bars + summaries, the thread
-- float (`K`/`<CR>`), the compose float (`gc`), `]t`/`[t`, the display
-- toggles (`<leader>dt`/`ds`/`dr`), `gP` and the jump used by
-- `:Diffy threads`.
--
-- A backend exposes `name`, `capabilities = {resolve, suggestions, people}`,
-- `author(root)`, optionally `avatar_url(login)`,
-- `place(session, thread) -> nil | {win, start_line, end_line}` (in the open
-- file), `view_place(session, thread, pair?)` (any file of a pair), and for
-- authoring `save(session, thread, comment?)` (`gc`, `r`, `x` are no-ops
-- without it) and `clear(session, cb)`.
-- Drafts live in the branch's one store (`review/drafts.lua`).
--
-- `session.review`: nil until `M.ensure` runs, `false` if the range kind
-- doesn't support review, else
--   { backend, branch, threads: Thread[], inline (`<leader>dt`),
--     summaries (`<leader>ds`), hide_resolved (`<leader>dr`),
--     pr (GitHub only, `gP`'s source), merge_base (GitHub), _track
--     (`review/track.lua`'s diffs) }
local session_mod = require('diffy.session')
local model = require('diffy.review.model')
local run = require('diffy.git.run')
local highlight = require('diffy.highlight')
local avatar = require('diffy.avatar')
local layout = require('diffy.layout')
local render = require('diffy.review.render')

local M = {}

--- A scratch buffer named `diffy://<id>/<kind>/<n>`, registered with the session.
local function scratch_buf(session, kind, buftype, filetype)
  local buf = session_mod.scratch_buf(session, kind)
  vim.bo[buf].buftype = buftype
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  session_mod.register_buffer(session, kind .. '_' .. buf, buf)
  return buf
end

local function review_available(session)
  local kind = session.range and session.range.kind
  return kind == 'default' or kind == 'branch'
end

--- Lazily load the branch's stored threads for `session`. Returns the
--- `session.review` table, or nil if review isn't available for this
--- session's range kind. The backend is the local one until the GitHub
--- layer attaches (`review/github.lua`), which adds the published threads.
function M.ensure(session)
  if session.review ~= nil then
    return session.review or nil
  end
  if not review_available(session) then
    session.review = false
    return nil
  end
  local backend = require('diffy.review.local')
  session.review = {
    backend = backend,
    branch = session.branch,
    threads = {},
    inline = true,
    summaries = true,
  }
  local drafts = require('diffy.review.drafts')
  drafts.apply(session.review.threads, drafts.attach(session).threads)
  if backend.sync then
    backend.sync(session)
  end
  return session.review
end

--- Redraw once what placing the threads needs is fetched; the PR row too,
--- which counts sync conflicts.
function M.redraw(session)
  require('diffy.review.track').prepare(session, function()
    if session.layer and session.layer.attached then
      require('diffy.panels.log').apply_layer(session)
    end
    M.decorate(session)
  end)
end

function M.side_of(session, win)
  if win == session.wins.left then
    return 'left'
  elseif win == session.wins.right then
    return 'right'
  end
  return nil
end

-- row(l) = l + Σ diff_filler(k) for k ≤ l; equal rows in the two windows are
-- counterpart lines. Returns `win`'s line -> row and row -> line maps.
local function row_map(win)
  return vim.api.nvim_win_call(win, function()
    local row, line, filler = {}, {}, 0
    for l = 1, vim.api.nvim_buf_line_count(0) do
      filler = filler + vim.fn.diff_filler(l)
      row[l] = l + filler
      line[l + filler] = l
    end
    return { row = row, line = line }
  end)
end

--- The short states a summary carries: a sync conflict, a draft GitHub
--- can't take, staged changes.
local function summary_badges(thread)
  local out, seen = {}, {}
  local function add(text, hl)
    if not seen[text] then
      seen[text] = true
      table.insert(out, { text, hl })
    end
  end
  for _, c in ipairs(thread.comments) do
    if c.conflict or c.staged_conflict then
      add('conflict', 'DiffyThreadConflict')
    elseif c.state == 'draft' and c.blocked and not c.gh then
      add('local only', 'DiffyThreadDraft')
    elseif c.staged_delete then
      add('deletion staged', 'DiffyThreadStaged')
    elseif c.staged_body then
      add('edit staged', 'DiffyThreadStaged')
    end
  end
  for _, b in ipairs(model.thread_badges(thread)) do
    add(b[1], b[2])
  end
  return out
end

--- One summary line: `● author +N: first line of the comment`, the dot in
--- the thread's lane colour, cut to `width` so threads on the same line can
--- be told apart. A resolved one reads `✓ author +N: …`, dimmed. `mode`
--- (see `paint`): 'open' draws the whole line bold in the lane colour,
--- 'near' in the lane colour.
local function summary_chunks(thread, width, mode, url)
  local first = thread.comments[1]
  local head = (first and first.author or 'unknown') .. (#thread.comments > 1 and (' +%d'):format(#thread.comments - 1) or '')
  local icon = thread.resolved and '✓' or '●'
  local text_hl = thread.resolved and 'DiffyThreadSummaryResolved' or 'DiffyThreadSummary'
  local icon_hl = thread.resolved and 'DiffyThreadResolved' or highlight.lane(thread.id)
  local hl, dot_hl
  if mode == 'open' then
    -- DiffyThreadCurrent only adds the weight; the colour stays the lane's
    hl, dot_hl = { thread.resolved and text_hl or icon_hl, 'DiffyThreadCurrent' }, { 'DiffyThreadCurrent', icon_hl }
  elseif mode == 'near' then
    hl = thread.resolved and text_hl or icon_hl
  end
  local chunks = { { icon .. ' ', dot_hl or icon_hl } }
  local slot = url ~= nil and avatar.ready(url)
  if slot then
    -- placed over by `draw_summary_avatars`, two cells in from the text start
    table.insert(chunks, { '   ', 'Normal' })
  end
  table.insert(chunks, { head, hl or text_hl })
  local marks = ''
  for _, b in ipairs(summary_badges(thread)) do
    table.insert(chunks, { ' ' .. b[1], b[2] })
    marks = marks .. ' ' .. b[1]
  end
  local line = first and vim.split(first.body or '', '\n', { plain = true })[1] or ''
  local room = width - vim.fn.strdisplaywidth(icon .. ' ' .. head .. marks) - 2 - (slot and 3 or 0)
  if line ~= '' and room >= 8 then
    table.insert(chunks, { ': ' .. highlight.truncate(line, room), hl or (thread.resolved and text_hl or 'Comment') })
  end
  return chunks, slot
end

--- The current window, or the diff window under it when it's the thread
--- float; second result: whether it's the float.
local function source_win(session)
  local win = vim.api.nvim_get_current_win()
  local open = session.review and session.review._open
  if open and win == open.float then
    return open.src, true
  end
  return win, false
end

--- Threads covering the cursor line of the current window, if it's a diff
--- window: the "relevant" ones whose summaries stand out.
local function relevant_threads(session)
  local win = source_win(session)
  if not M.side_of(session, win) then
    return {}
  end
  return M.threads_at(session, win, vim.api.nvim_win_get_cursor(win)[1])
end

-- Range bars are drawn by 'statuscolumn', not signs: it also runs for
-- virt_lines and diff filler rows, so a bar goes on through the summaries
-- and fillers inside its range and down to its own summary.
-- `gutters[win]` = { buf, width (lanes), threads (placed in `win`, `_lane`
-- set), rows (line -> diffy virt_lines under it), pos (thread -> its
-- summary's row under its last line), lit (thread -> 'open' | 'near') }.
local gutters = {}
local STATUSCOLUMN = "%C%s%=%l %{%v:lua.require'diffy.review.ui'.statuscolumn()%}"
-- only the open thread's bar is heavy; each bar ends on its summary row
local BAR = { open = '┃', off = '│' }
local BAR_END = { open = '┗', off = '╰' }
-- a bar ending runs right to its summary, across the bars still going on
local ACROSS = { open = '━', off = '─' }
-- CROSS[going bar][ending bar]
local CROSS = {
  off = { off = '┼', open = '┿' },
  open = { off = '╂', open = '╋' },
}

local function weight(g, thread)
  return g.lit[thread] == 'open' and 'open' or 'off'
end

local function lane_hl(thread)
  return thread.resolved and 'DiffyThreadSummaryResolved' or highlight.lane(thread.id)
end

local function cell(thread, ch)
  return ('%%#%s#%s'):format(lane_hl(thread), ch)
end

--- 'statuscolumn' item of diff windows with threads: the range bars of
--- the row being drawn, one cell per lane, then a space (a line to the
--- summary on a thread's summary row).
function M.statuscolumn()
  -- %{} items run with the drawn window current
  local win = vim.api.nvim_get_current_win()
  local g = gutters[win]
  if not g or vim.api.nvim_win_get_buf(win) ~= g.buf then
    return ''
  end
  local l, v = vim.v.lnum, vim.v.virtnum
  -- virtual rows under `l`, top to bottom: diffy's virt_lines, then filler
  local k = v < 0 and (g.rows[l] or 0) + vim.fn.diff_filler(l + 1) + v + 1
  local going, ending = {}, nil
  for _, t in ipairs(g.threads) do
    local s, e = t._place.start_line, t._place.end_line
    if s <= l and (l < e or (l == e and (v >= 0 or (g.pos[t] and k < g.pos[t])))) then
      going[t._lane] = t
    elseif l == e and g.pos[t] == k then
      ending = t
    end
  end
  local across = ending and ACROSS[weight(g, ending)]
  local cells = {}
  for i = 1, g.width do
    local t = going[i]
    if ending and i == ending._lane then
      cells[i] = cell(ending, BAR_END[weight(g, ending)])
    elseif ending and i > ending._lane then
      cells[i] = t and cell(t, CROSS[weight(g, t)][weight(g, ending)]) or cell(ending, across)
    else
      cells[i] = t and cell(t, BAR[weight(g, t)]) or ' '
    end
  end
  return table.concat(cells) .. (ending and cell(ending, across) .. '%*' or '%* ')
end

--- The order `]t`/`[t` walk threads and lanes are handed out in: by first
--- line, then the larger range first (it's drawn left of the ones it
--- contains), then oldest first. The id makes it total: two threads can
--- start in the same second.
local function by_start(a, b)
  local pa, pb = a._place, b._place
  if pa.start_line ~= pb.start_line then
    return pa.start_line < pb.start_line
  end
  if pa.end_line ~= pb.end_line then
    return pa.end_line > pb.end_line
  end
  local sa, sb = model.started(a), model.started(b)
  if sa ~= sb then
    return sa < sb
  end
  return tostring(a.id) < tostring(b.id)
end

--- Give each of one window's placed `threads` a lane (`t._lane`), a
--- column of its own, so overlapping ranges draw side by side, handed out
--- in `by_start` order to the leftmost free lane. Returns the number of
--- lanes.
local function assign_lanes(threads)
  local order = vim.list_slice(threads)
  table.sort(order, by_start)
  local ends = {}
  for _, t in ipairs(order) do
    local lane = 1
    while ends[lane] and ends[lane] >= t._place.start_line do
      lane = lane + 1
    end
    ends[lane] = t._place.end_line
    t._lane = lane
  end
  return #ends
end

--- Draw `g`'s range bars in `win` (see `gutters`), or, with nil, put
--- back the 'statuscolumn' diffy found (kept in `w:diffy_statuscolumn`).
function M.fit_gutter(win, g)
  for w in pairs(gutters) do
    if not vim.api.nvim_win_is_valid(w) then
      gutters[w] = nil
    end
  end
  gutters[win] = g
  local saved = vim.w[win].diffy_statuscolumn
  if g then
    if saved == nil then
      vim.w[win].diffy_statuscolumn = vim.wo[win].statuscolumn
    end
    -- set even if unchanged: the column only shrinks when the option is set
    vim.api.nvim_set_option_value('statuscolumn', STATUSCOLUMN, { win = win, scope = 'local' })
  elseif saved ~= nil then
    vim.api.nvim_set_option_value('statuscolumn', saved, { win = win, scope = 'local' })
    vim.w[win].diffy_statuscolumn = nil
  end
end

local schedule_avatars, track_avatars

--- (Re)draw the summary virt_lines recorded by `M.decorate`, highlighting
--- the open thread and the others covering the cursor line, and thicken
--- the open thread's bar. Skipped when that highlighting is unchanged (most
--- cursor moves) unless `force` (new avatars to slot in).
local function paint(session, force)
  local review = session.review
  if not (review and review._draw) then
    return
  end
  local ns = session_mod.namespace(session, 'review')
  local relevant, key = {}, {}
  for _, t in ipairs(relevant_threads(session)) do
    relevant[t] = true
    key[#key + 1] = t.id
  end
  local open = review._open and review._open.thread
  -- on a one-sided file the float sits in the commented window itself, and
  -- the open thread's summary, wider than it, would show past its right
  -- edge: blank it (keeping its row, so nothing moves) while it's open
  local covered
  local o = review._open
  if o and vim.api.nvim_win_is_valid(o.float) and vim.api.nvim_win_is_valid(o.src)
    and vim.api.nvim_win_get_config(o.float).win == o.src then
    covered = vim.api.nvim_win_get_buf(o.src)
  end
  key = ('%s|%s|%s'):format(open and open.id or '', covered or '', table.concat(key, ','))
  if not force and review._painted == key then
    return
  end
  review._painted = key
  for _, d in ipairs(review._draw) do
    if vim.api.nvim_buf_is_valid(d.buf) then
      local vlines = {}
      d.slots = {}
      for i, t in ipairs(d.threads) do
        local mode = (t == open and 'open') or (relevant[t] and 'near') or nil
        if d.buf == covered and t == open then
          table.insert(vlines, { { '', 'Normal' } })
        else
          local first = t.comments[1]
          local url = first and first.author and review.backend.avatar_url and review.backend.avatar_url(first.author) or nil
          local chunks, slot = summary_chunks(t, d.width, mode, url)
          d.slots[i] = slot and url or nil
          table.insert(vlines, chunks)
        end
      end
      for _ = #vlines + 1, d.n do
        table.insert(vlines, { { '', 'Normal' } })
      end
      -- the buffer may have changed since `M.decorate` (a worktree edit or
      -- `:e`): hang the summaries where their extmark moved, within the buffer
      if d.id then
        local pos = vim.api.nvim_buf_get_extmark_by_id(d.buf, ns, d.id, {})
        if pos[1] then
          d.line = pos[1] + 1
        end
      end
      d.line = math.min(d.line, vim.api.nvim_buf_line_count(d.buf))
      d.id = vim.api.nvim_buf_set_extmark(d.buf, ns, d.line - 1, 0, { id = d.id, virt_lines = vlines })
    end
  end
  for win, g in pairs(gutters) do
    if vim.api.nvim_win_is_valid(win) and M.side_of(session, win) then
      local lit, changed = {}, false
      for _, t in ipairs(g.threads) do
        lit[t] = (t == open and 'open') or (relevant[t] and 'near') or nil
        changed = changed or lit[t] ~= g.lit[t]
      end
      if changed then
        g.lit = lit
        vim.api.nvim__redraw({ win = win, statuscolumn = true })
      end
    end
  end
end

--- Open any closed fold covering `lnum` in `win`: a thread placed on an
--- unchanged line (inside a diff fold) must stay visible, as github.com
--- adds a context hunk for it.
local function open_fold_if_closed(win, lnum)
  vim.api.nvim_win_call(win, function()
    if vim.fn.foldclosed(lnum) ~= -1 then
      vim.cmd(('%dfoldopen!'):format(lnum))
    end
  end)
end

--- The order threads are drawn in and `]t` walks, top to bottom: by the
--- line their summary hangs under (the range's last), then oldest first.
--- Total, so ties can't come out in a different order each time.
local function by_place(a, b)
  if a._place.end_line ~= b._place.end_line then
    return a._place.end_line < b._place.end_line
  end
  local sa, sb = model.started(a), model.started(b)
  if sa ~= sb then
    return sa < sb
  end
  if a._place.start_line ~= b._place.start_line then
    return a._place.start_line < b._place.start_line
  end
  return tostring(a.id) < tostring(b.id)
end

-- a card's widest; narrower windows take their text width
local CARD_WIDTH = 100

--- Float config over the diff window opposite `src_win`, its top level with
--- line `first`'s screen row, so the commented code stays in view. `height`
--- text rows plus `edges` title/footer rows are kept inside that window.
--- At most `CARD_WIDTH` wide, centred over the window's text. With no
--- other diff window (a one-sided file), in `src_win` right under lines
--- `first`..`last`, over their summaries, or above them when that fits
--- better, its left frame on `thread`'s range bar in the status column
--- (the first lane without a thread).
local function beside(session, src_win, first, last, height, edges, thread)
  local other = src_win == session.wins.left and session.wins.right
    or src_win == session.wins.right and session.wins.left
    or nil
  local target = other and vim.api.nvim_win_is_valid(other) and other or src_win
  -- setting 'statuscolumn' (`M.fit_gutter`) leaves the width it takes at 0 until drawn
  vim.api.nvim__redraw({ win = target, flush = true })
  -- getwininfo's height leaves out the winbar, nvim_win_get_height doesn't
  local info = vim.fn.getwininfo(target)[1]
  local h = info.height
  local text_width = highlight.text_width(target)
  -- the frame takes a column on each side
  local width = math.max(10, math.min(CARD_WIDTH, text_width - 2))
  local margin = math.max(0, math.floor((text_width - width - 2) / 2))
  if target == other then
    height = math.max(1, math.min(height, h - edges))
    local pos = vim.fn.screenpos(src_win, first, 1)
    -- window rows, not `bufpos` at w0: the top may be filler rows above w0
    local row = pos.row > 0 and pos.row - info.winrow - info.winbar or 0
    return { relative = 'win', win = target, row = math.max(0, math.min(row, h - height - edges)), col = info.textoff + margin, width = width, height = height }
  end

  -- relative to the window itself: row 0 is its first text row (under the
  -- winbar), col 0 its gutter
  -- the lanes are the status column's last cells but one (see `M.statuscolumn`)
  local g = gutters[target]
  local lanes = g and g.width or 0
  local lane = g and thread and vim.tbl_contains(g.threads, thread) and thread._lane or 1
  local cfg = { relative = 'win', win = target, col = math.max(0, info.textoff - 2 - lanes + lane), width = width }
  local text_top = info.winrow + info.winbar
  -- window rows of the range: `top` its first, `bottom` past its last (a
  -- wrapped last line ends further down); nil when off screen
  local s = vim.fn.screenpos(src_win, first, 1).row
  local last_text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(src_win), last - 1, last, false)[1] or ''
  local e = vim.fn.screenpos(src_win, last, math.max(1, #last_text)).row
  local top = s > 0 and s - text_top or nil
  local bottom = e > 0 and e - text_top + 1 or nil
  local below = bottom and h - bottom or 0
  local above = top or 0
  local need = height + edges
  if below >= need or (below >= above and below > edges) then
    cfg.height = math.max(1, math.min(height, below - edges))
    cfg.row = bottom
  elseif above > edges then
    cfg.height = math.max(1, math.min(height, above - edges))
    cfg.row = above - cfg.height - edges
  else
    -- the range fills the window: nothing left to keep in view
    cfg.height = math.max(1, math.min(height, h - edges))
    cfg.row = math.max(0, h - cfg.height - edges)
  end
  return cfg
end

--- Make room under the framed float `top` (the thread of lines
--- `first`..`last` of `anchor_win`) for another framed float of up to
--- `height` rows: both are placed by `beside` as one block, shrinking `top`
--- as needed, scrolled to its end, or to `lnum` at its top when given.
--- Returns the lower float's config.
local function stack_below(session, top, anchor_win, first, last, height, lnum, thread)
  local t = vim.api.nvim_win_get_config(top)
  local block = beside(session, anchor_win, first, last, t.height + 2 + height, 2, thread)
  -- the frames between the two, and at least three rows of `top`
  height = math.max(1, math.min(height, block.height - 5))
  local top_height = math.max(1, math.min(t.height, block.height - height - 2))
  vim.api.nvim_win_set_config(top, { relative = 'win', win = block.win, row = block.row, col = block.col, height = top_height, footer = '' })
  vim.api.nvim_win_call(top, function()
    if lnum then
      vim.api.nvim_win_set_cursor(top, { lnum, 0 })
      vim.cmd('normal! zt')
    else
      vim.cmd('normal! G')
    end
  end)
  return { relative = 'win', win = block.win, row = block.row + top_height + 2, col = block.col, width = t.width, height = height }
end

--- `CursorMoved` in a diff window: preview the cursor line's thread, keep
--- the open one if it covers the line, close it off every thread. After
--- `<Esc>` (`_hover_off`), nothing opens until the cursor leaves the line.
local function hover(session)
  local review = session.review
  if session.closed or not review.inline then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if not M.side_of(session, win) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local off = review._hover_off
  if off and (off.win ~= win or off.line ~= line) then
    review._hover_off = nil
  elseif off then
    paint(session)
    return
  end
  local threads = M.threads_at(session, win, line)
  local open = review._open
  if #threads == 0 and open then
    M.close_thread(session)
  elseif #threads == 0 or (open and open.src == win and vim.tbl_contains(threads, open.thread)) then
    paint(session)
  else
    M.show_thread(session, threads[1])
  end
end

--- Hover: the cursor on a commented line of a diff window opens that line's
--- thread in a preview float (focus stays in the diff); off every thread,
--- the preview closes. Registered once per session.
local function setup_hover(session)
  local review = session.review
  if review._hover then
    return
  end
  review._hover = true
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = session.augroup,
    callback = function()
      hover(session)
    end,
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = session.augroup,
    callback = function()
      local open = review._open
      local win = vim.api.nvim_get_current_win()
      if open and win ~= open.float and win ~= review._reply_win and not M.side_of(session, win) then
        M.close_thread(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = session.augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if review._open and win and M.side_of(session, win) then
        M.follow_scroll(session)
      end
    end,
  })
  -- a card keeps its width limit and stays centred: the editor or the diff
  -- windows changed size (floats resizing themselves don't count)
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = session.augroup,
    callback = function(args)
      if args.event == 'WinResized' then
        local diff = false
        for _, w in ipairs(vim.v.event.windows or {}) do
          diff = diff or M.side_of(session, w) ~= nil
        end
        if not diff then
          return
        end
      end
      vim.schedule(function()
        M.refit(session)
      end)
    end,
  })
end

--- Fit card float `win` again with `fit()` whenever the editor or a diff
--- window is resized, while it's open.
local function refit_on_resize(session, win, fit)
  session.review._refits = session.review._refits or {}
  session.review._refits[win] = fit
end

--- Fit every open card float to the windows' current sizes.
function M.refit(session)
  local review = session.review
  if session.closed or type(review) ~= 'table' then
    return
  end
  -- a refit may open a float in place of its own (and register it)
  local fits = {}
  for win, fit in pairs(review._refits or {}) do
    if vim.api.nvim_win_is_valid(win) then
      table.insert(fits, fit)
    else
      review._refits[win] = nil
    end
  end
  for _, fit in ipairs(fits) do
    fit()
  end
end

--- Place every shown thread (`thread._place`) in `wins` (left/right).
--- Returns the placed threads per side.
local function place_threads(session, review, wins)
  local placed = { left = {}, right = {} }
  for _, thread in ipairs(review.threads) do
    thread._place = nil
    if session.current_path and not (review.hide_resolved and thread.resolved) then
      local place = review.backend.place(session, thread)
      local win = place and wins[place.win]
      -- while a window is being swapped its buffer can be shorter than the place
      if win and vim.api.nvim_win_is_valid(win) and (place.end_line or 0) <= vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) then
        thread._place = place
        table.insert(placed[place.win], thread)
      end
    end
  end
  return placed
end

--- Fetch the comment authors' avatars, repainting the summaries once in.
local function request_summary_avatars(session, review)
  if not review.backend.avatar_url then
    return
  end
  local urls = {}
  for _, t in ipairs(review.threads) do
    for _, c in ipairs(t.comments) do
      local url = c.author and review.backend.avatar_url(c.author)
      if url then
        table.insert(urls, url)
      end
    end
  end
  avatar.request(urls, function()
    if not session.closed then
      paint(session, true)
      schedule_avatars(session)
    end
  end)
end

--- Keep the open thread open if it's still placed, re-anchored to its new
--- spot; a thread dropped from the store keeps its stale `_place`.
local function reshow_open_thread(session, review)
  local open = review._open
  if not open then
    return
  end
  local focused = vim.api.nvim_get_current_win() == open.float
  if open.thread._place and vim.tbl_contains(review.threads, open.thread)
    and vim.api.nvim_win_is_valid(session.wins[open.thread._place.win] or -1) then
    M.show_thread(session, open.thread, { focus = focused })
  else
    M.close_thread(session)
  end
end

--- Redraw every thread's range bar + summary for the current file/pair (call
--- after `diffpair.show`), and the counterpart blank lines that keep the
--- two windows aligned. Placement comes from `review.backend.place`, cached
--- on `thread._place` (session-only, not persisted) for `M.threads_at`,
--- `M.next_thread` and `M.goto_thread`.
function M.decorate(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  local ns = session_mod.namespace(session, 'review')
  local wins = { left = session.wins.left, right = session.wins.right }
  local live_wins = {}
  for _, w in pairs(wins) do
    if w and vim.api.nvim_win_is_valid(w) then
      table.insert(live_wins, w)
    end
  end
  pcall(vim.api.nvim__ns_set, ns, { wins = live_wins })

  for _, w in ipairs(live_wins) do
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(w), ns, 0, -1)
  end

  -- live: outdated as soon as an edit touches a thread's lines
  local track = require('diffy.review.track')
  for _, t in ipairs(review.threads) do
    track.status(session, t)
  end

  if not review.inline then
    for _, t in ipairs(review.threads) do
      t._place = nil
    end
    for _, w in ipairs(live_wins) do
      M.fit_gutter(w, nil)
    end
    review._draw = nil
    -- the summaries' images sit on the terminal, not in the buffer
    schedule_avatars(session)
    layout.refresh(session, 'threads')
    run.ready({ session = session.id, event = 'review' })
    return
  end

  local placed = place_threads(session, review, wins)

  -- Summaries per side, keyed by screen row so both windows get the same
  -- number of virt_lines at each aligned row: a side's own summaries, padded
  -- with blanks up to the other side's count (never the sum of both).
  -- Without summaries, only the range bars.
  local rows, maps = {}, {}
  for _, name in ipairs({ 'left', 'right' }) do
    local win = wins[name]
    local g
    if win and vim.api.nvim_win_is_valid(win) and #placed[name] > 0 then
      maps[name] = row_map(win)
      local line_rows = maps[name]
      table.sort(placed[name], by_place)
      g = {
        buf = vim.api.nvim_win_get_buf(win),
        width = assign_lanes(placed[name]),
        threads = placed[name],
        rows = {},
        pos = {},
        lit = {},
      }
      for _, t in ipairs(placed[name]) do
        open_fold_if_closed(win, t._place.start_line)
        open_fold_if_closed(win, t._place.end_line)
        if review.summaries ~= false then
          local row = line_rows.row[t._place.end_line]
          rows[row] = rows[row] or {}
          rows[row][name] = rows[row][name] or { line = t._place.end_line, threads = {} }
          table.insert(rows[row][name].threads, t)
        end
      end
    end
    if win and vim.api.nvim_win_is_valid(win) then
      -- before the summaries measure the text width
      M.fit_gutter(win, g)
    end
  end
  local draw = {}
  for row, entry in pairs(rows) do
    local n = math.max(entry.left and #entry.left.threads or 0, entry.right and #entry.right.threads or 0)
    for _, name in ipairs({ 'left', 'right' }) do
      local win = wins[name]
      if win and vim.api.nvim_win_is_valid(win) then
        maps[name] = maps[name] or row_map(win)
        local e = entry[name]
        local line = e and e.line or maps[name].line[row]
        if line then
          open_fold_if_closed(win, line)
          local g = gutters[win]
          if g then
            g.rows[line] = n
            for i, t in ipairs(e and e.threads or {}) do
              g.pos[t] = i
            end
          end
          table.insert(draw, {
            buf = vim.api.nvim_win_get_buf(win),
            line = line,
            n = n,
            threads = e and e.threads or {},
            width = highlight.text_width(win),
          })
        end
      end
    end
  end
  review._draw, review._painted = draw, nil
  setup_hover(session)
  request_summary_avatars(session, review)
  reshow_open_thread(session, review)
  paint(session)
  track_avatars(session)
  schedule_avatars(session)
  layout.refresh(session, 'threads')
  run.ready({ session = session.id, event = 'review' })
end

--- `<leader>dt`: toggle inline decorations without touching drafts.
function M.toggle_inline(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  review.inline = not review.inline
  if not review.inline then
    M.close_thread(session)
  end
  M.decorate(session)
end

--- `<leader>ds`: summaries under commented lines on/off; the range bars
--- stay, and hovering a commented line still previews its thread.
function M.toggle_summaries(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  review.summaries = review.summaries == false
  M.decorate(session)
end

--- `<leader>dr`: resolved threads on/off.
function M.toggle_resolved(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  review.hide_resolved = not review.hide_resolved
  local n = 0
  for _, t in ipairs(review.threads) do
    if t.resolved then
      n = n + 1
    end
  end
  M.decorate(session)
  vim.notify(('diffy: %d resolved thread%s %s'):format(n, n == 1 and '' or 's', review.hide_resolved and 'hidden' or 'shown'))
end

--- Diff window and range (first, last line) where `thread` is drawn in the current view.
local function thread_anchor(session, thread)
  local p = thread._place
  if p and session.wins[p.win] and vim.api.nvim_win_is_valid(session.wins[p.win]) then
    return session.wins[p.win], p.start_line, p.end_line
  end
  return vim.api.nvim_get_current_win(), thread.anchor.start_line, thread.anchor.end_line
end

-- ---------------------------------------------------------------------
-- comment cards: the thread float and `gP`

local CARD_HL = highlight.CARD_HL

--- A card title, set in the top border like a tab.
local function card_title(text, width)
  return { { ' ' .. highlight.truncate(text, width - 4) .. ' ', 'DiffyThreadHeader' } }
end

--- A float drawn as a card: its own background inside a thin frame, wrapped text.
local function card_window(win)
  session_mod.unbind(win)
  vim.wo[win].winhighlight = CARD_HL
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  -- a cut preview ends mid-paragraph: no `@@@` marker there
  vim.wo[win].fillchars = 'eob: ,lastline: '
end

local function close_win(win)
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

--- Open `buf` in a card float, entering it once it's set up.
local function open_card(buf, enter, cfg)
  local win = vim.api.nvim_open_win(buf, false, cfg)
  card_window(win)
  if enter then
    vim.api.nvim_set_current_win(win)
  end
  return win
end

--- "just now", "5 min ago", "3 hours ago", "yesterday", "4 days ago", then
--- the date.
local function ago(t)
  local e = model.epoch(t)
  if not e then
    return ''
  end
  local d = os.time() - e
  if d < 60 then
    return 'just now'
  elseif d < 3600 then
    return ('%d min ago'):format(math.floor(d / 60))
  elseif d < 86400 then
    local h = math.floor(d / 3600)
    return h == 1 and '1 hour ago' or ('%d hours ago'):format(h)
  elseif d < 2 * 86400 then
    return 'yesterday'
  elseif d < 7 * 86400 then
    return ('%d days ago'):format(math.floor(d / 86400))
  end
  local day = ('%s %d'):format(os.date('%b', e), tonumber(os.date('%d', e)))
  return os.date('%Y', e) == os.date('%Y') and day or ('%s, %s'):format(day, os.date('%Y', e))
end

local function card_ns(session)
  return session_mod.namespace(session, 'review_card')
end

--- Header strip of one card: avatar slot (once drawable), author, age, and
--- right-aligned badges. Painted again when the avatar arrives.
local function paint_header(session, buf, head)
  local H = 'DiffyThreadHeader'
  local left = { { ' ', H } }
  if head.url and avatar.ready(head.url) then
    -- the image is one row tall, so a bit over two cells wide
    table.insert(left, { '   ', H })
    head.slot = true
  end
  table.insert(left, { head.name, { H, highlight.author(head.name), 'DiffyThreadAuthor' } })
  local when = ago(head.comment.created_at)
  if when ~= '' then
    table.insert(left, { '  ' .. when, { H, 'DiffyThreadTime' } })
  end
  head.left_id = vim.api.nvim_buf_set_extmark(buf, card_ns(session), head.row, 0, {
    id = head.left_id,
    virt_text = left,
    virt_text_pos = 'inline',
    hl_mode = 'combine',
    line_hl_group = H,
  })
  if #head.badges > 0 and not head.right_id then
    local right = {}
    for _, b in ipairs(head.badges) do
      table.insert(right, { b[1], { H, b[2] } })
      table.insert(right, { '  ', H })
    end
    right[#right][1] = ' '
    head.right_id = vim.api.nvim_buf_set_extmark(buf, card_ns(session), head.row, 0, {
      virt_text = right,
      virt_text_pos = 'right_align',
      hl_mode = 'combine',
    })
  end
end

--- Fill `buf` with one card per comment: a header strip, then the markdown
--- body. The header is virtual text on an empty line, so each body parses
--- as markdown on its own. `opts.people`: names and avatars (else every
--- comment is "You"); `opts.badges`: extra badges on the first header;
--- `opts.avatar_url(login)`; `opts.preamble`: lines put above the cards,
--- as they are. Returns the headers.
local function fill_cards(session, buf, comments, opts)
  local lines, heads, code, labels = vim.list_extend({}, opts.preamble or {}), {}, {}, {}
  local marks = {}
  render.reset(buf)
  for i, c in ipairs(comments) do
    local badges = model.comment_badges(c)
    if i == 1 then
      vim.list_extend(badges, opts.badges or {})
    end
    table.insert(heads, {
      row = #lines,
      comment = c,
      name = opts.people and (c.author or 'unknown') or 'You',
      badges = badges,
      url = opts.people and opts.avatar_url and c.author and opts.avatar_url(c.author) or nil,
    })
    table.insert(lines, '')
    local body = render.body(c.body)
    local base = #lines
    render.add(buf, body, base, 1)
    for _, cl in ipairs(body.code) do
      table.insert(code, { row = base + cl.row, suggestion = cl.suggestion })
    end
    for _, lb in ipairs(body.labels) do
      -- the row above the body is the card's header
      table.insert(labels, { row = base + lb.row, empty = lb.empty })
    end
    for _, m in ipairs(body.marks) do
      table.insert(marks, { row = base + m.row, col = m.col + 1, end_col = m.end_col + 1, hl = m.hl })
    end
    for _, l in ipairs(body.lines) do
      -- one cell of padding; markdown allows up to three before any block
      table.insert(lines, ' ' .. l)
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = card_ns(session)
  for i, h in ipairs(heads) do
    paint_header(session, buf, h)
    if i > 1 then
      -- clipped at the window's edge; FloatBorder takes the card's frame colour
      vim.api.nvim_buf_set_extmark(buf, ns, h.row, 0, {
        virt_lines = { { { ('─'):rep(vim.o.columns), 'FloatBorder' } } },
        virt_lines_above = true,
      })
    end
  end
  for _, cl in ipairs(code) do
    vim.api.nvim_buf_set_extmark(buf, ns, cl.row, 0, {
      virt_text = { { '▎', cl.suggestion and 'DiffyThreadSuggestion' or 'DiffyThreadCodeBar' } },
      virt_text_pos = 'overlay',
    })
  end
  for _, lb in ipairs(labels) do
    local text = lb.empty and ' Suggested change: remove these lines' or ' Suggested change'
    vim.api.nvim_buf_set_extmark(buf, ns, lb.row, 0, { virt_lines = { { { text, 'DiffyThreadSuggestion' } } } })
  end
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl, priority = 200 })
  end
  pcall(vim.treesitter.start, buf, 'markdown')
  return heads
end

--- Draw the avatars of the card window (`review._cards`) where its headers
--- are on screen; clear them once it's gone or its tab isn't current.
local function draw_avatars(session)
  local cards = session.review and session.review._cards
  if not (cards and vim.api.nvim_win_is_valid(cards.win)) or vim.api.nvim_get_current_tabpage() ~= session.tab then
    avatar.clear(session.id)
    return
  end
  local items = {}
  for _, h in ipairs(cards.heads) do
    if h.slot then
      local pos = vim.fn.screenpos(cards.win, h.row + 1, 1)
      if pos.row > 0 then
        -- after the header's padding cell
        table.insert(items, { url = h.url, row = pos.row, col = pos.col + 1 })
      end
    end
  end
  vim.list_extend(items, render.image_items(cards.win, vim.api.nvim_win_get_buf(cards.win)))
  avatar.place(session.id, items)
end

-- the cell rectangles of the current tab's floats, which cover summaries
local function float_rects()
  local rects = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= '' then
      local info = vim.fn.getwininfo(w)[1]
      -- a possible border: one cell around
      table.insert(rects, {
        top = info.winrow - 1,
        bottom = info.winrow + info.winbar + info.height,
        left = info.wincol - 1,
        right = info.wincol + info.width,
      })
    end
  end
  return rects
end

local function under_float(rects, row, col)
  for _, r in ipairs(rects) do
    -- the image is a bit over two cells wide
    if row >= r.top and row <= r.bottom and col + 2 >= r.left and col <= r.right then
      return true
    end
  end
  return false
end

--- The screen cells of draw entry `d`'s avatar slots in `win`, visible rows
--- `top`..`bottom` only, appended to `items` as `{ url, row, col }`.
local function slot_cells(win, d, top, bottom, items)
  if vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(d.line) end) ~= -1 then
    return
  end
  local pos = vim.fn.screenpos(win, d.line, 1)
  if pos.row == 0 then
    return
  end
  local h = vim.api.nvim_win_text_height(win, { start_row = d.line - 1, end_row = d.line - 1 })
  -- virt_lines come right under the line's own rows, before fillers
  local base = pos.row + h.all - h.fill
  for i, url in pairs(d.slots) do
    local row = base + i - 1
    if row >= top and row <= bottom then
      table.insert(items, { url = url, row = row, col = pos.col + 2 })
    end
  end
end

--- Draw the avatars reserved in the summary virt_lines (`d.slots`, set by
--- `paint`) of the diff windows, where those rows are on screen.
local function draw_summary_avatars(session)
  local owner = session.id .. ':summaries'
  local review = session.review
  if not (review and review._draw and review.inline) or vim.api.nvim_get_current_tabpage() ~= session.tab then
    avatar.clear(owner)
    return
  end
  local cells = {}
  for _, name in ipairs({ 'left', 'right' }) do
    local win = session.wins[name]
    if win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local info = vim.fn.getwininfo(win)[1]
      local top = info.winrow + info.winbar
      for _, d in ipairs(review._draw) do
        if d.buf == buf and d.slots and next(d.slots) then
          slot_cells(win, d, top, top + info.height - 1, cells)
        end
      end
    end
  end
  local items = {}
  local rects = #cells > 0 and float_rects() or {}
  for _, c in ipairs(cells) do
    if not under_float(rects, c.row, c.col) then
      table.insert(items, c)
    end
  end
  avatar.place(owner, items)
end

schedule_avatars = function(session)
  vim.schedule(function()
    if not session.closed then
      -- a float anchored to a buffer line only moves when its window
      -- scrolls on redraw: measure after it
      local review = session.review
      local any = review and review._cards ~= nil
      for _, d in ipairs(not any and review and review._draw or {}) do
        any = any or (d.slots and next(d.slots)) ~= nil
      end
      if any then
        vim.cmd('redraw')
      end
      draw_avatars(session)
      draw_summary_avatars(session)
    end
  end)
end

-- images sit at screen cells: follow the windows, leave with the tab
track_avatars = function(session)
  local review = session.review
  if review._avatar_track then
    return
  end
  review._avatar_track = true
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'VimResized', 'TabEnter' }, {
    group = session.augroup,
    callback = function()
      schedule_avatars(session)
    end,
  })
  vim.api.nvim_create_autocmd('TabLeave', {
    group = session.augroup,
    callback = function()
      avatar.clear(session.id)
      avatar.clear(session.id .. ':summaries')
    end,
  })
end

--- Make `win` (showing `buf`, filled by `fill_cards`) the card window whose
--- avatars are drawn, fetching the ones not cached yet.
local function show_avatars(session, win, buf, heads)
  local review = session.review
  review._cards = { win = win, heads = heads }
  track_avatars(session)
  local urls = {}
  for _, h in ipairs(heads) do
    if h.url then
      table.insert(urls, h.url)
    end
  end
  avatar.request(urls, function()
    local cards = review._cards
    if not (cards and cards.win == win and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    for _, h in ipairs(heads) do
      if not h.slot and h.url and avatar.ready(h.url) then
        paint_header(session, buf, h)
      end
    end
    schedule_avatars(session)
  end)
  local images = {}
  for _, im in ipairs(render.images(buf)) do
    table.insert(images, im.url)
  end
  avatar.request(images, function()
    local cards = review._cards
    if cards and cards.win == win and vim.api.nvim_buf_is_valid(buf) then
      render.paint_images(buf, card_ns(session))
      schedule_avatars(session)
    end
  end, { image = true })
  schedule_avatars(session)
end

--- Stop drawing avatars for `win` (any card window when nil).
local function hide_avatars(session, win)
  local review = session.review
  if review and review._cards and (not win or review._cards.win == win) then
    review._cards = nil
    avatar.clear(session.id)
  end
end

local key_hints = highlight.key_hints

-- ---------------------------------------------------------------------
-- compose float (`gc`)

--- Open a floating markdown compose buffer beside lines `first`..`last` of
--- `anchor_win` (see `beside`), so the code being commented stays
--- visible; with `opts.above` (the thread float), right under that float
--- instead, so the thread stays in view (its end, or its line
--- `opts.above_line`). `<C-s>`/`:w` calls `on_save(lines)` and closes; `q`
--- cancels. `opts.on_close(saved)` runs once it's closed, either way.
--- `opts.thread`: the thread replied to or edited, whose bar it lines up on.
--- `opts.prefill` seeds the buffer (editing a draft), which then opens in
--- normal mode at its end; otherwise in insert mode.
function M.open_compose(session, anchor_win, first, last, on_save, opts)
  opts = opts or {}
  local buf = scratch_buf(session, 'compose', 'acwrite', 'markdown')
  if opts.prefill then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.prefill)
    vim.bo[buf].modified = false
  end

  local keys = { { '<C-s>', 'save' }, { 'q', 'cancel' } }
  if opts.suggestion then
    table.insert(keys, { '<C-g>s', 'suggest a change', drop = 1 })
  end
  local function place()
    local cfg
    if opts.above and vim.api.nvim_win_is_valid(opts.above) then
      -- the thread above takes the width the two share
      vim.api.nvim_win_set_config(opts.above, { width = beside(session, anchor_win, first, last, 1, 2, opts.thread).width })
      cfg = stack_below(session, opts.above, anchor_win, first, last, 8, opts.above_line, opts.thread)
      -- the thread moved and scrolled: its avatars follow
      schedule_avatars(session)
    else
      cfg = beside(session, anchor_win, first, last, 8, 2, opts.thread)
    end
    cfg.title = card_title(opts.title or 'New comment', cfg.width)
    cfg.footer = key_hints(keys, cfg.width)
    return cfg
  end
  local cfg = place()
  cfg.style = 'minimal'
  cfg.border = 'rounded'
  cfg.zindex = 200
  local win = open_card(buf, false, cfg)
  -- before focusing it: entering it mustn't close the thread above
  session.review._reply_win = opts.above and win or nil
  vim.api.nvim_set_current_win(win)
  vim.wo[win].foldcolumn = '1'
  refit_on_resize(session, win, function()
    vim.api.nvim_win_set_config(win, place())
  end)

  local closed = false
  local function close(saved)
    if closed then
      return
    end
    closed = true
    vim.cmd('stopinsert')
    if session.review._reply_win == win then
      session.review._reply_win = nil
    end
    close_win(win)
    if opts.on_close and not session.closed then
      opts.on_close(saved == true)
    end
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    -- `:q` and friends: deferred, closing windows from WinClosed races
    callback = function()
      vim.schedule(close)
    end,
  })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = session.augroup,
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      on_save(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      close(true)
    end,
  })

  session_mod.map(session, { 'n', 'i' }, '<C-s>', function()
    vim.cmd('write')
  end, { buffer = buf, desc = 'save comment' })
  session_mod.map(session, 'n', 'q', function()
    close()
  end, { buffer = buf, desc = 'cancel comment' })
  session_mod.map(session, { 'n', 'i' }, '<C-g>s', function()
    if not opts.suggestion then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local block = { '```suggestion' }
    vim.list_extend(block, opts.suggestion)
    table.insert(block, '```')
    vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, block)
    vim.api.nvim_win_set_cursor(0, { lnum + #block, 0 })
  end, { buffer = buf, desc = 'insert suggestion block' })

  if opts.prefill then
    -- editing: in normal mode, at the end of what's there
    local n = vim.api.nvim_buf_line_count(buf)
    local text = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ''
    vim.api.nvim_win_set_cursor(win, { n, math.max(0, #text - 1) })
  else
    vim.cmd('startinsert')
  end
  run.ready({ session = session.id, event = 'compose' })
end

--- A new draft comment by the user with `body` (buffer lines).
local function new_draft(session, review, body)
  return {
    id = model.new_id('c'),
    author = review.backend.author(session.root),
    body = table.concat(body, '\n'),
    created_at = os.time(),
    state = 'draft',
  }
end

--- The lines `gc` comments on in `win`: the cursor line (`mode='n'`) or
--- the visual selection (`mode='v'`).
local function selected_lines(win, mode)
  if mode == 'v' then
    vim.cmd('normal! \27') -- <Esc>, so the '< '> marks settle
    local a = vim.api.nvim_buf_get_mark(0, '<')[1]
    local b = vim.api.nvim_buf_get_mark(0, '>')[1]
    return math.min(a, b), math.max(a, b)
  end
  local l = vim.api.nvim_win_get_cursor(win)[1]
  return l, l
end

--- `gc` (normal on a line, `mode='n'`; visual on a range, `mode='v'`):
--- compose a brand-new thread anchored at the cursor line/marked range.
function M.compose(session, mode)
  local win = vim.api.nvim_get_current_win()
  local side = M.side_of(session, win)
  if not side then
    return
  end
  if session.pair and session.pair.top.kind == 'push' then
    vim.notify('diffy: this commit is no longer in the branch: reply to its threads here, write new ones on the branch', vim.log.levels.WARN)
    return
  end
  if not session.current_path or not vim.w[win].diffy_path then
    vim.notify('diffy: no file on this side to comment on', vim.log.levels.WARN)
    return
  end
  local review = M.ensure(session)
  if not review then
    vim.notify('diffy: review is only available in :Diffy, :Diffy branch and :Diffy pr', vim.log.levels.WARN)
    return
  end
  if type(review.backend.save) ~= 'function' then
    vim.notify(('diffy: composing comments isn\'t implemented yet for %s'):format(review.backend.name), vim.log.levels.WARN)
    return
  end

  local start_line, end_line = selected_lines(win, mode)

  local buf = vim.api.nvim_win_get_buf(win)
  local excerpt = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local pair = session.file_pair or session.pair
  local rev = side == 'left' and pair.left or pair.right
  local anchor = {
    path = session.current_path,
    side = side == 'left' and 'old' or 'new',
    start_line = start_line,
    end_line = end_line,
    commit = model.rev_to_commit(rev, session.head_sha),
    excerpt = excerpt,
  }
  local function pin(r)
    return r == 'HEAD' and session.head_sha or r
  end
  local pinned_left, pinned_right = pin(pair.left), pin(pair.right)

  local suggestion = review.backend.capabilities.suggestions and excerpt or nil
  M.open_compose(session, win, start_line, end_line, function(body)
    if vim.trim(table.concat(body, '\n')) == '' then
      return
    end
    local thread = {
      id = model.new_id('t'),
      backend = review.backend.name,
      anchor = anchor,
      comments = { new_draft(session, review, body) },
      resolved = false,
      -- the pair the comment was written against, for review.md's diff hunk
      view = { left = pinned_left, right = pinned_right },
    }
    table.insert(review.threads, thread)
    M.remember(session, thread, thread.comments[1])
    review.backend.save(session, thread, thread.comments[1])
  end, {
    suggestion = suggestion,
    title = start_line == end_line and ('Comment on line %d'):format(start_line) or ('Comment on lines %d–%d'):format(start_line, end_line),
  })
end

--- The thread float, when it's open on `thread`.
local function open_float_of(review, thread)
  local open = review._open
  return open and open.thread == thread and vim.api.nvim_win_is_valid(open.float) and open.float or nil
end

--- `on_close` of a box opened from the thread float `above`: a save closes
--- the thread and goes back to the diff window it was entered from; a
--- cancel goes back into the thread (`show_opts`).
local function back_from_box(session, thread, above, show_opts)
  if not above then
    return nil
  end
  local src = session.review._open.src
  return function(saved)
    if not saved then
      return M.show_thread(session, thread, show_opts)
    end
    M.close_thread(session)
    if vim.api.nvim_win_is_valid(src) then
      vim.api.nvim_set_current_win(src)
    end
  end
end

--- Reply to an existing `thread`: appends a new comment on save. From the
--- thread float, the reply box opens under it and the thread stays in
--- view (see `back_from_box` for where closing it goes).
function M.reply(session, thread)
  local review = session.review
  if type(review.backend.save) ~= 'function' then
    vim.notify(('diffy: replying isn\'t implemented yet for %s'):format(review.backend.name), vim.log.levels.WARN)
    return
  end
  local backend = review.backend
  local above = open_float_of(review, thread)
  local win, first, last = thread_anchor(session, thread)
  M.open_compose(session, win, first, last, function(body)
    if vim.trim(table.concat(body, '\n')) == '' then
      return
    end
    local comment = new_draft(session, review, body)
    table.insert(thread.comments, comment)
    backend.save(session, thread, comment)
  end, {
    title = backend.capabilities.people and thread.comments[1] and ('Reply to %s'):format(thread.comments[1].author) or 'Reply',
    above = above,
    thread = thread,
    on_close = back_from_box(session, thread, above, { focus = true }),
  })
end

--- Edit `comment` of `thread` (a draft, or your published comment: then
--- the edit is staged until a GitHub submit), replacing its body on save.
--- From the thread float, the edit box opens under it with the comment in
--- view; cancelling goes back into the thread, on that comment.
function M.edit_comment(session, thread, comment)
  local review = session.review
  local backend = review.backend
  local above = open_float_of(review, thread)
  local above_line
  for _, h in ipairs(above and review._open.heads or {}) do
    if h.comment == comment then
      above_line = h.row + 1
    end
  end
  local real = comment._of or comment
  local staged = real.state == 'published'
  local win, first, last = thread_anchor(session, thread)
  M.open_compose(session, win, first, last, function(body)
    body = table.concat(body, '\n')
    if staged then
      backend.stage_edit(session, thread, real, body)
      return
    end
    comment.body = body
    backend.save(session, thread, comment)
  end, {
    prefill = vim.split(staged and (real.staged_body or real.body) or comment.body, '\n', { plain = true }),
    title = staged and 'Edit (sent when you submit to GitHub)' or 'Edit draft',
    above = above,
    thread = thread,
    above_line = above_line,
    on_close = back_from_box(session, thread, above, { focus = true, comment = real }),
  })
end

local function reply_open(review)
  return review._reply_win and vim.api.nvim_win_is_valid(review._reply_win)
end

--- The comment whose card holds 0-based `row` of a buffer filled by `fill_cards`.
local function comment_at(heads, row)
  local comment
  for _, h in ipairs(heads) do
    if h.row <= row then
      comment = h.comment
    end
  end
  return comment
end

--- Make `thread` (on `comment`, if given) the one `<leader>dl` goes back to.
--- Kept by ids: drafts.apply swaps a session's thread objects for new ones.
function M.remember(session, thread, comment)
  session.review._last = { thread = thread.id, comment = comment and (comment._of or comment).id }
end

--- `fit` (from `beside`) as a set_config position, `width` included if asked.
local function position(fit, width)
  return {
    relative = fit.relative,
    win = fit.win,
    row = fit.row,
    col = fit.col,
    width = width and fit.width or nil,
    height = fit.height,
  }
end

-- ---------------------------------------------------------------------
-- thread float (`K`/`<CR>`)

--- Threads whose placed range covers `lnum` of `win` (one of the session's
--- diff windows), left to right as their bars are.
function M.threads_at(session, win, lnum)
  local review = session.review
  local out = {}
  if not review then
    return out
  end
  for _, t in ipairs(review.threads) do
    if t._place and session.wins[t._place.win] == win and lnum >= t._place.start_line and lnum <= t._place.end_line then
      table.insert(out, t)
    end
  end
  table.sort(out, function(a, b)
    if a._lane ~= b._lane then
      return (a._lane or 0) < (b._lane or 0)
    end
    return by_start(a, b)
  end)
  return out
end

--- Close the thread float, without repainting.
local function close_float(session)
  local review = session.review
  local open = review and review._open
  if not open then
    return
  end
  review._open = nil
  hide_avatars(session, open.float)
  close_win(open.float)
  -- summary avatars it covered show again
  schedule_avatars(session)
end

--- Close the open thread (if any); focus goes back to its diff window when
--- it was in the float.
function M.close_thread(session)
  local review = session.review
  local open = review and review._open
  if not open then
    return
  end
  local was_focused = vim.api.nvim_get_current_win() == open.float
  close_float(session)
  if was_focused and vim.api.nvim_win_is_valid(open.src) then
    vim.api.nvim_set_current_win(open.src)
  end
  paint(session)
end

--- Threads of `win`'s side in the order `]t`/`[t` walk them.
local function side_threads(session, win)
  local side = M.side_of(session, win)
  local out = {}
  for _, t in ipairs(session.review and session.review.threads or {}) do
    if t._place and t._place.win == side then
      table.insert(out, t)
    end
  end
  table.sort(out, by_start)
  return out
end

--- Whether `e`/`dd` apply to `c` (a card's comment): drafts, and your
--- published comments, whose changes are staged.
function M.editable(session, c)
  local real = c._of or c
  if real.state == 'draft' then
    return true
  end
  local backend = session.review.backend
  return real.state == 'published' and type(backend.stage_edit) == 'function' and real.author == backend.author(session.root)
end

--- The cards of `thread`: a published comment with a staged edit shows the
--- edit; in conflict with a github.com edit, the live comment then your
--- edit (`_edit`). A shown copy keeps its comment in `_of`.
local function shown_comments(thread)
  local out = {}
  for _, c in ipairs(thread.comments) do
    if c.state == 'published' and c.staged_body and not c.staged_conflict then
      table.insert(out, setmetatable({ body = c.staged_body, _of = c }, { __index = c }))
    else
      table.insert(out, c)
      if c.state == 'published' and c.staged_conflict then
        table.insert(out, { _edit = true, _of = c, author = c.author, body = c.staged_body, created_at = c.created_at })
      end
    end
  end
  return out
end

--- Fill `buf` with `thread` as comment cards (as in the thread float), for
--- any window showing it. `opts.avatars` reserves room for the avatars;
--- `opts.preamble` goes above the cards. Returns the headers.
function M.render_thread(session, buf, thread, opts)
  opts = opts or {}
  local backend = session.review.backend
  local badges = {}
  if thread.outdated then
    table.insert(badges, { 'outdated', 'DiffyThreadOutdated' })
  end
  if thread.resolved then
    table.insert(badges, { '✓ resolved', 'DiffyThreadResolved' })
  end
  vim.list_extend(badges, model.thread_badges(thread))
  return fill_cards(session, buf, shown_comments(thread), {
    people = backend.capabilities.people,
    badges = badges,
    avatar_url = opts.avatars and backend.avatar_url or nil,
    preamble = opts.preamble,
  })
end

--- `x`: resolve (or unresolve) `thread`. A published one gets the change
--- staged until a GitHub submit (`x` again cancels); your own, in its saved
--- drafts. Redraws once done.
function M.set_resolved(session, thread, resolved)
  local review = session.review
  local backend = review.backend
  local published = vim.iter(thread.comments):any(function(c)
    return c.state == 'published'
  end)
  if published and type(backend.toggle_resolve) == 'function' then
    backend.toggle_resolve(session, thread)
    return
  end
  thread.resolved = resolved
  backend.save(session, thread)
end

--- `]t`/`[t`/`<Tab>`/`<S-Tab>` on `buf` (a diff window's or the thread float's).
local function map_walk_keys(session, buf, desc_prefix)
  local map = session_mod.map
  map(session, 'n', ']t', function()
    M.next_thread(session, vim.v.count1)
  end, { buffer = buf, desc = desc_prefix .. 'next thread' })
  map(session, 'n', '[t', function()
    M.next_thread(session, -vim.v.count1)
  end, { buffer = buf, desc = desc_prefix .. 'previous thread' })
  map(session, 'n', '<Tab>', function()
    M.cycle_line(session, 1)
  end, { buffer = buf, desc = desc_prefix .. 'next thread on this line' })
  map(session, 'n', '<S-Tab>', function()
    M.cycle_line(session, -1)
  end, { buffer = buf, desc = desc_prefix .. 'previous thread on this line' })
end

--- The entered thread float's key hints: what applies to `thread`, where
--- it stands among its side's threads and those on the cursor line.
local function focus_keys(session, thread, src)
  local backend = session.review.backend
  local keys = {}
  if type(backend.save) == 'function' then
    table.insert(keys, { 'r', 'reply' })
  end
  for _, c in ipairs(thread.comments) do
    if M.editable(session, c) then
      table.insert(keys, { 'e', 'edit', drop = 3 })
      table.insert(keys, { 'dd', 'delete', drop = 2 })
      break
    end
  end
  if backend.capabilities.resolve then
    local label = thread.resolve_staged and 'cancel ' .. thread.resolve_staged or (thread.resolved and 'unresolve' or 'resolve')
    table.insert(keys, { 'x', label, drop = 4 })
  end
  local order = side_threads(session, src)
  for i, t in ipairs(order) do
    if t == thread and #order > 1 then
      table.insert(keys, { ']t [t', ('%d/%d'):format(i, #order), drop = 1 })
    end
  end
  local here = M.threads_at(session, src, vim.api.nvim_win_get_cursor(src)[1])
  for i, t in ipairs(here) do
    if t == thread and #here > 1 then
      table.insert(keys, { '<Tab>', ('%d/%d on this line'):format(i, #here), drop = 1 })
    end
  end
  table.insert(keys, { 'q', 'close' })
  return keys
end

--- Show `thread` alone in the thread float: over the other diff
--- window, level with the thread, with its code range highlighted in its
--- own window. `opts.focus` moves the cursor into it (`<CR>`), on
--- `opts.comment` if given, else on the latest comment; otherwise it's a
--- preview and focus stays in the diff.
function M.show_thread(session, thread, opts)
  opts = opts or {}
  local review = session.review
  review._hover_off = nil
  local backend = review.backend
  local place = thread._place
  local src = place and session.wins[place.win]
  if not (src and vim.api.nvim_win_is_valid(src)) then
    return
  end
  close_float(session)

  local buf = scratch_buf(session, 'thread', 'nofile')
  local heads = M.render_thread(session, buf, thread, { avatars = true })

  local edges = 2
  local cfg = beside(session, src, place.start_line, place.end_line, vim.api.nvim_buf_line_count(buf), edges, thread)
  cfg.style = 'minimal'
  cfg.zindex = 50
  if opts.focus then
    cfg.footer = key_hints(focus_keys(session, thread, src), cfg.width)
  end
  cfg.border = 'rounded'
  local fwin = open_card(buf, false, cfg)
  vim.wo[fwin].winhighlight = highlight.card_hl(thread)
  vim.wo[fwin].conceallevel = 2
  vim.wo[fwin].concealcursor = 'nc'
  render.attach(session, fwin, buf)
  if opts.focus then
    vim.api.nvim_set_current_win(fwin)
  end
  -- the real height once wrapping, concealed fences and labels are known
  local rows = vim.api.nvim_win_text_height(fwin, {}).all
  local fit_cfg = {}
  if not opts.focus then
    -- a hover shouldn't bury the other side: cut long previews
    local room = cfg.win and vim.fn.getwininfo(cfg.win)[1].height or vim.o.lines
    local cap = math.max(6, math.floor(room / 2))
    if rows > cap then
      fit_cfg.footer = key_hints({ { '<CR>', ('%d more lines'):format(rows - cap) } }, cfg.width)
      rows = cap
    end
  end
  local fit = beside(session, src, place.start_line, place.end_line, rows, edges, thread)
  vim.api.nvim_win_set_config(fwin, vim.tbl_extend('force', fit_cfg, position(fit, true)))
  review._open = { thread = thread, src = src, float = fwin, buf = buf, heads = heads, rows = rows }
  refit_on_resize(session, fwin, function()
    -- a reply box under it places both
    if reply_open(review) then
      return
    end
    local now = thread._place
    if not (now and review._open and review._open.float == fwin) then
      return
    end
    local target = beside(session, src, now.start_line, now.end_line, rows, edges, thread)
    local cur = vim.api.nvim_win_get_config(fwin)
    if cur.width == target.width and cur.col == target.col then
      M.follow_scroll(session)
      return
    end
    -- a new width wraps the text anew: show it again, on the same comment
    local focused = vim.api.nvim_get_current_win() == fwin
    local comment = comment_at(heads, vim.api.nvim_win_get_cursor(fwin)[1] - 1)
    M.show_thread(session, thread, { focus = focused, comment = focused and comment or nil })
  end)
  if opts.focus then
    -- on `opts.comment`, else on the latest comment
    local target = heads[#heads]
    for _, h in ipairs(heads) do
      if opts.comment and (h.comment == opts.comment or h.comment._of == opts.comment) then
        target = h
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(fwin, { target.row + 1, 0 })
    end
  end
  if opts.focus then
    M.remember(session, thread, comment_at(heads, vim.api.nvim_win_get_cursor(fwin)[1] - 1))
  end
  -- entered by hand (`<C-w>w`) or moved in: a preview counts once you're in it
  vim.api.nvim_create_autocmd({ 'WinEnter', 'CursorMoved' }, {
    group = session.augroup,
    buffer = buf,
    callback = function()
      if vim.api.nvim_get_current_win() == fwin then
        M.remember(session, thread, comment_at(heads, vim.api.nvim_win_get_cursor(fwin)[1] - 1))
      end
    end,
  })
  if backend.capabilities.people then
    show_avatars(session, fwin, buf, heads)
  end

  vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(fwin),
    once = true,
    callback = function()
      if review._open and review._open.float == fwin then
        close_float(session)
        vim.schedule(function()
          if not session.closed then
            paint(session)
          end
        end)
      end
    end,
  })

  local map = session_mod.map
  map(session, 'n', 'q', function()
    M.close_thread(session)
  end, { buffer = buf, desc = 'close thread' })
  map_walk_keys(session, buf, '')
  map(session, 'n', 'r', function()
    M.reply(session, thread)
  end, { buffer = buf, desc = 'reply' })
  local function editable_at_cursor(verb)
    local comment = comment_at(heads, vim.api.nvim_win_get_cursor(fwin)[1] - 1)
    if not comment or not M.editable(session, comment) then
      vim.notify(('diffy: only a draft or your own comment can be %s'):format(verb), vim.log.levels.WARN)
      return nil
    end
    return comment
  end
  map(session, 'n', 'e', function()
    local comment = editable_at_cursor('edited')
    if comment then
      M.edit_comment(session, thread, comment)
    end
  end, { buffer = buf, desc = 'edit' })
  map(session, 'n', 'dd', function()
    local comment = editable_at_cursor('deleted')
    if not comment then
      return
    end
    if comment._edit then
      backend.drop_edit(session, thread, comment._of)
    elseif (comment._of or comment).state == 'published' then
      backend.toggle_delete(session, thread, comment._of or comment)
    else
      M.close_thread(session)
      require('diffy.review.drafts').remove(session, { comment.id })
    end
  end, { buffer = buf, desc = 'delete' })
  if backend.capabilities.resolve then
    map(session, 'n', 'x', function()
      M.set_resolved(session, thread, not thread.resolved)
    end, { buffer = buf, desc = 'resolve/unresolve thread' })
  end
  local toggle = require('diffy').config.keymaps.toggle_panel
  if toggle and toggle ~= '' then
    map(session, 'n', toggle, function()
      local showing = session.panel_hidden
      require('diffy.layout').toggle_column(session)
      -- the cursor went to the column: the float doesn't follow it
      if showing then
        M.close_thread(session)
      end
    end, { buffer = buf, nowait = true, desc = 'toggle panels' })
  end
  M.map_last(session, buf)

  paint(session)
  run.ready({ session = session.id, event = 'thread' })
end

--- Move the open thread's float back level with its thread after the diff
--- scrolled under it; it keeps its size. Not while a reply box is stacked
--- under it: the two are placed as one block.
function M.follow_scroll(session)
  local review = session.review
  local open = review and review._open
  if not (open and vim.api.nvim_win_is_valid(open.float) and vim.api.nvim_win_is_valid(open.src)) then
    return
  end
  if reply_open(review) then
    return
  end
  local place = open.thread._place
  if not place then
    return
  end
  local fit = beside(session, open.src, place.start_line, place.end_line, open.rows, 2, open.thread)
  local cur = vim.api.nvim_win_get_config(open.float)
  if cur.win == fit.win and cur.row == fit.row and cur.col == fit.col and cur.height == fit.height then
    return
  end
  vim.api.nvim_win_set_config(open.float, position(fit))
end

--- `K`/`<CR>`: enter the thread at the cursor line (the one previewed, or
--- the first covering the line). No-op off every thread.
function M.open_thread(session)
  local win = vim.api.nvim_get_current_win()
  local threads = M.threads_at(session, win, vim.api.nvim_win_get_cursor(win)[1])
  if #threads == 0 then
    return
  end
  local open = session.review._open
  local thread = (open and open.src == win and vim.tbl_contains(threads, open.thread)) and open.thread or threads[1]
  M.show_thread(session, thread, { focus = true })
end

--- Whether the diff of selection `c` shows `thread`.
local function selection_shows(session, thread, c)
  local pair = require('diffy.selection').resolve(session.entries, c.top, c.bottom)
  return session.review.backend.view_place(session, thread, pair) ~= nil
end

--- A selection showing `thread`: the current one if it does, the whole
--- range, or the newest commit that does. nil if none does.
local function selection_for(session, thread)
  local entries = session.entries or {}
  local candidates = {}
  if session.sel and require('diffy.panels.tree').has_path(session, thread.anchor.path) then
    table.insert(candidates, session.sel)
  end
  table.insert(candidates, require('diffy.panels.log').default_selection(entries, session.range))
  for i, e in ipairs(entries) do
    if require('diffy.selection').selectable(e) then
      table.insert(candidates, { top = i, bottom = i })
    end
  end
  for _, c in ipairs(candidates) do
    if selection_shows(session, thread, c) then
      return c
    end
  end
  return nil
end

--- The view an outdated `thread` was written in, to read it where it was
--- made: its commit alone when that commit changes its file (written from
--- the commit's view), else everything up to that commit (written from the
--- full view back then). `cb(selection | nil)`.
local function written_selection(session, thread, cb)
  local entries = session.entries or {}
  local at
  for i, e in ipairs(entries) do
    if e.kind == 'commit' and not e.merge and e.sha == thread.anchor.commit then
      at = i
    end
  end
  if not at then
    cb(nil)
    return
  end
  local sha = entries[at].sha
  run.git({ 'diff', '--quiet', require('diffy.selection').parent(entries[at]), sha, '--', thread.anchor.path }, {
    cwd = session.root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      local alone = { top = at, bottom = at }
      local up_to = { top = at, bottom = require('diffy.selection').last_selectable(entries) }
      -- `git diff --quiet` exits 1 when the file differs
      if res.code == 1 and selection_shows(session, thread, alone) then
        cb(alone)
      elseif selection_shows(session, thread, up_to) then
        cb(up_to)
      else
        cb(nil)
      end
    end,
  })
end

--- Whether the session's log lists commit `sha`.
function M.in_log(session, sha)
  for _, e in ipairs(session.entries or {}) do
    if e.kind == 'commit' and e.sha == sha then
      return true
    end
  end
  return false
end

--- The commit an outdated or detached `thread` was written on when the log
--- doesn't list it (a rebase or force-push rewrote it), else nil.
local function written_off_branch(session, thread)
  local sha = (thread.outdated or thread._detached) and model.written_on(thread)
  if sha and not M.in_log(session, sha) then
    return sha
  end
  return nil
end

--- Select the throwaway view of `sha`, a commit rewritten out of the branch
--- (`log.show_push`): the branch as it was then, from its fork point off
--- the base (`sha`'s own changes without a merge-base), as GitHub anchors
--- comments. `cb()` once drawn; warns instead when the repo doesn't have
--- `sha` anymore.
local function select_push(session, sha, cb)
  local review = session.review
  local mb = review.merge_base or (session.entries and session.entries.base)
  local function git(args, on_exit)
    run.git(args, { cwd = session.root, session = session, notify_on_error = false, on_exit = on_exit })
  end
  git({ 'show', '-s', '--format=%H%x1f%P%x1f%s', sha .. '^{commit}' }, function(res)
    local full, parents, subject = (res.stdout or ''):match('^(%x+)\31([^\31]*)\31([^\n]*)')
    if res.code ~= 0 or not full then
      vim.notify(
        ('diffy: this thread was written on %s, which this repo no longer has: fetch it to see the thread there'):format(sha:sub(1, 7)),
        vim.log.levels.WARN
      )
      return
    end
    local entry = {
      kind = 'push',
      sha = full,
      rev = full,
      parents = vim.split(parents, ' ', { trimempty = true }),
      subject = subject,
      label = ('⟲ %s %s'):format(full:sub(1, 7), subject),
    }
    local function show(base)
      entry.base = base or require('diffy.selection').parent(entry)
      require('diffy.panels.log').show_push(session, entry, cb)
    end
    if not mb then
      show(nil)
      return
    end
    git({ 'merge-base', mb, full }, function(r)
      show(r.code == 0 and vim.trim(r.stdout) or nil)
    end)
  end)
end

--- Select `sel` (unless it's the current selection), then jump to `thread`.
local function reveal(session, thread, sel, opts)
  opts = vim.tbl_extend('force', opts, { revealed = true })
  if sel and not (session.sel and sel.top == session.sel.top and sel.bottom == session.sel.bottom) then
    require('diffy.panels.log').select(session, sel.top, sel.bottom, function()
      M.goto_thread(session, thread, opts)
    end)
  else
    M.goto_thread(session, thread, opts)
  end
end

--- Jump to `thread` from anywhere in the session: open its file in the
--- diff, put the cursor on its first line and hover it there (that thread,
--- even when others share the line). Shows what it takes to see it:
--- resolved threads, inline comments, and a selection that shows it (for
--- an outdated thread, the view it was written in); says why when none
--- can. `opts.focus` enters the thread (on `opts.comment`) instead of
--- hovering it.
function M.goto_thread(session, thread, opts)
  opts = opts or {}
  if not opts.revealed then
    local off_branch = written_off_branch(session, thread)
    if off_branch then
      select_push(session, off_branch, function()
        M.goto_thread(session, thread, vim.tbl_extend('force', opts, { revealed = true }))
      end)
    elseif thread.outdated then
      written_selection(session, thread, function(sel)
        reveal(session, thread, sel or selection_for(session, thread), opts)
      end)
    else
      reveal(session, thread, selection_for(session, thread), opts)
    end
    return
  end
  local review = session.review
  local redraw = false
  if not review.inline then
    review.inline, redraw = true, true
  end
  if thread.resolved and review.hide_resolved then
    review.hide_resolved, redraw = false, true
  end
  local tree = require('diffy.panels.tree')
  local path = thread.anchor.path
  local function shows(pair)
    return review.backend.view_place(session, thread, pair) ~= nil
  end
  -- the working tree's sections can list the path twice: open the row showing the thread
  local reopen = session.current_path ~= path or not shows(session.file_pair or session.pair)
  if reopen and tree.open_path(session, path, shows) then
    redraw = false
  elseif session.current_path ~= path then
    if not tree.open_path(session, path) then
      vim.notify(('diffy: %s has no changes in this selection'):format(path), vim.log.levels.WARN)
      return
    end
    redraw = false
  end
  if redraw then
    M.decorate(session)
  end
  local place = thread._place
  local win = place and session.wins[place.win]
  if not (win and vim.api.nvim_win_is_valid(win)) then
    local where = ''
    if review.backend.visible_in then
      local visible = review.backend.visible_in(session, thread)
      where = #visible > 0 and (' (it is in: %s)'):format(table.concat(visible, ', ')) or ''
    elseif thread._detached then
      where = ': its lines were changed or deleted'
    end
    vim.notify(('diffy: this thread isn\'t in the current view%s'):format(where), vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { place.start_line, 0 })
  M.show_thread(session, thread, { focus = opts.focus, comment = opts.comment })
end

--- `<leader>dl`: back into the thread you were last in (a thread float you
--- entered, or the comment you last wrote), on the comment you left it on.
function M.goto_last(session)
  local review = M.ensure(session)
  local last = review and review._last
  if not last then
    vim.notify('diffy: no thread visited yet', vim.log.levels.WARN)
    return
  end
  for _, thread in ipairs(review.threads) do
    if thread.id == last.thread then
      local comment
      for _, c in ipairs(thread.comments) do
        if c.id == last.comment then
          comment = c
        end
      end
      M.goto_thread(session, thread, { focus = true, comment = comment })
      return
    end
  end
  vim.notify('diffy: the last thread you visited is gone', vim.log.levels.WARN)
end

--- `<leader>dl` on `buf`, a diffy window's.
function M.map_last(session, buf)
  session_mod.map(session, 'n', '<leader>dl', function()
    M.goto_last(session)
  end, { buffer = buf, desc = 'review: back to the last thread' })
end

--- `<leader>dc` (the threads view) on `buf`, a diff window's or the column's.
function M.map_threads(session, buf)
  session_mod.map(session, 'n', '<leader>dc', function()
    require('diffy.review.threads').open(session, {})
  end, { buffer = buf, desc = 'review: every thread' })
end

--- `gX` (the PR on github.com) on `buf`, a diff window's, the column's or the `gP` card's.
function M.map_open_pr(session, buf)
  session_mod.map(session, 'n', 'gX', function()
    M.open_pr_in_browser(session)
  end, { buffer = buf, desc = 'review: open the PR in the browser' })
end

function M.open_pr_in_browser(session)
  local pr = session.review and session.review.pr
  if not (pr and pr.url) then
    vim.notify('diffy: `gX` needs the branch to have an open PR', vim.log.levels.WARN)
    return
  end
  vim.ui.open(pr.url)
end

--- The thread `]t` (`delta` > 0) or `[t` (< 0) opens from the current
--- window, `|delta|` threads away and stopping at the first/last one, and
--- the diff window it's in; nil when there's none that way.
local function step_target(session, delta)
  local review = session.review
  if not review then
    return nil
  end
  local open = review._open
  local win = source_win(session)
  if not M.side_of(session, win) then
    return nil
  end
  local order = side_threads(session, win)
  if open and open.src == win then
    for i, t in ipairs(order) do
      if t == open.thread then
        local j = math.max(1, math.min(#order, i + delta))
        return j ~= i and order[j] or nil, win
      end
    end
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local ahead = {}
  if delta > 0 then
    for _, t in ipairs(order) do
      if t._place.start_line > lnum then
        table.insert(ahead, t)
      end
    end
  else
    for i = #order, 1, -1 do
      if order[i]._place.start_line < lnum then
        table.insert(ahead, order[i])
      end
    end
  end
  return ahead[math.min(#ahead, math.abs(delta))], win
end

--- `]t`/`[t` (from a diff window or the thread float): open the thread
--- `delta` threads away in that window (a count, signed), stacked threads
--- included, moving the diff cursor to it. Stops at the first/last one.
function M.next_thread(session, delta)
  local target, win = step_target(session, delta)
  if not target then
    return
  end
  local open = session.review._open
  local in_float = open and vim.api.nvim_get_current_win() == open.float
  vim.api.nvim_win_set_cursor(win, { target._place.start_line, 0 })
  M.show_thread(session, target, { focus = in_float })
end

--- `<Tab>`/`<S-Tab>` (from a diff window or the thread float): open the
--- next (`delta` 1) or previous thread among those covering the cursor
--- line, left to right as their bars, wrapping around. With none of them
--- open, the leftmost (or, going back, the rightmost).
function M.cycle_line(session, delta)
  local review = session.review
  if not review then
    return
  end
  local open = review._open
  local win, in_float = source_win(session)
  if not M.side_of(session, win) then
    return
  end
  local threads = M.threads_at(session, win, vim.api.nvim_win_get_cursor(win)[1])
  if #threads == 0 then
    return
  end
  local at = delta > 0 and 1 or #threads
  for i, t in ipairs(threads) do
    if open and t == open.thread then
      at = (i - 1 + delta) % #threads + 1
    end
  end
  M.show_thread(session, threads[at], { focus = in_float })
end

--- Review keymaps of a diff-window buffer, real file or blob alike (set on
--- every left/right swap).
function M.setup_diff_keymaps(session, buf)
  local map = session_mod.map
  map(session, 'n', 'gc', function()
    M.compose(session, 'n')
  end, { buffer = buf, nowait = true, desc = 'review: new comment' })
  map(session, { 'v', 'x' }, 'gc', function()
    M.compose(session, 'v')
  end, { buffer = buf, nowait = true, desc = 'review: new comment on range' })
  map(session, 'n', '<CR>', function()
    M.open_thread(session)
  end, { buffer = buf, desc = 'review: open thread' })
  map(session, 'n', '<leader>dt', function()
    M.toggle_inline(session)
  end, { buffer = buf, desc = 'review: toggle inline threads' })
  map(session, 'n', '<leader>ds', function()
    M.toggle_summaries(session)
  end, { buffer = buf, desc = 'review: toggle thread summaries (range bars stay)' })
  map(session, 'n', '<leader>dr', function()
    M.toggle_resolved(session)
  end, { buffer = buf, desc = 'review: toggle resolved threads' })
  map(session, 'n', 'gP', function()
    M.open_pr_description(session)
  end, { buffer = buf, desc = 'review: PR description' })
  map_walk_keys(session, buf, 'review: ')
  M.map_last(session, buf)
  M.map_threads(session, buf)
  M.map_open_pr(session, buf)
  render.map_click(session, buf)
  map(session, 'n', '<Esc>', function()
    return M.dismiss(session)
  end, { buffer = buf, fallback = true, desc = 'review: close the thread card, no hover on this line' })
end

--- `<Esc>` in a diff window: close the open thread card and keep hover from
--- reopening one until the cursor leaves its line. False when no card is open.
function M.dismiss(session)
  local review = session.review
  if not (review and review._open) then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  review._hover_off = { win = win, line = vim.api.nvim_win_get_cursor(win)[1] }
  M.close_thread(session)
  return true
end

-- ---------------------------------------------------------------------
-- `gP`: GitHub PR description + conversation comments

--- `gP`: read-only float with the PR's description and conversation
--- (`review.pr`), one card per message. Only available for a `:Diffy pr`
--- session.
function M.open_pr_description(session)
  local review = session.review
  if not review or not review.pr then
    vim.notify('diffy: `gP` needs the branch to have an open PR', vim.log.levels.WARN)
    return
  end
  local pr = review.pr
  local messages = {
    { author = pr.author, created_at = pr.created_at, body = vim.trim(pr.body or '') ~= '' and pr.body or '_No description provided._' },
  }
  vim.list_extend(messages, pr.conversation)

  local buf = scratch_buf(session, 'pr', 'nofile')
  local heads = fill_cards(session, buf, messages, { people = true, avatar_url = review.backend.avatar_url })

  local title = ('#%d %s'):format(pr.number, pr.title or '')
  local function width()
    return math.max(40, math.min(CARD_WIDTH, vim.o.columns - 4))
  end
  local win = open_card(buf, true, layout.centered(width(), 1, {
    row = 1,
    style = 'minimal',
    border = 'rounded',
    title = card_title(title, width()),
    footer = key_hints({ { 'q', 'close' } }, width()),
    zindex = 200,
  }))
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nc'
  render.attach(session, win, buf)
  -- as tall as its wrapped text allows; the frame's two rows count
  local function place()
    local w = width()
    vim.api.nvim_win_set_config(win, { width = w, title = card_title(title, w), footer = key_hints({ { 'q', 'close' } }, w) })
    local height = math.max(1, math.min(vim.api.nvim_win_text_height(win, {}).all, vim.o.lines - 6))
    vim.api.nvim_win_set_config(win, layout.centered(w, height, { row = math.floor((vim.o.lines - height - 2) / 2) }))
  end
  place()
  refit_on_resize(session, win, function()
    place()
    schedule_avatars(session)
  end)
  show_avatars(session, win, buf, heads)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      hide_avatars(session, win)
    end,
  })
  session_mod.map(session, 'n', 'q', function()
    close_win(win)
  end, { buffer = buf, desc = 'close PR description' })
  M.map_open_pr(session, buf)
end

--- The message modal (`:Diffy review agent`/`github`, `:Diffy feedback`),
--- centered since a message isn't anchored to any line: write, then
--- `<C-s>`/`:w`; `q` cancels. `opts.verdicts` (`{ { label, value }, … }`,
--- from `opts.verdict`) cycle with `<C-t>`, named in the title.
--- `opts.recap(done)` fills a list under the message (`opts.recap_title`):
--- `done(rows, blocked)`, rows `{ text, value? }`, those with a value
--- checked and left out or put back with `x`; `<Tab>` goes between the two.
--- A `<C-s>` before `done` waits for it; a `blocked` reason refuses it.
--- Then the modal closes and `on_save(body, verdict, excluded)` runs (body
--- blank if left empty, `excluded` the set of values left out).
function M.open_submit_body(session, on_save, opts)
  opts = opts or {}
  local verdicts = opts.verdicts or {}
  local verdict = opts.verdict or 1
  local buf = scratch_buf(session, 'submit', 'acwrite', 'markdown')
  local width = math.max(40, math.min(80, vim.o.columns - 4))
  local height = 8
  local recap = opts.recap and { excluded = {} }

  local function title()
    local text = opts.title or 'Submit review'
    if #verdicts > 1 then
      text = ('%s · %s'):format(text, verdicts[verdict][1])
    end
    return card_title(text, width)
  end
  local hints = { { '<C-s>', opts.action or 'submit' } }
  if #verdicts > 1 then
    table.insert(hints, { '<C-t>', 'verdict', drop = 2 })
  end
  if recap then
    table.insert(hints, { '<Tab>', 'list', drop = 1 })
  end
  table.insert(hints, { 'q', 'cancel' })

  local function recap_lines()
    if not recap.rows then
      return { '    syncing…' }
    end
    local out = {}
    for _, r in ipairs(recap.rows) do
      if r.value ~= nil then
        table.insert(out, ('[%s] %s'):format(recap.excluded[r.value] and ' ' or 'x', r.text))
      else
        table.insert(out, '    ' .. r.text)
      end
    end
    return out
  end

  --- The message on top, the list right under it, both centered together.
  local function configs(recap_rows)
    local rh = recap and math.max(1, math.min(recap_rows, 12, vim.o.lines - height - 8)) or 0
    local total = height + 2 + (recap and rh + 2 or 0)
    local top = math.max(0, math.floor((vim.o.lines - total) / 2))
    local col = math.floor((vim.o.columns - width) / 2)
    return { relative = 'editor', row = top, col = col, width = width, height = height },
      { relative = 'editor', row = top + height + 2, col = col, width = width, height = rh }
  end

  local msg_cfg, recap_cfg = configs(1)
  local win = open_card(buf, true, vim.tbl_extend('force', msg_cfg, {
    style = 'minimal',
    border = 'rounded',
    title = title(),
    footer = key_hints(hints, width),
    zindex = 200,
  }))
  vim.wo[win].foldcolumn = '1'

  local recap_buf, recap_win
  local function draw_recap()
    local lines = recap_lines()
    vim.bo[recap_buf].modifiable = true
    vim.api.nvim_buf_set_lines(recap_buf, 0, -1, false, lines)
    vim.bo[recap_buf].modifiable = false
    local m, r = configs(#lines)
    vim.api.nvim_win_set_config(win, m)
    vim.api.nvim_win_set_config(recap_win, r)
  end
  if recap then
    recap_buf = scratch_buf(session, 'submit_recap', 'nofile')
    recap_win = open_card(recap_buf, false, vim.tbl_extend('force', recap_cfg, {
      style = 'minimal',
      border = 'rounded',
      title = card_title(opts.recap_title or 'Going out', width),
      footer = key_hints({ { 'x', 'leave out / put back' }, { '<Tab>', 'message', drop = 1 }, { '<C-s>', opts.action or 'submit' } }, width),
      zindex = 200,
    }))
    vim.wo[recap_win].wrap = false
    vim.wo[recap_win].cursorline = true
    draw_recap()
  end

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_get_current_win() == win then
      vim.cmd('stopinsert')
    end
    close_win(win)
    if recap_win then
      close_win(recap_win)
    end
  end
  for _, w in ipairs({ win, recap_win }) do
    vim.api.nvim_create_autocmd('WinClosed', {
      group = session.augroup,
      pattern = tostring(w),
      once = true,
      -- a `:q` in one closes the other
      callback = function()
        vim.schedule(close)
      end,
    })
  end

  local queued = false
  local function submit()
    if closed then
      return
    end
    if recap and not recap.rows then
      queued = true
      return
    end
    if recap and recap.blocked then
      vim.notify('diffy: ' .. recap.blocked, vim.log.levels.WARN)
      return
    end
    local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    close()
    on_save(body, verdicts[verdict] and verdicts[verdict][2], recap and recap.excluded or {})
  end

  local map = session_mod.map
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = session.augroup,
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      submit()
    end,
  })
  map(session, { 'n', 'i' }, '<C-s>', function()
    vim.cmd('write')
  end, { buffer = buf, desc = 'submit' })
  map(session, 'n', 'q', close, { buffer = buf, desc = 'cancel' })
  if #verdicts > 1 then
    for _, b in ipairs({ buf, recap_buf }) do
      map(session, { 'n', 'i' }, '<C-t>', function()
        verdict = verdict % #verdicts + 1
        vim.api.nvim_win_set_config(win, { title = title() })
      end, { buffer = b, desc = 'next review event' })
    end
  end

  if recap then
    map(session, 'n', '<Tab>', function()
      vim.api.nvim_set_current_win(recap_win)
    end, { buffer = buf, desc = 'to the list' })
    map(session, 'n', '<Tab>', function()
      vim.api.nvim_set_current_win(win)
    end, { buffer = recap_buf, desc = 'to the message' })
    map(session, 'n', '<C-s>', submit, { buffer = recap_buf, desc = 'submit' })
    map(session, 'n', 'q', close, { buffer = recap_buf, nowait = true, desc = 'cancel' })
    map(session, 'n', 'x', function()
      local r = recap.rows and recap.rows[vim.api.nvim_win_get_cursor(recap_win)[1]]
      if r and r.value ~= nil then
        recap.excluded[r.value] = not recap.excluded[r.value] or nil
        draw_recap()
      end
    end, { buffer = recap_buf, nowait = true, desc = 'leave out / put back' })
    opts.recap(function(rows, blocked)
      if closed then
        return
      end
      recap.rows, recap.blocked = rows, blocked
      draw_recap()
      run.ready({ session = session.id, event = 'recap' })
      if queued then
        queued = false
        submit()
      end
    end)
  end

  vim.cmd('startinsert')
  run.ready({ session = session.id, event = 'compose' })
end

return M
