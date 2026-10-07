-- Key-driven confirmation float. Use it instead of `vim.fn.confirm`, whose
-- modal prompt doesn't block for real input in the test harness.
local session_mod = require('diffy.session')

local M = {}

--- A small centered float showing `lines`, focused. Returns `map(lhs, fn)`
--- (a key on its buffer) and `finish(value)`, which closes it and calls
--- `cb(value)` exactly once.
local function open(session, lines, cb)
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 4)

  local buf = session_mod.scratch_buf(session, 'prompt')
  session_mod.register_buffer(session, 'prompt', buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

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
  return map, finish
end

--- Waits for one keypress among `keys` (`{ [lhs] = value }`); `<Esc>`/`q`
--- decline with nil.
local function ask(session, lines, keys, cb)
  local map, finish = open(session, lines, cb)
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

return M
