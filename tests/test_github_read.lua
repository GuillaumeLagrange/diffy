-- The GitHub layer's read side over `:Diffy branch`: loading, the PR row,
-- review markers, offline cache, detaching, reading cadence, placement
-- tracked across commits, `:Diffy pr`.
--
-- Fixture repo: a `git bundle` of the sandbox PR #2's `base/placement` and
-- `sandbox/placement` branches (`tests/fixtures/github/placement.bundle`), so
-- shas match the recorded GraphQL fixture (`tests/fixtures/github/pr2.json`)
-- and line tracking runs real `git diff` offline.
-- `make test-gh`: only the cases that don't need a hand-built PR state run
-- live (fresh PR per case).
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

--- Swap `review/github.lua`'s transport for the fake, loaded with the real
--- PR #2 read fixture, `sandbox/placement` having PR #2.
local function install_fake(c)
  c.lua(([[
    local fake = require('tests.helpers.fake_github')
    local state = fake.load_fixture(%q, 2)
    state.branches = { ['sandbox/placement'] = 2 }
    _G.__fake_state = state
    fake.install(state)
  ]]):format(PR2_FIXTURE))
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

  -- <CR> on it from head selects P1, the commit it shows in, and hovers it
  ui.arm_ready_raw(child, 'thread')
  child.type_keys('<CR>')
  ui.wait_ready_raw(child)
  MiniTest.expect.equality(ui.threads_view(child), vim.NIL)
  local selected = ui.rows_with(child, 'log', 'DiffySelection')
  MiniTest.expect.equality(#selected, 1)
  MiniTest.expect.equality(selected[1]:find('786410a', 1, true) ~= nil, true)
  local float = ui.thread_float(child)
  MiniTest.expect.equality(float.focused, false)
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
    -- landing on the line hovers OUT2 there before the selection switches
    local function shows()
      local f = ui.thread_float(child)
      return f ~= vim.NIL and table.concat(f.text, '\n'):find(id, 1, true) ~= nil and f
    end
    vim.wait(2000, shows, 10)
    local float = shows()
    MiniTest.expect.equality(float and float.focused, false)
    -- commit ids, the first word of each subject (the log cuts them)
    return vim.tbl_map(function(s)
      return s:match('^%S+')
    end, ui.log_subjects(child, ui.rows_with(child, 'log', 'DiffySelection')))
  end
  MiniTest.expect.equality(go('OUT2'), { 'P2' })
  MiniTest.expect.equality(go('OUT3'), { 'P3', 'P2', 'P1' })

  child.cmd('Diffy close')
end

local function log_rows()
  return ui.layout(child).log
end

--- Log rows drawn as selected, without the selection mark.
local function selected_rows()
  return vim.tbl_map(function(r)
    return vim.trim((r:gsub('^\226\150\140', '')))
  end, ui.rows_with(child, 'log', 'DiffySelection'))
end

local function fake(code)
  child.lua('local fake = require("tests.helpers.fake_github"); local state = _G.__fake_state; ' .. code)
end

local function threads_json()
  local path = dir .. '/.git/diffy/sandbox/placement/threads.json'
  return vim.fn.filereadable(path) == 1 and vim.json.decode(table.concat(vim.fn.readfile(path), '\n')) or {}
end

--- `keys` typed in the log at row `row`, waiting for `event`.
local function log_keys(row, keys, event)
  ui.cursor_to(child, 'log', row)
  ui.arm_ready(child, event)
  child.type_keys(keys)
  ui.wait_ready(child)
end

--- The PR row's float, after resting the cursor on it.
local function pr_float()
  local lnum = ui.lnum(child, 'log', 1)
  child.api.nvim_set_current_win(wins().log)
  ui.arm_ready_raw(child, 'commitmsg')
  child.api.nvim_win_set_cursor(wins().log, { lnum, 0 })
  ui.wait_ready_raw(child)
  return child.lua_get([[(function()
    local s = require('diffy.session').current()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.wins.commitmsg), 0, -1, false)
  end)()]])
