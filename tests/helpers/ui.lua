-- Observation helpers: describe what the user sees, never
-- diffy's internal tables. Each takes the `MiniTest.child` driving the UI
-- (except `git`, which inspects the fixture repo directly on disk).
--
-- `wins` is the one exception: it looks the session's windows up so a test
-- can *address* them (focus, move the cursor). Never assert on its result.
local M = {}

--- Window ids of the session in `child`'s current tab, by role (`tree`,
--- `log`, `left`, `right`, and during a conflict `ours`, `theirs`, `base`,
--- `result`), or `{}` if none is open. The tree and the log share one
--- window in the default column. For addressing only.
function M.wins(child)
  return child.lua_get([[(function()
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    return s and s.wins or {}
  end)()]])
end

--- Buffer line of `view`'s ('tree' | 'log') row `row` in its window, for
--- moving the cursor there. For addressing only.
function M.lnum(child, view, row)
  return child.lua(
    [[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    return require('diffy.panels.stack').lnum(s, ...)
  ]],
    { view, row }
  )
end

--- Put `view`'s window cursor on its row `row`, focusing the window.
function M.cursor_to(child, view, row)
  local win = M.wins(child)[view]
  child.api.nvim_set_current_win(win)
  child.api.nvim_win_set_cursor(win, { M.lnum(child, view, row), 0 })
end

--- `{ tree = lines, log = lines, left = side, right = side, diff = bool,
---   bars = { winbar, … } }` for the session in `child`'s current tab, or
--- `nil` if none is open. A side is `{ rev, path, bar, name, text }`: `bar` is
--- the winbar as drawn, `rev`/`path` are parsed from it (`'worktree'`,
--- `'index'`, `'HEAD'` or a 7-char sha, then the path; both nil for
--- placeholders like `(outside diff)`), `name` the buffer name and `text` its
--- lines. `bars` lists every window's winbar in the tab, in screen order.
function M.layout(child)
  local result = child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return vim.NIL end
    local function ok(win) return win and vim.api.nvim_win_is_valid(win) end

    -- a view's own rows: the tree and the log may share a buffer
    local function view_lines(name)
      if not ok(s.wins[name]) then return vim.NIL end
      local first, count = require('diffy.panels.stack').range(s, name)
      return vim.api.nvim_buf_get_lines(s.bufs[name], first, first + count, false)
    end

    local function side(win)
      if not ok(win) then return vim.NIL end
      local buf = vim.api.nvim_win_get_buf(win)
      local bar = vim.wo[win].winbar
      local rev, path = bar:match('^(%S+)  (.+)$')
      return {
        rev = rev, path = path, bar = bar,
        name = vim.api.nvim_buf_get_name(buf),
        text = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      }
    end

    local wins = vim.api.nvim_tabpage_list_wins(0)
    table.sort(wins, function(a, b)
      local pa, pb = vim.api.nvim_win_get_position(a), vim.api.nvim_win_get_position(b)
      return pa[2] < pb[2] or (pa[2] == pb[2] and pa[1] < pb[1])
    end)
    local bars = {}
    for _, w in ipairs(wins) do table.insert(bars, vim.wo[w].winbar) end

    return {
      tree = view_lines('tree'),
      log = view_lines('log'),
      left = side(s.wins.left),
      right = side(s.wins.right),
      diff = ok(s.wins.left) and vim.wo[s.wins.left].diff or false,
      bars = bars,
    }
  ]])
  if result == vim.NIL then
    return nil
  end
  return result
end

--- Rows of the `panel` ('log' | 'tree') as drawn: `{ { text, hl = { group =
--- true, … } }, … }`, where `hl` holds the whole-line and line-number
--- highlight groups rendered on that row (`DiffySelection`, `DiffyMerge`,
--- `DiffyCurrentFile`, `DiffyThreadRange`).
function M.panel(child, panel)
  return child.lua(([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    local win = s and s.wins[%q]
    if not (win and vim.api.nvim_win_is_valid(win)) then return {} end
    local buf = vim.api.nvim_win_get_buf(win)
    local first, count = require('diffy.panels.stack').range(s, %q)
    local rows = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, first, first + count, false)) do
      rows[i] = { text = l, hl = vim.empty_dict() }
    end
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      local row = rows[m[2] - first + 1]
      if row then
        for _, key in ipairs({ 'line_hl_group', 'number_hl_group' }) do
          local g = m[4][key]
          if g then row.hl[g] = true end
        end
      end
    end
    return rows
  ]]):format(panel, panel))
end

