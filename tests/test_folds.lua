-- The diff windows' folds: what a closed fold says, and where opening one
-- leaves the view.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local snapshot
local repo

local RENDER = 'function M.render(items)'
local LOOP = 'for _, item in ipairs(items) do'

-- Changes at line 2, inside render's loop (right line 57) and at the end of
-- other (right line 130). The right side's folds: [9, 50], between the first
-- two, and [64, 123], between the last two.
local function lines(edited)
  local out = { 'local M = {}' }
  if edited then
    table.insert(out, 'M.version = 1')
  end
  vim.list_extend(out, { '', RENDER, '  local out = {}', '  ' .. LOOP })
  for i = 1, 60 do
    table.insert(out, ('    local v%d = item[%d]'):format(i, i))
    if edited and i == 50 then
      table.insert(out, '    out.n = (out.n or 0) + 1')
    end
  end
  vim.list_extend(out, { '  end', '  return out', 'end', '', 'function M.other()' })
  for i = 1, 60 do
    table.insert(out, ('  local w%d = %d'):format(i, (edited and i == 58) and 0 or i))
  end
  vim.list_extend(out, { 'end', 'return M' })
  return out
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.o.lines, child.o.columns = 50, 220
      snapshot = leak.snapshot(child)
      repo = Repo.new():commit('base', { ['f.lua'] = lines(false) })
      vim.fn.writefile(lines(true), repo.dir .. '/f.lua')
      child.fn.chdir(repo.dir)
      ui.arm_ready(child, 'render')
      child.cmd('Diffy')
      ui.wait_ready(child)
    end,
    post_case = function()
      leak.check(child, snapshot)
      repo:destroy()
    end,
  },
})

local function fold_text(win, lnum)
  return child.lua(('return vim.api.nvim_win_call(%d, function() return vim.fn.foldtextresult(%d) end)'):format(win, lnum))
end

local function screen_row(win, lnum)
  child.cmd('redraw')
  return child.fn.screenpos(win, lnum, 1).row
end

T['a closed fold names the scopes the change below it sits in, on both sides'] = function()
  local w = ui.wins(child)
  eq(fold_text(w.right, 9), '+-- 42 lines: ' .. RENDER .. ' › ' .. LOOP)
  eq(fold_text(w.right, 64), '+-- 60 lines: function M.other()')
  -- the left side lacks line 2, and has the loop's new line as filler
  eq(fold_text(w.left, 8), '+-- 42 lines: ' .. RENDER .. ' › ' .. LOOP)
end

T['a fold too narrow for every scope drops the outer ones'] = function()
  local w = ui.wins(child)
  child.api.nvim_win_set_width(w.right, 60)
  eq(fold_text(w.right, 9), '+-- 42 lines: … › ' .. LOOP)
end

T['opening a fold in the top half keeps the change below it in place'] = function()
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)
  child.fn.winrestview({ topline = 8, lnum = 9 })
  local before = screen_row(w.right, 57)
  child.type_keys('za')
  eq(screen_row(w.right, 57), before)
  eq(child.fn.line('.'), 50)
  eq(ui.aligned(child), true)
  eq(child.lua_get(('vim.api.nvim_win_call(%d, function() return vim.fn.foldclosed(9) end)'):format(w.left)), -1)
end

T['opening a fold in the bottom half keeps the change above it in place'] = function()
  local w = ui.wins(child)
  for _, win in ipairs({ w.left, w.right }) do
    child.lua(('vim.api.nvim_win_call(%d, function() vim.cmd("9foldopen") end)'):format(win))
  end
  child.api.nvim_set_current_win(w.right)
  child.fn.winrestview({ topline = 30, lnum = 64 })
  local before = screen_row(w.right, 57)
  child.type_keys('zo')
  eq(screen_row(w.right, 57), before)
  eq(child.fn.line('.'), 64)
  eq(ui.aligned(child), true)
end

return T
