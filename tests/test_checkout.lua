-- Checkout mode (`X`): entering refuses with a dirty tree; while on, moving
-- the selection moves HEAD; a dirty tree keeps the current checkout; leaving
-- (X, closing the tab) restores the branch; an interrupted checkout (nvim
-- killed) is warned about on the next `:Diffy` and recovered by `:Diffy restore`.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local repo

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      repo = Repo.new()
        :commit('base', { ['f.txt'] = Repo.lines(5) })
        :branch('feat')
        :commit('C1', { ['f.txt'] = Repo.edit(1, 'C1 change') })
        :commit('C2', { ['f.txt'] = Repo.edit(2, 'C2 change') })
        :commit('C3', { ['f.txt'] = Repo.edit(3, 'C3 change') })
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

local function state_file()
  return repo.dir .. '/.git/diffy/checkout.json'
end

local function press(keys)
  ui.arm_ready(child, 'checkout')
  child.type_keys(keys)
  ui.wait_ready(child)
end

local function select(keys)
  ui.arm_ready(child, 'select')
  child.type_keys(keys)
  ui.wait_ready(child)
end

-- `:Diffy` selects the working tree, so X turns the mode on keeping the branch
local function enter_mode()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  child.api.nvim_set_current_win(ui.wins(child).log)
  press('X')
end

-- the mode on C2 (J past the branch head C3, which keeps the branch)
local function checkout_c2()
  enter_mode()
  select('J')
  press('J')
end

T['`X` on a commit with a dirty tree refuses, leaving HEAD untouched'] = function()
  vim.fn.writefile({ 'dirty, uncommitted' }, repo.dir .. '/f.txt')

  checkout_c2()

  MiniTest.expect.equality(ui.git(repo.dir, { 'symbolic-ref', '--short', 'HEAD' }), 'feat')
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', 'HEAD' }), repo.sha.C3)
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)

  child.cmd('Diffy close')
end

T['`X` then closing the tab returns to the original branch'] = function()
  checkout_c2()

  -- checked out: HEAD detached at C1, right side is now a real (WORKTREE) file
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', 'HEAD' }), repo.sha.C2)
  local branch_ok = pcall(ui.git, repo.dir, { 'symbolic-ref', '-q', 'HEAD' })
  MiniTest.expect.equality(branch_ok, false)
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 1)
  MiniTest.expect.equality(ui.layout(child).right.rev, 'worktree')

  ui.arm_ready(child, 'close')
  child.cmd('Diffy close')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'symbolic-ref', '--short', 'HEAD' }), 'feat')
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)
  MiniTest.expect.equality(#child.api.nvim_list_tabpages(), 1)
end

local function head()
  return ui.git(repo.dir, { 'rev-parse', 'HEAD' })
end

local function on_branch()
  local ok, name = pcall(ui.git, repo.dir, { 'symbolic-ref', '--short', '-q', 'HEAD' })
  return ok and name or nil
end

T['checkout mode: moving the selection moves HEAD, the branch head checks the branch out, X restores'] = function()
  enter_mode()
  MiniTest.expect.equality(on_branch(), 'feat')
  MiniTest.expect.equality(child.lua_get('vim.wo[' .. ui.wins(child).log .. '].winbar'), '⎇ checkout feat')

  select('J')
  MiniTest.expect.equality(on_branch(), 'feat')
  press('J')
  MiniTest.expect.equality(head(), repo.sha.C2)
  MiniTest.expect.equality(on_branch(), nil)
  MiniTest.expect.equality(ui.layout(child).right.rev, 'worktree')
  MiniTest.expect.equality(child.lua_get('vim.wo[' .. ui.wins(child).log .. '].winbar'), '⎇ checkout ' .. repo.sha.C2:sub(1, 7))

  press('J')
  MiniTest.expect.equality(head(), repo.sha.C1)

  press('K')
  press('K')
  MiniTest.expect.equality(on_branch(), 'feat')
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)

  press('J')
  MiniTest.expect.equality(head(), repo.sha.C2)
  press('X')
  MiniTest.expect.equality(on_branch(), 'feat')
  MiniTest.expect.equality(head(), repo.sha.C3)
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)
  MiniTest.expect.equality(child.lua_get('vim.wo[' .. ui.wins(child).log .. '].winbar'), '')

  -- mode off: moving no longer touches HEAD
  select('J')
  MiniTest.expect.equality(head(), repo.sha.C3)

  child.cmd('Diffy close')
end

T['checkout mode: a dirty tree keeps the current checkout on selection change'] = function()
  ui.capture_warnings(child)
  checkout_c2()
  vim.fn.writefile({ 'edited in the checkout' }, repo.dir .. '/f.txt')

  press('K')
  MiniTest.expect.equality(head(), repo.sha.C2)
  MiniTest.expect.equality(vim.fn.readfile(repo.dir .. '/f.txt'), { 'edited in the checkout' })
  MiniTest.expect.equality(#ui.warnings(child) >= 1, true)
  MiniTest.expect.equality(child.lua_get('vim.wo[' .. ui.wins(child).log .. '].winbar'), '⎇ checkout ' .. repo.sha.C2:sub(1, 7))

  ui.git(repo.dir, { 'checkout', '--quiet', '--', 'f.txt' })
  press('J')
  MiniTest.expect.equality(head(), repo.sha.C1)

  ui.arm_ready(child, 'close')
  child.cmd('Diffy close')
  ui.wait_ready(child)
  MiniTest.expect.equality(on_branch(), 'feat')
end

T['`X` to leave a checkout when git status fails shows the git error, staying checked out'] = function()
  checkout_c2()

  vim.fn.writefile({ 'garbage' }, repo.dir .. '/.git/index')
  ui.capture_warnings(child)
  child.type_keys('X')
  -- leaving emits no DiffyReady on refusal; wait on the notification itself
  local shown = child.lua([[
    return vim.wait(5000, function()
      return #_G.__diffy_warnings > 0 and _G.__diffy_warnings[1].msg:find('git status failed', 1, true) ~= nil
    end, 10)
  ]])
  MiniTest.expect.equality(shown, true)
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', 'HEAD' }), repo.sha.C2)

  vim.fn.delete(repo.dir .. '/.git/index')
  ui.git(repo.dir, { 'reset', '--quiet' })
  ui.arm_ready(child, 'close')
  child.cmd('Diffy close')
  ui.wait_ready(child)
end

T['quitting nvim during a checkout returns to the original branch'] = function()
  checkout_c2()
  MiniTest.expect.equality(head(), repo.sha.C2)

  child.stop()

  MiniTest.expect.equality(on_branch(), 'feat')
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  snapshot = leak.snapshot(child)
end

T['nvim killed during a checkout: the next :Diffy warns, and :Diffy restore returns to the branch'] = function()
  checkout_c2()
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 1)

  -- simulate `nvim` being killed outright (no VimLeavePre, unlike
  -- `child.stop()`/`child.restart()`, which run `:0cquit` and do fire it)
  local pid = child.lua_get('vim.fn.getpid()')
  vim.system({ 'kill', '-9', tostring(pid) }):wait()

  child.restart({ '-u', 'tests/minimal_init.lua' })
  snapshot = leak.snapshot(child) -- fresh process: rebase the post_case baseline
  child.fn.chdir(repo.dir)
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', 'HEAD' }), repo.sha.C2) -- still detached

  ui.capture_warnings(child)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.equality(#ui.warnings(child) >= 1, true)
  child.cmd('Diffy close')

  ui.arm_ready(child, 'restore')
  child.cmd('Diffy restore')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'symbolic-ref', '--short', 'HEAD' }), 'feat')
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)
end

return T
