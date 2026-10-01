-- Panel column toggle and single-line, width-fitted tree rows.
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
      child.o.lines, child.o.columns = 30, 120
      snapshot = leak.snapshot(child)
      repo = nil
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
      end
    end,
  },
})

local function tab_wins()
  return child.lua_get('vim.api.nvim_tabpage_list_wins(0)')
end

T['the panel toggle hides the column (diff spans the width, ]f still works) and brings it back'] = function()
  repo = Repo.new():commit('Base', { ['a.txt'] = Repo.lines(5, 'a'), ['b.txt'] = Repo.lines(5, 'b') })
  vim.fn.writefile({ 'a1', 'changed' }, repo.dir .. '/a.txt')
  vim.fn.writefile({ 'b1', 'changed' }, repo.dir .. '/b.txt')
  child.fn.chdir(repo.dir)
  child.o.number = true

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  local w = ui.wins(child)
  local before_hide = ui.layout(child)

  -- hide with the buffer-local key from a diff window
  child.api.nvim_set_current_win(w.left)
  child.type_keys('\\e')
  local hidden = ui.layout(child)
  MiniTest.expect.equality({ hidden.tree, hidden.log }, { vim.NIL, vim.NIL })
  MiniTest.expect.equality(#tab_wins(), 2)
  local lw, rw = child.api.nvim_win_get_width(w.left), child.api.nvim_win_get_width(w.right)
  MiniTest.expect.equality(lw + rw + 1, child.o.columns)
  MiniTest.expect.equality(math.abs(lw - rw) <= 1, true)
  MiniTest.expect.equality(hidden.left.path, 'a.txt')

  child.api.nvim_set_current_win(w.right)
  ui.arm_ready(child, 'open_row')
  child.type_keys(']f')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'b.txt')

  -- show again: same content, panel width, clean window options
  child.cmd('Diffy panel')
  w = ui.wins(child)
  local shown = ui.layout(child)
  MiniTest.expect.equality(shown.tree, before_hide.tree)
  MiniTest.expect.equality(shown.log, before_hide.log)
  MiniTest.expect.equality(child.api.nvim_win_get_width(w.tree), 40)
  MiniTest.expect.equality(child.lua_get('vim.wo[' .. w.tree .. '].number'), false)

  -- tree keys still open files after the re-show
  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, 'call cursor(2, 1)') -- past the Unstaged header
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'a.txt')

  -- hidden again, then closed: post_case's leak check covers the teardown
  child.type_keys('\\e')
  MiniTest.expect.equality(ui.layout(child).tree, vim.NIL)
  child.cmd('Diffy close')
end

T['diff-window keys are mapped on the placeholders, before the first render'] = function()
  repo = Repo.new():commit('Base', { ['a.txt'] = Repo.lines(5, 'a') })
  child.fn.chdir(repo.dir)
  child.lua([[_G.s = require('diffy.session').open({ root = vim.fn.getcwd() })]])
  child.api.nvim_set_current_win(child.lua_get('_G.s.wins.left'))
  child.v.errmsg = ''
  -- unmapped, ]f is nvim's gf on the word "diffy": E447
  child.type_keys(']f', '[f')
  MiniTest.expect.equality(child.v.errmsg, '')
  child.cmd('Diffy close')
end

T['<leader>e hides the column leaving the cursor in the diff, and shows it again with the cursor in the file tree'] = function()
  repo = Repo.new():commit('Base', { ['a.txt'] = Repo.lines(5, 'a') })
  vim.fn.writefile({ 'a1', 'changed' }, repo.dir .. '/a.txt')
  child.fn.chdir(repo.dir)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  local w = ui.wins(child)

  child.api.nvim_set_current_win(w.right)
  child.type_keys('\\e')
  MiniTest.expect.equality(ui.layout(child).tree, vim.NIL)
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.right)

  child.type_keys('\\e')
  MiniTest.expect.equality(ui.layout(child).tree ~= vim.NIL, true)
  MiniTest.expect.equality(child.api.nvim_get_current_win(), ui.wins(child).tree)

  child.cmd('Diffy close')
end

