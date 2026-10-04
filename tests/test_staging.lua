-- The working tree's Unstaged/Staged sections, tree staging keys, and
-- nested directory grouping.
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

local function tree()
  return ui.layout(child).tree
end

local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

local function exact_line(lines, text)
  for i, l in ipairs(lines) do
    if l == text then
      return i
    end
  end
  return nil
end

local function has(lines, text)
  return exact_line(lines, text) ~= nil
end

--- Line of the first tree row containing `needle` after the `section` header.
local function line_in(section, needle)
  local lines = tree()
  local from = find_line(lines, section .. ' (')
  assert(from, section .. ' header missing')
  for i = from + 1, #lines do
    if lines[i]:match('^%S') then
      return nil
    end
    if lines[i]:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

local function tree_cursor_text()
  local w = ui.wins(child)
  return tree()[child.api.nvim_win_get_cursor(w.tree)[1]]
end

local function press_in_tree(lnum, keys, event)
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  child.api.nvim_win_set_cursor(w.tree, { lnum, 0 })
  ui.arm_ready(child, event or 'render')
  child.type_keys(keys)
  ui.wait_ready(child)
end

--- Line numbers of the tree rows marked as the file shown in the diff.
local function marked_lines()
  local out = {}
  for i, r in ipairs(ui.panel(child, 'tree')) do
    if r.hl.DiffyCurrentFile then
      table.insert(out, i)
    end
  end
  return out
end

T[':Diffy selects the working tree and lists its Unstaged and Staged sections, each file opening its own pair'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(5), ['g.txt'] = Repo.lines(5) })
  local f = Repo.lines(5)
  f[1] = 'staged1'
  vim.fn.writefile(f, repo.dir .. '/f.txt')
  vim.fn.writefile({ 'staged g' }, repo.dir .. '/g.txt')
  ui.git(repo.dir, { 'add', 'f.txt', 'g.txt' })
  f[5] = 'unstaged5'
  vim.fn.writefile(f, repo.dir .. '/f.txt')
  vim.fn.writefile({ 'new' }, repo.dir .. '/u.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.rows_with(child, 'log', 'DiffySelection'), { '\226\150\140 Working tree' })
  local lines = tree()
  MiniTest.expect.equality(lines[1], '▾ Unstaged (2)')
  MiniTest.expect.equality(lines[4], '▾ Staged (2)')
  MiniTest.expect.equality(line_in('Unstaged', 'M f.txt'), 2)
  MiniTest.expect.equality(line_in('Unstaged', '? u.txt'), 3)
  MiniTest.expect.equality(line_in('Staged', 'M f.txt'), 5)
  MiniTest.expect.equality(line_in('Staged', 'M g.txt'), 6)

  press_in_tree(5, '<CR>', 'open_row')
  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.rev, l.left.path, l.right.rev, l.right.path }, { 'HEAD', 'f.txt', 'index', 'f.txt' })
  MiniTest.expect.equality(l.right.text[5], '5')
  -- only the opened row is marked, not the same path in the other section
  MiniTest.expect.equality(marked_lines(), { 5 })

  press_in_tree(2, '<CR>', 'open_row')
  l = ui.layout(child)
  MiniTest.expect.equality({ l.left.rev, l.left.path, l.right.rev, l.right.path }, { 'index', 'f.txt', 'worktree', 'f.txt' })
  MiniTest.expect.equality(l.right.text[5], 'unstaged5')
  MiniTest.expect.equality(marked_lines(), { 2 })

  child.cmd('Diffy close')
end

T['a staged-section file shows the index on the right, and writing it unstages the reverted hunk'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(20) })
  local edited = Repo.lines(20)
  edited[5] = 'edited5'
  edited[15] = 'edited15'
  vim.fn.writefile(edited, repo.dir .. '/f.txt')
  ui.git(repo.dir, { 'add', 'f.txt' })
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.rev, l.right.rev }, { 'HEAD', 'index' })
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  child.type_keys('do')
  child.cmd('write')

  local staged = ui.git(repo.dir, { 'diff', '--cached' })
  MiniTest.expect.equality(staged:find('+edited5', 1, true) ~= nil, false)
  MiniTest.expect.equality(staged:find('+edited15', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['an unstaged-section file shows index/worktree, and writing the left buffer stages exactly the edited hunk'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(20) })
  local edited = Repo.lines(20)
  edited[5] = 'edited5'
  edited[15] = 'edited15'
  vim.fn.writefile(edited, repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.rev, l.left.path }, { 'index', 'f.txt' })
  MiniTest.expect.equality({ l.right.rev, l.right.path }, { 'worktree', 'f.txt' })
  local w = ui.wins(child)

  child.api.nvim_set_current_win(w.left)
  child.fn.win_execute(w.left, 'call cursor(5, 1)')
  child.type_keys('do')
  child.cmd('write')

  -- check the changed lines themselves, not the hunk header (git's context
  -- annotation on `@@ ... @@` can echo either edited line as text)
  local staged = ui.git(repo.dir, { 'diff', '--cached' })
  MiniTest.expect.equality(staged:find('+edited5', 1, true) ~= nil, true)
  MiniTest.expect.equality(staged:find('+edited15', 1, true) ~= nil, false)

  local unstaged = ui.git(repo.dir, { 'diff' })
  MiniTest.expect.equality(unstaged:find('+edited15', 1, true) ~= nil, true)
  MiniTest.expect.equality(unstaged:find('+edited5', 1, true) ~= nil, false)

  child.cmd('Diffy close')
