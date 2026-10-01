-- `:Diffy threads` (`<leader>dc`): every thread of the review, grouped by
-- where it stands (`GROUPS`), then by file, the file in the diff first. A
-- layout.lua view: in a float over the diff with the thread under the
-- cursor previewed beside it, or compact in the column when
-- `config.column` lists it.
local model = require('diffy.review.model')
local ui = require('diffy.review.ui')
local highlight = require('diffy.highlight')
local session_mod = require('diffy.session')
local layout = require('diffy.layout')
local run = require('diffy.git.run')

local M = {}

-- rows of code in a preview; the middle of a longer range is cut
local SNIPPET_ROWS = 14
-- the column's share the view takes at most
local COLUMN_SHARE = 0.35
-- views named in a preview's "Shown in"; a PR has many commits
local VIEWS_LISTED = 4

-- in display order; `folded` ones start collapsed
local GROUPS = {
  { key = 'open', label = 'Open' },
  { key = 'outdated', label = 'Outdated' },
  { key = 'detached', label = 'Detached' },
  { key = 'resolved', label = 'Resolved', folded = true },
  { key = 'resolved_outdated', label = 'Resolved, outdated', folded = true },
}

local function group_of(t)
  local gone = (t.outdated and 'outdated') or (t._detached and 'detached') or nil
  if t.resolved then
    return gone and 'resolved_outdated' or 'resolved'
  end
  return gone or 'open'
end

--- A thread's `state=` value.
local function state_of(t)
  return t.resolved and 'resolved' or (t.outdated and 'outdated') or (t._detached and 'detached') or 'open'
end

-- an open thread's dot takes its bar's colour
local ICONS = {
  open = { '●' },
  resolved = { '✓', 'DiffyThreadResolved' },
  outdated = { '◌', 'DiffyThreadOutdated' },
  detached = { '✗', 'DiffyThreadOutdated' },
}

--- The view's state: filters, folded groups, what each buffer line shows.
local function state(session)
  if not session.threads_view then
    local folded = {}
    for _, g in ipairs(GROUPS) do
      folded[g.key] = g.folded or false
    end
    session.threads_view = { filters = {}, folded = folded, mine = false, rows = {} }
  end
  return session.threads_view
end

local function review_of(session)
  return type(session.review) == 'table' and session.review or nil
end

--- Entries `{ thread, group, line, here }` matching the filters, by file
--- (the one in the diff first), then line, then age. `here`: shown in the
--- current selection, `line` being where; else `line` is the thread's own.
local function collect(session, st)
  local review = session.review
  local files = {}
  for _, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' then
      files[row.entry.path] = true
    end
  end
  local f = st.filters
  local me = st.mine and review.backend.capabilities.people and review.backend.author(session.root) or nil
  local out = {}
  for _, t in ipairs(review.threads) do
    local author = t.comments[1] and t.comments[1].author or ''
    if
      (not f.author or f.author == author)
      and (not f.state or f.state == state_of(t))
      and (not f.review or f.review == (t.review_id or ''))
      and (not f.path or f.path == t.anchor.path)
      and (not me or me == author)
    then
      local place = files[t.anchor.path] and review.backend.view_place(session, t) or nil
      table.insert(out, {
        thread = t,
        group = group_of(t),
        here = place ~= nil,
        line = place and place.start_line or t.anchor.start_line,
      })
    end
  end
  local current = session.current_path
  table.sort(out, function(a, b)
    local pa, pb = a.thread.anchor.path, b.thread.anchor.path
    if pa ~= pb then
      if pa == current or pb == current then
        return pa == current
      end
      return pa < pb
    end
    if (a.line or 0) ~= (b.line or 0) then
      return (a.line or 0) < (b.line or 0)
    end
    return model.started(a.thread) < model.started(b.thread)
  end)
  return out
end

local function first_line(t)
  return t.comments[1] and vim.split(t.comments[1].body or '', '\n', { plain = true })[1] or ''
end

