-- The GitHub layer's write side through the UI: push (local validation,
-- per-commit routing, tracking to HEAD), pull, reply, resolve/unresolve,
-- submit and its destination. Repo: a git bundle of the sandbox's `pending`
-- PR (exact shas). `make test-gh`: the real transport against a fresh PR
-- per case.
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

local function clone_pending()
  return live.clone_sandbox(PENDING_BUNDLE, 'pending')
end

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
    ]]):format(PR4_FIXTURE, dir, MERGE_BASE, BASE, HEAD_SHA))
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
  local owner, name = live.REPO:match('(.+)/(.+)')
  local threads = live.graphql(
    'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:10){nodes{id comments(first:1){nodes{body}}}}}}}',
    { o = owner, r = name, n = pr.number }
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

--- An empty PR (no threads, no pending review) - for the push scenarios,
--- so pushed drafts are the *only* content. Live: the fresh PR as is.
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
      dir = clone_pending()
      if live.enabled then
        live.open_pr(dir, MERGE_BASE, HEAD_SHA)
      end
      child.fn.chdir(dir)
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

local function select_all()
  local w = wins()
  child.api.nvim_set_current_win(w.log)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, 'call cursor(1, 1)')
  child.type_keys('a')
  ui.wait_ready(child, live.timeout)
end

local function arm_ready_raw(event)
  ui.arm_ready_raw(child, event)
end

local function wait_ready_raw()
  ui.wait_ready_raw(child, live.timeout)
end

--- GitHub's state of the PR's reviews: `{ pending = bool, submitted =
--- { { state, body }, … } }` (the fake's recorded db, or the live API).
local function remote_reviews()
  if live.enabled then
    local owner, name = live.REPO:match('(.+)/(.+)')
    local pr = live.graphql(
      'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(last:50){nodes{state body}}}}}',
      { o = owner, r = name, n = pr_number() }
    ).repository.pullRequest
    local out = { pending = false, submitted = {} }
    for _, r in ipairs(pr.reviews.nodes) do
      if r.state == 'PENDING' then
        out.pending = true
      else
        table.insert(out.submitted, { state = r.state, body = r.body })
      end
    end
    return out
  end
  return child.api.nvim_exec_lua(
    [[
    local db = (_G.__fake_state._db or {})[4] or { pending = {}, reviews = {} }
    local out = { pending = next(db.pending) ~= nil, submitted = {} }
    for _, r in ipairs(db.reviews) do
      table.insert(out.submitted, { state = r.state, body = r.body })
    end
    return out
  ]],
    {}
  )
end

local function save_composed(body)
  wait_ready_raw()
  child.type_keys(body, '<Esc>')
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  wait_ready_raw()
end

local function compose_draft(win, lnum, body)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
  arm_ready_raw('compose')
  child.type_keys('gc')
  save_composed(body)
end

local function compose_draft_range(win, lnum1, lnum2, body)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum1))
  child.type_keys('v')
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum2))
  arm_ready_raw('compose')
  child.type_keys('gc')
  save_composed(body)
end

--- Replies to the default thread at `lnum` of `win`; the float stays open.
local function reply_at(win, lnum, body)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
  child.type_keys('K')
  arm_ready_raw('compose')
  child.type_keys('r')
  save_composed(body)
end

--- Your drafts in the branch's threads.json (not the GitHub cache next to
--- them), as JSON text, or nil when there is no file.
local function drafts_text()
  local branch = ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  local path = ('%s/.git/diffy/%s/threads.json'):format(dir, branch)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  return vim.json.encode({ threads = data.threads or {} })
end

local function drafts_file()
  local text = drafts_text()
  MiniTest.expect.equality(text ~= nil, true)
  return vim.json.decode(text)
end

local function push()
  ui.arm_ready(child, 'review')
  child.cmd('Diffy review push')
  ui.wait_ready(child, live.timeout)
end

--- Every thread row of `:Diffy threads`, groups unfolded: `{ lnum, text,
--- group, shown }`, `lnum` being the line the row says and `shown` the
--- preview's list of the views showing it (the cursor moved onto the row).
local function thread_entries()
  child.o.columns = 200
  ui.all_threads(child, 'Diffy threads')
  local out, group = {}, nil
  for i, r in ipairs(ui.thread_rows(ui.threads_view(child))) do
    if r.kind == 'group' then
      group = r.label
    elseif r.kind == 'thread' then
      child.type_keys(i .. 'G')
      local shown = ui.threads_view(child).preview[1]
      table.insert(out, { lnum = tonumber(r.text:match(':(%d+)%s')), text = r.text, group = group, shown = shown })
    end
  end
  child.type_keys('q')
  return out
