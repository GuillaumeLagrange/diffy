-- Every teardown path leaves no diffy state, and two
-- sessions in separate tabs are fully independent.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local repo

local function tabs()
  return child.lua_get('#vim.api.nvim_list_tabpages()')
end

local function expect_no_session()
  MiniTest.expect.equality(tabs(), 1)
  MiniTest.expect.equality(ui.diffy_buffers(child), {})
  MiniTest.expect.equality(ui.layout(child), nil)
end

-- some teardown paths are deferred to the next tick
local function wait_tabs(n)
  child.lua(('vim.wait(500, function() return #vim.api.nvim_list_tabpages() == %d end)'):format(n))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      repo = Repo.new():commit('base', { ['f.txt'] = Repo.lines(5) })
      child.fn.chdir(repo.dir)
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
      end
    end,
  },
})

T[':Diffy opens a session tab with the layout skeleton'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  local l = ui.layout(child)
  MiniTest.expect.equality(
    { tree = l.tree ~= vim.NIL, log = l.log ~= vim.NIL, left = l.left ~= vim.NIL, right = l.right ~= vim.NIL },
    { tree = true, log = true, left = true, right = true }
  )
  MiniTest.expect.equality(#l.bars, 3)
end

T['closing the tab with :tabclose leaves no diffy state'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('tabclose')
  wait_tabs(1)
  expect_no_session()
end

T[':tabclose before DiffyReady tears down cleanly, and the pending async render is a no-op'] = function()
  -- hold back delivery of the first git call (`rev-parse --show-toplevel`)
  -- until after the tab is gone
  child.lua([[
    local real_system = vim.system
    _G.__release_root = nil
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'git' and cmd[2] == 'rev-parse' and cmd[3] == '--show-toplevel' then
        return real_system(cmd, opts, function(res)
          _G.__release_root = function() on_exit(res) end
        end)
      end
      return real_system(cmd, opts, on_exit)
    end
  ]])

  child.lua("vim.v.errmsg = ''")
  child.cmd('Diffy')
  child.cmd('tabclose')
  wait_tabs(1)
  expect_no_session()

  -- release it and let the rest of the real async chain run to where it used to crash
  child.lua('vim.wait(2000, function() return _G.__release_root ~= nil end)')
  child.lua('_G.__release_root()')
  child.lua("vim.wait(1500, function() return vim.v.errmsg ~= '' end)")

  MiniTest.expect.equality(child.lua_get('vim.v.errmsg'), '')
  expect_no_session()
end

T['quitting a managed window closes the whole session'] = MiniTest.new_set({
  parametrize = { { 'tree' }, { 'log' }, { 'left' }, { 'right' } },
})

T['quitting a managed window closes the whole session']['leaves no diffy state'] = function(name)
  child.cmd('Diffy')
  child.fn.win_gotoid(ui.wins(child)[name])
  child.cmd('q')
  wait_tabs(1)
  expect_no_session()
end

T['wiping a panel buffer closes the whole session'] = MiniTest.new_set({
  parametrize = { { 'tree' }, { 'log' } },
})

T['wiping a panel buffer closes the whole session']['leaves no diffy state'] = function(name)
  child.cmd('Diffy')
  local bufnr = child.api.nvim_win_get_buf(ui.wins(child)[name])
  child.cmd(('bwipeout! %d'):format(bufnr))
  wait_tabs(1)
  expect_no_session()
end

T[':Diffy close tears down the session'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('Diffy close')
  expect_no_session()
end

T['quitting nvim (VimLeavePre) tears down every open session'] = function()
  -- a real :qa would end the child before anything is observable
  child.cmd('Diffy')
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 3)
  child.cmd('doautocmd VimLeavePre')
  expect_no_session()
end

T['closing one of two session tabs leaves the other working'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.equality(tabs(), 3)

  child.cmd('Diffy close')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('tabnext 2')
  MiniTest.expect.equality(ui.layout(child) ~= nil, true)

  -- session 1 still reacts to its keys: R picks up a new worktree change
  vim.fn.writefile({ 'changed' }, repo.dir .. '/f.txt')
  child.api.nvim_set_current_win(ui.wins(child).tree)
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)
  local l = ui.layout(child)
  MiniTest.expect.equality(vim.iter(l.tree):any(function(t) return t:find('f.txt', 1, true) ~= nil end), true)
  MiniTest.expect.equality(l.right.rev, 'worktree')
  MiniTest.expect.equality(l.right.path, 'f.txt')
end

T['the worktree side is a listed buffer, like :edit would open'] = function()
  vim.fn.writefile({ 'changed' }, repo.dir .. '/f.txt')
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  ui.open_tree_row(child, 'f.txt', 'o', 'open_row')
  MiniTest.expect.equality(ui.layout(child).right.rev, 'worktree')
  local right = ui.wins(child).right
  -- sidekick's {this} only sends file + position for listed file buffers
  MiniTest.expect.equality(child.lua_get(('vim.bo[vim.api.nvim_win_get_buf(%d)].buflisted'):format(right)), true)
end

local function open_worktree_file()
  child.o.foldmethod = 'indent'
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/f.txt')
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.rev, 'worktree')
end

local function plain_window(win)
  return child.lua(
    [[
    local win = ...
    local wo = vim.wo[win]
    return {
      name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)),
      diff = wo.diff, scrollbind = wo.scrollbind, cursorbind = wo.cursorbind,
      winbar = wo.winbar, foldmethod = wo.foldmethod, wrap = wo.wrap,
    }
  ]],
    { win }
  )