local function width_of(chunks)
  local n = 0
  for _, c in ipairs(chunks) do
    n = n + vim.fn.strdisplaywidth(c[1])
  end
  return n
end

--- A thread's cells: state, line, who (first author, replies, who spoke
--- last; `me` is "you"), what isn't published yet, first line.
local function cells(session, e, full, me)
  local t = e.thread
  local people = session.review.backend.capabilities.people
  -- threads the selection doesn't show are dimmed where they are
  local loc_hl = not e.here and 'DiffyThreadTime' or nil
  local function person(login)
    if not people or login == me then
      return { 'you', 'DiffyThreadAuthor' }
    end
    return { login or 'unknown', highlight.author(login or 'unknown') }
  end
  local who = { person(t.comments[1] and t.comments[1].author) }
  if #t.comments > 1 then
    table.insert(who, { (' +%d'):format(#t.comments - 1), 'DiffyThreadTime' })
    local last = t.comments[#t.comments].author
    if people and full and last ~= t.comments[1].author then
      table.insert(who, { ' ↩ ', 'DiffyThreadTime' })
      table.insert(who, person(last))
    end
  end
  local badges, seen = {}, {}
  for _, c in ipairs(t.comments) do
    if (c.state == 'draft' or c.state == 'pending') and not seen[c.state] then
      seen[c.state] = true
      table.insert(badges, { (#badges > 0 and ' ' or '') .. c.state, c.state == 'draft' and 'DiffyThreadDraft' or 'DiffyThreadPending' })
    end
  end
  local state_name = state_of(t)
  local icon = ICONS[state_name]
  return {
    icon = { { icon[1], icon[2] or highlight.lane(t.id) } },
    loc = { { e.line and tostring(e.line) or 'file', loc_hl } },
    who = who,
    badges = badges,
    text = { first_line(t), t.resolved and 'DiffyThreadSummaryResolved' or nil },
  }
end

local CELL_ORDER = { 'icon', 'loc', 'who', 'badges' }

--- One line per thread with every cell padded to its widest (line numbers
--- right-aligned), so the first lines start at the same column; the text is
--- cut to `width`.
local function thread_lines(session, entries, width, full)
  local backend = session.review.backend
  local me = backend.capabilities.people and backend.author(session.root) or nil
  local all, w = {}, {}
  for i, e in ipairs(entries) do
    all[i] = cells(session, e, full, me)
    for _, k in ipairs(CELL_ORDER) do
      w[k] = math.max(w[k] or 0, width_of(all[i][k]))
    end
  end
  local out = {}
  for i, c in ipairs(all) do
    local chunks = { { '    ' } }
    for _, k in ipairs(CELL_ORDER) do
      if w[k] > 0 then
        local pad = (' '):rep(w[k] - width_of(c[k]))
        if k == 'loc' then
          table.insert(chunks, { pad })
          vim.list_extend(chunks, c[k])
          table.insert(chunks, { '  ' })
        else
          vim.list_extend(chunks, c[k])
          table.insert(chunks, { pad .. '  ' })
        end
      end
    end
    local room = math.max(1, width - width_of(chunks))
    table.insert(chunks, { highlight.truncate(c.text[1], room), c.text[2] })
    out[i] = chunks
  end
  return out
end

--- Chunk lines -> buffer lines and highlight spans `{ line, from, to, group }`.
local function flatten(chunk_lines)
  local lines, spans = {}, {}
  for i, chunks in ipairs(chunk_lines) do
    local text = ''
    for _, c in ipairs(chunks) do
      if c[2] and #c[1] > 0 then
        table.insert(spans, { i - 1, #text, #text + #c[1], c[2] })
      end
      text = text .. c[1]
    end
    lines[i] = text
  end
  return lines, spans
end

--- What the row under the view's cursor shows, as an identity that
--- survives a re-render.
local function row_key(row)
  if not row then
    return nil
  end
  if row.kind == 'group' then
    return 'group:' .. row.key
  end
  if row.kind == 'file' then
    return ('file:%s:%s'):format(row.group, row.path)
  end
  return 'thread:' .. row.entry.thread.id
end

local function cursor_row(session)
  local win = session.wins.threads
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil, nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  return state(session).rows[lnum], lnum
end

local function title(session)
  local st = state(session)
  local parts = { 'Threads' }
  if st.filters.path then
    table.insert(parts, st.filters.path)
  end
  for _, k in ipairs({ 'author', 'state', 'review' }) do
    if st.filters[k] then
      table.insert(parts, k .. '=' .. st.filters[k])
    end
  end
  if st.mine then
    table.insert(parts, 'mine')
  end
  return table.concat(parts, ' · ')
end

local function render(session)
  local buf = session.bufs.threads
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local st = state(session)
  local win = session.wins.threads
  local shown = win and vim.api.nvim_win_is_valid(win)
  local full = layout.host(session, 'threads') == 'float'
  local width = shown and highlight.text_width(win) - 1 or 40
  local prev_row, prev_lnum = cursor_row(session)
  local prev_key = row_key(prev_row)

  local chunk_lines, rows = {}, {}
  local review = review_of(session)
  if not review then
    chunk_lines = { { { '  no review in this view', 'DiffyThreadTime' } } }
  else
    local by_group = {}
    for _, e in ipairs(collect(session, st)) do
      by_group[e.group] = by_group[e.group] or {}
      table.insert(by_group[e.group], e)
    end
    for _, g in ipairs(GROUPS) do
      local entries = by_group[g.key]
      if entries then
        if #chunk_lines > 0 then
          table.insert(chunk_lines, { { '' } })
        end
        local folded = st.folded[g.key]
        table.insert(chunk_lines, {
          { (folded and '▸ ' or '▾ ') .. g.label, 'DiffyLabel' },
          { ('  %d'):format(#entries), 'DiffyThreadTime' },
        })
        rows[#chunk_lines] = { kind = 'group', key = g.key }
        if not folded then
          local path
          for i, chunks in ipairs(thread_lines(session, entries, width, full)) do
            local e = entries[i]
            if e.thread.anchor.path ~= path then
              path = e.thread.anchor.path
              table.insert(chunk_lines, {
                { '  ' },
                { highlight.truncate_path(path, width - 2), path == session.current_path and { 'DiffyDirectory', 'DiffyCurrentFileName' } or 'DiffyDirectory' },
              })
              rows[#chunk_lines] = { kind = 'file', path = path, entry = e, group = g.key }
            end
            table.insert(chunk_lines, chunks)
            rows[#chunk_lines] = { kind = 'thread', entry = e, group = g.key }
          end
        end
      end
    end
    if #chunk_lines == 0 then
      chunk_lines = { { { '  no threads', 'DiffyThreadTime' } } }
    end
  end
  st.rows = rows

  local lines, spans = flatten(chunk_lines)
  local grew = vim.api.nvim_buf_line_count(buf) ~= #lines
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = session_mod.namespace(session, 'threads_render')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, sp in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, sp[1], sp[2], { end_col = sp[3], hl_group = sp[4] })
  end

  if not shown then
    return
  end
  -- back on the same thread or group; else the same line (what was under
  -- it moved into a folded group), and on a fresh view the first thread of
  -- the file in the diff, else the first thread
  local target
  for lnum, row in pairs(rows) do
    if prev_key and row_key(row) == prev_key then
      target = lnum
    end
  end
  if not target and prev_key then
    target = math.min(prev_lnum, #lines)
  end
  if not target then
    local first
    for lnum = 1, #lines do
      local row = rows[lnum]
      if row and row.kind == 'thread' then
        first = first or lnum
        if row.entry.thread.anchor.path == session.current_path then
          target = lnum
          break
        end
      end
    end
    target = target or first or 1
  end
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  if full then
    layout.place_float(session, 'threads')
  elseif grew then
    layout.relayout(session)
  end
end

--- The code a thread is on, as a fenced block in the file's language (the
--- preview's markdown highlighting injects it), lines cut to `width`.
--- Returns the lines and, per 1-based line, its snippet row.
local function code_block(t, width)
  local snippet = model.snippet(t, SNIPPET_ROWS)
  if not snippet then
    return nil
  end
  -- a fence longer than any backtick run in the code
  local fence = 3
  for _, r in ipairs(snippet) do
    for run_ in (r.text or ''):gmatch('`+') do
      fence = math.max(fence, #run_ + 1)
    end
  end
  fence = ('`'):rep(fence)
  local lines, at = { fence .. (vim.filetype.match({ filename = t.anchor.path }) or '') }, {}
  for _, r in ipairs(snippet) do
    if r.gap then
      at[#lines] = at[#lines] or {}
      at[#lines].gap = r.gap
    else
      table.insert(lines, highlight.truncate(r.text, width))
      at[#lines] = { row = r }
    end
  end
  table.insert(lines, fence)
  table.insert(lines, '')
  return lines, at
end

--- The preview pane: the thread under the cursor, under the code it's on.
local function preview(session, buf, win)
  local card_ns = session_mod.namespace(session, 'review_card')
  local ns = session_mod.namespace(session, 'review_snippet')
  vim.api.nvim_buf_clear_namespace(buf, card_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local row = cursor_row(session)
  if not (row and row.kind == 'thread') then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.bo[buf].modifiable = false
    vim.api.nvim_win_set_config(win, { title = '' })
    vim.wo[win].winhighlight = highlight.CARD_HL
    return
  end
  local e = row.entry
  local t = e.thread
  -- '%5s' line number + 2 spaces, see the virt_text below
  local gutter = 7
  local code, code_at = code_block(t, math.max(20, vim.api.nvim_win_get_width(win) - gutter - 1))
  local lines, at = {}, {}
  local backend = session.review.backend
  if backend.visible_in then
    local views = backend.visible_in(session, t)
    local text = 'Not shown inline in any view'
    if #views > 0 then
      text = 'Shown in: ' .. table.concat(vim.list_slice(views, 1, VIEWS_LISTED), ', ')
      if #views > VIEWS_LISTED then
        text = text .. (' and %d more commits'):format(#views - VIEWS_LISTED)
      end
    end
    table.insert(lines, text)
    table.insert(lines, '')
  end
  for i, l in ipairs(code or {}) do
    lines[#lines + 1] = l
    at[#lines] = code_at[i]
  end
  ui.render_thread(session, buf, t, { preamble = lines })
  local lane = highlight.lane(t.id)
  for i, a in pairs(at) do
    if a.row then
      local r = a.row
      -- the commented lines stand out as in the diff: number and bar in the
      -- thread's colour
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = {
          { ('%5s'):format(r.n or ''), r.range and { lane, 'DiffyThreadCurrent' } or 'LineNr' },
          { r.range and ' │' or '  ', lane },
        },
        virt_text_pos = 'inline',
        line_hl_group = r.kind == 'add' and 'DiffAdd' or r.kind == 'del' and 'DiffDelete' or nil,
      })
    end
    if a.gap then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_lines = { { { ('%s⋯ %d more line%s'):format((' '):rep(gutter), a.gap, a.gap == 1 and '' or 's'), 'Comment' } } },
      })
    end
  end
  local wo = vim.wo[win]
  wo.wrap, wo.linebreak, wo.breakindent = true, true, true
  wo.conceallevel, wo.concealcursor = 2, 'nvic'
  wo.winhighlight = highlight.card_hl(t)
  require('diffy.review.render').attach(session, win, buf)
  local where = e.line and ('%s:%d'):format(t.anchor.path, e.line) or t.anchor.path
  vim.api.nvim_win_set_config(win, { title = { { ' ' .. where .. ' ', 'DiffyThreadHeader' } }, title_pos = 'left' })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

--- Into the thread: the float closes, the diff shows it (switching the
--- selection when this one doesn't) and hovers it.
local function jump(session, t)
  if layout.host(session, 'threads') == 'float' then
    layout.close_float(session, 'threads')
  end
  ui.goto_thread(session, t)
end

local function toggle_group(session, key)
  local st = state(session)
  st.folded[key] = not st.folded[key]
  layout.refresh(session, 'threads')
end

local function scroll_preview(session, key)
  local f = session.floats.threads
  if f and f.preview and vim.api.nvim_win_is_valid(f.preview) then
    vim.api.nvim_win_call(f.preview, function()
      vim.cmd.normal({ vim.keycode(key), bang = true })
    end)
  end
end

local function setup(session, buf)
  local map = session_mod.map
  map(session, 'n', '<CR>', function()
    local row = cursor_row(session)
    if row and row.kind == 'group' then
      toggle_group(session, row.key)
    elseif row then
      jump(session, row.entry.thread)
    end
  end, { buffer = buf, desc = 'go to thread / fold group' })
  map(session, 'n', '<Tab>', function()
    local row = cursor_row(session)
    if row then
      toggle_group(session, row.kind == 'group' and row.key or row.group)
    end
  end, { buffer = buf, desc = 'fold group' })
  map(session, 'n', 'x', function()
    local row = cursor_row(session)
    local review = review_of(session)
    if not (row and row.kind == 'thread' and review) then
      return
    end
    if not review.backend.capabilities.resolve then
      vim.notify(("diffy: resolving isn't available for %s"):format(review.backend.name), vim.log.levels.WARN)
      return
    end
    ui.set_resolved(session, row.entry.thread, not row.entry.thread.resolved)
  end, { buffer = buf, desc = 'resolve/unresolve thread' })
  map(session, 'n', 'm', function()
    local review = review_of(session)
    if not (review and review.backend.capabilities.people) then
      return
    end
    local st = state(session)
    st.mine = not st.mine
    layout.refresh(session, 'threads')
  end, { buffer = buf, desc = 'only your threads' })
  map(session, 'n', '<C-f>', function()
    scroll_preview(session, '<C-d>')
  end, { buffer = buf, desc = 'scroll the preview down' })
  map(session, 'n', '<C-b>', function()
    scroll_preview(session, '<C-u>')
  end, { buffer = buf, desc = 'scroll the preview up' })
  layout.map_toggle(session, buf)
end

M.view = {
  label = ' Threads',
  title = title,
  setup = setup,
  render = render,
  preview = preview,
  keys = function(session)
    local review = review_of(session)
    local keys = { { '<CR>', 'go to' }, { '<Tab>', 'fold', drop = 2 } }
    if review and review.backend.capabilities.resolve then
      table.insert(keys, { 'x', 'resolve', drop = 3 })
    end
    if review and review.backend.capabilities.people then
      table.insert(keys, { 'm', state(session).mine and 'everyone' or 'mine', drop = 1 })
    end
    return keys
  end,
  height = function(session, room)
    local buf = session.bufs.threads
    local n = buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_line_count(buf) or 1
    return math.max(3, math.min(n, math.floor(room * COLUMN_SHARE)))
  end,
}

--- `:Diffy threads [file] [author=<name>] [state=<open|resolved|outdated|
--- detached>] [review=<id>]`: the view with these filters, `file` keeping
--- the threads of the file in the diff.
function M.open(session, args)
  local review = ui.ensure(session)
  if not review then
    vim.notify('diffy: review is only available in :Diffy, :Diffy branch and :Diffy pr', vim.log.levels.WARN)
    return
  end
  local filters = {}
  for _, a in ipairs(args or {}) do
    local k, v = a:match('^(%a+)=(.*)$')
    if k then
      filters[k] = v
    elseif a == 'file' then
      if not session.current_path then
        vim.notify('diffy: no file shown in the diff', vim.log.levels.WARN)
        return
      end
      filters.path = session.current_path
    end
  end
  state(session).filters = filters
  layout.show(session, 'threads')
  run.ready({ session = session.id, event = 'threads' })
end

return M
