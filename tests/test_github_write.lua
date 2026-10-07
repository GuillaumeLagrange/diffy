-- The GitHub layer's write side through the UI: drafts mirrored into your
-- pending review in the background, the sync conflict rules, staged changes,
-- submitting (to the agent or GitHub) and clearing. Repo: a git bundle of the
-- sandbox's `pending` PR (exact shas). `make test-gh`: the real transport
-- against a fresh PR per case; the cases that need GitHub in a state only
-- the fake can be put in (a failing mutation, a thread deleted under a
-- draft) are fake-only.
local leak = require('tests.helpers.leak')
local live = require('tests.helpers.github_live')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local dir

local PENDING_BUNDLE = vim.fn.getcwd() .. '/tests/fixtures/github/pending.bundle'
local PR4_FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/github/pr4.json'
local BASE = 'base/pending'
local MERGE_BASE = '00c9d496d93a587199db453b2f18d7c4e0c994e8' -- == base/pending's own tip
local Q1 = '624697d43fdafc6e982d28e5cc504dc58ffd78f3' -- f.txt L5-7
local Q2 = '555868b2a02f69191ea2a6f02ce7365285b02ce6' -- f.txt L20
local HEAD_SHA = '5a5dae9a718551dcddd9ecd66fb85ef6c43c6b28' -- Q3, sandbox/pending's tip, f.txt L30
local OWNER, NAME = live.REPO:match('(.+)/(.+)')

local eq = MiniTest.expect.equality

local function pr_number()
  return live.enabled and live.current.number or 4
end

--- The recorded PR #4 state in the fake; live, the same shapes created on
--- the fresh PR: D1 (published, head R30), D2 (published, resolved, head
--- R20), and a pending review with E1 on Q1 R5-7 and E3 written through the
--- legacy position API on Q2 R20.
local function setup_pending()
  if not live.enabled then
    child.lua(([[
      local fake = require('tests.helpers.fake_github')
      local state = fake.load_fixture(%q, 4)
      state.repo_dir = %q
      state.merge_base = %q
      state.viewer = 'GuillaumeLagrange'
      state.branches = { ['sandbox/pending'] = 4 }
      _G.__fake_state = state
      fake.install(state)
    ]]):format(PR4_FIXTURE, dir, MERGE_BASE))
    return
  end
  local pr = live.current
  local add_review = [[mutation($pr:ID!,$c:GitObjectID!,$t:[DraftPullRequestReviewThread],$e:PullRequestReviewEvent){
    addPullRequestReview(input:{pullRequestId:$pr,commitOID:$c,threads:$t,event:$e}){pullRequestReview{id}}}]]
  live.graphql(add_review, {
    pr = pr.id,
    c = HEAD_SHA,
    e = 'COMMENT',
    t = {
      { path = 'f.txt', line = 30, side = 'RIGHT', body = 'D1 published thread' },
      { path = 'f.txt', line = 20, side = 'RIGHT', body = 'D2 published thread, resolved' },
    },
  })
  local threads = live.graphql(
    'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:10){nodes{id comments(first:1){nodes{body}}}}}}}',
    { o = OWNER, r = NAME, n = pr.number }
  ).repository.pullRequest.reviewThreads.nodes
  for _, t in ipairs(threads) do
    if t.comments.nodes[1].body:find('^D2') then
      live.graphql('mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{id}}}', { t = t.id })
    end
  end
  local review = live.graphql(add_review, {
    pr = pr.id,
    c = Q1,
    t = { { path = 'f.txt', startLine = 5, line = 7, side = 'RIGHT', startSide = 'RIGHT', body = 'E1 pending on Q1 R5-7' } },
  }).addPullRequestReview.pullRequestReview.id
  live.graphql(
    [[mutation($r:ID!,$c:GitObjectID!,$p:Int!,$b:String!){
      addPullRequestReviewComment(input:{pullRequestReviewId:$r,commitOID:$c,path:"f.txt",position:$p,body:$b}){comment{id}}}]],
    { r = review, c = Q2, p = live.position(dir, MERGE_BASE, Q2, 'f.txt', 20), b = 'E3 pending on Q2 R20 (legacy position)' }
  )
end

--- An empty PR (no threads, no pending review). Live: the fresh PR as is.
local function setup_empty()
  if live.enabled then
    return
  end
  child.lua(([[
    local fake = require('tests.helpers.fake_github')
    local state = {
      repo_dir = %q,
      merge_base = %q,
      reads = { [4] = { repository = { pullRequest = {
        id = 'PR_TEST', number = 4, title = 't', body = '',
        baseRefName = %q, headRefOid = %q, author = { login = 'x' },
        comments = { nodes = {} }, reviews = { nodes = {} },
        pendingReviews = { nodes = {} },
        reviewThreads = { pageInfo = { hasNextPage = false }, nodes = {} },
      } } } },
      branches = { ['sandbox/pending'] = 4 },
    }
    _G.__fake_state = state
    fake.install(state)
  ]]):format(dir, MERGE_BASE, BASE, HEAD_SHA))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      dir = live.clone_sandbox(PENDING_BUNDLE, 'pending')
      if live.enabled then
        live.open_pr(dir, MERGE_BASE, HEAD_SHA)
      end
      child.fn.chdir(dir)
      child.lua('require("diffy.review.github").sync_delay = 100')
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
local wins, open_pr, open_file, select_commit = view.wins, view.open_pr, view.open_file, view.select_commit

local function wait_ready_raw()
  ui.wait_ready_raw(child, live.timeout)
end

local function wait_for(pred, what)
  local ok = vim.wait(live.timeout, pred, live.enabled and 1000 or 20)
  if not ok then
    local err = child.api.nvim_exec_lua('return vim.v.errmsg', {})
    error(('timed out waiting for %s (last error: %s)'):format(what or 'a condition', err))
  end
end

