-- The branch's one store of comments: migration from the old files, and
-- several sessions on the same branch, in one nvim and across nvims.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local other = MiniTest.new_child_neovim()
local snapshot
local repo

local function start(c)
  c.restart({ '-u', 'tests/minimal_init.lua' })
  -- pinned: the local backend's author comes from `git config user.name`
  c.lua([[vim.env.GIT_CONFIG_GLOBAL = '/dev/null'; vim.env.GIT_CONFIG_NOSYSTEM = '1']])
  c.fn.chdir(repo.dir)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo = Repo.new()
      repo:commit('base', { ['f.txt'] = Repo.lines(30) })
      vim.fn.writefile(Repo.edit(3, 'uncommitted')(vim.fn.readfile(repo.dir .. '/f.txt')), repo.dir .. '/f.txt')
      start(child)
      snapshot = leak.snapshot(child)
    end,
    post_case = function()
      leak.check(child, snapshot)
      if other.is_running() then
        leak.check(other)
        other.stop()
      end
      if repo then
        repo:destroy()
      end
    end,
  },
})

local function dir_file(name)
  return repo.dir .. '/.git/diffy/main/' .. name
end

local function open_default(c)
  ui.arm_ready(c, 'render')
  c.cmd('Diffy')
  ui.wait_ready(c)
end

--- `gc` on line `lnum` of `c`'s right window, type `body`, `<C-s>`.
local function write_comment(c, lnum, body)
  local right = ui.wins(c).right
  c.api.nvim_set_current_win(right)
  c.fn.win_execute(right, ('call cursor(%d, 1)'):format(lnum))
  ui.arm_ready_raw(c, 'compose')
  c.type_keys('gc')
  ui.wait_ready_raw(c)
  c.type_keys(body, '<Esc>')
  ui.arm_ready_raw(c, 'review')
  c.type_keys('<C-s>')
  ui.wait_ready_raw(c)
end

local function lines_shown(c)
  return vim.tbl_map(function(v)
    return v.line
  end, ui.threads_visible(c, 'right'))
end

--- Wait until `c` shows threads on exactly `want` in its right window.
local function expect_shown(c, want)
  vim.wait(5000, function()
    return vim.deep_equal(lines_shown(c), want)
  end, 20)
  MiniTest.expect.equality(lines_shown(c), want)
end

T['old local.json and pr-<n>.json drafts move into threads.json, review.md ticks still resolving theirs'] = function()
  local head = ui.git(repo.dir, { 'rev-parse', 'HEAD' })
  vim.fn.mkdir(dir_file(''), 'p')
  local function write(name, data)
    vim.fn.writefile({ vim.json.encode(data) }, dir_file(name))
  end
  -- the same ids in both: local.json's are the ones review.md names
  write('local.json', {
    threads = {
      {
        id = 't1',
        backend = 'local',
        resolved = false,
        anchor = { path = 'f.txt', side = 'new', commit = head, start_line = 5, end_line = 5, excerpt = { '5' } },
        comments = { { id = 'c1', author = 'me', body = 'sent to the agent', created_at = 1700000000, state = 'sent' } },
      },
    },
  })
  write('pr-7.json', {
    threads = {
      {
        id = 't1',
        backend = 'github',
        resolved = false,
        anchor = { path = 'f.txt', side = 'new', commit = head, start_line = 10, end_line = 10 },
        comments = { { id = 'c1', author = 'me', body = 'a PR draft', created_at = 1700000000, state = 'draft' } },
      },
    },
  })
  vim.fn.writefile({ '# Review of main', '', '## c1 — f.txt:5', '- [x] resolved', '', 'sent to the agent' }, dir_file('review.md'))

  open_default(child)
  expect_shown(child, { 5, 10 })
  local groups = {}
  for _, g in ipairs(ui.all_threads(child, 'Diffy threads')) do
    groups[g.group] = vim.tbl_map(function(row)
      return row:match('f%.txt:%d+')
    end, g.rows)
  end
  child.type_keys('q')
  MiniTest.expect.equality(groups, { Open = { 'f.txt:10' }, Resolved = { 'f.txt:5' } })
  MiniTest.expect.equality(
    { vim.fn.filereadable(dir_file('local.json')), vim.fn.filereadable(dir_file('pr-7.json')), vim.fn.filereadable(dir_file('threads.json')) },
    { 0, 0, 1 }
  )

  child.cmd('Diffy close')
end

T['a draft written in one tab shows in the other tab on the same branch'] = function()
  open_default(child)
  open_default(child)
  write_comment(child, 5, 'from the second tab')

  child.cmd('tabnext 2')
  expect_shown(child, { 5 })

  -- the other session's tab closes with the leak check
  child.cmd('Diffy close')
end

T["two nvims on the same branch keep each other's drafts, and one's deletion stays deleted"] = function()
  start(other)
  open_default(child)
  open_default(other)

  write_comment(child, 5, 'from the first')
  expect_shown(other, { 5 })
  write_comment(other, 10, 'from the second')
  expect_shown(child, { 5, 10 })

  -- the first deletes its draft; the second, drafting on, doesn't bring it back
  local right = ui.wins(child).right
  child.api.nvim_set_current_win(right)
  child.fn.win_execute(right, 'call cursor(5, 1)')
  child.type_keys('<CR>')
  ui.arm_ready_raw(child, 'review')
  child.type_keys('dd')
  ui.wait_ready_raw(child)
  expect_shown(other, { 10 })
  write_comment(other, 15, 'more from the second')
  expect_shown(child, { 10, 15 })

  local text = table.concat(vim.fn.readfile(dir_file('threads.json')), '\n')
  MiniTest.expect.equality(
    { text:find('from the first', 1, true), text:find('from the second', 1, true) ~= nil, text:find('more from the second', 1, true) ~= nil },
    { nil, true, true }
  )

  child.cmd('Diffy close')
  other.cmd('Diffy close')
end

return T
