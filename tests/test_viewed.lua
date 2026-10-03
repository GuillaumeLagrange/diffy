-- Viewed marks: the Viewed group, skipping viewed files, `●` on a return, and
-- what counts as the same change (blob pair per view, renames, symlinks,
-- submodules, deletions), across sessions and nvims.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local other
local snapshot
local repo

local ENV = {
  GIT_AUTHOR_NAME = 'diffy',
  GIT_AUTHOR_EMAIL = 'diffy@example.com',
  GIT_COMMITTER_NAME = 'diffy',
  GIT_COMMITTER_EMAIL = 'diffy@example.com',
  GIT_CONFIG_GLOBAL = '/dev/null',
  GIT_CONFIG_NOSYSTEM = '1',
}

local function sh(dir, args)
  local res = vim.system(args, { cwd = dir, text = true, env = ENV }):wait()
  assert(res.code == 0, table.concat(args, ' ') .. ': ' .. (res.stderr or ''))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      repo = Repo.new()
      repo:commit('Base', {
        ['a.txt'] = Repo.lines(10, 'a'),
        ['b.txt'] = Repo.lines(10, 'b'),
        ['c.txt'] = Repo.lines(10, 'c'),
        ['d.txt'] = Repo.lines(10, 'd'),
      })
      repo:branch('feat')
      repo:commit('C1', { ['a.txt'] = Repo.edit(1, 'a one'), ['b.txt'] = Repo.edit(1, 'b one'), ['c.txt'] = Repo.edit(1, 'c one') })
      repo:commit('C2', { ['a.txt'] = Repo.edit(2, 'a two') })
      child.fn.chdir(repo.dir)
    end,
    post_case = function()
      if other then
        other.stop()
        other = nil
      end
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
      end
    end,
  },
})

--- The tree's lines without the +/- counts.
local function tree()
  return vim.tbl_map(function(l)
    return (l:gsub('%s+%+%d+ %-%d+$', ''))
  end, ui.layout(child).tree)
end

local function open_branch()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
end

local function reopen_branch()
  child.cmd('Diffy close')
  open_branch()
end

local function refresh()
  child.api.nvim_set_current_win(ui.wins(child).tree)
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)
end

local function mark_in_tree(text)
  ui.open_tree_row(child, text, 'm', 'viewed')
end

local function shown()
  return ui.layout(child).right.path
end

local function in_diff(keys, event)
  child.api.nvim_set_current_win(ui.wins(child).right)
  ui.arm_ready(child, event)
  child.type_keys(keys)
  ui.wait_ready(child)
end

local function capture_info()
  child.lua([[
    _G.__infos = {}
    local notify = vim.notify
    vim.notify = function(msg, level, ...)
      table.insert(_G.__infos, msg)
      return notify(msg, level, ...)
    end
  ]])
end

T['marking a file moves it into a folded Viewed group and ]f skips it'] = function()
  open_branch()
  MiniTest.expect.equality(shown(), 'a.txt')

  mark_in_tree('b.txt')
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M c.txt', '▸ Viewed (1)' })
  -- skipped even when its group is unfolded
  child.api.nvim_win_set_cursor(ui.wins(child).tree, { 3, 0 })
  child.type_keys('o')
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M c.txt', '▾ Viewed (1)', '  M b.txt' })

  in_diff(']f', 'open_row')
  MiniTest.expect.equality(shown(), 'c.txt')
  child.type_keys(']f')
  MiniTest.expect.equality(shown(), 'c.txt')
  in_diff('[f', 'open_row')
  MiniTest.expect.equality(shown(), 'a.txt')

  child.cmd('Diffy close')
end

T['marking the shown file opens the next unviewed one, and stays on the last one saying so'] = function()
  open_branch()
  capture_info()

  in_diff('\\m', 'viewed')
  MiniTest.expect.equality(shown(), 'b.txt')
  ui.arm_ready(child, 'viewed')
  child.cmd('Diffy viewed')
  ui.wait_ready(child)
  MiniTest.expect.equality(shown(), 'c.txt')
  in_diff('\\m', 'viewed')
  MiniTest.expect.equality(shown(), 'c.txt')
  MiniTest.expect.equality(child.lua_get('_G.__infos'), { 'diffy: no unviewed file left' })
  -- unfolded while it holds the file shown
  MiniTest.expect.equality(tree(), { '▾ Viewed (3)', '  M a.txt', '  M b.txt', '  M c.txt' })

  ui.arm_ready(child, 'viewed')
  child.cmd('Diffy viewed')
  ui.wait_ready(child)
  MiniTest.expect.equality(tree(), { 'M c.txt', '▸ Viewed (2)' })

  child.cmd('Diffy close')
end

T['m on the Viewed header unmarks them all, on a folder marks every file in it'] = function()
  repo:commit('Dir', { ['dir/x.txt'] = 'x', ['dir/y.txt'] = 'y' })
  open_branch()
  mark_in_tree('dir/')
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M b.txt', 'M c.txt', '▸ Viewed (2)' })
  mark_in_tree('Viewed')
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M b.txt', 'M c.txt', '▾ dir/', '  A x.txt', '  A y.txt' })

  child.cmd('Diffy close')
end