end

--- The PR row's status after the (cut) title, sync icon included: '' when
--- in sync and online, nil when there's no PR row.
local function pr_status()
  local r = log_rows()[1]
  if not r:match('^  #2 P') then
    return nil
  end
  local status = r:match(' (· .*)$')
  if status then
    return status
  end
  for _, icon in ipairs({ '↻', '⊘', '⚠' }) do
    if vim.endswith(r, ' ' .. icon) then
      return icon
    end
  end
  return ''
end

local function fixture_only()
  if live.enabled then
    MiniTest.skip('hand-built PR state: recorded-fixture only')
  end
end

T[':Diffy branch renders before gh answers, and the PR row appears once it does'] = function()
  fixture_only()
  child.o.columns = 300
  fake('state.hold = true')
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch')
  ui.wait_ready(child)
  MiniTest.expect.equality(log_rows()[1], '▌ Working tree')

  ui.arm_ready(child, 'pr')
  fake('fake.release(state)')
  ui.wait_ready(child)
  MiniTest.expect.equality(pr_status(), '')
  MiniTest.expect.equality(log_rows()[2], '▌ Working tree')
  child.cmd('Diffy close')
end

T['while a found PR loads, its row shows with a spinner, then the read replaces it'] = function()
  fixture_only()
  child.o.columns = 300
  -- `gh pr view` answers; the PR's read waits
  child.lua([[
    local github = require('diffy.review.github')
    local real = github.transport
    _G.__held_reads = {}
    github.transport = function(...)
      local args = { ... }
      table.insert(_G.__held_reads, function() real(unpack(args)) end)
    end
    _G.__release_reads = function()
      github.transport = real
      for _, f in ipairs(_G.__held_reads) do f() end
    end
  ]])
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch')
  ui.wait_ready(child)
  local function first_row()
    return log_rows()[1]
  end
  local loading = '^  #2 P.* ([\226][\160-\163][\128-\191])$'
  MiniTest.expect.no_equality(vim.wait(3000, function()
    return first_row():match(loading) ~= nil
  end), false)
  MiniTest.expect.equality(log_rows()[2], '▌ Working tree')
  local frame = first_row():match(loading)
  MiniTest.expect.no_equality(vim.wait(3000, function()
    local now = first_row():match(loading)
    return now ~= nil and now ~= frame
  end), false)

  ui.arm_ready(child, 'pr')
  child.lua('_G.__release_reads()')
  ui.wait_ready(child)
  MiniTest.expect.equality(pr_status(), '')
  MiniTest.expect.equality(log_rows()[2], '▌ Working tree')
  child.cmd('Diffy close')
end

T['a PR whose read fails with nothing cached leaves no loading row'] = function()
  fixture_only()
  child.lua([[
    local github = require('diffy.review.github')
    github.transport = function(_, _, cb)
      vim.schedule(function() cb(nil, 'error connecting to api.github.com') end)
    end
  ]])
  open_pr()
  MiniTest.expect.equality(log_rows()[1], '▌ Working tree')
  child.cmd('Diffy close')
end

T['a branch without a PR, or with gh failing and nothing cached, gets no PR row and no warning'] = function()
  fixture_only()
  ui.capture_warnings(child)
  for _, setup in ipairs({ 'state.branches = {}', 'state.offline = true' }) do
    fake(setup)
    open_pr()
    MiniTest.expect.equality(log_rows()[1], '▌ Working tree')
    MiniTest.expect.equality(ui.warnings(child), {})
    child.cmd('Diffy close')
  end
end

T['offline, the layer comes back from the last read: its threads and an offline PR row'] = function()
  fixture_only()
  child.o.columns = 300
  open_pr()
  child.cmd('Diffy close')

  fake('state.offline = true')
  open_pr()
  MiniTest.expect.equality(pr_status(), '⊘')
  open_file('f.txt')
  -- B1, tracked to head line 13
  MiniTest.expect.equality(lines_with_signs('right')[13], true)
  child.cmd('Diffy close')
