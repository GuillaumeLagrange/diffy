-- Key-driven confirmation float. Use it instead of `vim.fn.confirm`, whose
-- modal prompt doesn't block for real input in the test harness.
local session_mod = require('diffy.session')

local M = {}

--- A small centered float showing `lines`, focused. Returns its window,
--- `set_lines(lines)`, `map(lhs, fn)` (a key on its buffer) and
--- `finish(value)`, which closes it and calls `cb(value)` exactly once.
local function open(session, lines, cb)
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 4)

  local buf = session_mod.scratch_buf(session, 'prompt')
  session_mod.register_buffer(session, 'prompt', buf)
  local function set_lines(text)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
    vim.bo[buf].modifiable = false
  end
  set_lines(lines)

  local win = vim.api.nvim_open_win(
    buf,
    false,
    require('diffy.layout').centered(width, #lines, { style = 'minimal', border = 'rounded', zindex = 250 })
  )
  session_mod.unbind(win)
  vim.api.nvim_set_current_win(win)

  local done = false
  local function finish(value)
    if done then
      return
    end
    done = true
    session_mod.unmap_buffer(session, buf)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    cb(value)
  end
  -- nowait: fugitive's global `y<C-G>` would hold `y` for 'timeoutlen'
  local function map(lhs, fn)
    session_mod.map(session, 'n', lhs, fn, { buffer = buf, nowait = true, desc = 'prompt: ' .. lhs })
  end
  return win, set_lines, map, finish
end

--- Waits for one keypress among `keys` (`{ [lhs] = value }`); `<Esc>`/`q`
--- decline with nil.
local function ask(session, lines, keys, cb)
  local _, _, map, finish = open(session, lines, cb)
  local function key(lhs, value)
    map(lhs, function()
      finish(value)
    end)
  end
  for lhs, value in pairs(keys) do
    key(lhs, value)
  end
  key('<Esc>', nil)
  key('q', nil)
end

--- Yes/no: `y`/`<CR>` accepts, `n`/`<Esc>`/`q` declines. `cb(accepted)`.
--- @param cb fun(accepted: boolean)
function M.confirm(session, lines, cb)
  ask(session, lines, { y = true, ['<CR>'] = true, n = false }, function(value)
    cb(value == true)
  end)
end

--- One of `choices` (`{ { key, label, value }, … }`), listed under `title`;
--- `<Esc>`/`q` cancel. `cb(value)`, nil when cancelled.
function M.choose(session, title, choices, cb)
  local lines, keys = { title }, {}
  for _, c in ipairs(choices) do
    table.insert(lines, ('  %s  %s'):format(c[1], c[2]))
    keys[c[1]] = c[3]
  end
  ask(session, lines, keys, cb)
end

--- A list to confirm under `title`: `rows` = `{ { text, value? } }`, those
--- with a value checked (`[x]`) and excludable with `x` on their line.
--- `<CR>`/`y` confirms, `cb(excluded)` with the excluded values as a set;
--- `<Esc>`/`q` cancel, `cb(nil)`.
function M.checklist(session, title, rows, cb)
  local excluded = {}
  local function lines()
    local out = { title }
    for _, r in ipairs(rows) do
      if r.value ~= nil then
        table.insert(out, ('  [%s] %s'):format(excluded[r.value] and ' ' or 'x', r.text))
      else
        table.insert(out, '      ' .. r.text)
      end
    end
    table.insert(out, '')
    table.insert(out, '  x leave out / put back   <CR> go   q cancel')
    return out
  end
  local text = lines()
  local win, set_lines, map, finish = open(session, text, cb)
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { math.min(2, #text), 0 })

  map('x', function()
    local r = rows[vim.api.nvim_win_get_cursor(win)[1] - 1]
    if r and r.value ~= nil then
      excluded[r.value] = not excluded[r.value] or nil
      set_lines(lines())
    end
  end)
  for _, lhs in ipairs({ '<CR>', 'y' }) do
    map(lhs, function()
      finish(excluded)
    end)
  end
  for _, lhs in ipairs({ '<Esc>', 'q' }) do
    map(lhs, function()
      finish(nil)
    end)
  end
end

return M
