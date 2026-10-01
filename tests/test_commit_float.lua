-- The commit message float shown while the log cursor rests on a commit.
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
        :commit('Base', { ['f.txt'] = Repo.lines(10) })
        :commit('Tweak the parser\n\nThe parser used to drop the last token.\nKeep it.', {
          ['f.txt'] = Repo.edit(3, 'x'),
        })
        :commit('Second', { ['f.txt'] = Repo.edit(5, 'y') })
      vim.fn.writefile({ 'dirty' }, repo.dir .. '/g.txt')
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

--- Lines of the non-focusable float in the current tab, or nil.
local function float_lines()
  return child.lua([[
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= '' and not c.focusable then
        return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
      end
    end
    return vim.NIL
  ]])
end

local function row_of(text)
  for i, l in ipairs(ui.layout(child).log) do
    if l:find(text, 1, true) then
      return i
    end
  end
  error(text .. ' not in the log')
end

local function keys_ready(keys)
  ui.arm_ready(child, 'commitmsg')
  child.type_keys(keys)
  ui.wait_ready(child)
end

local function open()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.log)
  child.api.nvim_win_set_cursor(w.log, { 1, 0 })
end

T['resting on a commit shows its full message, wrapped; Esc, other rows and leaving the log close it'] = function()
  open()
  local tweak, second, unstaged = row_of('Tweak the parser'), row_of('Second'), row_of('Working tree')
  MiniTest.expect.equality(float_lines(), vim.NIL)

  keys_ready(tostring(tweak) .. 'G')
  local lines = float_lines()
  MiniTest.expect.equality(lines[1]:sub(1, 7), repo.sha['Tweak the parser\n\nThe parser used to drop the last token.\nKeep it.']:sub(1, 7))
  MiniTest.expect.equality(vim.list_slice(lines, 2), {
    '',
    'Tweak the parser',
    '',
    'The parser used to drop the last',
    'token.',
    'Keep it.',
  })

  child.type_keys('<Esc>')
  MiniTest.expect.equality(float_lines(), vim.NIL)

  keys_ready(tostring(second) .. 'G')
  MiniTest.expect.equality(float_lines()[3], 'Second')

  keys_ready(tostring(unstaged) .. 'G')
  MiniTest.expect.equality(float_lines(), vim.NIL)

  keys_ready(tostring(second) .. 'G')
  MiniTest.expect.equality(float_lines()[3], 'Second')
  keys_ready('<C-w>l')
  MiniTest.expect.equality(float_lines(), vim.NIL)

  child.cmd('Diffy close')
end

T['Esc with no commit message shown does what it was mapped to before diffy'] = function()
  child.lua([[
    _G.esc = 0
    vim.keymap.set('n', '<Esc>', function() _G.esc = _G.esc + 1 end)
  ]])
  open()
  keys_ready(tostring(row_of('Second')) .. 'G')
  child.type_keys('<Esc>')
  MiniTest.expect.equality({ float_lines(), child.lua_get('_G.esc') }, { vim.NIL, 0 })
  child.type_keys('<Esc>')
  MiniTest.expect.equality(child.lua_get('_G.esc'), 1)

  child.cmd('Diffy close')
end

T['the float sits right of the column, beside the cursor row'] = function()
  open()
  local second = row_of('Second')
  keys_ready(tostring(second) .. 'G')
  local geo = child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    local log = s.wins.log
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= '' and not c.focusable then
        local p = vim.api.nvim_win_get_position(w)
        return { col = p[2], row = p[1], log_right = vim.api.nvim_win_get_position(log)[2] + vim.api.nvim_win_get_width(log),
          cursor = vim.fn.screenpos(log, vim.fn.line('.', log), 1).row - 1, diff = vim.wo[w].diff, sb = vim.wo[w].scrollbind }
      end
    end
  ]])
  MiniTest.expect.equality(geo.col > geo.log_right, true)
  -- the top frame sits on the row above the cursor, so the header lines up with it
  MiniTest.expect.equality(geo.row + 1, geo.cursor)
  MiniTest.expect.equality({ geo.diff, geo.sb }, { false, false })
  child.cmd('Diffy close')
end

return T
