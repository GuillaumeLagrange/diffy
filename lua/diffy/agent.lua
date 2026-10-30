-- Handing what you look at to your agent: `config.send_to_agent(text, ctx)`,
-- or the `+` register without one. diffy only builds the text (markdown) and
-- a plain-data `ctx`; how it reaches the agent is the user's callback.
local M = {}

--- Give `text` to the agent: the configured callback, else `+`. `what` names
--- it in the message.
function M.send(text, ctx, what)
  local fn = require('diffy').config.send_to_agent
  if not fn then
    vim.fn.setreg('+', text)
    vim.notify(('diffy: %s copied to +'):format(what))
    return true
  end
  local ok, err = pcall(fn, text, ctx)
  if not ok then
    vim.notify('diffy: send_to_agent failed: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  vim.notify(('diffy: %s sent to the agent'):format(what))
  return true
end

local function base_ctx(session, kind)
  return { kind = kind, root = session.root, branch = session.branch }
end

--- A fence longer than any backtick run in `lines`.
local function fence(lines)
  local n = 3
  for _, l in ipairs(lines) do
    for run in l:gmatch('`+') do
      n = math.max(n, #run + 1)
    end
  end
  return ('`'):rep(n)
end

local function rev_text(rev)
  if rev == 'WORKTREE' then
    return 'the working tree'
  elseif rev == 'INDEX' then
    return 'the index'
  end
  return rev:match('^%x+$') and rev:sub(1, 7) or rev
end

local function guide_lines(out, sections)
  for _, g in ipairs(sections) do
    table.insert(out, '')
    table.insert(out, ('The branch guide\'s section %d, "%s":'):format(g.index, g.title))
    if g.body ~= '' then
      vim.list_extend(out, vim.split(g.body, '\n', { plain = true }))
    end
    for _, n in ipairs(g.notes) do
      table.insert(out, 'Note on this change: ' .. n)
    end
  end
end

local function thread_lines(out, threads)
  if #threads == 0 then
    return
  end
  table.insert(out, '')
  table.insert(out, 'Review comments on these lines:')
  for _, t in ipairs(threads) do
    for i, c in ipairs(t.comments) do
      local body = vim.split(c.body, '\n', { plain = true })
      table.insert(out, ('%s %s%s: %s'):format(i == 1 and '-' or '  -', c.author, t.resolved and ' (resolved)' or '', body[1]))
      for k = 2, #body do
        table.insert(out, (i == 1 and '  ' or '    ') .. body[k])
      end
    end
  end
end

--- Lines `first`..`last` of diff window `win`: the code, the guide sections
--- covering them, the review threads on them.
function M.lines(session, win, first, last)
  local name = session.wins.left == win and 'left' or session.wins.right == win and 'right' or nil
  local path, rev = vim.w[win].diffy_path, vim.w[win].diffy_rev
  if not (name and path and rev) then
    vim.notify('diffy: no file here', vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local code = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local side = name == 'right' and 'new' or 'old'
  local guide = {}
  for _, g in ipairs(require('diffy.panels.guide').sections_at(session, session.current_path, side, first, last)) do
    table.insert(guide, { index = g.index, title = g.title, body = g.body, notes = g.notes })
  end
  local threads, seen = {}, {}
  local ui = require('diffy.review.ui')
  for l = first, last do
    for _, t in ipairs(ui.threads_at(session, win, l)) do
      if not seen[t] then
        seen[t] = true
        local comments = {}
        for _, c in ipairs(t.comments) do
          table.insert(comments, { author = c.author or 'you', body = vim.trim(c.body or '') })
        end
        table.insert(threads, { resolved = t.resolved or false, comments = comments })
      end
    end
  end
  local range = first == last and ('line %d'):format(first) or ('lines %d-%d'):format(first, last)
  local out = { ('`%s` in %s, %s:'):format(path, rev_text(rev), range) }
  local f = fence(code)
  table.insert(out, f .. vim.bo[buf].filetype)
  vim.list_extend(out, code)
  table.insert(out, f)
  guide_lines(out, guide)
  thread_lines(out, threads)
  local ctx = base_ctx(session, 'lines')
  ctx.path, ctx.rev, ctx.side, ctx.first, ctx.last = path, rev, name, first, last
  ctx.lines, ctx.guide, ctx.threads = code, guide, threads
  M.send(table.concat(out, '\n'), ctx, range)
end

--- A section of the guide (`item`: the item you're on, else nil).
function M.guide(session, sec, item)
  local out = { ('The branch guide\'s section %d, "%s":'):format(sec.index, sec.title) }
  if sec.body ~= '' then
    vim.list_extend(out, vim.split(sec.body, '\n', { plain = true }))
  end
  local items = {}
  for _, it in ipairs(sec.hunks) do
    local h = it.git[1]
    local notes = vim.tbl_map(function(n)
      return n.text
    end, it.notes)
    table.insert(items, { path = it.path, line = h and (h.new_count > 0 and h.new_start or h.old_start) or nil, notes = notes })
  end
  local function where(i)
    return '`' .. i.path .. (i.line and (':' .. i.line) or '') .. '`' .. (#i.notes > 0 and (': ' .. table.concat(i.notes, '; ')) or '')
  end
  local shown
  if item then
    for i, it in ipairs(sec.hunks) do
      if it == item then
        shown = items[i]
      end
    end
  end
  if shown then
    table.insert(out, '')
    table.insert(out, 'About the change at ' .. where(shown))
  elseif #items > 0 then
    table.insert(out, '')
    table.insert(out, 'Its changes:')
    for _, i in ipairs(items) do
      table.insert(out, '- ' .. where(i))
    end
  end
  local ctx = base_ctx(session, 'guide')
  ctx.section = { index = sec.index, title = sec.title, body = sec.body, items = items }
  ctx.item = shown
  M.send(table.concat(out, '\n'), ctx, 'guide section')
end

--- Map `keymaps.send_to_agent` on diff buffer `buf`: the cursor line, or the
--- visual selection's lines.
function M.map_diff(session, buf)
  local key = require('diffy').config.keymaps.send_to_agent
  if not key or key == '' then
    return
  end
  local map = require('diffy.session').map
  map(session, 'n', key, function()
    local l = vim.api.nvim_win_get_cursor(0)[1]
    M.lines(session, vim.api.nvim_get_current_win(), l, l)
  end, { buffer = buf, desc = 'send the line to the agent' })
  map(session, 'x', key, function()
    local a, b = vim.fn.line('v'), vim.fn.line('.')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
    M.lines(session, vim.api.nvim_get_current_win(), math.min(a, b), math.max(a, b))
  end, { buffer = buf, desc = 'send the lines to the agent' })
end

return M
