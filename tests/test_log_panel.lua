-- The log for `:Diffy branch`, merge dimming/navigation-skip.
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

local function subjects(texts)
  return ui.log_subjects(child, texts)
end

local function selected()
  return subjects(ui.rows_with(child, 'log', 'DiffySelection'))
end

local function open_branch()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
end

local all_entries = { 'Working tree', 'Shift', 'Add', 'Delete', 'Rename', 'Merge branch \'main\' into feat', 'C1' }
local c1_tree = { 'M f.txt' .. (' '):rep(27) .. '+1 -1' }

T[':Diffy branch lists the working tree and the branch commits, with only the merge dimmed'] = function()
  open_branch()

  MiniTest.expect.equality(subjects(), all_entries)
  MiniTest.expect.equality(subjects(ui.rows_with(child, 'log', 'DiffyMerge')), { 'Merge branch \'main\' into feat' })

  child.cmd('Diffy close')
end

T[':Diffy branch selects the working tree with the commits, so the right side has uncommitted changes'] = function()
  local f = vim.fn.readfile(repo.dir .. '/f.txt')
  f[2] = 'staged edit'
  vim.fn.writefile(f, repo.dir .. '/f.txt')
  ui.git(repo.dir, { 'add', 'f.txt' })
  f[3] = 'unstaged edit'
  vim.fn.writefile(f, repo.dir .. '/f.txt')
  open_branch()

  MiniTest.expect.equality(selected(), all_entries)
  ui.open_tree_row(child, 'f.txt', '<CR>', 'open_row')
  local right = ui.layout(child).right
  MiniTest.expect.equality({ right.text[2], right.text[3] }, { 'staged edit', 'unstaged edit' })

  child.cmd('Diffy close')
end

T[']f/[f in the log move through the files instead of gf on the sha under the cursor'] = function()
  open_branch()
  local w = ui.wins(child)
  ui.cursor_to(child, 'log', 3)
  child.v.errmsg = ''
  -- unmapped, ]f is nvim's gf on the short sha: E447
  child.type_keys(']f', '[f')
  MiniTest.expect.equality(child.v.errmsg, '')
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.log)
  child.cmd('Diffy close')
end

T[']r from the commit before the merge lands on the commit after it, skipping it'] = function()
  open_branch()
  ui.select_log_row(child, 5)
  MiniTest.expect.equality(selected(), { 'Rename' })

  child.api.nvim_set_current_win(ui.wins(child).right)
  ui.arm_ready(child, 'select')
  child.type_keys(']r')
  ui.wait_ready(child)

  MiniTest.expect.equality(selected(), { 'C1' })
  MiniTest.expect.equality(ui.layout(child).tree, c1_tree)

  child.cmd('Diffy close')
end

T['a count on ]r/[r moves that many commits, skipping the merge and stopping at the last'] = function()
  open_branch()
  ui.select_log_row(child, 2)
  child.api.nvim_set_current_win(ui.wins(child).right)

  ui.arm_ready(child, 'select')
  child.type_keys('2]r')
  ui.wait_ready(child)
  MiniTest.expect.equality(selected(), { 'Delete' })

  ui.arm_ready(child, 'select')
  child.type_keys('3]r')
  ui.wait_ready(child)
  MiniTest.expect.equality(selected(), { 'C1' })

  ui.arm_ready(child, 'select')
  child.type_keys('2[r')
  ui.wait_ready(child)
  MiniTest.expect.equality(selected(), { 'Delete' })
  child.cmd('Diffy close')
end

T[']r/[r in the file tree move the commit selection instead of nvim\'s spell motion'] = function()
  open_branch()
  ui.select_log_row(child, 5)
  child.api.nvim_set_current_win(ui.wins(child).tree)
  child.v.errmsg = ''
  -- unmapped, ]r is nvim's next rare word: E756 with 'spell' off
  ui.arm_ready(child, 'select')
  child.type_keys(']r')
  ui.wait_ready(child)
  MiniTest.expect.equality(child.v.errmsg, '')
  MiniTest.expect.equality(selected(), { 'C1' })

  ui.arm_ready(child, 'select')
  child.type_keys('[r')
  ui.wait_ready(child)
  MiniTest.expect.equality(selected(), { 'Rename' })
  child.cmd('Diffy close')
end

T['rapid J J J ends up showing the last selection, even if an earlier one\'s git calls resolve later'] = function()
  open_branch()
  ui.select_log_row(child, 3) -- Add

  -- J visits Delete, Rename, then (skipping the merge) C1. Hold back every
  -- diff call naming Delete's commit until released below, so its render
  -- completes only after C1's has landed.
  local delete = ui.git(repo.dir, { 'log', '--format=%H', '--grep=^Delete$' })
  child.lua(([[
    local run_mod = require('diffy.git.run')
    local real_git = run_mod.git
    _G.__deferred = {}
    run_mod.git = function(args, opts)
      if args[1] == 'diff' and table.concat(args, ' '):find(%q, 1, true) then
        table.insert(_G.__deferred, function() real_git(args, opts) end)
        return nil
      end
      return real_git(args, opts)
    end
  ]]):format(delete))

  ui.arm_ready(child, 'select')
  child.type_keys('J')
  child.type_keys('J')
  child.type_keys('J')
  ui.wait_ready(child)

  MiniTest.expect.equality(selected(), { 'C1' })
  MiniTest.expect.equality(ui.layout(child).tree, c1_tree)

  -- release the stale render (raw, then the numstat it triggers)
  for _ = 1, 10 do
    child.lua([[
      while #_G.__deferred > 0 do
        table.remove(_G.__deferred, 1)()
      end
    ]])
    child.lua('vim.wait(300, function() return #_G.__deferred > 0 end)')
  end

  MiniTest.expect.equality(ui.layout(child).tree, c1_tree)
  MiniTest.expect.equality(selected(), { 'C1' })

  child.cmd('Diffy close')
end

return T
