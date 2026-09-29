-- A `BufWinEnter` in the right diff window swaps the
-- pair when the new buffer's path is in the current file list and
-- highlights it in the tree; otherwise diff mode turns off and the left
-- window shows an "outside diff" placeholder. `<C-o>` restores the pair.
--
-- The jump cases simulate what an LSP go-to-definition does without an LSP:
-- push the tag stack, then `:edit` the target in the current window.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local snapshot
local repo
local base_wins

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      repo = Repo.new()
        :commit('base', {
          ['a.txt'] = Repo.lines(30),
          ['b.txt'] = Repo.lines(30, 'b'),
          ['outside.txt'] = Repo.lines(30, 'o'),
          ['del.txt'] = Repo.lines(5, 'd'),
          ['old.txt'] = Repo.lines(10, 'r'),
        })
        :mv('old.txt', 'new.txt')
        :commit('rename', { ['new.txt'] = Repo.edit(2, 'r2 renamed') })
      -- unstaged edits so bare `:Diffy` (Unstaged selected) shows a real,
      -- editable worktree file on the right; plus one added, one deleted file
      vim.fn.writefile(vim.list_extend({ '1 edited' }, Repo.lines(29)), repo.dir .. '/a.txt')
      local b = Repo.lines(30, 'b')
      b[1] = 'b1 edited'
      vim.fn.writefile(b, repo.dir .. '/b.txt')
      vim.fn.writefile({ 'added' }, repo.dir .. '/added.txt')
      vim.fn.delete(repo.dir .. '/del.txt')
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

local function path(p)
  return vim.fn.fnameescape(repo.dir .. '/' .. p)
end

local function open()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  base_wins = #child.api.nvim_tabpage_list_wins(0)
  eq(ui.layout(child).right.path, 'a.txt')
end

--- What an LSP definition jump does: tag stack entry, then `:edit` in the
--- current window (or a split).
local function lsp_jump(target, lnum, split)
  child.lua(
    [[
    local target, lnum, split = ...
    local win = vim.api.nvim_get_current_win()
    local pos = vim.api.nvim_win_get_cursor(win)
    local from = { vim.api.nvim_get_current_buf(), pos[1], pos[2] + 1, 0 }
    vim.fn.settagstack(win, { items = { { tagname = 'x', from = from } } }, 't')
    vim.cmd("normal! m'")
    if split then vim.cmd(split) end
    if target ~= '' then vim.cmd('edit ' .. vim.fn.fnameescape(target)) end
    vim.api.nvim_win_set_cursor(0, { lnum or 1, 0 })
  ]],
    { target or '', lnum, split or false }
  )
end

local function keys(k)
  child.type_keys(k)
end

-- diffy maps <Tab> in the diff windows, and without the terminal's extended
-- keys <C-i> is <Tab>
local function forward()
  child.lua([[vim.api.nvim_feedkeys('\t', 'nx', false)]])
end

local function wo(win, opt)
  return child.lua_get(('vim.api.nvim_win_is_valid(%d) and vim.wo[%d].%s'):format(win, win, opt))
end

local function current_rows()
  local out = {}
  for _, r in ipairs(ui.rows_with(child, 'tree', 'DiffyCurrentFile')) do
    table.insert(out, vim.trim(r))
  end
  return out
end

local function no_errors()
  eq(child.v.errmsg, '')
end