end

local function expect_plain(win)
  MiniTest.expect.equality(plain_window(win), {
    name = repo.dir .. '/f.txt',
    diff = false,
    scrollbind = false,
    cursorbind = false,
    winbar = '',
    foldmethod = 'indent',
    wrap = true,
  })
end

T['<C-w>o in the worktree side ends the session and keeps the file alone in a plain window'] = function()
  open_worktree_file()
  local right = ui.wins(child).right
  child.api.nvim_set_current_win(right)
  child.type_keys('<C-w>o')
  child.lua('vim.wait(500, function() return vim.wo.winbar == "" end)')
  MiniTest.expect.equality(tabs(), 2)
  MiniTest.expect.equality(child.api.nvim_tabpage_list_wins(0), { right })
  expect_plain(right)
  MiniTest.expect.equality(ui.layout(child), nil)
  MiniTest.expect.equality(ui.diffy_buffers(child), {})
  child.cmd('tabclose')
end

T[':tab split of the worktree side opens a plain window, where diffy keys do what they do elsewhere'] = function()
  open_worktree_file()
  child.lua([[vim.keymap.set('n', ']f', function() vim.g.user_next_file = true end)]])
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.cmd('tab split')
  local clone = child.api.nvim_get_current_win()
  child.lua('vim.wait(500, function() return vim.wo.winbar == "" end)')
  expect_plain(clone)
  child.type_keys(']f')
  MiniTest.expect.equality(child.g.user_next_file, true)
  child.cmd('tabclose')
  child.cmd('Diffy close')
end

T[':tab split of an added file shows it without the added colour, scrolled too'] = function()
  child.o.termguicolors = true
  child.cmd('hi DiffAdd guibg=#00ff00')
  vim.fn.writefile(Repo.lines(10, 'line '), repo.dir .. '/new.txt')
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  ui.open_tree_row(child, 'new.txt', '<CR>', 'open_row')
  local right = ui.wins(child).right
  local GREEN, all = 0x00ff00, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
  MiniTest.expect.equality(ui.lines_with_bg(child, right, GREEN, all), all)
  child.cmd('tab split')
  local clone = child.api.nvim_get_current_win()
  child.lua('vim.wait(500, function() return vim.wo.winbar == "" end)')
  MiniTest.expect.equality(ui.lines_with_bg(child, clone, GREEN), {})
  -- a redraw starting below the first line, as after scrolling or a cursor move
  child.type_keys('<C-e>')
  MiniTest.expect.equality(ui.lines_with_bg(child, clone, GREEN), {})
  child.cmd('tabclose')
  MiniTest.expect.equality(ui.lines_with_bg(child, right, GREEN, all), all)
  child.cmd('Diffy close')
end

return T