end

T['writing either diff side refreshes the tree: the worktree file its counts, the index its Staged row'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(20) })
  local edited = Repo.lines(20)
  edited[5] = 'edited5'
  vim.fn.writefile(edited, repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.equality(line_in('Unstaged', '+1 -1') ~= nil, true)

  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)
  child.type_keys('15G', 'o', 'typed', '<Esc>')
  ui.arm_ready(child, 'render')
  child.cmd('write')
  ui.wait_ready(child)
  MiniTest.expect.equality(line_in('Unstaged', '+2 -1') ~= nil, true)
  MiniTest.expect.equality(line_in('Staged', 'f.txt'), nil)

  child.api.nvim_set_current_win(w.left)
  child.fn.win_execute(w.left, 'call cursor(5, 1)')
  child.type_keys('do')
  ui.arm_ready(child, 'render')
  child.cmd('write')
  ui.wait_ready(child)
  MiniTest.expect.equality(line_in('Staged', '+1 -1') ~= nil, true)
  MiniTest.expect.equality(line_in('Unstaged', '+1 -0') ~= nil, true)

  child.cmd('Diffy close')
end

T['`-` moves a file to the other section and the cursor follows it'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(5), ['g.txt'] = Repo.lines(5) })
  vim.fn.writefile({ 'changed' }, repo.dir .. '/g.txt')
  vim.fn.writefile({ 'changed' }, repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  press_in_tree(line_in('Unstaged', 'g.txt'), '-')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), 'g.txt')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--name-only' }), 'f.txt')
  MiniTest.expect.equality(tree()[1], '▾ Unstaged (1)')
  local staged_g = line_in('Staged', 'g.txt')
  MiniTest.expect.equality(staged_g ~= nil, true)
  MiniTest.expect.equality(line_in('Unstaged', 'g.txt'), nil)
  MiniTest.expect.equality(child.api.nvim_win_get_cursor(ui.wins(child).tree)[1], staged_g)

  press_in_tree(staged_g, '-')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), '')
  MiniTest.expect.equality(tree_cursor_text():find('g.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(line_in('Unstaged', 'g.txt'), child.api.nvim_win_get_cursor(ui.wins(child).tree)[1])

  child.cmd('Diffy close')
end

T['keys on a section header apply to all its files'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(5), ['g.txt'] = Repo.lines(5) })
  vim.fn.writefile({ 'changed' }, repo.dir .. '/g.txt')
  vim.fn.writefile({ 'changed' }, repo.dir .. '/f.txt')
  vim.fn.writefile({ 'new' }, repo.dir .. '/u.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  press_in_tree(1, '-')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), 'f.txt\ng.txt\nu.txt')
  -- an empty section has nothing to fold: no marker
  MiniTest.expect.equality(tree()[1], '  Unstaged (0)')
  MiniTest.expect.equality(tree()[2], '▾ Staged (3)')
  MiniTest.expect.equality(tree_cursor_text(), '  Unstaged (0)')

  press_in_tree(2, 'u')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), '')
  MiniTest.expect.equality(tree()[1], '▾ Unstaged (3)')
  MiniTest.expect.equality(tree_cursor_text(), '  Staged (0)')

  child.cmd('Diffy close')
end