--- Both diff windows show `p` (left from `lp`), bound and in diff mode.
local function expect_pair(p, lp)
  local l = ui.layout(child)
  local w = ui.wins(child)
  eq({ l.left.path, l.right.path }, { lp or p, p })
  for _, side in ipairs({ 'left', 'right' }) do
    eq({ side, wo(w[side], 'diff'), wo(w[side], 'scrollbind'), wo(w[side], 'cursorbind') }, { side, true, true, true })
  end
  eq(#child.api.nvim_tabpage_list_wins(0), base_wins)
  local rows = current_rows()
  eq(#rows, 1)
  eq(rows[1]:find(p, 1, true) ~= nil, true)
  no_errors()
end

--- Only one diff window, showing the added/deleted `p`.
local function expect_one(side, p)
  local l = ui.layout(child)
  local w = ui.wins(child)
  eq(l[side == 'left' and 'right' or 'left'], vim.NIL)
  eq(l[side].path, p)
  eq({ wo(w[side], 'diff'), wo(w[side], 'scrollbind') }, { false, false })
  eq(#child.api.nvim_tabpage_list_wins(0), base_wins - 1)
  local rows = current_rows()
  eq(#rows, 1)
  eq(rows[1]:find(p, 1, true) ~= nil, true)
  no_errors()
end

--- Outside the file list: the right window shows `name`, unbound, the left
--- the placeholder, nothing marked in the tree.
local function expect_outside(name)
  local l = ui.layout(child)
  local w = ui.wins(child)
  eq(l.right.name, name)
  eq(l.right.bar, '(outside diff)')
  eq(l.left.text, { '(outside diff)' })
  for _, side in ipairs({ 'left', 'right' }) do
    eq({ side, wo(w[side], 'diff'), wo(w[side], 'scrollbind'), wo(w[side], 'cursorbind') }, { side, false, false, false })
  end
  eq(#child.api.nvim_tabpage_list_wins(0), base_wins)
  eq(current_rows(), {})
  no_errors()
end

--- Either a pair (whatever file) or the outside state, never a mix.
local function expect_consistent()
  local l = ui.layout(child)
  if l.right.bar == '(outside diff)' then
    expect_outside(l.right.name)
  else
    expect_pair(l.right.path, l.left.path)
  end
end

T['jumping to another listed file swaps both sides and highlights the tree'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.cmd('edit ' .. path('b.txt'))
  expect_pair('b.txt')
  child.cmd('Diffy close')
end

T['jumping outside the file list leaves diff mode with a placeholder, and <C-o> restores the pair'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.cmd('edit ' .. path('outside.txt'))
  expect_outside(repo.dir .. '/outside.txt')
  keys('<C-o>')
  expect_pair('a.txt')
  child.cmd('Diffy close')
end

T['a definition outside the diff and back with <C-t> restores the pair'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  lsp_jump(repo.dir .. '/outside.txt', 20)
  expect_outside(repo.dir .. '/outside.txt')
  keys('<C-t>')
  expect_pair('a.txt')
  eq(child.api.nvim_win_get_cursor(0)[1], 12)
  keys('<C-o>')
  expect_outside(repo.dir .. '/outside.txt')
  forward()
  expect_pair('a.txt')
  -- the jumplist starts with the session: nothing from before it
  keys('<C-o><C-o><C-o><C-o>')
  eq(ui.layout(child).right.name ~= '', true)
  no_errors()
  child.cmd('Diffy close')
end

T['<C-t> back into a file listed in both sections returns to the section it left'] = function()
  ui.git(repo.dir, { 'add', 'a.txt' })
  local a = Repo.lines(30)
  a[1], a[30] = '1 edited', '30 edited'
  vim.fn.writefile(a, repo.dir .. '/a.txt')
  open()
  local staged_row
  for i, r in ipairs(ui.panel(child, 'tree')) do
    if staged_row == nil and r.text:match('^Staged') then
      staged_row = false
    elseif staged_row == false and r.text:find('a.txt', 1, true) then
      staged_row = i
    end
  end
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  child.api.nvim_win_set_cursor(w.tree, { staged_row, 0 })
  ui.arm_ready(child, 'open_row')
  keys('<CR>')
  ui.wait_ready(child)
  local l = ui.layout(child)
  eq({ l.left.rev, l.right.rev }, { 'HEAD', 'index' })
  child.api.nvim_set_current_win(w.right)
  lsp_jump(repo.dir .. '/outside.txt', 3)
  expect_outside(repo.dir .. '/outside.txt')
  keys('<C-t>')
  expect_pair('a.txt')
  l = ui.layout(child)
  eq({ l.left.rev, l.right.rev }, { 'HEAD', 'index' })
  child.cmd('Diffy close')
end

T['a definition in another listed file and back with <C-t> swaps the pair twice'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(repo.dir .. '/b.txt', 5)
  expect_pair('b.txt')
  eq(child.api.nvim_win_get_cursor(0)[1], 5)
  keys('<C-t>')
  expect_pair('a.txt')
  child.cmd('Diffy close')
end

T['a definition further down the same file keeps the pair'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(nil, 25)
  expect_pair('a.txt')
  keys('<C-t>')
  expect_pair('a.txt')
  eq(child.api.nvim_win_get_cursor(0)[1], 1)
  child.cmd('Diffy close')
end

T['a definition jump from the left window opens in the right one, and <C-t> there restores the pair'] = function()
  open()
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.left)
  child.api.nvim_win_set_cursor(0, { 8, 0 })
  lsp_jump(repo.dir .. '/outside.txt', 3)
  expect_outside(repo.dir .. '/outside.txt')
  eq(child.api.nvim_get_current_win(), w.right)
  eq(child.api.nvim_win_get_cursor(0)[1], 3)
  keys('<C-t>')
  expect_pair('a.txt')
  eq(child.api.nvim_get_current_win(), w.right)
  child.cmd('Diffy close')
end

T['a definition jump from the left window into a listed file swaps the pair'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).left)
  lsp_jump(repo.dir .. '/b.txt', 3)
  expect_pair('b.txt')
  keys('<C-t>')
  expect_pair('a.txt')
  child.cmd('Diffy close')
end

T['jumping out of an added file and back shows it alone again'] = function()
  open()
  ui.open_tree_row(child, 'added.txt', 'o', 'open_row')
  expect_one('right', 'added.txt')
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(repo.dir .. '/outside.txt', 3)
  eq(ui.layout(child).right.name, repo.dir .. '/outside.txt')
  eq(ui.layout(child).right.bar, '(outside diff)')
  no_errors()
  keys('<C-t>')
  expect_one('right', 'added.txt')
  lsp_jump(repo.dir .. '/b.txt', 3)
  expect_pair('b.txt')
  keys('<C-t>')
  expect_one('right', 'added.txt')
  child.cmd('Diffy close')
end

T['jumping out of a deleted file brings back both windows, and the tree shows it alone again'] = function()
  open()
  ui.open_tree_row(child, 'del.txt', 'o', 'open_row')
  expect_one('left', 'del.txt')
  child.api.nvim_set_current_win(ui.wins(child).left)
  lsp_jump(repo.dir .. '/outside.txt', 3)
  expect_outside(repo.dir .. '/outside.txt')
  ui.open_tree_row(child, 'del.txt', 'o', 'open_row')
  expect_one('left', 'del.txt')
  child.api.nvim_set_current_win(ui.wins(child).left)
  lsp_jump(repo.dir .. '/b.txt', 3)
  expect_pair('b.txt')
  child.cmd('Diffy close')
end

T['selecting another commit while outside the diff, then <C-o> to a file not in it, stays outside'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(repo.dir .. '/outside.txt', 3)
  expect_outside(repo.dir .. '/outside.txt')
  ui.select_log_row(child, 'rename')
  expect_pair('new.txt', 'old.txt')
  child.api.nvim_set_current_win(ui.wins(child).right)
  -- back to a file not in the rename commit
  keys('<C-o>')
  eq(ui.layout(child).right.bar, '(outside diff)')
  expect_consistent()
  ui.open_tree_row(child, 'new.txt', 'o', 'open_row')
  expect_pair('new.txt', 'old.txt')
  child.cmd('Diffy close')
end

T['<C-o> in the left window through blobs of earlier pairs keeps a consistent layout'] = function()
  open()
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.left)
  keys('20G')
  ui.open_tree_row(child, 'b.txt', 'o', 'open_row')
  child.api.nvim_set_current_win(w.left)
  keys('20G')
  ui.select_log_row(child, 'rename')
  for _ = 1, 4 do
    child.api.nvim_set_current_win(ui.wins(child).left)
    keys('<C-o>')
    child.lua('vim.wait(0)')
    expect_consistent()
  end
  for _ = 1, 4 do
    forward()
    child.lua('vim.wait(0)')
    expect_consistent()
  end
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.cmd('edit ' .. path('outside.txt'))
  expect_outside(repo.dir .. '/outside.txt')
  child.cmd('Diffy close')
end

T['a diff plugin erroring while diffy swaps buffers does not stop later jumps from leaving the diff'] = function()
  open()
  -- diffchar.vim's E716 when diffy swaps the worktree file in, once
  child.lua([[
    local id
    id = vim.api.nvim_create_autocmd('BufWinEnter', {
      callback = function()
        -- not bufload's hidden autocmd window
        if vim.w.diffy_path then
          vim.api.nvim_del_autocmd(id)
          error('E716: Key not present')
        end
      end,
    })
  ]])
  pcall(ui.open_tree_row, child, 'b.txt', 'o', 'open_row', 500)
  child.v.errmsg = ''
  ui.open_tree_row(child, 'a.txt', 'o', 'open_row')
  expect_pair('a.txt')
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.cmd('edit ' .. path('outside.txt'))
  expect_outside(repo.dir .. '/outside.txt')
  child.cmd('Diffy close')
end

T['deleting the file shown on the right with a window-keeping :bdelete leaves the session usable'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.lua([[require('mini.bufremove').delete(0, true)]])
  no_errors()
  eq(ui.layout(child).left.text, { '(outside diff)' })
  eq(#child.api.nvim_tabpage_list_wins(0), base_wins)
  ui.open_tree_row(child, 'b.txt', 'o', 'open_row')
  expect_pair('b.txt')
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.lua([[require('mini.bufremove').wipeout(0, true)]])
  no_errors()
  ui.open_tree_row(child, 'a.txt', 'o', 'open_row')
  expect_pair('a.txt')
  child.cmd('Diffy close')
end

T['a definition opened in a split closes back to the pair'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  for _, split in ipairs({ 'split', 'vsplit' }) do
    lsp_jump(repo.dir .. '/outside.txt', 3, split)
    no_errors()
    local w = ui.wins(child)
    eq(wo(w.right, 'diff'), true)
    local cur = child.api.nvim_get_current_win()
    eq({ wo(cur, 'diff'), wo(cur, 'scrollbind'), wo(cur, 'cursorbind') }, { false, false, false })
    child.cmd('q')
    expect_pair('a.txt')
    lsp_jump(repo.dir .. '/b.txt', 3, split)
    no_errors()
    child.cmd('q')
    expect_pair('a.txt')
  end
  child.cmd('Diffy close')
end

T[':edit of a file in another repo or of a panel buffer from the right window'] = function()
  open()
  local other = vim.fn.tempname()
  vim.fn.writefile({ 'x' }, other)
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(other, 1)
  expect_outside(other)
  -- on from the outside state (left shows the placeholder): out, then in
  lsp_jump(repo.dir .. '/outside.txt', 2)
  expect_outside(repo.dir .. '/outside.txt')
  lsp_jump(repo.dir .. '/b.txt', 2)
  expect_pair('b.txt')
  keys('<C-t>')
  expect_outside(repo.dir .. '/outside.txt')
  keys('<C-t>')
  expect_outside(other)
  keys('<C-t>')
  expect_pair('a.txt')
  local tree_name = child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(ui.wins(child).tree))
  child.cmd('buffer ' .. child.api.nvim_win_get_buf(ui.wins(child).tree))
  no_errors()
  keys('<C-o>')
  expect_pair('a.txt')
  eq(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(ui.wins(child).tree)), tree_name)
  child.cmd('Diffy close')
  vim.fn.delete(other)
end

T['refreshing while outside the diff, then <C-t>, restores the pair'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(repo.dir .. '/outside.txt', 3)
  child.api.nvim_set_current_win(ui.wins(child).tree)
  ui.arm_ready(child, 'render')
  keys('R')
  ui.wait_ready(child)
  no_errors()
  child.api.nvim_set_current_win(ui.wins(child).right)
  keys('<C-t>')
  expect_pair('a.txt')
  child.cmd('Diffy close')
end

T['toggling the panel while outside the diff, then <C-t>, restores the pair'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(repo.dir .. '/outside.txt', 3)
  child.api.nvim_set_current_win(ui.wins(child).tree)
  keys('\\e')
  no_errors()
  eq(#child.api.nvim_tabpage_list_wins(0), base_wins - 2)
  child.api.nvim_set_current_win(ui.wins(child).left)
  keys('\\e')
  no_errors()
  child.api.nvim_set_current_win(ui.wins(child).right)
  keys('<C-t>')
  expect_pair('a.txt')
  child.cmd('Diffy close')
end

T['a definition in a renamed file swaps to the rename pair'] = function()
  open()
  ui.select_log_row(child, 'rename')
  expect_pair('new.txt', 'old.txt')
  child.api.nvim_set_current_win(ui.wins(child).right)
  lsp_jump(repo.dir .. '/outside.txt', 3)
  expect_outside(repo.dir .. '/outside.txt')
  keys('<C-t>')
  expect_pair('new.txt', 'old.txt')
  child.cmd('Diffy close')
end

T['gf from the tree opens the real file in the previous tab and leaves the pair'] = function()
  open()
  local tab = child.api.nvim_get_current_tabpage()
  ui.open_tree_row(child, 'b.txt', 'o', 'open_row')
  keys('gf')
  no_errors()
  eq(child.api.nvim_buf_get_name(0), repo.dir .. '/b.txt')
  child.api.nvim_set_current_tabpage(tab)
  expect_pair('b.txt')
  child.cmd('Diffy close')
  child.cmd('buffer 1')
  child.cmd('bwipeout! ' .. path('b.txt'))
end

T['repeated jumps out and back keep the pair intact every time'] = function()
  open()
  child.api.nvim_set_current_win(ui.wins(child).right)
  for _ = 1, 5 do
    lsp_jump(repo.dir .. '/outside.txt', 3)
    expect_outside(repo.dir .. '/outside.txt')
    keys('<C-t>')
    expect_pair('a.txt')
    lsp_jump(repo.dir .. '/b.txt', 3)
    expect_pair('b.txt')
    keys('<C-t>')
    expect_pair('a.txt')
    lsp_jump(repo.dir .. '/outside.txt', 3)
    keys('<C-o>')
    expect_pair('a.txt')
    forward()
    expect_outside(repo.dir .. '/outside.txt')
    keys('<C-o>')
    expect_pair('a.txt')
  end
  child.cmd('Diffy close')
end

T['a diff plugin tracking the pair on BufWinEnter/OptionSet follows every jump and never meets a gone buffer'] = function()
  open()
  -- what diffchar.vim does: remember the diff windows' buffers on OptionSet
  -- diff, touch them on every BufWinEnter (E5555 once one is wiped)
  child.lua([[
    local seen = {}
    local function record()
      seen = {}
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[w].diff then table.insert(seen, vim.api.nvim_win_get_buf(w)) end
      end
      _G.nav_seen = seen
    end
    record()
    vim.api.nvim_create_autocmd('OptionSet', { pattern = 'diff', callback = record })
    vim.api.nvim_create_autocmd('BufWinEnter', {
      callback = function()
        for _, b in ipairs(seen) do
          vim.api.nvim_buf_get_name(b)
        end
        record()
      end,
    })
  ]])
  local function tracks_pair()
    local w = ui.wins(child)
    local shown = { child.api.nvim_win_get_buf(w.left), child.api.nvim_win_get_buf(w.right) }
    local seen = child.lua_get('_G.nav_seen')
    table.sort(shown)
    table.sort(seen)
    eq(seen, shown)
  end
  for _, side in ipairs({ 'left', 'right', 'left' }) do
    child.api.nvim_set_current_win(ui.wins(child)[side])
    lsp_jump(repo.dir .. '/outside.txt', 3)
    expect_outside(repo.dir .. '/outside.txt')
    keys('<C-t>')
    expect_pair('a.txt')
    tracks_pair()
    child.api.nvim_set_current_win(ui.wins(child)[side])
    lsp_jump(repo.dir .. '/b.txt', 3)
    expect_pair('b.txt')
    tracks_pair()
    keys('<C-t>')
    expect_pair('a.txt')
    tracks_pair()
  end
  child.cmd('Diffy close')
end

return T