--- The text of every float in the current tab other than the diffy windows
--- shown before (`except`), `{ { text = …, row = …, col = … } }`.
local function floats(except)
  return child.lua(
    [[
    local out = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' and not vim.tbl_contains(..., w) then
        local pos = vim.api.nvim_win_get_position(w)
        table.insert(out, {
          text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)[1],
          row = pos[1], col = pos[2],
        })
      end
    end
    return out
  ]],
    { except or {} }
  )
end

T['a long path under nested dirs renders as one row fitting the panel, the start of the file name visible'] = function()
  local dir = 'nvim/diffy/lua/diffy/a_rather_long_directory_name/with_more/nested_levels/'
  local long = dir .. 'init_with_an_extremely_long_file_name.lua'
  repo = Repo.new():commit('Base', {
    [long] = Repo.lines(5),
    [dir .. 'short.lua'] = Repo.lines(5),
    ['nvim/diffy/lua/diffy/other.lua'] = Repo.lines(5),
  })
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/' .. long)
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/' .. dir .. 'short.lua')
  vim.fn.writefile({ '1', '2', 'changed', '4', '5' }, repo.dir .. '/nvim/diffy/lua/diffy/other.lua')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  local width = child.api.nvim_win_get_width(ui.wins(child).tree)
  local lines = ui.layout(child).tree

  -- the section header, the root dir chain, the long dir chain, its two
  -- files, the sibling, the empty Staged section
  MiniTest.expect.equality(#lines, 7)
  MiniTest.expect.equality(lines[2], '  nvim/diffy/lua/diffy/')
  -- a dir chain too long keeps its last dir whole, cutting what leads to it
  MiniTest.expect.equality(lines[3]:match('^    \226\128\166[%w_/]*/nested_levels/$') ~= nil, true)
  -- a file name too long keeps its start, cut at the end
  MiniTest.expect.equality(lines[4]:match('^      M init_with_an_[%w_]*\226\128\166 +%+1 %-1$') ~= nil, true)
  MiniTest.expect.equality(lines[5]:match('^      M short%.lua +%+1 %-1$') ~= nil, true)
  MiniTest.expect.equality(lines[6]:match('^    M other%.lua +%+1 %-1$') ~= nil, true)
  for _, l in ipairs(lines) do
    MiniTest.expect.equality(child.fn.strdisplaywidth(l) <= width, true)
  end
  child.cmd('Diffy close')
end

T['resting the tree cursor on a cut row shows it whole over the row, gone on an uncut row or out of the tree'] = function()
  local long = 'src/a_rather_long_directory_name/init_with_an_extremely_long_file_name.lua'
  repo = Repo.new():commit('Base', { [long] = Repo.lines(5), ['src/short.lua'] = Repo.lines(5) })
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/' .. long)
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/src/short.lua')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  local w = ui.wins(child)
  local before = child.api.nvim_tabpage_list_wins(0)
  local lines = ui.layout(child).tree
  local lnum
  for i, l in ipairs(lines) do
    if l:find('init_with', 1, true) then
      lnum = i
    end
  end
  MiniTest.expect.equality(lines[lnum]:find('file_name.lua', 1, true), nil)

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, 'call cursor(1, 1)')
  child.type_keys(('%dG'):format(lnum))
  local shown = floats(before)
  MiniTest.expect.equality(#shown, 1)
  MiniTest.expect.equality(shown[1].text, '    M a_rather_long_directory_name/init_with_an_extremely_long_file_name.lua +1 -1')
  local tree_pos = child.api.nvim_win_get_position(w.tree)
  MiniTest.expect.equality({ shown[1].row, shown[1].col }, { tree_pos[1] + lnum - 1, tree_pos[2] })

  -- the uncut sibling row: nothing over it
  child.type_keys('j')
  MiniTest.expect.equality(child.api.nvim_get_current_line():find('short.lua', 1, true) ~= nil, true)
  MiniTest.expect.equality(floats(before), {})

  -- back on the cut row, then out of the tree
  child.type_keys('k')
  MiniTest.expect.equality(#floats(before), 1)
  child.type_keys('<C-w>l')
  child.lua(
    [[
    local before = ...
    vim.wait(1000, function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not vim.tbl_contains(before, w) then
          return false
        end
      end
      return true
    end, 10)
  ]],
    { before }
  )
  MiniTest.expect.equality(floats(before), {})
  child.cmd('Diffy close')
end

return T
