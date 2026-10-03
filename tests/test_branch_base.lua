-- A branch view's full selection diffs against the merge-base, so
-- changes merged in from the base branch don't show as branch changes.
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
      repo = Repo.standard()
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

T['all commits of :Diffy branch diff against the merge-base; the oldest commit alone against its parent'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  -- default selection is every branch commit: main's line-90 edit, merged
  -- into the branch, is on both sides, so it isn't part of the diff
  ui.open_tree_row(child, 'f.txt', '<CR>', 'open_row')
  local l = ui.layout(child)
  MiniTest.expect.equality(l.left.text[90], 'main: line 90 v2')
  MiniTest.expect.equality(l.right.text[91], 'main: line 90 v2')
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', l.left.rev }), repo.sha.M2)

  -- C1 alone (the oldest commit, before the merge): its own parent
  ui.select_log_row(child, repo.sha.C1:sub(1, 7))
  l = ui.layout(child)
  MiniTest.expect.equality(l.left.text[90], '90')
  MiniTest.expect.equality(l.right.text[10], 'feat: line 10')

  child.cmd('Diffy close')
end

T['a branch with no commits past its base shows the working tree'] = function()
  repo:destroy()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(10) }):branch('feat')
  vim.fn.writefile(Repo.lines(11), repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  MiniTest.expect.equality(
    ui.layout(child).tree,
    { '▾ Unstaged (1)', '  M f.txt                         +1 -0', '  Staged (0)' }
  )
  MiniTest.expect.equality(child.v.errmsg, '')
  child.cmd('Diffy close')
end

return T
