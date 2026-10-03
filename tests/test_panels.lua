-- Panel column toggle, single-line, width-fitted tree rows, and the files and
-- commits sharing the column window.
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

T['a count on ]f/[f moves that many files, stopping at the first/last'] = function()
  repo = Repo.new():commit('Base', { ['a.txt'] = Repo.lines(5, 'a'), ['b.txt'] = Repo.lines(5, 'b'), ['c.txt'] = Repo.lines(5, 'c') })
  for _, f in ipairs({ 'a', 'b', 'c' }) do
    vim.fn.writefile({ f .. '1', 'changed' }, repo.dir .. '/' .. f .. '.txt')
  end
  child.fn.chdir(repo.dir)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  child.api.nvim_set_current_win(ui.wins(child).right)
  MiniTest.expect.equality(ui.layout(child).right.path, 'a.txt')

  ui.arm_ready(child, 'open_row')
  child.type_keys('2]f')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'c.txt')

  ui.arm_ready(child, 'open_row')
  child.type_keys('5[f')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'a.txt')
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
--- shown before (`except`), with the screen cell its text starts at,
--- `{ { text = …, row = …, col = … } }` (1-based).
local function floats(except)
  return child.lua(
    [[
    local out = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' and not vim.tbl_contains(..., w) then
        local pos = vim.fn.screenpos(w, 1, 1)
        table.insert(out, {
          text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)[1],
          row = pos.row, col = pos.col,
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
  -- a dir chain too long shortens the dirs leading to its last one, none hidden
  MiniTest.expect.equality(lines[3], '    a/with_more/nested_levels/')
  -- a file name too long keeps its start, cut at the end
  MiniTest.expect.equality(lines[4]:match('^      M init_with_an_[%w_]*\226\128\166 +%+1 %-1$') ~= nil, true)
  MiniTest.expect.equality(lines[5]:match('^      M short%.lua +%+1 %-1$') ~= nil, true)
  MiniTest.expect.equality(lines[6]:match('^    M other%.lua +%+1 %-1$') ~= nil, true)
  for _, l in ipairs(lines) do
    MiniTest.expect.equality(child.fn.strdisplaywidth(l) <= width, true)
  end
  child.cmd('Diffy close')
end

T['a path too long shortens its directories to one letter, outermost first, before cutting the name'] = function()
  local fit = function(s, width)
    return child.lua('return require("diffy.highlight").truncate_path(...)', { s, width })
  end
  local path = 'packages/api/prisma/migrations/20261001_agent_version/migration.sql'
  MiniTest.expect.equality(fit(path, #path), path)
  MiniTest.expect.equality(fit(path, #path - 1), 'p/api/prisma/migrations/20261001_agent_version/migration.sql')
  MiniTest.expect.equality(fit(path, 44), 'p/a/p/m/20261001_agent_version/migration.sql')
  MiniTest.expect.equality(fit(path, 43), 'p/a/p/m/2/migration.sql')
  -- no room left for the whole name: its end is cut, every directory kept
  MiniTest.expect.equality(fit(path, 18), 'p/a/p/m/2/migrati…')
  -- not even a few letters of the name next to the directories: they give way
  MiniTest.expect.equality(fit(path, 12), '…/migration…')
  MiniTest.expect.equality(fit('.github/workflows/release.yml', 20), '.g/w/release.yml')
end

T['resting the tree cursor on a cut row shows it whole over the row, gone on an uncut row or out of the tree'] = function()
  local long = 'src/a_rather_long_directory_name/init_with_an_extremely_long_file_name.lua'
  repo = Repo.new():commit('Base', { [long] = Repo.lines(5), ['src/short.lua'] = Repo.lines(5) })
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/' .. long)
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/src/short.lua')
  child.fn.chdir(repo.dir)

  -- the user's config frames every float by default
  child.o.winborder = 'rounded'
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
  child.cmd('redraw')
  local shown = floats(before)
  MiniTest.expect.equality(#shown, 1)
  MiniTest.expect.equality(shown[1].text, '    M a_rather_long_directory_name/init_with_an_extremely_long_file_name.lua +1 -1')
  local row_pos = child.fn.screenpos(w.tree, lnum, 1)
  MiniTest.expect.equality({ shown[1].row, shown[1].col }, { row_pos.row, row_pos.col })
  -- laid on the row alone: the rows around it stay visible
  MiniTest.expect.equality(child.fn.screenstring(row_pos.row - 1, row_pos.col + 4), lines[lnum - 1]:sub(5, 5))

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

--- A feature branch off `main` changing `files` files in its first commit,
--- then one file in each of `extra` more commits.
local function branch_repo(files, extra)
  local base, change = {}, {}
  for i = 1, files do
    local name = ('f%02d.txt'):format(i)
    base[name] = Repo.lines(3, name)
    change[name] = Repo.edit(2, 'changed')
  end
  local r = Repo.new():commit('base', base):branch('feat'):commit('c1', change)
  for i = 2, extra + 1 do
    r:commit('c' .. i, { ['f01.txt'] = Repo.edit(1, 'c' .. i) })
  end
  child.fn.chdir(r.dir)
  return r
end

local function open_branch()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
end

--- Text rows of the floats laid over the column window's edges, by side,
--- once they settle into `want` (waits up to 1 s, then returns what's there).
local function peeks(want)
  return child.lua(
    [[
    local win, want = ...
    local function read()
      local out = { above = vim.NIL, below = vim.NIL }
      local height = vim.fn.getwininfo(win)[1].height
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local c = vim.api.nvim_win_get_config(w)
        if c.relative == 'win' and c.win == win and not c.focusable then
          local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
          out[c.row == 0 and 'above' or 'below'] = lines
          if c.row ~= 0 then
            assert(c.row + #lines == height, 'the bottom float ends on the last row')
          end
        end
      end
      return out
    end
    vim.wait(1000, function() return vim.deep_equal(read(), want) end, 10)
    return read()
  ]],
    { ui.wins(child).tree, want or vim.NIL }
  )
end

--- Screen rows of the column window's first and last text rows, and of the
--- tree's first row and the log's last.
local function rows()
  local w = ui.wins(child)
  local l = ui.layout(child)
  return child.lua(
    [[
    local win, tree_first, log_last = ...
    local info = vim.fn.getwininfo(win)[1]
    return {
      top = info.winrow,
      bottom = info.winrow + info.height - 1,
      tree_first = vim.fn.screenpos(win, tree_first, 1).row,
      log_last = vim.fn.screenpos(win, log_last, 1).row,
    }
  ]],
    { w.tree, ui.lnum(child, 'tree', 1), ui.lnum(child, 'log', #l.log) }
  )
end

T['the files start at the top of the column and the commits end at its bottom while both fit'] = function()
  repo = branch_repo(3, 1)
  open_branch()
  local r = rows()
  MiniTest.expect.equality({ r.tree_first, r.log_last }, { r.top, r.bottom })
  MiniTest.expect.equality(peeks({ above = vim.NIL, below = vim.NIL }), { above = vim.NIL, below = vim.NIL })

  -- a selection with fewer files: the commits stay where they are
  ui.select_log_row(child, 'c2')
  MiniTest.expect.equality(#ui.layout(child).tree, 1)
  r = rows()
  MiniTest.expect.equality({ r.tree_first, r.log_last }, { r.top, r.bottom })
  child.cmd('Diffy close')
end

T['past the column\'s edge, the selected commits are pinned over it; with them in view, counts say what is off screen'] = function()
  repo = branch_repo(30, 4)
  open_branch()
  local w = ui.wins(child)
  -- everything is selected, below the files: pinned with the rule above it
  local rule_lnum = ui.lnum(child, 'log', 0)
  local rule = child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(w.tree), rule_lnum - 1, rule_lnum, false)[1]
  local want = {
    above = vim.NIL,
    below = { rule, '▌ Working tree', '▌ ' .. repo.sha.c5:sub(1, 7) .. ' c5', '  … 4 more selected' },
  }
  MiniTest.expect.equality(peeks(want), want)

  -- at the bottom the selection is in view: only the files above are
  -- counted, the one under the float included
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('G')
  local hidden = child.lua_get(('vim.fn.line("w0", %d)'):format(w.tree))
  want = { above = { ('↑ %d files'):format(hidden) }, below = vim.NIL }
  MiniTest.expect.equality(peeks(want), want)
  child.cmd('Diffy close')
end

T[']] goes from the files to the selected commit, [[ back to the file shown; J selects the next commit from a file row'] = function()
  repo = branch_repo(3, 2)
  open_branch()
  ui.select_log_row(child, 'c2')
  local w = ui.wins(child)
  ui.cursor_to(child, 'tree', 1)
  child.type_keys(']]')
  local log_cursor = ui.layout(child).log[child.api.nvim_win_get_cursor(w.log)[1] - ui.lnum(child, 'log', 0)]
  MiniTest.expect.equality(ui.log_subjects(child, { log_cursor }), { 'c2' })

  child.type_keys('[[')
  local tree_row = ui.panel(child, 'tree')[child.api.nvim_win_get_cursor(w.tree)[1] - ui.lnum(child, 'tree', 0)]
  MiniTest.expect.equality(tree_row.hl.DiffyCurrentFile, true)

  ui.arm_ready(child, 'select')
  child.type_keys('J')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.log_subjects(child, ui.rows_with(child, 'log', 'DiffySelection')), { 'c1' })
  child.cmd('Diffy close')
end

return T