local ALL_COMMENTS = 'id body state line originalLine commit{oid} originalCommit{oid} pullRequestReview{id}'

--- GitHub's side of the PR: `{ pending = review id | nil, threads = { {
--- id, side, resolved, comments = { { id, body, state, line, original_line,
--- commit, original_commit, review } } } }, submitted = { {state, body} } }`.
local function remote()
  local raw
  if live.enabled then
    local query = ('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){pending:reviews(states:[PENDING],first:1){nodes{id}} reviews(last:50){nodes{state body}} reviewThreads(first:50){nodes{id diffSide isResolved comments(first:50){nodes{%s}}}}}}}'):format(ALL_COMMENTS)
    local vars = { o = OWNER, r = NAME, n = pr_number() }
    -- GitHub answers "Something went wrong" now and then: one more try
    local ok, data = pcall(live.graphql, query, vars)
    local pr = (ok and data or live.graphql(query, vars)).repository.pullRequest
    raw = { pending = pr.pending.nodes[1] and pr.pending.nodes[1].id, threads = pr.reviewThreads.nodes, reviews = pr.reviews.nodes }
  else
    raw = child.api.nvim_exec_lua(
      [[
      local db = require('tests.helpers.fake_github').db(_G.__fake_state, 4)
      local p = db.pending[_G.__fake_state.viewer]
      return { pending = p and p.id or vim.NIL, threads = db.threads, reviews = db.reviews }
    ]],
      {}
    )
  end
  local out = { pending = raw.pending ~= vim.NIL and raw.pending or nil, threads = {}, submitted = {} }
  for _, t in ipairs(raw.threads) do
    local th = { id = t.id, side = t.diffSide, resolved = t.isResolved, comments = {} }
    for _, c in ipairs(t.comments.nodes) do
      table.insert(th.comments, {
        id = c.id,
        body = c.body,
        state = c.state,
        line = c.line ~= vim.NIL and c.line or nil,
        original_line = c.originalLine,
        commit = c.commit ~= vim.NIL and c.commit and c.commit.oid or nil,
        original_commit = c.originalCommit ~= vim.NIL and c.originalCommit and c.originalCommit.oid or nil,
        review = c.pullRequestReview ~= vim.NIL and c.pullRequestReview and c.pullRequestReview.id or nil,
      })
    end
    table.insert(out.threads, th)
  end
  for _, r in ipairs(raw.reviews) do
    if r.state ~= 'PENDING' then
      table.insert(out.submitted, { state = r.state, body = r.body })
    end
  end
  return out
end

--- The remote comment whose body starts with `prefix` (and its thread), or nil.
local function remote_comment(prefix, r)
  for _, t in ipairs((r or remote()).threads) do
    for _, c in ipairs(t.comments) do
      if c.body:sub(1, #prefix) == prefix then
        return c, t
      end
    end
  end
  return nil
end

local function web_edit(prefix, body)
  local c = assert(remote_comment(prefix), 'no remote comment ' .. prefix)
  if live.enabled then
    live.graphql('mutation($id:ID!,$b:String!){updatePullRequestReviewComment(input:{pullRequestReviewCommentId:$id,body:$b}){clientMutationId}}', { id = c.id, b = body })
  else
    child.lua(('require("tests.helpers.fake_github").edit_comment(_G.__fake_state, %q, %q)'):format(c.id, body))
  end
end

local function web_delete(prefix)
  local c = assert(remote_comment(prefix), 'no remote comment ' .. prefix)
  if live.enabled then
    live.graphql('mutation($id:ID!){deletePullRequestReviewComment(input:{id:$id}){clientMutationId}}', { id = c.id })
  else
    child.lua(('require("tests.helpers.fake_github").delete_comment(_G.__fake_state, %q)'):format(c.id))
  end
end

local function fake_only()
  if live.enabled then
    MiniTest.skip('needs a GitHub state only the fake can be put in')
  end
end

local function branch_dir()
  return ('%s/.git/diffy/%s'):format(dir, ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' }))
end

--- threads.json as it is on disk (`threads`, `mirror`), `{}` without one.
local function store()
  local path = branch_dir() .. '/threads.json'
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

--- The stored comment whose body starts with `prefix`, and its thread.
local function stored(prefix)
  for _, t in ipairs(store().threads or {}) do
    for _, c in ipairs(t.comments) do
      if (c.body or c.staged_body or ''):sub(1, #prefix) == prefix then
        return c, t
      end
    end
  end
  return nil
end

local function save_composed(body)
  wait_ready_raw()
  child.type_keys(body, '<Esc>')
  ui.arm_ready_raw(child, 'review')
  child.type_keys('<C-s>')
  wait_ready_raw()
end

local function compose_draft(win, lnum, body)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
  ui.arm_ready_raw(child, 'compose')
  child.type_keys('gc')
  save_composed(body)
end

--- Enter the thread at `lnum` of `win` whose text has `needle`: `<CR>` opens the
--- default one, `]t`/`[t` step through the others stacked there.
local function enter_thread_with(win, lnum, needle)
  child.api.nvim_set_current_win(win)
  for _, step in ipairs({ ']t', '[t' }) do
    child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
    child.type_keys('<CR>')
    for _ = 1, 4 do
      local f = ui.thread_float(child)
      if f ~= vim.NIL and table.concat(f.text, '\n'):find(needle, 1, true) then
        return f
      end
      child.type_keys(step)
    end
    child.type_keys('q')
  end
  error('no thread with ' .. needle .. ' at line ' .. lnum)
end

--- In the open thread float: put the cursor on the card whose body has
--- `needle`.
local function to_card(needle)
  for i, l in ipairs(child.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(needle, 1, true) then
      child.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  error('no card with ' .. needle)
end

--- In the open thread float: `e` on the card with `needle`, its text
--- replaced by `body`. Saving leaves the cursor in the diff.
local function edit_card(needle, body)
  to_card(needle)
  ui.arm_ready_raw(child, 'compose')
  child.type_keys('e')
  wait_ready_raw()
  child.type_keys('ggdG', 'i' .. body, '<Esc>')
  ui.arm_ready_raw(child, 'review')
  child.type_keys('<C-s>')
  wait_ready_raw()
end

local function key_in_float(needle, keys)
  to_card(needle)
  ui.arm_ready_raw(child, 'review')
  child.type_keys(keys)
  wait_ready_raw()
end

--- `R`: rebuild and read GitHub again, then wait for `done()`.
local function read_github(done, what)
  child.api.nvim_set_current_win(wins().log)
  ui.arm_ready(child, 'pr')
  child.type_keys('R')
  ui.wait_ready(child, live.timeout)
  if done then
    wait_for(done, what)
  end
end

local function pr_row()
  return ui.layout(child).log[1]
end

--- `:Diffy review github` with `body`, then into the list of what goes out
--- once it's in; returns its lines.
local function submit_to_github(body)
  ui.arm_ready_raw(child, 'recap')
  child.cmd('Diffy review github')
  wait_ready_raw()
  child.type_keys(body, '<Esc>', '<Tab>')
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function submitted(body)
  for _, s in ipairs(remote().submitted) do
    if s.body == body then
      return true
    end
  end
  return false
end

T['a draft is in your pending review moments after you write it; its edit and deletion follow'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 30, 'mirrored draft')

  wait_for(function()
    local c = remote_comment('mirrored draft')
    return c and c.state == 'PENDING'
  end, 'the draft in the pending review')
  local r = remote()
  local c, t = remote_comment('mirrored draft', r)
  eq({ side = t.side, line = c.original_line, commit = c.original_commit, review = c.review }, { side = 'RIGHT', line = 30, commit = HEAD_SHA, review = r.pending })
  eq(stored('mirrored draft').gh.id, c.id)

  enter_thread_with(right, 30, 'mirrored draft')
  eq(ui.thread_float(child).text[1]:find('  pending$') ~= nil, true)
  edit_card('mirrored draft', 'mirrored draft, edited')
  wait_for(function()
    local e = remote_comment('mirrored draft')
    return e and e.body == 'mirrored draft, edited'
  end, 'the edit on GitHub')
  enter_thread_with(right, 30, 'mirrored draft, edited')
  key_in_float('mirrored draft', 'dd')
  -- its last comment gone, GitHub deletes the review itself
  wait_for(function()
    local now = remote()
    return #now.threads == 0 and now.pending == nil and store().mirror == nil
  end, 'the deletion on GitHub, forgotten here')
  child.cmd('Diffy close')
end

T['a draft on an older commit mirrors on that commit, a removed line as a left-side comment'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  -- log entries, newest first: head(Q3)=1, Q2=2, Q1=3
  select_commit(3)
  compose_draft(wins().right, 5, 'on Q1 line 5')
  -- Q2's old side is Q1 (Q1's own is the merge-base: a head comment)
  select_commit(2)
  compose_draft(wins().left, 20, 'on the removed line 20')

  wait_for(function()
    return remote_comment('on Q1 line 5') and remote_comment('on the removed line 20')
  end, 'both drafts on GitHub')
  local new, nt = remote_comment('on Q1 line 5')
  eq({ nt.side, new.original_commit, new.original_line, new.state }, { 'RIGHT', Q1, 5, 'PENDING' })
  local old, ot = remote_comment('on the removed line 20')
  eq({ ot.side, old.original_commit, old.original_line }, { 'LEFT', Q2, 20 })
  child.cmd('Diffy close')
end

T['a draft an nvim closed on before mirroring goes with the next sync'] = function()
  setup_empty()
  child.lua('require("diffy.review.github").sync_delay = 60000')
  open_pr()
  open_file('f.txt')
  compose_draft(wins().right, 30, 'left behind')
  child.cmd('Diffy close')
  eq(remote_comment('left behind'), nil)

  open_pr()
  wait_for(function()
    return remote_comment('left behind') ~= nil
  end, 'the leftover mirrored')
  child.cmd('Diffy close')
end

T['two copies of one draft, mirrored by two nvims at once, are merged on read'] = function()
  fake_only()
  setup_empty()
  open_pr()
  open_file('f.txt')
  compose_draft(wins().right, 30, 'mirrored twice')
  wait_for(function()
    return remote_comment('mirrored twice') ~= nil
  end, 'the draft mirrored')
  -- the other nvim's copy: same place, same body
  child.lua([[
    local db = require('tests.helpers.fake_github').db(_G.__fake_state, 4)
    local copy = vim.deepcopy(db.threads[1])
    copy.id = 'OTHER_THREAD'
    copy.comments.nodes[1].id = 'OTHER_COMMENT'
    table.insert(db.threads, copy)
  ]])
  read_github(function()
    return #remote().threads == 1
  end, 'one copy left')
  eq(remote_comment('mirrored twice') ~= nil, true)
  local n = 0
  for _, t in ipairs(store().threads or {}) do
    n = n + #t.comments
  end
  eq(n, 1)
  child.cmd('Diffy close')
end

T['a sync answer arriving after the session closed is kept, and leaves nothing watched'] = function()
  fake_only()
  setup_empty()
  open_pr()
  open_file('f.txt')
  child.lua('_G.__fake_state.hold_answers = true')
  compose_draft(wins().right, 30, 'late answer')
  wait_for(function()
    return remote().pending ~= nil
  end, 'the review created, its answer held')
  child.cmd('Diffy close')
  child.lua('require("tests.helpers.fake_github").release_answers(_G.__fake_state)')
  wait_for(function()
    local c = stored('late answer')
    return c and c.gh ~= nil
  end, 'the late answer recorded')
  eq(stored('late answer').gh.id, remote_comment('late answer').id)
end

T['a sync the session closed during finishes, and the next session mirrors again'] = function()
  fake_only()
  setup_empty()
  child.lua('require("diffy.review.github").sync_delay = 60000')
  open_pr()
  open_file('f.txt')
  compose_draft(wins().right, 30, 'first of two')
  child.lua('require("diffy.review.github").sync_delay = 100; _G.__fake_state.hold_answers = true')
  select_commit(3)
  compose_draft(wins().right, 5, 'second of two')
  wait_for(function()
    return remote().pending ~= nil
  end, 'the review created, its answer held')
  child.cmd('Diffy close')
  child.lua('require("tests.helpers.fake_github").release_answers(_G.__fake_state)')

  open_pr()
  wait_for(function()
    return remote_comment('first of two') ~= nil and remote_comment('second of two') ~= nil
  end, 'both drafts mirrored')
  child.cmd('Diffy close')
end

--- The sync icon ending the PR row, or nil.
local function row_icon()
  for _, icon in ipairs({ '↻', '⊘', '⚠' }) do
    if vim.endswith(pr_row(), ' ' .. icon) then
      return icon
    end
  end
end

T['the PR row shows ↻ while a draft waits, ⚠ when GitHub refuses it, nothing once mirrored'] = function()
  fake_only()
  setup_empty()
  child.lua('require("diffy.review.github").sync_delay = 60000')
  child.lua([[_G.__fake_state.fail = { addPullRequestReview = 'boom' }]])
  open_pr()
  open_file('f.txt')
  eq(row_icon(), nil)

  compose_draft(wins().right, 30, 'row state')
  eq(row_icon(), '↻')

  read_github(function()
    return row_icon() == '⚠'
  end, '⚠ on the row')
  eq(remote_comment('row state'), nil)

  child.lua('_G.__fake_state.fail = nil')
  read_github(function()
    return remote_comment('row state') ~= nil and row_icon() == nil
  end, 'mirrored, the row quiet again')
  child.cmd('Diffy close')
end

T['creating the pending review while another nvim just made one adopts that one'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  -- the other nvim's review, created after this one's read
  local other
  if live.enabled then
    other = live.graphql('mutation($pr:ID!,$c:GitObjectID!){addPullRequestReview(input:{pullRequestId:$pr,commitOID:$c}){pullRequestReview{id}}}', { pr = live.current.id, c = HEAD_SHA })
      .addPullRequestReview.pullRequestReview.id
  else
    other = child.lua([[
      local db = require('tests.helpers.fake_github').db(_G.__fake_state, 4)
      db.pending[_G.__fake_state.viewer] = { id = 'OTHER_NVIM_REVIEW', commitOID = db.head }
      return 'OTHER_NVIM_REVIEW'
    ]])
  end
  compose_draft(wins().right, 30, 'into the adopted review')

  wait_for(function()
    return remote_comment('into the adopted review') ~= nil
  end, 'the draft on GitHub')
  local r = remote()
  eq({ r.pending, remote_comment('into the adopted review', r).review }, { other, other })
  child.cmd('Diffy close')
end

T['deleting the last mirrored draft deletes the pending review; the next draft makes a fresh one'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 30, 'first draft')
  wait_for(function()
    return remote().pending ~= nil and remote_comment('first draft') ~= nil
  end, 'the first review')
  local first = remote().pending

  enter_thread_with(right, 30, 'first draft')
  key_in_float('first draft', 'dd')
  wait_for(function()
    return remote().pending == nil
  end, 'the review deleted with its last comment')

  compose_draft(right, 28, 'second draft')
  wait_for(function()
    return remote_comment('second draft') ~= nil
  end, 'the second draft on GitHub')
  local r = remote()
  eq(r.pending ~= nil and r.pending ~= first, true)
  eq(remote_comment('second draft', r).review, r.pending)
  child.cmd('Diffy close')
end

T['a reply drafted on a new thread follows it into the same GitHub thread'] = function()
  setup_empty()
  child.lua('require("diffy.review.github").sync_delay = 60000')
  open_pr()
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 20, 'nit')
  enter_thread_with(right, 20, 'nit')
  ui.arm_ready_raw(child, 'compose')
  child.type_keys('r')
  save_composed('follow-up')

  compose_draft(right, 30, 'nit')
  -- a read syncs too
  read_github(function()
    local c, t = remote_comment('follow-up')
    return c and #t.comments == 2
  end, 'the reply in its thread')
  local r = remote()
  local _, t = remote_comment('follow-up', r)
  eq({ t.comments[1].body, t.comments[1].original_line }, { 'nit', 20 })
  child.cmd('Diffy close')
end

T['a pending comment changed on both sides keeps both versions until dd drops one'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 30, 'mine v1')
  wait_for(function()
    return remote_comment('mine v1') ~= nil
  end, 'the draft on GitHub')

  web_edit('mine v1', 'web v2')
  enter_thread_with(right, 30, 'mine v1')
  edit_card('mine v1', 'mine v2')
  wait_for(function()
    local c = stored('mine v2')
    return c and c.conflict
  end, 'the conflict')
  -- nothing was overwritten
  eq(remote_comment('web v2') ~= nil, true)
  eq(pr_row():find('1 conflict', 1, true) ~= nil, true)
  local text = enter_thread_with(right, 30, 'mine v2').text
  local function header_of(body)
    for i, l in ipairs(text) do
      if l:find(body, 1, true) then
        return text[i - 1]
      end
    end
  end
  eq(header_of('mine v2'):find('conflict', 1, true) ~= nil, true)
  eq(header_of('web v2'):find('github%.com$') ~= nil, true)

  -- dropping the github.com version: yours goes to GitHub, the conflict ends
  key_in_float('web v2', 'dd')
  wait_for(function()
    local c = remote_comment('mine v2')
    return c ~= nil
  end, 'your version on GitHub')
  eq(stored('mine v2').conflict, nil)
  eq(stored('web v2'), nil)
  eq(pr_row():find('conflict', 1, true), nil)
  child.cmd('Diffy close')
end

T['an edit beats a delete, whichever side made which'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 30, 'deleted here')
  compose_draft(right, 28, 'deleted there')
  wait_for(function()
    return remote_comment('deleted here') and remote_comment('deleted there')
  end, 'both drafts on GitHub')

  -- edited on github.com, deleted here: it comes back with the web text
  web_edit('deleted here', 'deleted here, but edited on the web')
  enter_thread_with(right, 30, 'deleted here')
  key_in_float('deleted here', 'dd')
  -- edited here, deleted on github.com: mirrored again
  web_delete('deleted there')
  enter_thread_with(right, 28, 'deleted there')
  edit_card('deleted there', 'deleted there, but edited here')

  read_github(function()
    return stored('deleted here, but edited on the web') ~= nil and remote_comment('deleted there, but edited here') ~= nil
  end, 'both edits kept')
  eq(remote_comment('deleted here, but edited on the web') ~= nil, true)
  child.cmd('Diffy close')
end

T['x stages a resolve, x again cancels it; nothing reaches GitHub before a submit'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  enter_thread_with(right, 30, 'D1')
  ui.arm_ready_raw(child, 'review')
  child.type_keys('x')
  wait_ready_raw()
  local f = ui.thread_float(child)
  eq(f.text[1]:find('resolve staged', 1, true) ~= nil, true)
  local _, d1 = remote_comment('D1')
  eq(d1.resolved, false)

  ui.arm_ready_raw(child, 'review')
  child.type_keys('x')
  wait_ready_raw()
  eq(ui.thread_float(child).text[1]:find('staged', 1, true), nil)
  child.type_keys('q')
  for _, t in ipairs(store().threads or {}) do
    eq(t.resolve_staged, nil)
  end
  eq(select(2, remote_comment('D1')).resolved, false)
  child.cmd('Diffy close')
end

T['a staged edit next to an edit made on github.com: dd drops yours, dd on the live one stages its deletion'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  enter_thread_with(right, 30, 'D1')
  edit_card('D1', 'D1 my staged edit')
  eq(enter_thread_with(right, 30, 'D1 my staged edit').text[1]:find('edit staged', 1, true) ~= nil, true)
  child.type_keys('q')
  -- staged only
  eq(remote_comment('D1').body:find('^D1 published') ~= nil, true)

  web_edit('D1', 'D1 edited on the web')
  read_github(function()
    local c = stored('D1 my staged edit')
    return c and c.staged_conflict
  end, 'the conflict')
  eq(pr_row():find('1 conflict', 1, true) ~= nil, true)
  local text = enter_thread_with(right, 30, 'D1 edited on the web').text
  local joined = table.concat(text, '\n')
  eq(joined:find('edited on github.com', 1, true) ~= nil, true)
  eq(joined:find('your edit', 1, true) ~= nil, true)
  key_in_float('D1 my staged edit', 'dd')
  eq(table.concat(ui.thread_float(child).text, '\n'):find('D1 my staged edit', 1, true), nil)
  key_in_float('D1 edited on the web', 'dd')
  eq(ui.thread_float(child).text[1]:find('deletion staged', 1, true) ~= nil, true)
  child.type_keys('q')
  eq(remote_comment('D1 edited on the web') ~= nil, true)
  child.cmd('Diffy close')
end

T['a staged deletion of a comment edited on github.com is cancelled, with a notification'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  enter_thread_with(wins().right, 30, 'D1')
  key_in_float('D1', 'dd')
  eq(ui.thread_float(child).text[1]:find('deletion staged', 1, true) ~= nil, true)
  child.type_keys('q')
  eq(remote_comment('D1') ~= nil, true)
  web_edit('D1', 'D1 edited on the web')
  ui.capture_warnings(child)
  read_github(function()
    for _, t in ipairs(store().threads or {}) do
      for _, c in ipairs(t.comments) do
        if c.staged_delete then
          return false
        end
      end
    end
    return true
  end, 'the deletion cancelled')
  local warned = table.concat(ui.warnings(child, 'WARN'), '\n')
  eq(warned:find('deletion cancelled', 1, true) ~= nil, true)
  child.cmd('Diffy close')
end

T['a staged edit of a comment deleted on github.com becomes a draft reply, or goes with a notification when its thread is gone'] = function()
  fake_only()
  setup_pending()
  -- a second published comment of yours under D1, and D2 alone in its thread
  child.lua([[
    local fake = require('tests.helpers.fake_github')
    local db = fake.db(_G.__fake_state, 4)
    local d1 = db.threads[1]
    local at = fake.now(_G.__fake_state)
    table.insert(d1.comments.nodes, 2, vim.tbl_extend('force', vim.deepcopy(d1.comments.nodes[1]), {
      id = 'PRRC_D1_REPLY', body = 'D1R published reply', createdAt = at, updatedAt = at,
    }))
  ]])
  open_pr()
  open_file('f.txt')
  local right = wins().right
  enter_thread_with(right, 30, 'D1R')
  edit_card('D1R', 'D1R my edit')
  enter_thread_with(right, 20, 'D2')
  edit_card('D2', 'D2 my edit')

  web_delete('D1R')
  web_delete('D2')
  ui.capture_warnings(child)
  read_github(function()
    local c = stored('D1R my edit')
    return c and c.state == 'draft' and stored('D2 my edit') == nil
  end, 'the edit as a reply, the other dropped')
  local _, t = stored('D1R my edit')
  eq(t.id, select(2, remote_comment('D1 published')).id)
  local warned = table.concat(ui.warnings(child, 'WARN'), '\n')
  eq(warned:find('D2 my edit', 1, true) ~= nil, true)
  child.cmd('Diffy close')
end

T['your pending review made elsewhere is adopted: its comments are your drafts, mirrored into it'] = function()
  setup_pending()
  open_pr()
  wait_for(function()
    return stored('E3') ~= nil
  end, 'the adopted comments')
  -- E3 was written through the legacy position API on Q2: it keeps where
  -- it was written, not where GitHub moved it
  local e3, t3 = stored('E3')
  eq({ t3.anchor.commit, t3.anchor.end_line, e3.state }, { Q2, 20, 'draft' })
  local review = remote().pending
  open_file('f.txt')
  select_commit(3)
  enter_thread_with(wins().right, 7, 'E1')
  eq(ui.thread_float(child).text[1]:find('pending', 1, true) ~= nil, true)
  edit_card('E1', 'E1 edited in diffy')
  wait_for(function()
    return remote_comment('E1 edited in diffy') ~= nil
  end, 'the edit on GitHub')
  eq(remote_comment('E1 edited in diffy').review, review)
  child.cmd('Diffy close')
end

T['a draft GitHub cannot take stays local with a badge until a commit and a push make it mirrorable'] = function()
  setup_empty()
  local lines = vim.fn.readfile(dir .. '/f.txt')
  lines[35] = 'line 35 in the worktree'
  vim.fn.writefile(lines, dir .. '/f.txt')
  open_pr()
  ui.select_log_row(child, 'Working tree')
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 35, 'on the worktree')
  compose_draft(right, 1, 'nowhere near a change')
  read_github(function()
    local w, o = stored('on the worktree'), stored('nowhere near')
    return w and w.blocked == 'worktree' and o and o.blocked == 'outside the diff'
  end, 'both drafts kept local')
  eq(enter_thread_with(right, 35, 'on the worktree').text[1]:find('local only: worktree', 1, true) ~= nil, true)
  child.type_keys('q')
  eq(#remote().threads, 0)

  ui.git(dir, { 'commit', '-qam', 'worktree change' })
  local sha = ui.git(dir, { 'rev-parse', 'HEAD' })
  read_github(function()
    local w = stored('on the worktree')
    return w and w.blocked == 'unpushed'
  end, 'the draft on an unpushed commit')
  eq(#remote().threads, 0)

  if live.enabled then
    ui.git(dir, { 'push', '-q', 'origin', 'HEAD:refs/heads/' .. live.current.head })
    -- GitHub moves the PR head a moment after the push
    wait_for(function()
      return live.graphql('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){headRefOid}}}', { o = OWNER, r = NAME, n = pr_number() })
        .repository.pullRequest.headRefOid == sha
    end, 'the PR head moved')
  else
    child.lua(('require("tests.helpers.fake_github").push(_G.__fake_state, 4, %q)'):format(sha))
  end
  read_github(function()
    return remote_comment('on the worktree') ~= nil
  end, 'the draft mirrored after the push')
  local c = remote_comment('on the worktree')
  eq({ c.original_commit, c.original_line }, { sha, 35 })
  eq(remote_comment('nowhere near'), nil)
  child.cmd('Diffy close')
end

T['a draft on a line the PR base on GitHub has since taken in stays local with a badge, no warning'] = function()
  setup_empty()
  -- the base branch moved on GitHub to Q1 (f.txt L5-7) while the local one
  -- still points at the old base: diffy shows L6 changed, GitHub doesn't
  if live.enabled then
    ui.git(dir, { 'push', '-q', 'origin', Q1 .. ':refs/heads/' .. live.current.base })
    wait_for(function()
      return live.graphql('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){baseRefOid}}}', { o = OWNER, r = NAME, n = pr_number() })
        .repository.pullRequest.baseRefOid == Q1
    end, 'the PR base moved')
  else
    child.lua(('_G.__fake_state.merge_base = %q'):format(Q1))
  end
  open_pr()
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 6, 'on the old base')
  read_github(function()
    local c = stored('on the old base')
    return c and c.blocked == 'outside the diff' and row_icon() ~= '↻'
  end, 'the draft kept local, the sync over')
  eq(row_icon(), nil)
  eq(#remote().threads, 0)
  eq(enter_thread_with(right, 6, 'on the old base').text[1]:find('local only: outside the diff', 1, true) ~= nil, true)
  child.type_keys('q')
  child.cmd('Diffy close')
end

T['a draft reply on a resolved thread is mirrored; once its thread is deleted, it goes with its text in a notification'] = function()
  fake_only()
  setup_pending()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  enter_thread_with(right, 20, 'D2')
  ui.arm_ready_raw(child, 'compose')
  child.type_keys('r')
  save_composed('reply on a resolved thread')
  wait_for(function()
    return remote_comment('reply on a resolved thread') ~= nil
  end, 'the reply in the pending review')
  eq(select(2, remote_comment('reply on a resolved thread')).resolved, true)

  child.lua([[
    local db = require('tests.helpers.fake_github').db(_G.__fake_state, 4)
    for i, t in ipairs(db.threads) do
      if t.comments.nodes[1].body:find('^D2') then
        table.remove(db.threads, i)
        break
      end
    end
  ]])
  ui.capture_warnings(child)
  read_github(function()
    return stored('reply on a resolved thread') == nil
  end, 'the reply dropped')
  eq(table.concat(ui.warnings(child, 'WARN'), '\n'):find('reply on a resolved thread', 1, true) ~= nil, true)
  child.cmd('Diffy close')
end

T['submitting to the agent takes your drafts out of the pending review'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  compose_draft(wins().right, 30, 'for the agent')
  wait_for(function()
    return remote_comment('for the agent') ~= nil
  end, 'the draft mirrored')

  ui.arm_ready_raw(child, 'compose')
  child.cmd('Diffy review agent')
  wait_ready_raw()
  child.type_keys('<C-s>')
  -- a background sync's redraw also fires `review`
  wait_for(function()
    return vim.fn.filereadable(branch_dir() .. '/review.md') == 1
  end, 'review.md written')

  local md = table.concat(vim.fn.readfile(branch_dir() .. '/review.md'), '\n')
  -- your drafts, adopted ones included; not D1, which is published (only quoted, above the E4 reply to it)
  eq({ md:find('for the agent', 1, true) ~= nil, md:find('E1 pending', 1, true) ~= nil, md:find('\nD1 published', 1, true) }, { true, true, nil })
  wait_for(function()
    return remote().pending == nil
  end, 'the pending review emptied')
  eq(remote_comment('for the agent'), nil)
  eq(remote_comment('D1 published') ~= nil, true)
  eq({ stored('for the agent').state, stored('for the agent').gh }, { 'sent', nil })
  child.cmd('Diffy close')
end

T['a reply sent to the agent comes with the thread it answers'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  enter_thread_with(wins().right, 30, 'D1')
  ui.arm_ready_raw(child, 'compose')
  child.type_keys('r')
  save_composed('a reply for the agent')

  ui.arm_ready_raw(child, 'compose')
  child.cmd('Diffy review agent')
  wait_ready_raw()
  ui.arm_ready_raw(child, 'review')
  child.type_keys('<C-s>')
  wait_ready_raw()

  local md = table.concat(vim.fn.readfile(branch_dir() .. '/review.md'), '\n')
  local section = md:match('\n## [^\n]* f%.txt:30\n(.-a reply for the agent)')
  eq(section and section:find('> D1 published thread', 1, true) ~= nil, true)
  child.cmd('Diffy close')
end

T['the list under the GitHub submit message shows what goes out; a draft left out returns into a fresh pending review'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  compose_draft(right, 30, 'goes out')
  compose_draft(right, 28, 'stays for later')
  compose_draft(right, 1, 'cannot go')
  wait_for(function()
    return remote_comment('goes out') and remote_comment('stays for later')
  end, 'both drafts mirrored')
  local first = remote().pending

  local float = submit_to_github('round one')
  local text = table.concat(float, '\n')
  eq(text:find('[x] new thread f.txt:30  goes out', 1, true) ~= nil, true)
  eq(text:find('[x] new thread f.txt:28  stays for later', 1, true) ~= nil, true)
  eq(text:find('stays behind: f.txt:1  cannot go (outside the diff)', 1, true) ~= nil, true)
  for i, l in ipairs(float) do
    if l:find('stays for later', 1, true) then
      child.api.nvim_win_set_cursor(0, { i, 0 })
    end
  end
  child.type_keys('x')
  eq(table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('[ ] new thread f.txt:28', 1, true) ~= nil, true)
  child.type_keys('<C-s>')

  wait_for(function()
    local r = remote()
    local later = remote_comment('stays for later', r)
    return submitted('round one') and later and later.state == 'PENDING' and r.pending ~= nil
  end, 'the submit, then the left-out draft in a new review')
  local r = remote()
  eq(remote_comment('goes out', r).state, 'SUBMITTED')
  eq(r.pending ~= first, true)
  eq(stored('goes out'), nil)
  child.cmd('Diffy close')
end

T['a GitHub submit sends the review, then staged edits and deletions, then resolves; a failing one stays staged and the next sync retries it'] = function()
  fake_only()
  setup_pending()
  child.lua([[_G.__fake_state.fail = { resolveReviewThread = 'boom' }]])
  open_pr()
  open_file('f.txt')
  local right = wins().right
  enter_thread_with(right, 30, 'D1')
  edit_card('D1', 'D1 edited at submit')
  enter_thread_with(right, 30, 'D1 edited at submit')
  ui.arm_ready_raw(child, 'review')
  child.type_keys('x')
  wait_ready_raw()
  child.type_keys('q')
  enter_thread_with(right, 20, 'D2')
  key_in_float('D2', 'dd')
  child.type_keys('q')
  child.lua('_G.__fake_state.calls = {}')

  local text = table.concat(submit_to_github('with staged changes'), '\n')
  for _, want in ipairs({ 'edit       f.txt:30  D1 edited at submit', 'delete     f.txt:20  D2', 'resolve    f.txt:30  D1', 'new thread f.txt:7  E1', 'reply      f.txt:30  E4' }) do
    eq({ want, text:find(want, 1, true) ~= nil }, { want, true })
  end
  ui.capture_warnings(child)
  child.type_keys('<C-s>')
  wait_for(function()
    return submitted('with staged changes') and remote_comment('D1 edited at submit') ~= nil and remote_comment('D2') == nil
  end, 'the submit and the staged changes')
  local calls = child.lua_get('_G.__fake_state.calls')
  local order = vim.tbl_filter(function(c)
    return c == 'submitPullRequestReview' or c == 'updatePullRequestReviewComment' or c == 'deletePullRequestReviewComment' or c == 'resolveReviewThread'
  end, calls)
  -- the syncs after it may retry the failed resolve already
  eq(vim.list_slice(order, 1, 4), { 'submitPullRequestReview', 'updatePullRequestReviewComment', 'deletePullRequestReviewComment', 'resolveReviewThread' })
  -- the resolve failed: still staged
  wait_for(function()
    for _, t in ipairs(store().threads or {}) do
      if t.resolve_staged == 'resolve' and t.retry then
        return true
      end
    end
    return false
  end, 'the resolve kept staged')
  eq(select(2, remote_comment('D1 edited')).resolved, false)

  child.lua('_G.__fake_state.fail = nil')
  read_github(function()
    return select(2, remote_comment('D1 edited')).resolved == true
  end, 'the resolve retried')
  child.cmd('Diffy close')
end

T['a staged edit GitHub refuses shows ⚠ on the PR row, stays staged and goes with the next sync'] = function()
  fake_only()
  setup_pending()
  child.lua([[_G.__fake_state.fail = { updatePullRequestReviewComment = 'boom' }]])
  open_pr()
  open_file('f.txt')
  enter_thread_with(wins().right, 30, 'D1')
  edit_card('D1', 'D1 refused edit')
  submit_to_github('with a refused edit')
  ui.capture_warnings(child)
  child.type_keys('<C-s>')
  wait_for(function()
    return submitted('with a refused edit') and row_icon() == '⚠'
  end, '⚠ on the row')
  eq(stored('D1 refused edit').staged_body, 'D1 refused edit')
  eq(remote_comment('D1 refused edit'), nil)

  child.lua('_G.__fake_state.fail = nil')
  read_github(function()
    return remote_comment('D1 refused edit') ~= nil and row_icon() == nil
  end, 'the edit applied, the row quiet again')
  child.cmd('Diffy close')
end

T['review github: the event cycles in the title while you write, the list says only the message goes; approving needs no drafts'] = function()
  setup_empty()
  open_pr()
  eq(child.fn.getcompletion('Diffy review github ', 'cmdline'), live.enabled and { 'comment' } or { 'comment', 'approve', 'request_changes' })

  local function title()
    return child.api.nvim_win_get_config(0).title[1][1]
  end
  ui.arm_ready_raw(child, 'recap')
  child.cmd('Diffy review github')
  wait_ready_raw()
  child.type_keys('lgtm')
  local expected
  if live.enabled then
    -- your own PR: comment is the only event
    eq(title(), ' Submit to GitHub ')
    expected = { state = 'COMMENTED', body = 'lgtm' }
  else
    eq(title(), ' Submit to GitHub · comment ')
    child.type_keys('<C-t>')
    eq(title(), ' Submit to GitHub · approve ')
    expected = { state = 'APPROVED', body = 'lgtm' }
  end
  child.type_keys('<Esc>', '<Tab>')
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { '    no comments or staged changes: only the message' })
  child.type_keys('<C-s>')
  wait_for(function()
    return vim.deep_equal(remote().submitted, { expected })
  end, 'the review')
  child.cmd('Diffy close')
end

T['review github starts on the event its argument names'] = function()
  fake_only()
  setup_empty()
  open_pr()
  ui.arm_ready_raw(child, 'recap')
  child.cmd('Diffy review github request_changes')
  wait_ready_raw()
  eq(child.api.nvim_win_get_config(0).title[1][1], ' Submit to GitHub · request changes ')
  child.type_keys('<C-t>')
  eq(child.api.nvim_win_get_config(0).title[1][1], ' Submit to GitHub · comment ')
  child.type_keys('<Esc>', 'q')
  child.cmd('Diffy close')
end

T['dd in the threads view deletes your unpublished thread, from your pending review too; a published one stays'] = function()
  child.o.columns = 220
  setup_pending()
  open_pr()
  child.cmd('Diffy threads')
  local function cursor_on(needle)
    for i, l in ipairs(ui.threads_view(child).rows) do
      if l:find(needle, 1, true) then
        child.api.nvim_win_set_cursor(wins().threads, { i, 0 })
      end
    end
  end
  ui.capture_warnings(child)
  cursor_on('D1 published')
  child.type_keys('dd')
  eq(table.concat(ui.warnings(child, 'WARN'), '\n'):find('unpublished', 1, true) ~= nil, true)
  cursor_on('E1 pending')
  child.type_keys('dd')
  wait_for(function()
    return remote_comment('E1 pending') == nil
  end, 'E1 out of the pending review')
  eq(remote_comment('D1 published') ~= nil, true)
  eq(stored('E1 pending'), nil)
  child.type_keys('q')
  child.cmd('Diffy close')
end

T[':Diffy review clear asks, then drops your drafts and deletes your pending review'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  compose_draft(wins().right, 30, 'to be cleared')
  wait_for(function()
    return remote_comment('to be cleared') ~= nil and remote().pending ~= nil
  end, 'the draft mirrored')

  child.cmd('Diffy review clear')
  child.type_keys('n')
  eq(stored('to be cleared') ~= nil, true)
  eq(remote().pending ~= nil, true)

  ui.arm_ready_raw(child, 'review')
  child.cmd('Diffy review clear')
  child.type_keys('y')
  wait_ready_raw()
  wait_for(function()
    return remote().pending == nil
  end, 'the pending review deleted')
  -- adopted comments went with it; published ones stay
  eq({ remote_comment('E1'), remote_comment('to be cleared'), remote_comment('D1') ~= nil }, { nil, nil, true })
  eq(#(store().threads or {}), 0)
  child.cmd('Diffy close')
end

T['with a PR, review completes agent, clear and github'] = function()
  setup_empty()
  open_pr()
  eq(child.fn.getcompletion('Diffy review ', 'cmdline'), { 'agent', 'clear', 'github' })
  child.cmd('Diffy close')
end

T['the thread float names each author and marks drafts, pending comments and resolved threads'] = function()
  setup_pending()
  child.lua('require("diffy.review.github").sync_delay = 60000')
  open_pr()
  open_file('f.txt')
  local right = wins().right
  enter_thread_with(right, 30, 'D1')
  ui.arm_ready_raw(child, 'compose')
  child.type_keys('r')
  save_composed('a reply')

  local text = enter_thread_with(right, 30, 'a reply').text
  -- D1 is published: its header carries no state
  eq(text[1]:find('^GuillaumeLagrange  ') ~= nil, true)
  eq({ text[1]:find('draft', 1, true), text[1]:find('pending', 1, true) }, {})
  eq(text[2]:find('^D1 published thread') ~= nil, true)
  if not live.enabled then
    -- the recorded PR has E4, a reply in the viewer's pending review
    eq(text[4]:find('  pending$') ~= nil, true)
  end
  eq({ text[#text - 1]:find('  draft$') ~= nil, text[#text] }, { true, 'a reply' })
  child.type_keys('q')

  enter_thread_with(right, 20, 'D2')
  eq(ui.thread_float(child).text[1]:match('  ✓ resolved$') ~= nil, true)
  child.type_keys('q')
  child.cmd('Diffy close')
end

return T