--- Texts of the `panel` rows drawn with line or line-number highlight `group`.
function M.rows_with(child, panel, group)
  local out = {}
  for _, r in ipairs(M.panel(child, panel)) do
    if r.hl[group] then
      table.insert(out, r.text)
    end
  end
  return out
end

--- Lines of `win`'s buffer drawn on screen (first cell) with background `bg`
--- (0xRRGGBB, under 'termguicolors'); lines scrolled out of view are left
--- out. With `want`, first waits up to 1 s for exactly those lines: a colour
--- can land a redraw after the DiffyReady that drew the file.
function M.lines_with_bg(child, win, bg, want)
  return child.lua(
    [[
    local win, bg, want = ...
    local function lines()
      vim.cmd('redraw!')
      local out = {}
      for l = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) do
        local pos = vim.fn.screenpos(win, l, 1)
        local cell = pos.row > 0 and vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)
        if cell and cell[2] and cell[2].background == bg then
          table.insert(out, l)
        end
      end
      return out
    end
    if want then
      vim.wait(1000, function() return vim.deep_equal(lines(), want) end, 20)
    end
    return lines()
  ]],
    { win, bg, want }
  )
end

--- Names of every `diffy://` buffer still loaded in `child`.
function M.diffy_buffers(child)
  return child.lua_get([[(function()
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local n = vim.api.nvim_buf_get_name(b)
      if n:find('^diffy://') then table.insert(out, n) end
    end
    return out
  end)()]])
end

--- Commit subjects of log rows `texts` (default: every drawn log row),
--- stripped of the current-row marker, padding and 7-char sha;
--- 'Working tree' passes through.
function M.log_subjects(child, texts)
  local out = {}
  for i, t in ipairs(texts or M.layout(child).log) do
    out[i] = (t:gsub('^\226\150\140', ''):gsub('^%s*', ''):gsub('^%x%x%x%x%x%x%x ', ''))
  end
  return out
end

--- Put the log cursor on `row` (a line number, or the first row containing
--- string `row`) and press `<CR>`, waiting for the `select` render.
function M.select_log_row(child, row)
  if type(row) == 'string' then
    local needle = row
    for i, l in ipairs(M.layout(child).log) do
      if l:find(needle, 1, true) then
        row = i
        break
      end
    end
    assert(type(row) == 'number', needle .. ' not in the log')
  end
  M.cursor_to(child, 'log', row)
  M.arm_ready(child, 'select')
  child.type_keys('<CR>')
  M.wait_ready(child)
end

--- Focus the tree, put the cursor on `path`'s row, press `key` and wait (up
--- to `timeout` ms) for the `event` DiffyReady it triggers.
function M.open_tree_row(child, path, key, event, timeout)
  local found
  for i, row in ipairs(M.panel(child, 'tree')) do
    if row.text:find(path, 1, true) then
      found = i
      break
    end
  end
  assert(found, path .. ' not in the tree')
  M.cursor_to(child, 'tree', found)
  M.arm_ready(child, event)
  child.type_keys(key)
  M.wait_ready(child, timeout)
end

--- Record every WARN/ERROR `vim.notify` message from now on, instead of
--- displaying it; read them with `M.warnings`.
function M.capture_warnings(child)
  child.lua([[
    _G.__diffy_warnings = {}
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN or level == vim.log.levels.ERROR then
        table.insert(_G.__diffy_warnings, { msg = msg, level = level })
      end
    end
  ]])
end

--- Messages recorded since `M.capture_warnings`, only those at `level`
--- ('WARN'/'ERROR') if given. Raw API, so it also works while the child is
--- transiently blocking.
function M.warnings(child, level)
  local out = {}
  for _, w in ipairs(child.api.nvim_exec_lua('return _G.__diffy_warnings', {})) do
    if not level or w.level == vim.log.levels[level] then
      table.insert(out, w.msg)
    end
  end
  return out
end

--- Runs `git <args>` in fixture repo `dir`, for asserting HEAD/index/branch/
--- files on disk. Returns trimmed stdout; raises on nonzero exit.
function M.git(dir, args)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  if res.code ~= 0 then
    error(('ui.git: `git %s` failed (%d)\n%s'):format(table.concat(args, ' '), res.code, res.stderr or ''), 2)
  end
  return vim.trim(res.stdout or '')
end