T['the working tree selected with commits shows one merged tree, no sections'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(5) }):commit('C1', { ['c.txt'] = Repo.lines(2) })
  vim.fn.writefile({ 'staged' }, repo.dir .. '/s.txt')
  ui.git(repo.dir, { 'add', 's.txt' })
  vim.fn.writefile({ 'changed' }, repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  ui.cursor_to(child, 'log', 1)
  ui.arm_ready(child, 'select')
  child.type_keys('Vj<CR>')
  ui.wait_ready(child)

  local lines = tree()
  MiniTest.expect.equality(find_line(lines, 'Unstaged'), nil)
  MiniTest.expect.equality(find_line(lines, 'Staged'), nil)
  MiniTest.expect.equality(find_line(lines, 'A c.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(lines, 'M f.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(lines, 'A s.txt') ~= nil, true)
  press_in_tree(find_line(lines, 'M f.txt'), '<CR>', 'open_row')
  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.rev, l.right.rev }, { repo.sha.C1:sub(1, 7) .. '^', 'worktree' })

  child.cmd('Diffy close')
end

T['`u` on a staged rename pair unstages both paths'] = function()
  repo = Repo.new():commit('Base', { ['h.txt'] = Repo.lines(5) })
  repo:mv('h.txt', 'i.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  local lnum = find_line(tree(), 'R h.txt')
  MiniTest.expect.equality(lnum ~= nil, true)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(lnum))

  ui.arm_ready(child, 'render')
  child.type_keys('u')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), '')
  -- `ui.git` trims the whole output, dropping the first line's leading
  -- status-column space; match the rest of each porcelain line instead
  local status = ui.git(repo.dir, { 'status', '--porcelain' })
  MiniTest.expect.equality(status:find('D h.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(status:find('?? i.txt', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['an unstaged rename shows as D + ?, as R after `git add -N`, and `s` stages both paths'] = function()
  repo = Repo.new():commit('Base', { ['h.txt'] = Repo.lines(5) })
  os.rename(repo.dir .. '/h.txt', repo.dir .. '/i.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
  local before = tree()
  MiniTest.expect.equality(find_line(before, 'D h.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(before, '? i.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(before, 'R h.txt') == nil, true)

  ui.git(repo.dir, { 'add', '-N', 'i.txt' })
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)

  local after = tree()
  local lnum = find_line(after, 'R h.txt \226\134\146 i.txt')
  MiniTest.expect.equality(lnum ~= nil, true)

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(lnum))
  ui.arm_ready(child, 'render')
  child.type_keys('s') -- stage the rename pair from its Unstaged (intent-to-add) row
  ui.wait_ready(child)

  local staged = ui.git(repo.dir, { 'diff', '--cached', '-M', '--name-status' })
  MiniTest.expect.equality(staged:sub(1, 1), 'R')
  MiniTest.expect.equality(staged:find('h.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(staged:find('i.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--name-only' }), '')

  child.cmd('Diffy close')
end

T['staging keys are a no-op, with a warning, when the selection is not the working tree alone'] = function()
  repo = Repo.standard()
  local cur = vim.fn.readfile(repo.dir .. '/f.txt')
  cur[1] = 'dirty'
  vim.fn.writefile(cur, repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  ui.select_log_row(child, 'Shift') -- touches f.txt, same file as the dirty edit
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, 'call cursor(1, 1)')

  ui.capture_warnings(child)
  child.type_keys('s')
  MiniTest.expect.equality(#ui.warnings(child) >= 1, true)

  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), '')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--name-only' }), 'f.txt')

  child.cmd('Diffy close')
end

T['section and unstage keys leave a conflicted file in conflict'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(3) })
  repo:branch('other'):commit('Theirs', { ['f.txt'] = Repo.edit(2, 'theirs') })
  repo:checkout('main'):commit('Ours', { ['f.txt'] = Repo.edit(2, 'ours') })
  repo:merge_conflict('other')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  -- `git add` on the Unstaged header would skip the marker check, `git
  -- reset` on the Staged row would drop the conflict stages
  child.api.nvim_win_set_cursor(w.tree, { 1, 0 })
  child.type_keys('s')
  child.api.nvim_win_set_cursor(w.tree, { line_in('Staged', 'U f.txt'), 0 })
  child.type_keys('u')
  -- a `git add`/`git reset` the keys would wrongly run has exited once every command diffy started has
  child.lua([[
    vim.wait(1000, function()
      for _, e in ipairs(require('diffy.git.run').recent) do
        if e.code == nil then
          return false
        end
      end
      return true
    end, 10)
  ]])
  MiniTest.expect.equality(ui.git(repo.dir, { 'ls-files', '-u', '--', 'f.txt' }) ~= '', true)

  child.cmd('Diffy close')
end

T['nested directories group under collapsible headers, single-child chains flattened'] = function()
  repo = Repo.new()
    :commit('Base', { ['top.txt'] = Repo.lines(1) })
    :commit('Add', {
      ['a/b/c/file1.txt'] = Repo.lines(1),
      ['a/b/c/file2.txt'] = Repo.lines(1),
      ['a/d/file3.txt'] = Repo.lines(1),
    })
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd(('Diffy %s..%s'):format(repo.sha.Base, repo.sha.Add))
  ui.wait_ready(child)

  local w = ui.wins(child)
  local lines = tree()
  -- a/b/c collapses into one "b/c/" row under "a/" (chain flattening), not
  -- three separate header rows
  MiniTest.expect.equality(has(lines, '▾ a/'), true)
  MiniTest.expect.equality(has(lines, '  ▾ b/c/'), true)
  MiniTest.expect.equality(has(lines, '  ▾ b/'), false)
  MiniTest.expect.equality(has(lines, '    ▾ c/'), false)
  -- a/d holds a single file, so `d/` never gets a header row at all
  MiniTest.expect.equality(has(lines, '  ▾ d/'), false)

  -- rows under a header show the path relative to it
  local f1 = find_line(lines, 'A file1.txt')
  local f3 = find_line(lines, 'A d/file3.txt')
  MiniTest.expect.equality(find_line(lines, 'a/b/c/file1.txt'), nil)
  MiniTest.expect.equality(lines[f1]:match('^(%s*)'), '    ')
  MiniTest.expect.equality(lines[f3]:match('^(%s*)'), '  ')

  child.cmd('Diffy close')
end

--- The tree's rows without their +/- counts.
local function tree_rows()
  return vim.tbl_map(function(l)
    return (l:gsub('%s+%+%d+ %-%d+$', ''))
  end, tree())
end

--- Put the tree cursor on the row reading `text` (counts left out) and type `keys`.
local function keys_on(text, keys)
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  child.api.nvim_win_set_cursor(w.tree, { exact_line(tree_rows(), text), 0 })
  child.type_keys(keys)
end

T['<CR> on a folder collapses it to its header and expands it back, top-level folders included; ▸/▾ say which'] = function()
  repo = Repo.new()
    :commit('Base', { ['top.txt'] = Repo.lines(1) })
    :commit('Add', {
      ['a/b/c/file1.txt'] = Repo.lines(1),
      ['a/b/c/file2.txt'] = Repo.lines(1),
      ['a/d/file3.txt'] = Repo.lines(1),
      ['z/one.txt'] = Repo.lines(1),
      ['z/two.txt'] = Repo.lines(1),
    })
  child.fn.chdir(repo.dir)
  ui.arm_ready(child, 'render')
  child.cmd(('Diffy %s..%s'):format(repo.sha.Base, repo.sha.Add))
  ui.wait_ready(child)
  local w = ui.wins(child)

  keys_on('  ▾ b/c/', '<CR>')
  MiniTest.expect.equality(tree_rows(), { '▾ a/', '  ▸ b/c/', '  A d/file3.txt', '▾ z/', '  A one.txt', '  A two.txt' })
  -- the cursor stays on the header, in the tree
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.tree)
  MiniTest.expect.equality(child.api.nvim_win_get_cursor(w.tree)[1], 2)

  keys_on('▾ z/', '<CR>')
  MiniTest.expect.equality(tree_rows(), { '▾ a/', '  ▸ b/c/', '  A d/file3.txt', '▸ z/' })
  keys_on('▾ a/', '<CR>')
  MiniTest.expect.equality(tree_rows(), { '▸ a/', '▸ z/' })
  -- expanding a/ shows b/c/ as it was left
  keys_on('▸ a/', '<CR>')
  MiniTest.expect.equality(tree_rows(), { '▾ a/', '  ▸ b/c/', '  A d/file3.txt', '▸ z/' })
  keys_on('  ▸ b/c/', '<CR>')
  MiniTest.expect.equality(tree_rows()[2], '  ▾ b/c/')
  MiniTest.expect.equality(tree_rows()[3], '    A file1.txt')
  child.cmd('Diffy close')
end

T['a collapsed folder stays collapsed across renders, ]f skips it, a jump to a file in it expands it'] = function()
  repo = Repo.new():commit('Base', {
    ['0.txt'] = Repo.lines(3),
    ['a/one.txt'] = Repo.lines(3),
    ['a/two.txt'] = Repo.lines(3),
    ['z/four.txt'] = Repo.lines(3),
    ['z/three.txt'] = Repo.lines(3),
  })
  for _, p in ipairs({ '0.txt', 'a/one.txt', 'a/two.txt', 'z/four.txt', 'z/three.txt' }) do
    vim.fn.writefile({ '1', 'changed', '3' }, repo.dir .. '/' .. p)
  end
  child.fn.chdir(repo.dir)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  press_in_tree(exact_line(tree_rows(), '    M one.txt'), 'o', 'open_row')
  keys_on('  ▾ a/', '<CR>')
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)
  MiniTest.expect.equality(
    tree_rows(),
    { '▾ Unstaged (5)', '  M 0.txt', '  ▸ a/', '  ▾ z/', '    M four.txt', '    M three.txt', '  Staged (0)' }
  )
  MiniTest.expect.equality(ui.layout(child).right.path, 'a/one.txt')

  -- from the hidden a/one.txt, ]f goes to the next file in sight
  ui.arm_ready(child, 'open_row')
  child.type_keys(']f')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'z/four.txt')

  child.api.nvim_set_current_win(ui.wins(child).right)
  child.cmd('edit ' .. repo.dir .. '/a/two.txt')
  vim.wait(2000, function()
    return ui.layout(child).right.path == 'a/two.txt'
  end)
  MiniTest.expect.equality(tree_rows()[3], '  ▾ a/')
  MiniTest.expect.equality(marked_lines(), { exact_line(tree_rows(), '    M two.txt') })
  child.cmd('Diffy close')