end

T['a PR merged since the last read detaches: the row, its threads and the cache go, your drafts stay'] = function()
  fixture_only()
  vim.fn.mkdir(dir .. '/.git/diffy/sandbox/placement', 'p')
  vim.fn.writefile({ vim.json.encode({ threads = { {
    id = 'tmine', backend = 'local', resolved = false,
    anchor = { path = 'f.txt', side = 'new', start_line = 2, end_line = 2, commit = HEAD_SHA },
    comments = { { id = 'cmine', author = 'me', body = 'my draft', created_at = 0, state = 'draft' } },
  } } }) }, dir .. '/.git/diffy/sandbox/placement/threads.json')
  open_pr()
  open_file('f.txt')
  local before = lines_with_signs('right')
  MiniTest.expect.equality({ before[2], before[13] }, { true, true })
  MiniTest.expect.equality(threads_json().github ~= nil, true)

  fake('fake.db(state, 2).state = "MERGED"')
  log_keys(2, 'R', 'pr')
  MiniTest.expect.equality(log_rows()[1], '▌ Working tree')
  MiniTest.expect.equality(lines_with_signs('right'), { [2] = true })
  local stored = threads_json()
  MiniTest.expect.equality(stored.github, nil)
  MiniTest.expect.equality(stored.threads[1].comments[1].body, 'my draft')
  child.cmd('Diffy close')
end

