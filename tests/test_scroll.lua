-- Scrolling one diff window keeps the other aligned with it.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local snapshot
local repo

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.o.lines, child.o.columns = 50, 160
      snapshot = leak.snapshot(child)
      local base = Repo.lines(130)
      repo = Repo.new():commit('base', { ['f.txt'] = base })
      -- 15 lines added near the top and a 60-line block further down, with
      -- unchanged lines folded away between them
      local edited = {}
      for i, l in ipairs(base) do
        table.insert(edited, l)
        for j = 1, (i == 2 and 15 or i == 95 and 60 or 0) do
          table.insert(edited, ('added %d.%d'):format(i, j))
        end
      end
      vim.fn.writefile(edited, repo.dir .. '/f.txt')
      child.fn.chdir(repo.dir)
    end,
    post_case = function()
      leak.check(child, snapshot)
      repo:destroy()
    end,
  },
})

T['<C-u> through a long added block keeps the other side aligned when a plugin reads its view'] = function()
  -- what diffchar.vim does on every scroll: read each diff window's visible
  -- range, which makes nvim bring that window's cursor into view
  child.cmd([[autocmd WinScrolled * for w in nvim_tabpage_list_wins(0) | call win_execute(w, 'let g:top = line("w0")') | endfor]])
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  child.api.nvim_set_current_win(ui.wins(child).right)
  for _, key in ipairs({ 'G', '<C-u>', '<C-u>', '<C-u>' }) do
    child.type_keys(key)
    eq({ key, ui.aligned(child) }, { key, true })
  end
end

return T
