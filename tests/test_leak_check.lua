-- The leak check itself fails on a deliberately leaked diffy augroup, buffer,
-- buffer-local keymap or extmark. No `post_case` check: the leak is the point.
local leak = require('tests.helpers.leak')

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
    end,
  },
})

local function expect_leak(category)
  local ok, err = pcall(leak.check, child)
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(tostring(err):find(category, 1, true) ~= nil, true)
end

T['a leaked diffy augroup fails the check'] = function()
  child.lua([[vim.api.nvim_create_augroup('diffy_session_999', {})]])
  expect_leak('augroup:')
end

T['a leaked diffy:// buffer fails the check'] = function()
  child.lua([[
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'diffy://999/tree')
  ]])
  expect_leak('buffer:')
end

T['a leaked diffy buffer-local keymap fails the check'] = function()
  child.lua([[
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set('n', 'gg', function() end, { buffer = buf, desc = 'diffy: test' })
  ]])
  expect_leak('keymap:')
end

T['a leaked extmark in a diffy namespace fails the check'] = function()
  child.lua([[
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace('diffy/999/test')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'hello' })
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {})
  ]])
  expect_leak('extmark:')
end

return T