T['the log starts on origin/HEAD, then moves once to the PR base, keeping the selected commit'] = function()
  fixture_only()
  -- origin/HEAD at P5: before gh answers, the log only has P6 and P7
  git(dir, { 'update-ref', 'refs/remotes/origin/base/placement', '8259525' })
  fake('state.hold = true')
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch')
  ui.wait_ready(child)
  local first = ui.log_subjects(child)
  MiniTest.expect.equality(first[#first]:match('^%S+'), 'P6')
  log_keys(3, '<CR>', 'select') -- P6
  local function selected_ids()
    return vim.tbl_map(function(s)
      return s:match('^%S+')
    end, ui.log_subjects(child, selected_rows()))
  end
  MiniTest.expect.equality(selected_ids(), { 'P6' })

  ui.arm_ready(child, 'pr')
  fake('fake.release(state)')
  ui.wait_ready(child)
  local after = ui.log_subjects(child)
  MiniTest.expect.equality(after[#after]:match('^%S+'), 'P1')
  MiniTest.expect.equality(selected_ids(), { 'P6' })
  child.cmd('Diffy close')

  -- the next session starts on the cached PR base
  fake('state.hold = true')
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch')
  ui.wait_ready(child)
  local cached = ui.log_subjects(child)
  MiniTest.expect.equality(cached[#cached]:match('^%S+'), 'P1')
  fake('fake.release(state)')
  child.cmd('Diffy close')
end

T['J, K, a and visual ranges never select the PR row or a review marker'] = function()
  fixture_only()
  open_pr()
  log_keys(2, '<CR>', 'select')
  MiniTest.expect.equality(selected_rows(), { 'Working tree' })
  log_keys(2, 'K', 'select')
  MiniTest.expect.equality(selected_rows(), { 'Working tree' })
  -- the marker above P7 sits between the working tree and P7
  log_keys(2, 'J', 'select')
  MiniTest.expect.equality(ui.log_subjects(child, selected_rows()), { 'P7 unrelated: g.txt only' })
  log_keys(4, 'K', 'select')
  MiniTest.expect.equality(selected_rows(), { 'Working tree' })
  log_keys(1, 'a', 'select')
  local all = selected_rows()
  MiniTest.expect.equality(all[1], 'Working tree')
  MiniTest.expect.equality(vim.tbl_contains(all, log_rows()[1]:sub(3)), false)
  log_keys(1, 'Vj<CR>', 'select')
  MiniTest.expect.equality(selected_rows(), { 'Working tree' })
  child.cmd('Diffy close')
end

T[':Diffy shows the PR row with the working tree in sight, and <CR> on it opens the whole PR'] = function()
  fixture_only()
  -- upstream at HEAD: `:Diffy` lists only the working tree
  git(dir, { 'update-ref', 'refs/remotes/origin/sandbox/placement', 'HEAD' })
  git(dir, { 'branch', '-q', '--set-upstream-to', 'origin/sandbox/placement' })
  ui.arm_ready(child, 'pr')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.equality(pr_status(), '')
  MiniTest.expect.equality(log_rows()[2], '▌ Working tree')
  -- both rows in sight
  local log = wins().log
  local function on_screen(row)
    return child.fn.screenpos(log, ui.lnum(child, 'log', row), 1).row > 0
  end
  MiniTest.expect.equality({ on_screen(1), on_screen(2) }, { true, true })

  log_keys(1, '<CR>', 'render')
  MiniTest.expect.equality(pr_status(), '')
  local selected = vim.tbl_map(function(s)
    return s:match('^%S+')
  end, ui.log_subjects(child, selected_rows()))
  MiniTest.expect.equality({ selected[1], selected[2], selected[#selected] }, { 'Working', 'P7', 'P1' })
  child.cmd('Diffy close')
end

T['the PR row says where the branch stands against the PR head'] = function()
  fixture_only()
  child.o.columns = 300
  git(dir, { 'commit', '-q', '--allow-empty', '-m', 'local 1' })
  git(dir, { 'commit', '-q', '--allow-empty', '-m', 'local 2' })
  open_pr()
  MiniTest.expect.equality(pr_status(), '· 2 unpushed')
  child.cmd('Diffy close')

  fake('fake.db(state, 2).head = ("1"):rep(40); state.reads[2].repository.pullRequest.headRefOid = ("1"):rep(40); state._db = nil')
  open_pr()
  MiniTest.expect.equality(pr_status(), '· GitHub has newer commits')
  child.cmd('Diffy close')
end

T['a review shows as a marker above its commit; <CR> on it selects everything above'] = function()
  fixture_only()
  open_pr()
  local rows = log_rows()
  local at
  for i, r in ipairs(rows) do
    if r:find('P1 edit', 1, true) then
      at = i
    end
  end
  MiniTest.expect.equality(vim.trim(rows[at - 1]), '── GuillaumeLagrange ○ 4 threads')
  log_keys(at - 1, '<CR>', 'select')
  local sel = ui.log_subjects(child, selected_rows())
  MiniTest.expect.equality(sel[1], 'Working tree')
  MiniTest.expect.equality(sel[#sel], 'P2 edit f 50, re-edit f 11')
  child.cmd('Diffy close')
end

T['several reviews on one commit share one row summing their states and threads'] = function()
  fixture_only()
  fake(([[local nodes = fake.db(state, 2).reviews
    local oid = %q
    for _, r in ipairs({ { 'PRR_alice', 'alice', 'CHANGES_REQUESTED' }, { 'PRR_bob', 'bob', 'COMMENTED' } }) do
      table.insert(nodes, { id = r[1], author = { login = r[2] }, state = r[3], body = '',
        submittedAt = '2026-09-28T00:00:00Z', commit = { oid = oid } })
    end]]):format(git(dir, { 'rev-parse', ':/^P1 edit' })))
  open_pr()
  local rows = log_rows()
  local at
  for i, r in ipairs(rows) do
    if r:find('P1 edit', 1, true) then
      at = i
    end
  end
  MiniTest.expect.equality(vim.trim(rows[at - 1]), '── 3 reviews ✗○ 4 threads')
  MiniTest.expect.equality(rows[at - 2]:find('──', 1, true), nil)
  log_keys(at - 1, '<CR>', 'select')
  local sel = ui.log_subjects(child, selected_rows())
  MiniTest.expect.equality(sel[#sel], 'P2 edit f 50, re-edit f 11')
  child.cmd('Diffy close')
end

T["the PR row's float lists every review, those on commits the log doesn't list with why"] = function()
  fixture_only()
  child.o.columns = 300
  -- a review on the merge-base: in the branch, not in its log
  fake(([[table.insert(state.reads[2].repository.pullRequest.reviews.nodes, {
    id = 'PRR_base', author = { login = 'alice' }, state = 'CHANGES_REQUESTED', body = '', submittedAt = '2026-09-28T00:00:00Z', commit = { oid = %q } })]]):format(git(dir, { 'merge-base', BASE, HEAD_SHA })))
  open_pr()
  local float = pr_float()
  local function after(title)
    local out, on = {}, false
    for _, l in ipairs(float) do
      if on and l == '' then
        break
      end
      if on then
        table.insert(out, l)
      end
      on = on or l == title
    end
    return out
  end
  MiniTest.expect.equality(after('Reviewers'), { '  GuillaumeLagrange ○ commented', '  alice ✗ changes requested' })
  MiniTest.expect.equality(after('Reviews'), {
    '  GuillaumeLagrange ○ 15a977e  no longer in the branch',
    '  GuillaumeLagrange ○ 786410a',
    '  GuillaumeLagrange ○ 6980f1a',
    '  GuillaumeLagrange ○ 865a585',
    '  alice ✗ ' .. git(dir, { 'merge-base', BASE, HEAD_SHA }):sub(1, 7) .. '  not in this log',
  })
  child.cmd('Diffy close')
end

T['R reads GitHub again, writing a file does not'] = function()
  fixture_only()
  child.o.columns = 300
  open_pr()
  open_file('f.txt')
  fake('fake.db(state, 2).title = "Renamed"')
  child.api.nvim_set_current_win(wins().right)
  ui.arm_ready(child, 'render')
  child.cmd('normal! Gox')
  child.cmd('write')
  ui.wait_ready(child)
  MiniTest.expect.equality(pr_status(), '')
  log_keys(2, 'R', 'pr')
  MiniTest.expect.equality(log_rows()[1], '  #2 Renamed')
  child.cmd('Diffy close')
end

T['a thread with more comments than one page shows all of them'] = function()
  fixture_only()
  child.lua('require("diffy.review.github").page_size = 2')
  fake([[
    local t = state.reads[2].repository.pullRequest.reviewThreads.nodes[1]
    local first = t.comments.nodes[1]
    for i = 2, 5 do
      local c = vim.deepcopy(first)
      c.id, c.body = 'PRRC_more' .. i, 'reply ' .. i
      table.insert(t.comments.nodes, c)
    end
    _G.__first_thread = t.comments.nodes[1].body:match('^%S+')
  ]])
  child.o.columns = 200
  open_pr()
  local id = child.lua_get('_G.__first_thread')
  local found
  for _, g in ipairs(ui.all_threads(child, 'Diffy threads') or {}) do
    for _, row in ipairs(g.rows) do
      if row:find(id, 1, true) then
        found = row
      end
    end
  end
  MiniTest.expect.equality(found ~= nil and found:find('+4', 1, true) ~= nil, true)
  child.cmd('Diffy close')
end

T[':Diffy pr opens :Diffy branch on the PR base, and warns on a branch without an open PR'] = function()
  fixture_only()
  child.o.columns = 300
  ui.arm_ready(child, 'pr')
  child.cmd('Diffy pr')
  ui.wait_ready(child)
  MiniTest.expect.equality(pr_status(), '')
  child.cmd('Diffy close')

  fake('state.branches = {}')
  ui.capture_warnings(child)
  ui.arm_ready(child, 'pr')
  child.cmd('Diffy pr')
  ui.wait_ready(child)
  MiniTest.expect.equality(#ui.warnings(child, 'WARN'), 1)
  MiniTest.expect.equality(child.fn.tabpagenr('$'), 1)
  MiniTest.expect.equality(ui.diffy_buffers(child), {})
end

return T
