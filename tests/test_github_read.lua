-- The GitHub backend's read side through `:Diffy pr`: placement tracked across
-- commits, fold opening around a thread, and the readiness refusal.
--
-- Fixture repo: a `git bundle` of the sandbox PR #2's `base/placement` and
-- `sandbox/placement` branches (`tests/fixtures/github/placement.bundle`), so
-- shas match the recorded GraphQL fixture (`tests/fixtures/github/pr2.json`)
-- and line tracking runs real `git diff` offline.
-- `make test-gh`: only the refusal cases run live (fresh PR per case).
local leak = require('tests.helpers.leak')
local live = require('tests.helpers.github_live')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local dir

local BUNDLE = vim.fn.getcwd() .. '/tests/fixtures/github/placement.bundle'
local PR2_FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/github/pr2.json'
local HEAD_SHA = '865a58547f2547547f78345248fca0a6d03ebaf6' -- P7, sandbox/placement's tip
local BASE = 'base/placement'

local git = ui.git

local function clone_placement()
  return live.clone_sandbox(BUNDLE, 'placement')
end

--- Swap `review/github.lua`'s transport for the fake,
--- loaded with the real PR #2 read fixture and a `find_pr` entry matching
--- `sandbox/placement`.
local function install_fake(c)
  c.lua(([[
    local fake = require('tests.helpers.fake_github')
    local state = fake.load_fixture(%q, 2)
    state.find_pr = { ['sandbox/placement'] = { number = 2, baseRefName = %q, headRefOid = %q } }
    _G.__fake_state = state
    require('diffy.review.github').transport = fake.new(state).transport
  ]]):format(PR2_FIXTURE, BASE, HEAD_SHA))
end

--- Adds a published thread on head `line` of f.txt to the fake PR #2
--- (before `:Diffy pr` reads it).
local function serve_thread_at(line)
  child.lua(([[
    local pr = _G.__fake_state.reads[2].repository.pullRequest
    local head = %q
    table.insert(pr.reviewThreads.nodes, {
      id = 'PRRT_far', isResolved = false, path = 'f.txt', diffSide = 'RIGHT',
      line = %d, originalLine = %d,
      comments = { nodes = { {
        id = 'PRRC_far', author = { login = 'x' }, body = 'far from any change',
        createdAt = '2026-09-27T07:00:00Z', line = %d, originalLine = %d,
        commit = { oid = head }, originalCommit = { oid = head },
      } } },
    })
  ]]):format(HEAD_SHA, line, line, line, line))
end

--- Adds a published thread written on `commit` (a short sha), line `line`
--- of f.txt, that GitHub reports outdated (no current line), to the fake
--- PR #2.
local function serve_outdated(id, commit, line)
  child.lua(([[
    local pr = _G.__fake_state.reads[2].repository.pullRequest
    local oid = %q
    table.insert(pr.reviewThreads.nodes, {
      id = 'PRRT_' .. %q, isResolved = false, path = 'f.txt', diffSide = 'RIGHT',
      originalLine = %d,
      comments = { nodes = { {
        id = 'PRRC_' .. %q, author = { login = 'x' }, body = %q .. ' outdated here',
        createdAt = '2026-09-27T07:00:00Z', originalLine = %d,
        commit = { oid = oid }, originalCommit = { oid = oid },
      } } },
    })
  ]]):format(git(dir, { 'rev-parse', commit }), id, line, id, id, line))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      dir = clone_placement()
      child.fn.chdir(dir)
      if live.enabled then
        live.open_pr(dir, git(dir, { 'rev-parse', BASE }), HEAD_SHA)
      else
        install_fake(child)
      end
    end,
    post_case = function()
      if live.enabled then
        live.close()
      end
      leak.check(child, snapshot)
      if dir then
        vim.fn.delete(dir, 'rf')
      end
    end,
  },
})

local view = live.bind(child)
local wins, open_pr, open_file, select_commit, lines_with_signs =
  view.wins, view.open_pr, view.open_file, view.select_commit, view.lines_with_signs

