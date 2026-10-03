-- The commit message float: resting the cursor on a commit row of the log
-- shows its full message next to the log window; on the GitHub layer's PR
-- row, the PR's description, reviewers and conversation.
local run = require('diffy.git.run')
local session_mod = require('diffy.session')

local M = {}

local DEBOUNCE_MS = 80
local MAX_WIDTH = 100
local SEP = '\31'

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function state(session)
  session.commitmsg = session.commitmsg or { seq = 0 }
  return session.commitmsg
end

local function cursor_row(session)
  local win = session.wins.log
  if not valid(win) or vim.api.nvim_get_current_win() ~= win then
    return nil
  end
  return require('diffy.panels.stack').cursor(session, 'log')
end

local function commit_at(session, row)
  local e = row and session.entries and session.entries[row]
  return e and e.kind == 'commit' and e or nil
end

--- Word-wrap `text` at `width` cells; long words are cut.
local function wrap(text, width, out)
  if text == '' then
    table.insert(out, '')
    return
  end
  local line = ''
  for word in text:gmatch('%S+') do
    while vim.fn.strdisplaywidth(word) > width do
      if line ~= '' then
        table.insert(out, line)
        line = ''
      end
      local head = vim.fn.strcharpart(word, 0, width)
      table.insert(out, head)
      word = word:sub(#head + 1)
    end
    if line == '' then
      line = word
    elseif vim.fn.strdisplaywidth(line) + 1 + vim.fn.strdisplaywidth(word) <= width then
      line = line .. ' ' .. word
    else
      table.insert(out, line)
      line = word
    end
  end
  if line ~= '' then
    table.insert(out, line)
  end
end

--- `uv.now()` stamp `t` as `just now` / `3 min ago` / `2 h ago`.
local function ago(t)
  local s = math.floor((vim.uv.now() - t) / 1000)
  if s < 60 then
    return 'just now'
  elseif s < 3600 then
    return ('%d min ago'):format(math.floor(s / 60))
  end
  return ('%d h ago'):format(math.floor(s / 3600))
end

local STATE_TEXT = { APPROVED = 'approved', CHANGES_REQUESTED = 'changes requested', COMMENTED = 'commented', DISMISSED = 'dismissed' }

--- The PR row's float: description, each reviewer's latest state, every
--- review with where its commit is, then the conversation.
local function pr_content(session, width)
  local l = session.layer
  local pr = l.cache.pr
  local icon = require('diffy.panels.log').STATE_ICON
  local head = ('#%d'):format(pr.number)
  local lines = { head .. ' ' .. (pr.title or '') }
  local spans = { { 0, #head, 'DiffySha' } }
  local function section(title)
    table.insert(lines, '')
    table.insert(lines, title)
    table.insert(spans, { #lines - 1, 0, #title, 'DiffyLabel' })
  end
  local syncing = require('diffy.review.github').sync_status(session) == 'syncing'
  local read = l.offline and 'Offline: from the last read' or (l.read_at and ('Read %s'):format(ago(l.read_at)) or nil)
  local state = syncing and ('Syncing…' .. (read and ('  ' .. read) or '')) or read
  if state then
    table.insert(lines, state)
    table.insert(spans, { #lines - 1, 0, #state, 'DiffyThreadTime' })
  end
  if l.sync_error then
    local msg = 'Sync failed: ' .. l.sync_error
    table.insert(lines, msg)
    table.insert(spans, { #lines - 1, 0, #msg, 'DiffySyncFailed' })
  end
  table.insert(lines, '')
  local body = vim.trim((pr.body or ''):gsub('\r', ''))
  for _, b in ipairs(vim.split(body ~= '' and body or 'No description provided.', '\n', { plain = true })) do
    wrap(b, width, lines)
  end
  local listed = {}
  for _, e in ipairs(session.entries or {}) do
    if e.kind == 'commit' then
      listed[e.sha] = true
    end
  end
  local latest, order = {}, {}
  local reviews = vim.tbl_filter(function(rv)
    return rv.state ~= 'PENDING'
  end, pr.reviews or {})
  for _, rv in ipairs(reviews) do
    local who = rv.author or 'unknown'
    if not latest[who] then
      table.insert(order, who)
    end
    -- a comment doesn't replace an approval or a change request
    if not latest[who] or rv.state ~= 'COMMENTED' or latest[who] == 'COMMENTED' then
      latest[who] = rv.state
    end
  end
  if #order > 0 then
    section('Reviewers')
    for _, who in ipairs(order) do
      local s = latest[who]
      table.insert(lines, ('  %s %s %s'):format(who, icon[s] or '○', STATE_TEXT[s] or s:lower()))
    end
    section('Reviews')
    for _, rv in ipairs(reviews) do
      local line = ('  %s %s %s'):format(rv.author or 'unknown', icon[rv.state] or '○', (rv.commit or ''):sub(1, 7))
      if rv.commit and not listed[rv.commit] then
        line = line .. ((l.reach or {})[rv.commit] and '  not in this log' or '  no longer in the branch')
      end
      table.insert(lines, line)
    end
  end
  if #(pr.conversation or {}) > 0 then
    section('Conversation')
    for _, c in ipairs(pr.conversation) do
      local who = ('  %s  %s'):format(c.author or 'unknown', (c.created_at or ''):sub(1, 10))
      table.insert(lines, who)
      table.insert(spans, { #lines - 1, 2, 2 + #(c.author or 'unknown'), 'DiffyThreadAuthor' })
      for _, b in ipairs(vim.split(vim.trim((c.body or ''):gsub('\r', '')), '\n', { plain = true })) do
        local wrapped = {}
        wrap(b, width - 4, wrapped)
        for _, w in ipairs(#wrapped > 0 and wrapped or { '' }) do
          table.insert(lines, '    ' .. w)
        end
      end
    end
  end
  return lines, spans
end

--- Header and wrapped body for `msg`, plus highlight spans (`{ col, end,
--- group }` on the first line, or `{ line, col, end, group }`).
local function content(session, msg, width)
  if msg.pr then
    return pr_content(session, width)
  end
  local sha = msg.sha:sub(1, 7)
  local header = sha .. '  ' .. msg.author .. '  ' .. msg.date
  local spans = {
    { 0, #sha, 'DiffySha' },
    { #sha + 2, #sha + 2 + #msg.author, 'DiffyThreadAuthor' },
    { #sha + 4 + #msg.author, #header, 'DiffyThreadTime' },
  }
  local lines = { header, '' }
  local body = vim.split(vim.trim(msg.body), '\n', { plain = true })
  for _, l in ipairs(body) do
    wrap(l, width, lines)
  end
  return lines, spans
end

--- Editor-relative config beside the log window, aligned with its cursor row.
local function config(session, lines_fn)
  local log = session.wins.log
  local pos = vim.api.nvim_win_get_position(log)
  local is_float = vim.api.nvim_win_get_config(log).relative ~= ''
  -- a float's position is its frame's corner
  local right = pos[2] + vim.api.nvim_win_get_width(log) + (is_float and 2 or 1)
  local room = vim.o.columns - right - 2
  local col = right
  if room < 30 then
    -- no room beside a float host: overlap its right side instead
    room = math.min(MAX_WIDTH, vim.o.columns - 2)
    col = nil
  end
  local lines, spans = lines_fn(math.max(10, math.min(MAX_WIDTH, room)))
  local width = 1
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, math.max(10, math.min(MAX_WIDTH, room)))
  local height = math.max(1, math.min(#lines, vim.o.lines - 2 - vim.o.cmdheight - 2))
  local srow = vim.fn.screenpos(log, vim.api.nvim_win_get_cursor(log)[1], 1).row
  local row = srow > 0 and srow - 1 or pos[1]
  -- the frame's top border sits on the cursor row's line above the text
  row = math.max(0, math.min(row - 1, vim.o.lines - vim.o.cmdheight - height - 2))
  return {
    relative = 'editor',
    row = row,
    col = col or (vim.o.columns - width - 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    zindex = 60,
  },
    lines,
    spans
end

function M.close(session)
  local st = state(session)
  st.row = nil
  local win = session.wins.commitmsg
  session_mod.unregister_window(session, 'commitmsg')
  session.bufs.commitmsg = nil
  if valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function draw(session, msg)
  local st = state(session)
  local cfg, lines, spans = config(session, function(w)
    return content(session, msg, w)
  end)
  local win = session.wins.commitmsg
  local buf = session.bufs.commitmsg
  if not (valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = session_mod.scratch_buf(session, 'commitmsg')
    session_mod.register_buffer(session, 'commitmsg', buf)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = session_mod.namespace(session, 'commitmsg')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, sp in ipairs(spans) do
    local line = #sp == 4 and sp[1] or 0
    local s = #sp == 4 and { sp[2], sp[3], sp[4] } or sp
    vim.api.nvim_buf_set_extmark(buf, ns, line, s[1], { end_col = math.min(s[2], #lines[line + 1]), hl_group = s[3] })
  end
  if valid(win) then
    vim.api.nvim_win_set_config(win, cfg)
  else
    win = vim.api.nvim_open_win(buf, false, cfg)
    session_mod.register_window(session, 'commitmsg', win, { transient = true })
    -- opened from the log, never a diff window, but never bound either way
    session_mod.unbind(win)
    vim.wo[win].diff = false
    vim.wo[win].winhighlight = require('diffy.highlight').CARD_HL
    vim.wo[win].wrap = false
  end
  st.shown = msg
  run.ready({ session = session.id, event = 'commitmsg' })
end

local function parse(stdout)
  local sha, author, date, body = stdout:match('^(.-)' .. SEP .. '(.-)' .. SEP .. '(.-)' .. SEP .. '(.*)$')
  if not sha then
    return nil
  end
  return { sha = vim.trim(sha), author = author, date = date, body = body }
end

--- Show the float for the cursor row, or close it when that row isn't a
--- commit or the PR row.
function M.update(session)
  local st = state(session)
  local row = cursor_row(session)
  local e = row and session.entries and session.entries[row]
  local pr_row = e and e.kind == 'pr' and session.layer and session.layer.attached
  local entry = commit_at(session, row)
  if not (entry or pr_row) or st.suppressed == row then
    local was_open = valid(session.wins.commitmsg)
    M.close(session)
    if was_open then
      run.ready({ session = session.id, event = 'commitmsg' })
    end
    return
  end
  st.row = row
  if pr_row then
    draw(session, { pr = true })
    return
  end
  session.commit_msgs = session.commit_msgs or {}
  local cached = session.commit_msgs[entry.sha]
  if cached then
    draw(session, cached)
    return
  end
  run.git({ 'show', '-s', '--format=%H%x1f%an%x1f%ar%x1f%B', entry.sha }, {
    cwd = session.root,
    session = session,
    on_exit = function(res)
      local msg = res.code == 0 and parse(res.stdout or '') or nil
      if not msg then
        return
      end
      session.commit_msgs[entry.sha] = msg
      local now = cursor_row(session)
      if st.row == row and now == row and commit_at(session, now) == entry and st.suppressed ~= row then
        draw(session, msg)
      end
    end,
  })
end

function M.setup(session)
  local buf = session.bufs.log
  local group = session.augroup
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter' }, {
    group = group,
    buffer = buf,
    callback = function()
      local st = state(session)
      local row = cursor_row(session)
      if row == st.last then
        return
      end
      st.last = row
      st.suppressed = nil
      st.seq = st.seq + 1
      local seq = st.seq
      vim.defer_fn(function()
        if not session.closed and st.seq == seq then
          M.update(session)
        end
      end, DEBOUNCE_MS)
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    group = group,
    buffer = buf,
    callback = function()
      local st = state(session)
      st.seq = st.seq + 1
      st.last = nil
      if valid(session.wins.commitmsg) then
        vim.schedule(function()
          if not session.closed and cursor_row(session) == nil then
            M.close(session)
            run.ready({ session = session.id, event = 'commitmsg' })
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      local st = state(session)
      if valid(session.wins.commitmsg) and st.shown and cursor_row(session) then
        draw(session, st.shown)
      end
    end,
  })
  require('diffy.panels.stack').map(session, 'log', 'n', '<Esc>', function()
    local st = state(session)
    local shown = valid(session.wins.commitmsg)
    st.suppressed = cursor_row(session)
    st.seq = st.seq + 1
    M.close(session)
    return shown
  end, { buffer = buf, fallback = true, desc = 'close the commit message' })
end

return M
