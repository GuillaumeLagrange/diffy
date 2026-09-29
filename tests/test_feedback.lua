-- :Diffy feedback: the modal, and what the `User DiffyFeedback` handler receives.
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
      repo:commit('base', { ['f.txt'] = Repo.lines(10) })
      vim.fn.writefile(Repo.edit(3, 'uncommitted')(vim.fn.readfile(repo.dir .. '/f.txt')), repo.dir .. '/f.txt')
      child.fn.chdir(repo.dir)
      ui.arm_ready(child, 'render')
      child.cmd('Diffy')
      ui.wait_ready(child)
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
      end
    end,
  },
})

-- Records every DiffyFeedback with the state the handler sees.
local function add_handler()
  child.lua([[
    _G.got = {}
    vim.api.nvim_create_autocmd('User', {
      pattern = 'DiffyFeedback',
      callback = function(a)
        local floats = 0
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_config(w).relative ~= '' then
            floats = floats + 1
          end
        end
        table.insert(_G.got, {
          text = a.data.text,
          win = vim.api.nvim_get_current_win(),
          mode = vim.api.nvim_get_mode().mode,
          floats = floats,
        })
      end,
    })
  ]])
end

local function send_feedback(keys)
  ui.arm_ready_raw(child, 'compose')
  child.cmd('Diffy feedback')
  ui.wait_ready_raw(child)
  if keys ~= '' then
    child.type_keys(keys)
  end
  ui.arm_ready_raw(child, 'feedback')
  child.type_keys('<C-s>')
  ui.wait_ready_raw(child)
end

T['<C-s> hands the typed text to the handler, back in the diff window in normal mode with the modal gone'] = function()
  add_handler()
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)

  send_feedback('the tree jumps<CR>when I stage')

  local got = child.lua_get('_G.got')
  MiniTest.expect.equality(#got, 1)
  MiniTest.expect.equality(got[1].text, 'the tree jumps\nwhen I stage')
  MiniTest.expect.equality(got[1].win, w.right)
  MiniTest.expect.equality(got[1].mode, 'n')
  MiniTest.expect.equality(got[1].floats, 0)
end

T['blank feedback reaches no handler'] = function()
  add_handler()
  send_feedback('  ')
  MiniTest.expect.equality(child.lua_get('#_G.got'), 0)
end

T['without a handler it warns and opens nothing'] = function()
  ui.capture_warnings(child)
  local wins = #child.api.nvim_list_wins()
  child.cmd('Diffy feedback')
  MiniTest.expect.equality(#ui.warnings(child) > 0, true)
  MiniTest.expect.equality(#child.api.nvim_list_wins(), wins)
end

return T