T['placement tracks a thread across commits (shown at head/its own view) and hides+outdates one whose line later changed'] = function()
  -- Live: PR #2's between-pushes state can't be recreated; recorded fixtures cover it.
  if live.enabled then
    MiniTest.skip('placement: recorded-fixture only')
  end
  open_pr()
  open_file('f.txt')

  -- P1 (entries index 7, oldest of the 7 PR commits): both B1 (R10) and
  -- B2 (R11) were written here, at their own line
  select_commit(7)
  local at_p1 = lines_with_signs('right')
  MiniTest.expect.equality(at_p1[10], true)
  MiniTest.expect.equality(at_p1[11], true)

  -- P2 (index 6): P2 re-edited line 11, so B1 (unaffected line 10) is
  -- still tracked and visible; B2 is hidden (both range endpoints
  -- must be mappable, in either direction - B2's single line isn't)
  select_commit(6)
  local at_p2 = lines_with_signs('right')
  MiniTest.expect.equality(at_p2[10], true)
  MiniTest.expect.equality(at_p2[11], nil)

  -- head (default "all" selection): B1 tracked through P6's +3 top insert
  -- to R13; B2 stays hidden (it can't be tracked to HEAD either - outdated)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(wins().log, 'call cursor(1, 1)')
  child.type_keys('a') -- select-all, the default full-PR view
  ui.wait_ready(child)
  local at_head = lines_with_signs('right')
  MiniTest.expect.equality(at_head[13], true)
  MiniTest.expect.equality(at_head[11], nil)
  MiniTest.expect.equality(at_head[10], nil)

  -- `:Diffy threads`: B2 (resolved) is under "Resolved, outdated"; its
  -- preview lists only its own P1 view, never `head`
  child.o.columns = 200
  local b2_group
  for _, g in ipairs(ui.all_threads(child, 'Diffy threads')) do
    for _, row in ipairs(g.rows) do
      if row:find(' B2 ', 1, true) then
        b2_group = g.group
      end
    end
  end
  MiniTest.expect.equality(b2_group, 'Resolved, outdated')
  for i, l in ipairs(ui.threads_view(child).rows) do
    if l:find(' B2 ', 1, true) then
      child.type_keys(i .. 'G')
    end
  end
  MiniTest.expect.equality(ui.threads_view(child).preview[1], 'Shown in: 786410a')

  -- <CR> on it from head selects P1, the commit it shows in, and enters it
  ui.arm_ready_raw(child, 'thread')
  child.type_keys('<CR>')
  ui.wait_ready_raw(child)
  MiniTest.expect.equality(ui.threads_view(child), vim.NIL)
  local selected = ui.rows_with(child, 'log', 'DiffySelection')
  MiniTest.expect.equality(#selected, 1)
  MiniTest.expect.equality(selected[1]:find('786410a', 1, true) ~= nil, true)
  local float = ui.thread_float(child)
  MiniTest.expect.equality(float.focused, true)
  MiniTest.expect.equality(table.concat(float.text, '\n'):find('B2', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['a thread placed on a line unchanged in the viewed commit opens the fold around it'] = function()
  if live.enabled then
    MiniTest.skip('placement: recorded-fixture only')
  end
  -- f.txt's head changes cluster around 10-18/50-53/70/90; line 30 sits in
  -- a closed fold between them, far from PR #2's recorded threads
  serve_thread_at(30)
  open_pr()
  open_file('f.txt')

  local closed = child.lua_get(([[
    vim.api.nvim_win_call(%d, function() return vim.fn.foldclosed(30) end)
  ]]):format(wins().right))
  MiniTest.expect.equality(closed, -1)

  child.cmd('Diffy close')
end

T['gP shows an HTML bot comment as readable text: headings, badges, folded details, links behind gx and ctrl-click'] = function()
  if live.enabled then
    MiniTest.skip('body rendering: recorded-fixture only')
  end
  child.lua([[
    local pr = _G.__fake_state.reads[2].repository.pullRequest
    pr.body = table.concat({
      '<!-- greptile_summary -->',
      '<h2><a href="https://example.com/retrigger"><picture><source srcset="https://example.com/r.svg"><img alt="Retrigger" src="https://example.com/r.svg" align="right"></picture></a>Confidence Score: 4/5</h2>',
      '',
      '1. <img alt="P2" src="https://example.com/p2.svg" align="top">&nbsp;**Repeated debug\\-info work** <a href="https://example.com/discussion">▶</a>',
      '',
      '<details><summary>Fix with agent prompt</summary>',
      '',
      '`````markdown',
      'Fix it: https://example.com/long?prompt=abc',
      '`````',
      '',
      '</details>',
    }, '\n')
    _G.__opened = {}
    vim.ui.open = function(url) table.insert(_G.__opened, url) end
  ]])
  open_pr()
  open_file('f.txt')
  child.api.nvim_set_current_win(wins().right)
  child.type_keys('gP')

  -- the rows on screen: a closed fold shows its fold text
  local rows = child.lua_get([[(function()
    local out, l, last = {}, 1, vim.api.nvim_buf_line_count(0)
    while l <= last do
      local closed = vim.fn.foldclosedend(l)
      if closed ~= -1 then
        table.insert(out, vim.fn.foldtextresult(l))
        l = closed + 1
      else
        table.insert(out, vim.fn.getline(l))
        l = l + 1
      end
    end
    return out
  end)()]])
  MiniTest.expect.equality(vim.list_slice(rows, 2, 6), {
    ' ## Confidence Score: 4/5  [Retrigger]',
    ' ',
    ' 1. [P2] **Repeated debug-info work** ▶',
    ' ',
    ' ▸ Fix with agent prompt',
  })
  MiniTest.expect.equality(#rows, 6)
  MiniTest.expect.equality(table.concat(rows, '\n'):find('http', 1, true), nil)

  child.api.nvim_win_set_cursor(0, { 4, 0 })
  child.type_keys('gx')
  MiniTest.expect.equality(child.lua_get('_G.__opened'), { 'https://example.com/discussion' })

  -- ctrl-click on the ▶ link opens it; on a fold title, opens the fold
  local function ctrl_click(lnum, col)
    child.lua(
      [[
      local lnum, col = ...
      local p = vim.fn.screenpos(0, lnum, col)
      vim.api.nvim_input_mouse('left', 'press', 'C', 0, p.row - 1, p.col - 1)
    ]],
      { lnum, col }
    )
    vim.wait(50)
  end
  local line4 = child.fn.getline(4)
  ctrl_click(4, line4:find('▶', 1, true))
  MiniTest.expect.equality(child.lua_get('_G.__opened'), { 'https://example.com/discussion', 'https://example.com/discussion' })
  ctrl_click(6, 3)
  MiniTest.expect.equality(child.fn.foldclosed(6), -1)

  child.type_keys('q')
  child.cmd('Diffy close')
end

T['<CR> in the threads view opens an outdated thread where it was written: its commit, or everything up to it'] = function()
  if live.enabled then
    MiniTest.skip('placement: recorded-fixture only')
  end
  -- both on f.txt line 70, which P5 changes: outdated, still shown in the
  -- views of P2 to P3
  serve_outdated('OUT2', '6980f1a', 70) -- P2 changes f.txt: written in P2's own view
  serve_outdated('OUT3', '6ec44a6', 70) -- P3 doesn't: written from the full view at P3
  child.o.columns = 200
  open_pr()
  local function go(id)
    child.cmd('Diffy threads')
    for i, l in ipairs(ui.threads_view(child).rows) do
      if l:find(id .. ' outdated here', 1, true) then
        child.api.nvim_win_set_cursor(wins().threads, { i, 0 })
      end
    end
    ui.arm_ready_raw(child, 'thread')
    child.type_keys('<CR>')
    ui.wait_ready_raw(child)
    local float = ui.thread_float(child)
    MiniTest.expect.equality(float.focused, true)
    MiniTest.expect.equality(table.concat(float.text, '\n'):find(id, 1, true) ~= nil, true)
    -- commit ids, the first word of each subject (the log cuts them)
    return vim.tbl_map(function(s)
      return s:match('^%S+')
    end, ui.log_subjects(child, ui.rows_with(child, 'log', 'DiffySelection')))
  end
  MiniTest.expect.equality(go('OUT2'), { 'P2' })
  MiniTest.expect.equality(go('OUT3'), { 'P3', 'P2', 'P1' })

  child.cmd('Diffy close')
end

local function expect_refused()
  vim.wait(live.timeout, function()
    return #ui.warnings(child) > 0
  end, 10)
  MiniTest.expect.equality(#ui.warnings(child) > 0, true)
  MiniTest.expect.equality(child.fn.tabpagenr('$'), 1)
  MiniTest.expect.equality(ui.diffy_buffers(child), {})
end

T[':Diffy pr refuses to open when local HEAD differs from the PR head on GitHub'] = function()
  git(dir, { 'commit', '--amend', '-q', '--allow-empty', '-m', 'local-only amend' })
  ui.capture_warnings(child)
  child.cmd('Diffy pr')
  expect_refused()
end

T[':Diffy pr refuses to open when the tree is dirty'] = function()
  vim.fn.writefile({ 'dirty' }, dir .. '/f.txt')
  ui.capture_warnings(child)
  child.cmd('Diffy pr')
  expect_refused()
end

return T