end

--- The entry of the single thread at `lnum`.
local function thread_at(lnum)
  for _, e in ipairs(thread_entries()) do
    if e.lnum == lnum then
      return e
    end
  end
  return nil
end

--- The entry of the thread whose first line starts with `id` (the
--- sandbox's comment ids, e.g. 'D2').
local function thread_of(id)
  for _, e in ipairs(thread_entries()) do
    if e.text:find(' ' .. id .. ' ', 1, true) then
      return e
    end
  end
  return nil
end

--- Enter the thread at `lnum` of `win` whose text has `needle`: `K` opens the
--- default one, `]t`/`[t` step through the others stacked there.
local function enter_thread_with(win, lnum, needle)
  child.api.nvim_set_current_win(win)
  for _, step in ipairs({ ']t', '[t' }) do
    child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
    child.type_keys('K')
    for _ = 1, 4 do
      local f = ui.thread_float(child)
      if f ~= vim.NIL and table.concat(f.text, '\n'):find(needle, 1, true) then
        return
      end
      child.type_keys(step)
    end
    child.type_keys('q')
  end
  error('no thread with ' .. needle .. ' at line ' .. lnum)
end

T['push validates locally, sends nothing for an invalid draft (kept local with a warning), and pushes the rest'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')

  local right = wins().right
  compose_draft(right, 30, 'valid: on the head hunk')
  compose_draft(right, 1, 'invalid: nowhere near a change')

  ui.capture_warnings(child)
  push()

  MiniTest.expect.equality(#ui.warnings(child, 'WARN') > 0, true)
  MiniTest.expect.equality(ui.warnings(child, 'ERROR'), {})

  -- the valid one is now `pending` on GitHub (no longer just a local
  -- draft): still visible at its line after the push+refresh round-trip
  MiniTest.expect.equality(lines_with_signs('right')[30], true)

  -- the invalid one stayed local: persisted to disk, still `draft`
  local data = drafts_file()
  local found
  for _, t in ipairs(data.threads) do
    for _, c in ipairs(t.comments) do
      if c.body:find('invalid', 1, true) then
        found = c
      end
    end
  end
  MiniTest.expect.equality(found ~= nil, true)
  MiniTest.expect.equality(found.state, 'draft')

  child.cmd('Diffy close')
end

T['push with drafts on two commits lands each on its own commit; a multi-line draft on the second is tracked to HEAD'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')

  -- log entries, newest first: head(Q3)=1, Q2=2, Q1=3
  select_commit(3)
  local q1_right = wins().right
  compose_draft(q1_right, 5, 'on Q1 line 5')
  compose_draft(q1_right, 7, 'on Q1 line 7')

  select_commit(2)
  local q2_right = wins().right
  compose_draft_range(q2_right, 18, 22, 'on Q2, multi-line 18-22')

  push()

  -- Q1's two single-line drafts: primary commit (most drafts), pushed via
  -- the batched `addPullRequestReview` call, visible at their own commit
  select_commit(3)
  local at_q1 = lines_with_signs('right')
  MiniTest.expect.equality(at_q1[5], true)
  MiniTest.expect.equality(at_q1[7], true)

  -- Q2's multi-line draft: "other commit", tracked to HEAD via
  -- `addPullRequestReviewThread` (unshifted - Q3's own edit is at L30)
  select_all()
  local at_head = lines_with_signs('right')
  MiniTest.expect.equality(at_head[5], true)
  MiniTest.expect.equality(at_head[7], true)
  MiniTest.expect.equality(at_head[22], true)

  -- diffy's own cross-commit placement would show still-local drafts at the
  -- same lines, so only the emptied drafts file proves they were pushed
  local text = drafts_text() or ''
  MiniTest.expect.equality(text:find('multi-line 18-22', 1, true), nil)
  MiniTest.expect.equality(text:find('on Q1 line', 1, true), nil)

  local q1 = thread_at(5)
  local q2 = thread_at(18)
  MiniTest.expect.equality(q1 ~= nil, true)
  MiniTest.expect.equality(q1.shown:find(Q1:sub(1, 7), 1, true) ~= nil, true)
  MiniTest.expect.equality(q2 ~= nil, true)
  MiniTest.expect.equality(q2.shown:find('head', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['a reply drafted on a not-yet-pushed thread lands in that thread on push'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')

  local right = wins().right
  compose_draft(right, 30, 'root comment')
  reply_at(right, 30, 'follow-up')

  push()

  -- one thread on GitHub holding both comments, nothing left as a local draft
  local at_30 = {}
  for _, e in ipairs(thread_entries()) do
    if e.lnum == 30 then
      table.insert(at_30, e.text)
    end
  end
  MiniTest.expect.equality(#at_30, 1)
  MiniTest.expect.equality(at_30[1]:find('+1', 1, true) ~= nil, true)
  MiniTest.expect.equality((drafts_text() or ''):find('follow-up', 1, true), nil)

  child.cmd('Diffy close')
end

T['a reply drafted on one of two new same-file threads with the same body lands in its own thread'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')

  local right = wins().right
  compose_draft(right, 20, 'nit')
  reply_at(right, 20, 'follow-up')
  compose_draft(right, 30, 'nit')

  push()

  local by_line = {}
  for _, e in ipairs(thread_entries()) do
    by_line[e.lnum] = (by_line[e.lnum] or '') .. e.text
  end
  MiniTest.expect.equality(by_line[20]:find('+1', 1, true) ~= nil, true)
  MiniTest.expect.equality(by_line[30]:find('+1', 1, true), nil)

  child.cmd('Diffy close')
end

T['pull restores a pending comment (eagerly remapped for display) at its original commit and line'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')

  ui.arm_ready(child, 'review')
  child.cmd('Diffy review pull')
  ui.wait_ready(child, live.timeout)

  local data = drafts_file()

  -- E3 was written via the legacy position API against Q2 and eagerly
  -- remapped by GitHub to `commit = head` - `pull` must restore
  -- its *original* commit/line (Q2, L20), not the live-tracked one
  local e3
  for _, t in ipairs(data.threads) do
    for _, c in ipairs(t.comments) do
      if c.body:find('E3', 1, true) then
        e3 = { thread = t, comment = c }
      end
    end
  end
  MiniTest.expect.equality(e3 ~= nil, true)
  MiniTest.expect.equality(e3.thread.anchor.commit, Q2)
  MiniTest.expect.equality(e3.thread.anchor.end_line, 20)
  MiniTest.expect.equality(e3.comment.state, 'draft')

  child.cmd('Diffy close')
end

T['the thread float names each author and marks drafts and resolved threads'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  reply_at(right, 30, 'a reply')

  local text = ui.thread_float(child).text
  -- D1 is published: its header carries no state
  MiniTest.expect.equality(text[1]:find('^GuillaumeLagrange  ') ~= nil, true)
  MiniTest.expect.equality({ text[1]:find('draft', 1, true), text[1]:find('pending', 1, true) }, {})
  MiniTest.expect.equality(text[2]:find('^D1 published thread') ~= nil, true)
  if not live.enabled then
    -- the recorded PR has E4, a reply in the viewer's pending review
    MiniTest.expect.equality(text[3]:find('  pending$') ~= nil, true)
  end
  MiniTest.expect.equality({ text[#text - 1]:find('  draft$') ~= nil, text[#text] }, { true, 'a reply' })
  child.type_keys('q')

  enter_thread_with(right, 20, 'D2')
  MiniTest.expect.equality(ui.thread_float(child).text[1]:match('  ✓ resolved$') ~= nil, true)
  child.type_keys('q')

  child.cmd('Diffy close')
end

T['reply, resolve/unresolve and submit'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')

  -- pull first: recreating the pending review
  -- on push/submit must not silently drop the pre-existing E1/E2/E3/E4
  ui.arm_ready(child, 'review')
  child.cmd('Diffy review pull')
  ui.wait_ready(child, live.timeout)

  local right = wins().right
  -- D1 (published, head R30) and D2 (published, resolved, head R20)
  reply_at(right, 30, 'a reply from the test')

  MiniTest.expect.equality(lines_with_signs('right')[30], true)

  -- saving the reply went back into the thread; `x` resolves it in place and
  -- the thread stays open until `q`
  arm_ready_raw('review')
  child.type_keys('x')
  wait_ready_raw()
  child.type_keys('q')

  enter_thread_with(right, 20, 'D2')
  arm_ready_raw('review')
  child.type_keys('x')
  wait_ready_raw()
  child.type_keys('q')

  local d1 = thread_of('D1')
  local d2 = thread_of('D2')
  MiniTest.expect.equality(d1 ~= nil, true)
  MiniTest.expect.equality(d1.group:find('^Resolved') ~= nil, true)
  MiniTest.expect.equality(d2 ~= nil, true)
  MiniTest.expect.equality(d2.group:find('^Resolved'), nil)

  arm_ready_raw('compose')
  child.cmd('Diffy review submit comment')
  wait_ready_raw()
  child.type_keys('looks good', '<Esc>')
  child.type_keys('<C-s>')
  -- push+submit consumes the pending review on GitHub
  local function submitted()
    local r = remote_reviews()
    if r.pending then
      return false
    end
    for _, s in ipairs(r.submitted) do
      if s.body == 'looks good' then
        return true
      end
    end
    return false
  end
  MiniTest.expect.equality(vim.wait(live.timeout, submitted, live.enabled and 1000 or 10), true)

  child.cmd('Diffy close')
end

T['review submit asks agent or GitHub, then comment, approve or request changes; approving needs no drafts'] = function()
  setup_empty()
  open_pr()
  MiniTest.expect.equality(child.fn.getcompletion('Diffy review submit ', 'cmdline'), live.enabled and { 'comment' } or { 'comment', 'approve', 'request_changes' })

  arm_ready_raw('compose')
  child.cmd('Diffy review submit')
  wait_ready_raw()
  child.type_keys('lgtm', '<Esc>')
  arm_ready_raw('choose')
  child.type_keys('<C-s>')
  wait_ready_raw()
  MiniTest.expect.equality(vim.list_slice(child.api.nvim_buf_get_lines(0, 0, -1, false), 2), { '  a  agent', '  g  GitHub' })
  local expected
  if live.enabled then
    -- your own PR: comment is the only event, no second prompt
    child.type_keys('g')
    expected = { state = 'COMMENTED', body = 'lgtm' }
  else
    arm_ready_raw('choose')
    child.type_keys('g')
    wait_ready_raw()
    local prompt = child.api.nvim_buf_get_lines(0, 0, -1, false)
    MiniTest.expect.equality(vim.list_slice(prompt, 2), { '  c  comment', '  a  approve', '  r  request changes' })
    -- cancelling goes back to the message, kept
    child.type_keys('q')
    MiniTest.expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'lgtm' })
    arm_ready_raw('choose')
    child.type_keys('<C-s>')
    wait_ready_raw()
    arm_ready_raw('choose')
    child.type_keys('g')
    wait_ready_raw()
    child.type_keys('a')
    expected = { state = 'APPROVED', body = 'lgtm' }
  end
  MiniTest.expect.equality(vim.wait(live.timeout, function()
    return vim.deep_equal(remote_reviews().submitted, { expected })
  end, live.enabled and 1000 or 10), true)

  child.cmd('Diffy close')
end

T['with a PR, submitting to the agent sends only your drafts, marks them sent and leaves GitHub alone'] = function()
  setup_pending()
  open_pr()
  open_file('f.txt')
  compose_draft(wins().right, 30, 'for the agent')
  local remote = remote_reviews()

  arm_ready_raw('compose')
  child.cmd('Diffy review submit')
  wait_ready_raw()
  arm_ready_raw('choose')
  child.type_keys('<C-s>')
  wait_ready_raw()
  arm_ready_raw('review')
  child.type_keys('a')
  wait_ready_raw()

  local md = table.concat(vim.fn.readfile(dir .. '/.git/diffy/' .. ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' }) .. '/review.md'), '\n')
  MiniTest.expect.equality(md:find('for the agent', 1, true) ~= nil, true)
  -- D1 is published, E1 in your pending review: GitHub's, not the agent's
  MiniTest.expect.equality({ md:find('D1 published', 1, true), md:find('E1 pending', 1, true) }, {})
  MiniTest.expect.equality(drafts_file().threads[1].comments[1].state, 'sent')
  MiniTest.expect.equality(remote_reviews(), remote)
  child.cmd('Diffy close')
end

T['submitting 35 drafts lands them all even though GitHub errors returning the review'] = function()
  setup_empty()
  open_pr()
  open_file('f.txt')
  local right = wins().right
  for i = 1, 35 do
    compose_draft(right, 30, ('draft %d'):format(i))
  end

  arm_ready_raw('compose')
  child.cmd('Diffy review submit comment')
  wait_ready_raw()
  child.type_keys('big review', '<Esc>')
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  wait_ready_raw()

  MiniTest.expect.equality(remote_reviews(), { pending = false, submitted = { { state = 'COMMENTED', body = 'big review' } } })
  -- pushed drafts leave the local file; nothing is pushed twice later
  MiniTest.expect.equality(vim.json.decode(drafts_text()).threads or {}, {})

  child.cmd('Diffy close')
end

return T