--- Threads currently rendered in `side`'s window ('left'|'right') of the
--- session in `child`'s current tab, read from the extmarks actually drawn:
--- `{ { line = 15, summary = '● alice +1: first line' }, … }`; several
--- summaries under one line are joined with ' | '. `blanks` counts the
--- padding lines drawn under that line; `hl` maps each summary text to the
--- highlight group its text (past the dot) is drawn with, `dot` to the dot's.
function M.threads_visible(child, side)
  return child.lua(([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return {} end
    local win = s.wins[%q]
    if not win or not vim.api.nvim_win_is_valid(win) then return {} end
    local ns = s.ns.review
    if not ns then return {} end
    local buf = vim.api.nvim_win_get_buf(win)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local out = {}
    for _, m in ipairs(marks) do
      local details = m[4]
      if details.virt_lines then
        local parts, blanks, hl, dot = {}, 0, {}, {}
        for _, vl in ipairs(details.virt_lines) do
          local text = {}
          for _, chunk in ipairs(vl) do
            table.insert(text, chunk[1])
          end
          text = table.concat(text)
          if text ~= '' then
            table.insert(parts, text)
            -- a stacked highlight: the last group is the one that decides
            local function top(h) return type(h) == 'table' and h[#h] or h end
            hl[text] = top((vl[2] or vl[1])[2])
            dot[text] = top(vl[1][2])
          else
            blanks = blanks + 1
          end
        end
        if #parts > 0 then
          table.insert(out, { line = m[2] + 1, summary = table.concat(parts, ' | '), count = #parts, blanks = blanks, hl = hl, dot = dot })
        end
      end
    end
    table.sort(out, function(a, b) return a.line < b.line end)
    return out
  ]]):format(side))
end

--- Set of lines in `side`'s window with a thread drawn: `{ [15] = true, … }`.
function M.thread_lines(child, side)
  local out = {}
  for _, t in ipairs(M.threads_visible(child, side)) do
    out[t.line] = true
  end
  return out
end

--- Range bars in `side`'s window as the screen shows them, for every row
--- with one: `{ ['5'] = { text = '│┃', hl = { 'DiffyThreadLane2', 'DiffyThreadLane5' } },
--- ['5+1'] = { text = '│╰' }, … }`, lanes left to right, a blank lane ' '
--- (hl ''). `'5+k'` is the k-th virtual row (summary, padding, filler)
--- under line 5; `hl` is only read for buffer lines.
function M.thread_bars(child, side)
  return child.lua(([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    local win = s and s.wins[%q]
    if not (win and vim.api.nvim_win_is_valid(win)) then return {} end
    vim.cmd('redraw')
    local item = "%%{%%v:lua.require'diffy.review.ui'.statuscolumn()%%}"
    local info = vim.fn.getwininfo(win)[1]
    local out, width = {}, nil
    local function cells(row)
      local t = {}
      for c = info.wincol + info.textoff - width - 1, info.wincol + info.textoff - 2 do
        t[#t + 1] = vim.fn.screenstring(row, c)
      end
      return table.concat(t)
    end
    for l = info.topline, info.botline do
      local ev = vim.api.nvim_eval_statusline(item, { winid = win, use_statuscol_lnum = l, highlights = true })
      width = width or (ev.width > 0 and ev.width - 1 or nil)
      if not width then return {} end
      local row = vim.fn.screenpos(win, l, 1).row
      if row > 0 then
        local text = cells(row)
        if vim.trim(text) ~= '' then
          local hl = {}
          for i, h in ipairs(ev.highlights) do
            local stop = ev.highlights[i + 1] and ev.highlights[i + 1].start or #ev.str
            for _, ch in ipairs(vim.fn.split(ev.str:sub(h.start + 1, stop), '\\zs')) do
              if #hl < width then
                hl[#hl + 1] = ch == ' ' and '' or h.group
              end
            end
          end
          out[tostring(l)] = { text = text, hl = hl }
        end
        local next_row = l < info.botline and vim.fn.screenpos(win, l + 1, 1).row or 0
        local last = next_row > 0 and next_row - 1 or math.min(row + 20, info.winrow + info.height - 1)
        for r = row + 1, last do
          local vt = cells(r)
          if vim.trim(vt) ~= '' then
            out[('%%d+%%d'):format(l, r - row)] = { text = vt }
          end
        end
      end
    end
    return out
  ]]):format(side))
end

--- The thread float in `child`'s current tab, or nil: `{ text = lines as
--- drawn (virtual header text and labels included), footer = key hints,
--- over = 'left'|'right' (the diff window it's drawn over), focused = bool }`.
function M.thread_float(child)
  return child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return vim.NIL end
    local function join(chunks)
      local t = {}
      for _, ch in ipairs(chunks or {}) do
        t[#t + 1] = type(ch) == 'table' and ch[1] or ch
      end
      return table.concat(t)
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local cfg = vim.api.nvim_win_get_config(w)
      local buf = vim.api.nvim_win_get_buf(w)
      if cfg.relative ~= '' and vim.api.nvim_buf_get_name(buf):find('/thread/', 1, true) then
        local pre, post, above, below = {}, {}, {}, {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
          local row, d = m[2] + 1, m[4]
          if d.virt_text_pos == 'inline' then
            pre[row] = (pre[row] or '') .. join(d.virt_text)
          elseif d.virt_text_pos == 'right_align' then
            post[row] = join(d.virt_text)
          end
          if d.virt_lines then
            (d.virt_lines_above and above or below)[row] = vim.tbl_map(join, d.virt_lines)
          end
        end
        local text = {}
        for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
          for _, v in ipairs(above[i] or {}) do
            text[#text + 1] = vim.trim(v)
          end
          text[#text + 1] = vim.trim((pre[i] or '') .. l .. (post[i] and '  ' .. post[i] or ''))
          for _, v in ipairs(below[i] or {}) do
            text[#text + 1] = vim.trim(v)
          end
        end
        local over = cfg.win == s.wins.left and 'left' or cfg.win == s.wins.right and 'right' or vim.NIL
        return { text = text, footer = vim.trim(join(cfg.footer)), over = over, focused = w == vim.api.nvim_get_current_win() }
      end
    end
    return vim.NIL
  ]])
end

--- The threads view as drawn, or nil when it isn't shown: `{ float = bool,
--- rows = its lines, cursor = its cursor line, title, footer, preview =
--- the preview pane's lines (inline virtual text included), preview_title }`.
function M.threads_view(child)
  return child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    local win = s and s.wins.threads
    if not (win and vim.api.nvim_win_is_valid(win)) then return vim.NIL end
    local function join(chunks)
      local t = {}
      for _, ch in ipairs(type(chunks) == 'table' and chunks or {}) do
        t[#t + 1] = type(ch) == 'table' and ch[1] or ch
      end
      return vim.trim(table.concat(t))
    end
    local cfg = vim.api.nvim_win_get_config(win)
    local out = {
      float = cfg.relative ~= '',
      rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false),
      cursor = vim.api.nvim_win_get_cursor(win)[1],
      title = join(cfg.title),
      footer = join(cfg.footer),
    }
    local pwin = s.wins.threads_preview
    if pwin and vim.api.nvim_win_is_valid(pwin) then
      local pbuf = vim.api.nvim_win_get_buf(pwin)
      local pre = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pbuf, -1, 0, -1, { details = true })) do
        if m[4].virt_text_pos == 'inline' then
          pre[m[2] + 1] = (pre[m[2] + 1] or '') .. join(m[4].virt_text)
        end
      end
      out.preview = {}
      for i, l in ipairs(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)) do
        out.preview[i] = vim.trim((pre[i] or '') .. ' ' .. l)
      end
      out.preview_title = join(vim.api.nvim_win_get_config(pwin).title)
    end
    return out
  ]])