end

T['<CR> on a section header collapses the section; s on it stages every file'] = function()
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(5), ['d/g.txt'] = Repo.lines(5), ['d/h.txt'] = Repo.lines(5) })
  vim.fn.writefile({ 'f' }, repo.dir .. '/f.txt')
  vim.fn.writefile({ 'g' }, repo.dir .. '/d/g.txt')
  vim.fn.writefile({ 'h' }, repo.dir .. '/d/h.txt')
  child.fn.chdir(repo.dir)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  keys_on('▾ Unstaged (3)', '<CR>')
  MiniTest.expect.equality(tree_rows(), { '▸ Unstaged (3)', '  Staged (0)' })
  press_in_tree(1, 's')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), 'd/g.txt\nd/h.txt\nf.txt')
  child.cmd('Diffy close')
end

T['a new untracked directory shows its files individually as ? rows, grouped under a header'] = function()
  repo = Repo.new():commit('Base', { ['top.txt'] = Repo.lines(1) })
  vim.fn.mkdir(repo.dir .. '/newdir', 'p')
  vim.fn.writefile({ 'x' }, repo.dir .. '/newdir/a.txt')
  vim.fn.writefile({ 'y' }, repo.dir .. '/newdir/b.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local lines = tree()
  -- without `--untracked-files=all`, git status collapses a new untracked
  -- directory into one `?? newdir/` entry
  MiniTest.expect.equality(has(lines, '  ? newdir/'), false)
  MiniTest.expect.equality(has(lines, '  ▾ newdir/'), true)
  local a_lnum = find_line(lines, '? a.txt')
  local b_lnum = find_line(lines, '? b.txt')
  MiniTest.expect.equality(find_line(lines, 'newdir/a.txt'), nil)
  MiniTest.expect.equality(a_lnum ~= nil, true)
  MiniTest.expect.equality(b_lnum ~= nil, true)
  -- grouped under the directory's own header row, one level in from it
  MiniTest.expect.equality(lines[a_lnum]:match('^(%s*)'), '    ')
  MiniTest.expect.equality(lines[b_lnum]:match('^(%s*)'), '    ')

  child.cmd('Diffy close')
end

T['staging in :Diffy branch keeps the working tree selected'] = function()
  repo = Repo.new():commit('Base', { ['base.txt'] = Repo.lines(5) })
  repo:branch('feat'):commit('C1', { ['committed.txt'] = Repo.lines(3) })
  vim.fn.writefile({ 'dirty a' }, repo.dir .. '/a.txt')
  vim.fn.writefile({ 'dirty b' }, repo.dir .. '/b.txt')
  ui.git(repo.dir, { 'add', '-N', 'a.txt', 'b.txt' })
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
  ui.select_log_row(child, 'Working tree')
  press_in_tree(line_in('Unstaged', 'a.txt'), 's')

  -- still the working tree: a.txt moved to Staged, not the branch's committed file
  MiniTest.expect.equality(ui.rows_with(child, 'log', 'DiffySelection'), { '\226\150\140 Working tree' })
  MiniTest.expect.equality(line_in('Unstaged', 'b.txt') ~= nil, true)
  MiniTest.expect.equality(line_in('Unstaged', 'a.txt'), nil)
  MiniTest.expect.equality(line_in('Staged', 'a.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(tree(), 'committed.txt'), nil)

  child.cmd('Diffy close')
end

return T