T['a viewed file edited by another process comes back with a dot, cleared once opened'] = function()
  open_branch()
  mark_in_tree('b.txt')
  vim.fn.writefile({ 'edited elsewhere' }, repo.dir .. '/b.txt')
  refresh()
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M ● b.txt', 'M c.txt' })

  ui.open_tree_row(child, 'b.txt', 'o', 'open_row')
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M b.txt', 'M c.txt' })

  child.cmd('Diffy close')
end

T['editing the shown viewed file brings it back without a dot, undoing makes it viewed again'] = function()
  open_branch()
  mark_in_tree('b.txt')
  child.api.nvim_win_set_cursor(ui.wins(child).tree, { 3, 0 })
  child.type_keys('o')
  ui.open_tree_row(child, 'b.txt', 'o', 'open_row')
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M c.txt', '▾ Viewed (1)', '  M b.txt' })

  child.api.nvim_set_current_win(ui.wins(child).right)
  child.api.nvim_buf_set_lines(0, 0, 1, false, { 'my edit' })
  ui.arm_ready(child, 'render')
  child.cmd('write')
  ui.wait_ready(child)
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M b.txt', 'M c.txt' })

  ui.arm_ready(child, 'render')
  child.cmd('undo | write')
  ui.wait_ready(child)
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M c.txt', '▾ Viewed (1)', '  M b.txt' })

  child.cmd('Diffy close')
end

T['a rename without content change stays viewed'] = function()
  open_branch()
  mark_in_tree('a.txt')
  child.cmd('Diffy close')
  repo:mv('a.txt', 'z.txt'):commit('Move')
  open_branch()
  MiniTest.expect.equality(tree(), { 'M b.txt', 'M c.txt', '▸ Viewed (1)' })

  child.cmd('Diffy close')
end

T['retargeting a viewed symlink brings it back, even to a file with the same content'] = function()
  vim.uv.fs_symlink('g.txt', repo.dir .. '/l')
  repo:commit('Targets', { ['g.txt'] = 'other', ['h.txt'] = 'same', ['k.txt'] = 'same' })
  vim.fn.delete(repo.dir .. '/l')
  vim.uv.fs_symlink('h.txt', repo.dir .. '/l')
  open_branch()
  mark_in_tree('A l')
  MiniTest.expect.equality(vim.list_contains(tree(), 'A l'), false)

  vim.fn.delete(repo.dir .. '/l')
  vim.uv.fs_symlink('k.txt', repo.dir .. '/l')
  refresh()
  MiniTest.expect.equality(vim.list_contains(tree(), 'A ● l'), true)

  child.cmd('Diffy close')
end

T['moving a viewed submodule to another commit brings it back'] = function()
  local sub = repo.dir .. '/sub'
  vim.fn.mkdir(sub, 'p')
  sh(sub, { 'git', 'init', '-q' })
  sh(sub, { 'git', 'commit', '-q', '--allow-empty', '-m', 's1' })
  repo:commit('Sub')
  sh(sub, { 'git', 'commit', '-q', '--allow-empty', '-m', 's2' })
  ui.capture_warnings(child)
  open_branch()
  mark_in_tree('sub')
  MiniTest.expect.equality(ui.warnings(child), {})
  MiniTest.expect.equality(vim.list_contains(tree(), '▸ Viewed (1)'), true)

  sh(sub, { 'git', 'commit', '-q', '--allow-empty', '-m', 's3' })
  refresh()
  MiniTest.expect.equality(vim.list_contains(tree(), 'A ● sub'), true)

  child.cmd('Diffy close')
end

T['a file deleted from the worktree can be marked viewed'] = function()
  vim.fn.delete(repo.dir .. '/d.txt')
  ui.capture_warnings(child)
  open_branch()
  mark_in_tree('d.txt')
  MiniTest.expect.equality(ui.warnings(child), {})
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M b.txt', 'M c.txt', '▸ Viewed (1)' })

  child.cmd('Diffy close')
end

T['a mark made on one commit does not hide the file in the whole branch, and both marks survive'] = function()
  open_branch()
  ui.select_log_row(child, 'C2')
  mark_in_tree('a.txt')
  MiniTest.expect.equality(tree(), { '▾ Viewed (1)', '  M a.txt' })

  reopen_branch()
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M b.txt', 'M c.txt' })
  mark_in_tree('a.txt')

  ui.select_log_row(child, 'C2')
  MiniTest.expect.equality(tree(), { '▾ Viewed (1)', '  M a.txt' })
  reopen_branch()
  MiniTest.expect.equality(tree(), { 'M b.txt', 'M c.txt', '▸ Viewed (1)' })

  child.cmd('Diffy close')
end

T['a mark made in another nvim shows in an open session'] = function()
  open_branch()
  other = MiniTest.new_child_neovim()
  other.restart({ '-u', 'tests/minimal_init.lua' })
  other.fn.chdir(repo.dir)
  ui.arm_ready(other, 'render')
  other.cmd('Diffy branch main')
  ui.wait_ready(other)
  ui.open_tree_row(other, 'b.txt', 'm', 'viewed')

  child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    vim.wait(5000, function()
      return vim.list_contains(vim.api.nvim_buf_get_lines(s.bufs.tree, 0, -1, false), '▸ Viewed (1)')
    end)
  ]])
  MiniTest.expect.equality(tree(), { 'M a.txt', 'M c.txt', '▸ Viewed (1)' })

  child.cmd('Diffy close')
end

return T