end

--- The threads view's buffer lines, one entry each: `{ kind = 'group',
--- label, count, folded }`, `{ kind = 'file', path }`, `{ kind = 'thread',
--- path, text }` (`text` reads `● f.txt:5  you  body`, the row under its
--- file header with the path put back), `{ kind = 'other', text }`.
function M.thread_rows(view)
  local out, path = {}, nil
  for _, l in ipairs(view.rows) do
    local label, count = l:match('^▾ (.-)  (%d+)$')
    local folded = l:match('^▸ ') ~= nil
    if folded then
      label, count = l:match('^▸ (.-)  (%d+)$')
    end
    local icon, loc, rest = l:match('^    (%S+)%s+(%S+)  (.*)$')
    local header = l:match('^  (%S.*)$')
    if label then
      table.insert(out, { kind = 'group', label = label, count = tonumber(count), folded = folded })
    elseif icon and path then
      local where = loc == 'file' and (path .. ' (file)') or (path .. ':' .. loc)
      table.insert(out, { kind = 'thread', path = path, text = vim.trim(('%s %s  %s'):format(icon, where, rest)) })
    elseif header then
      path = header
      table.insert(out, { kind = 'file', path = header })
    else
      table.insert(out, { kind = 'other', text = vim.trim(l) })
    end
  end
  return out
end

--- The threads view's thread rows grouped under their headers: `{ { group =
--- 'Open', count = 2, files = { path, … }, rows = { thread text, … } }, … }`
--- (a folded group has none), from `M.thread_rows`.
function M.thread_groups(view)
  local out = {}
  for _, r in ipairs(M.thread_rows(view)) do
    if r.kind == 'group' then
      table.insert(out, { group = r.label, count = r.count, files = {}, rows = {} })
    elseif r.kind == 'file' and out[#out] then
      table.insert(out[#out].files, r.path)
    elseif r.kind == 'thread' and out[#out] then
      table.insert(out[#out].rows, r.text)
    end
  end
  return out
end

--- Run `cmd` (a `:Diffy threads …`), unfold every folded group with
--- `<Tab>` and return `M.thread_groups` of what the view then shows. The
--- view stays open.
function M.all_threads(child, cmd)
  child.cmd(cmd)
  local function folded_at()
    for i, l in ipairs(M.threads_view(child).rows) do
      if l:find('^▸ ') then
        return i
      end
    end
  end
  local lnum = folded_at()
  while lnum do
    child.api.nvim_win_set_cursor(M.wins(child).threads, { lnum, 0 })
    child.type_keys('<Tab>')
    lnum = folded_at()
  end
  return M.thread_groups(M.threads_view(child))
end

--- True if every pair of counterpart lines visible in both diff windows is
--- drawn on the same screen row. Counterparts come from nvim's own diff
--- alignment (`row(l) = l + Σ diff_filler(k)`, equal rows are
--- counterparts); the screen rows come from `screenpos`, so virt_lines that
--- shift one side only are caught.
function M.aligned(child)
  return child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return false end
    local lw, rw = s.wins.left, s.wins.right
    if not (lw and rw and vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw)) then
      return false
    end
    vim.cmd('redraw')
    local function rows(win)
      return vim.api.nvim_win_call(win, function()
        local by_row, filler = {}, 0
        for k = 1, vim.fn.line('w$') do
          filler = filler + vim.fn.diff_filler(k)
          if k >= vim.fn.line('w0') then
            by_row[k + filler] = k
          end
        end
        return by_row
      end)
    end
    local left, right = rows(lw), rows(rw)
    local pairs_seen = 0
    for row, l in pairs(left) do
      local r = right[row]
      if r then
        pairs_seen = pairs_seen + 1
        if vim.fn.screenpos(lw, l, 1).row ~= vim.fn.screenpos(rw, r, 1).row then
          return false
        end
      end
    end
    return pairs_seen > 0
  ]])
end

local function ready_listener(event)
  local filter = event and ('%q'):format(event) or 'nil'
  return ([[
    _G.__diffy_ready = false
    _G.__diffy_ready_au = vim.api.nvim_create_autocmd('User', {
      pattern = 'DiffyReady',
      callback = function(a)
        if %s == nil or (a.data and a.data.event == %s) then
          _G.__diffy_ready = true
        end
      end,
    })
  ]]):format(filter, filter)
end

--- Arm a one-shot listener for `User DiffyReady` in `child`, optionally
--- filtered to `data.event == event` (e.g. `'render'`, `'select'`,
--- `'open_row'`, see the modules that call `git/run.lua`'s `M.ready`). Call
--- this right before the action expected to trigger a render; pair with
--- `M.wait_ready` right after. This is the only synchronization point
--- tests use - never a sleep.
function M.arm_ready(child, event)
  child.lua(ready_listener(event))
end

--- `M.arm_ready` through raw `child.api` calls, for right before a keystroke
--- that leaves the child transiently `blocking` (opening/closing a float);
--- pair with `M.wait_ready_raw`.
function M.arm_ready_raw(child, event)
  child.api.nvim_exec_lua(ready_listener(event), {})
end

--- Block (up to `timeout` ms, default 5000) until the listener armed by
--- `M.arm_ready` fires, then remove it.
function M.wait_ready(child, timeout)
  child.lua(('vim.wait(%d, function() return _G.__diffy_ready end)'):format(timeout or 5000))
  child.lua('pcall(vim.api.nvim_del_autocmd, _G.__diffy_ready_au)')
end

--- `M.wait_ready` through raw `child.api` calls, for right after a keystroke
--- that leaves the child transiently `blocking` (a float + `startinsert`, or
--- a handler spawning git synchronously), where
--- `child.lua`'s guard would throw.
function M.wait_ready_raw(child, timeout)
  vim.wait(timeout or 5000, function()
    return child.api.nvim_exec_lua('return _G.__diffy_ready', {}) == true
  end, 10)
  child.api.nvim_exec_lua('pcall(vim.api.nvim_del_autocmd, _G.__diffy_ready_au)', {})
end

return M
