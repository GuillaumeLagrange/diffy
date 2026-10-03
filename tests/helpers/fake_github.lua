-- Fake GitHub transport, swapped in for `review/github.lua`'s `M.transport`
-- and `M.pr_view` in a child nvim before opening a session:
--
--   child.lua([[
--     local fake = require('tests.helpers.fake_github')
--     local state = fake.load_fixture('tests/fixtures/github/pr2.json', 2)
--     state.branches = { ['sandbox/placement'] = 2 }
--     fake.install(state)
--   ]])
--
-- `state` is plain Lua tables, so a test can hand-build one instead of a
-- recorded fixture. It takes:
--   state.branches     branch -> PR number, what `gh pr view <branch>` finds
--   state.offline      every request fails, as without network
--   state.hold         `gh pr view` doesn't answer until `M.release(state)`
--   state.hold_answers GitHub acts on every request but answers only on
--                      `M.release_answers(state)`
--   state.fail         mutation name -> error message: that mutation fails
--                      (e.g. `{ resolveReviewThread = 'boom' }`)
--   state.repo_dir     the fixture repo, for real `git diff` validation
--                      (GitHub's "changed line or ±3 context of
--                      merge-base...commit" rule)
--   state.merge_base   merge-base sha, used the same way
--   state.viewer       login owning the (one, per-user) pending review;
--                      defaults to 'diffy-test-user'
-- Every PR touched gets a mutable "db" deep-copied once from
-- `state.reads[number]` (`M.db`), so later reads reflect the mutations
-- (`db.state = 'MERGED'` merges it); `state.reads` itself is never modified.
-- Connections are paginated at the `$k` the request asks for.
--
-- Write-side behaviour, as measured on the sandbox:
-- - `addPullRequestReviewComment(pullRequestReviewId, commitOID, position)`
--   joins the pending review; a position on a `-` line makes a LEFT thread
--   (merge-base line), otherwise RIGHT; `originalCommit` is the commit,
--   `commit` moves to head at once when trackable, `line == originalLine`.
-- - `addPullRequestReviewThread(pullRequestReviewId)` joins it at head.
-- - A second `addPullRequestReview` while one is pending fails with
--   UNPROCESSABLE and creates nothing.
-- - Comments, pending or published, are edited and deleted in place; a thread
--   left empty goes; the last pending comment's deletion deletes its review
--   (later uses of the id are NOT_FOUND). A review created empty stays until
--   `deletePullRequestReview`.
-- - `updatedAt` moves on every edit and on submit; `lastEditedAt` and
--   `includesCreatedEdit` only on a published comment's edit. The clock ticks
--   one second per timestamp, so two edits never share one.
-- - `M.push` remaps pending and published comments alike.
local model = require('diffy.review.model')

local M = {}

-- what a submitted review's `state` reads for each event
local REVIEW_STATES = { COMMENT = 'COMMENTED', APPROVE = 'APPROVED', REQUEST_CHANGES = 'CHANGES_REQUESTED' }

local EPOCH = 1767225600 -- 2026-01-01T00:00:00Z

--- The fake clock: a fresh ISO timestamp, one second after the last.
function M.now(state)
  state.clock = (state.clock or 0) + 1
  return os.date('!%Y-%m-%dT%H:%M:%SZ', EPOCH + state.clock)
end

local function db_for(state, number)
  state._db = state._db or {}
  if state._db[number] then
    return state._db[number]
  end
  local fixture = state.reads and state.reads[number]
  local pr = fixture and fixture.repository and fixture.repository.pullRequest
  local db = {
    id = pr and pr.id or ('FAKE_PR_%d'):format(number),
    state = pr and pr.state or 'OPEN',
    base = pr and pr.baseRefName,
    head = pr and pr.headRefOid,
    title = pr and pr.title,
    body = pr and pr.body,
    conversation = pr and vim.deepcopy(pr.comments.nodes) or {},
    reviews = pr and vim.deepcopy(pr.reviews.nodes) or {},
    threads = pr and vim.deepcopy(pr.reviewThreads.nodes) or {},
    pending = {}, -- viewer login -> {id, commitOID}
    next_id = 1,
  }
  local pid = pr and pr.pendingReviews and pr.pendingReviews.nodes[1] and pr.pendingReviews.nodes[1].id
  if pid then
    db.pending[state.viewer] = { id = pid, commitOID = db.head }
  end
  -- recordings have no `state`: the pending review's comments are PENDING
  for _, t in ipairs(db.threads) do
    for _, c in ipairs(t.comments.nodes) do
      if not c.state then
        c.state = (pid and c.pullRequestReview and c.pullRequestReview.id == pid) and 'PENDING' or 'SUBMITTED'
      end
    end
  end
  state._db[number] = db
  return db
end
M.db = db_for

local URL = 'https://github.com/GuillaumeLagrange/diffy-tests/pull/%d'

--- `nodes[after+1 .. after+k]` as a connection; cursors are indices.
local function page(nodes, k, after)
  local from = tonumber(after or '0')
  local out = {}
  for i = from + 1, math.min(#nodes, from + k) do
    table.insert(out, nodes[i])
  end
  local last = from + #out
  return { totalCount = #nodes, pageInfo = { hasNextPage = last < #nodes, endCursor = tostring(last) }, nodes = out }
end

--- A thread node with its comments cut to the first page.
local function thread_page(t, k)
  local copy = {}
  for key, v in pairs(t) do
    if key ~= 'comments' and not tostring(key):match('^_') then
      copy[key] = v
    end
  end
  copy.comments = page(t.comments.nodes, k)
  return copy
end

local function threads_page(db, k, after)
  local p = page(db.threads, k, after)
  p.nodes = vim.tbl_map(function(t)
    return thread_page(t, k)
  end, p.nodes)
  return p
end

local function fresh_id(db, prefix)
  db.next_id = db.next_id + 1
  return ('FAKE_%s_%d'):format(prefix, db.next_id)
end

local function git(state, args)
  local res = vim.system(vim.list_extend({ 'git' }, args), { cwd = state.repo_dir, text = true }):wait()
  return res.code == 0 and (res.stdout or '') or nil
end

--- Real `git diff -U0 -M merge_base commitOID` hunks for `path` (`-U0`:
--- `model.anchor_valid` adds the ±3 context itself), or nil when
--- `state.repo_dir`/`state.merge_base` aren't configured.
local function validation_hunks(state, commit_oid, path)
  if not (state.repo_dir and state.merge_base) then
    return nil
  end
  local out = git(state, { 'diff', '-U0', '-M', state.merge_base, commit_oid })
  if not out then
    return nil, 'Path could not be resolved'
  end
  for _, f in ipairs(model.parse_diff_files(out)) do
    if f.old_path == path or f.new_path == path then
      return f.hunks
    end
  end
  return {}, nil -- unchanged file: no hunks, every line is "context"
end

--- GitHub accepts a changed line or ±3 context of `merge-base...commitOID`,
--- both sides; file-level is always valid. `true`, or `false, err`.
--- Always valid when the state has no repo configured.
local function validate(state, commit_oid, path, side, start_line, end_line)
  if not side then
    return true
  end
  local hunks, path_err = validation_hunks(state, commit_oid, path)
  if hunks == nil then
    if path_err then
      return false, path_err
    end
    return true -- no repo configured: nothing to check against
  end
  if model.anchor_valid(hunks, side, start_line, end_line or start_line) then
    return true
  end
  return false, 'Line could not be resolved'
end

--- What a legacy `position` (1-based, below the file's first `@@`) points
--- at: `'LEFT', old_line` on a `-` line, else `'RIGHT', new_line`.
local function line_at_position(diff_lines, position)
  local pos, ol, nl = nil, nil, nil
  for _, line in ipairs(diff_lines) do
    local old_start, new_start = line:match('^@@ %-(%d+),?%d* %+(%d+)')
    if new_start then
      pos = pos and (pos + 1) or 0
      ol, nl = tonumber(old_start) - 1, tonumber(new_start) - 1
    elseif pos then
      pos = pos + 1
      local kind = line:sub(1, 1)
      if kind ~= '+' then
        ol = ol + 1
      end
      if kind ~= '-' then
        nl = nl + 1
      end
      if pos == position then
        if kind == '-' then
          return 'LEFT', ol
        end
        return 'RIGHT', nl
      end
    end
  end
  return nil
end

--- The side and line a legacy `position` on `path` meant, in
--- `git diff -U3 -M base commit`, or nil.
local function position_line(state, base, commit, path, position)
  local out = git(state, { 'diff', '-U3', '-M', base, commit })
  if not out then
    return nil
  end
  local lines = vim.split(out, '\n', { plain = true })
  local section
  for _, l in ipairs(lines) do
    local a, b = l:match('^diff %-%-git a/(.-) b/(.*)$')
    if a then
      if section then
        break
      end
      if a == path or b == path then
        section = {}
      end
    end
    if section then
      table.insert(section, l)
    end
  end
  if not section then
    return nil
  end
  return line_at_position(section, position)
end

--- Hunks of `path` in `git diff -U0 -M from to`.
local function track_hunks(state, from, to, path)
  local out = git(state, { 'diff', '-U0', '-M', from, to })
  if not out then
    return nil
  end
  for _, f in ipairs(model.parse_diff_files(out)) do
    if f.old_path == path or f.new_path == path then
      return f.hunks
    end
  end
  return {}
end

local function thread_node(id, path, side, first_comment)
  return { id = id, isResolved = false, isOutdated = false, path = path, diffSide = side, comments = { nodes = { first_comment } } }
end

--- A comment node as GitHub returns it.
local function comment_node(state, id, review_id, fields)
  local at = M.now(state)
  return vim.tbl_extend('force', {
    id = id,
    author = { login = state.viewer },
    createdAt = at,
    updatedAt = at,
    lastEditedAt = nil,
    includesCreatedEdit = false,
    state = 'PENDING',
    diffHunk = '',
    outdated = false,
    pullRequestReview = { id = review_id },
  }, fields)
end

--- The db, thread, index and node of comment `id`, or nil.
local function find_comment(state, id)
  for _, db in pairs(state._db or {}) do
    for ti, t in ipairs(db.threads) do
      for ci, c in ipairs(t.comments.nodes) do
        if c.id == id then
          return db, t, ci, c, ti
        end
      end
    end
  end
  return nil
end

--- The db and viewer whose pending review is `id`, or nil.
local function pending_review(state, id)
  for _, db in pairs(state._db or {}) do
    for viewer, p in pairs(db.pending) do
      if p.id == id then
        return db, viewer
      end
    end
  end
  return nil
end

local function pending_count(db, review_id)
  local n = 0
  for _, t in ipairs(db.threads) do
    for _, c in ipairs(t.comments.nodes) do
      if c.pullRequestReview and c.pullRequestReview.id == review_id and c.state == 'PENDING' then
        n = n + 1
      end
    end
  end
  return n
end

local function edit(state, c, body)
  c.body = body
  c.updatedAt = M.now(state)
  if c.state ~= 'PENDING' then
    c.lastEditedAt = c.updatedAt
    c.includesCreatedEdit = true
  end
end

--- Delete comment `id` as GitHub does: its thread goes once empty, and a
--- pending review goes with its last comment. Returns the review's
--- `{id, state, totalCount}`, or nil when there's no such comment.
local function delete(state, id)
  local db, t, ci, c, ti = find_comment(state, id)
  if not db then
    return nil
  end
  table.remove(t.comments.nodes, ci)
  if #t.comments.nodes == 0 then
    table.remove(db.threads, ti)
  end
  local review_id = c.pullRequestReview and c.pullRequestReview.id
  if c.state == 'PENDING' then
    local left = pending_count(db, review_id)
    if left == 0 then
      for viewer, p in pairs(db.pending) do
        if p.id == review_id then
          db.pending[viewer] = nil
        end
      end
    end
    return { id = review_id, state = 'PENDING', comments = { totalCount = left } }
  end
  return { id = review_id, state = 'COMMENTED', comments = { totalCount = 0 } }
end

--- A web edit of comment `id` (pending or published), as github.com makes it.
function M.edit_comment(state, id, body)
  local _, _, _, c = find_comment(state, id)
  assert(c, 'no comment ' .. id)
  edit(state, c, body)
end

--- A web deletion of comment `id`.
function M.delete_comment(state, id)
  assert(delete(state, id), 'no comment ' .. id)
end

--- Every comment node whose body starts with `prefix`, across PRs.
function M.comments(state, prefix)
  local out = {}
  for _, db in pairs(state._db or {}) do
    for _, t in ipairs(db.threads) do
      for _, c in ipairs(t.comments.nodes) do
        if c.body:sub(1, #prefix) == prefix then
          table.insert(out, c)
        end
      end
    end
  end
  return out
end

--- A push (force-push too) of `head` to PR `number`: every comment, pending
--- or published, not on `head` is remapped. Trackable ones get `commit =
--- head` and their line moved; the others keep their commit and go
--- outdated, with `line = null` when published and unchanged when pending.
function M.push(state, number, head)
  local db = db_for(state, number)
  for _, t in ipairs(db.threads) do
    for _, c in ipairs(t.comments.nodes) do
      local from = c.commit and c.commit.oid
      if from and from ~= head and c.line then
        local moved
        if t.diffSide == 'LEFT' then
          moved = validate(state, head, t.path, 'old', c.startLine or c.line, c.line) and c.line or nil
        else
          local hunks = track_hunks(state, from, head, t.path)
          moved = hunks and model.map_line(hunks, c.line)
          if moved and c.startLine then
            c.startLine = model.map_line(hunks, c.startLine) or c.startLine
          end
        end
        if moved then
          c.commit, c.line = { oid = head }, moved
        else
          c.outdated, t.isOutdated = true, true
          if c.state ~= 'PENDING' then
            c.line = nil
          end
        end
      end
    end
  end
  db.head = head
end

--- Build `{ transport = fun(query, variables, cb), pr_view = fun(root,
--- branch, cb) }` backed by `state`. Matches the query/mutation by a
--- distinctive substring of the exact shapes this codebase sends.
function M.new(state)
  state.viewer = state.viewer or 'diffy-test-user'
  local self = { state = state }

  -- `state.hold_answers`: GitHub has acted, the answer waits for `M.release_answers`
  local function answer(f)
    if state.hold_answers then
      state.held_answers = state.held_answers or {}
      table.insert(state.held_answers, f)
    else
      vim.schedule(f)
    end
  end
  local function respond(cb, data)
    data = vim.deepcopy(data)
    answer(function()
      cb(data, nil)
    end)
  end
  local function fail(cb, message)
    answer(function()
      cb(nil, message)
    end)
  end
  -- GraphQL errors, as `review/github.lua`'s transport reports them
  local function gql_error(cb, kind, message)
    fail(cb, vim.json.encode({ { type = kind, message = message } }))
  end
  local function not_found(cb, id)
    gql_error(cb, 'NOT_FOUND', ("Could not resolve to a node with the global id of '%s'."):format(tostring(id)))
  end

  -- `gh pr view <branch> --json number,title,url,state,baseRefName,headRefOid`
  local function pr_view(branch, cb)
    if state.offline then
      fail(cb, 'error connecting to api.github.com')
      return
    end
    local number = state.branches and state.branches[branch]
    if not number then
      vim.schedule(function()
        cb(nil, nil)
      end)
      return
    end
    local db = db_for(state, number)
    respond(cb, { number = number, title = db.title, url = URL:format(number), state = db.state, baseRefName = db.base, headRefOid = db.head })
  end
  self.pr_view = function(_root, branch, cb)
    if state.hold then
      state.held = state.held or {}
      table.insert(state.held, function()
        pr_view(branch, cb)
      end)
      return
    end
    pr_view(branch, cb)
  end

  local function db_by_pr(pr_id)
    for n, d in pairs(state._db or {}) do
      if d.id == pr_id then
        return d, n
      end
    end
    for n in pairs(state.reads or {}) do
      return db_for(state, n), n
    end
  end

  self.transport = function(query, variables, cb)
    if state.offline then
      fail(cb, 'error connecting to api.github.com')
      return
    end
    -- the mutations in the order they came, for tests of ordering
    local op = query:match('^%s*mutation[^{]*{%s*(%w+)%(')
    if op then
      state.calls = state.calls or {}
      table.insert(state.calls, op)
    end
    for name, message in pairs(state.fail or {}) do
      if op == name then
        fail(cb, message)
        return
      end
    end
    local k = variables.k

    if query:find('query DiffyRead(', 1, true) then
      local db = db_for(state, variables.n)
      local mine = db.pending[state.viewer]
      respond(cb, {
        viewer = { login = state.viewer },
        repository = {
          pullRequest = {
            id = db.id,
            number = variables.n,
            state = db.state,
            title = db.title,
            body = db.body,
            baseRefName = db.base,
            headRefOid = db.head,
            author = { login = 'diffy-fixture-author' },
            comments = page(db.conversation, k),
            reviews = page(db.reviews, k),
            pendingReviews = { nodes = mine and { { id = mine.id } } or {} },
            reviewThreads = threads_page(db, k),
          },
        },
      })
      return
    end

    for name, field in pairs({ DiffyConversation = 'comments', DiffyReviews = 'reviews', DiffyThreads = 'reviewThreads' }) do
      if query:find('query ' .. name .. '(', 1, true) then
        local db = db_for(state, variables.n)
        local conn
        if field == 'reviewThreads' then
          conn = threads_page(db, k, variables.after)
        else
          conn = page(field == 'comments' and db.conversation or db.reviews, k, variables.after)
        end
        respond(cb, { repository = { pullRequest = { [field] = conn } } })
        return
      end
    end

    if query:find('query DiffyThreadComments(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.id then
            respond(cb, { node = { comments = page(t.comments.nodes, k, variables.after) } })
            return
          end
        end
      end
      not_found(cb, variables.id)
      return
    end

    if query:find('query DiffyComment(', 1, true) then
      local _, _, _, c = find_comment(state, variables.id)
      if not c then
        not_found(cb, variables.id)
        return
      end
      respond(cb, { node = c })
      return
    end

    if query:find('query DiffyPendingReview(', 1, true) then
      local db = db_for(state, variables.n)
      local mine = db.pending[state.viewer]
      respond(cb, { repository = { pullRequest = { reviews = { nodes = mine and { { id = mine.id } } or {} } } } })
      return
    end

    if query:find('query DiffyRecentThreads(', 1, true) then
      local db = db_for(state, variables.n)
      local nodes = {}
      for i = math.max(1, #db.threads - 19), #db.threads do
        table.insert(nodes, thread_page(db.threads[i], 1))
      end
      respond(cb, { repository = { pullRequest = { reviewThreads = { nodes = nodes } } } })
      return
    end

    if query:find('updatePullRequestReviewComment(', 1, true) then
      local _, _, _, c = find_comment(state, variables.id)
      if not c then
        not_found(cb, variables.id)
        return
      end
      edit(state, c, variables.b)
      respond(cb, { updatePullRequestReviewComment = { pullRequestReviewComment = c } })
      return
    end

    if query:find('deletePullRequestReviewComment(', 1, true) then
      local review = delete(state, variables.id)
      if not review then
        not_found(cb, variables.id)
        return
      end
      respond(cb, { deletePullRequestReviewComment = { pullRequestReview = review } })
      return
    end

    if query:find('deletePullRequestReview(', 1, true) then
      local db, viewer = pending_review(state, variables.id)
      if not db then
        not_found(cb, variables.id)
        return
      end
      db.pending[viewer] = nil
      -- only this review's own comments go: a thread keeps its published ones
      for i = #db.threads, 1, -1 do
        local t = db.threads[i]
        local kept = {}
        for _, c in ipairs(t.comments.nodes) do
          if not (c.pullRequestReview and c.pullRequestReview.id == variables.id and c.state == 'PENDING') then
            table.insert(kept, c)
          end
        end
        t.comments.nodes = kept
        if #kept == 0 then
          table.remove(db.threads, i)
        end
      end
      respond(cb, { deletePullRequestReview = { clientMutationId = vim.NIL } })
      return
    end

    if query:find('addPullRequestReviewThreadReply(', 1, true) then
      local db = pending_review(state, variables.r)
      if not db then
        not_found(cb, variables.r)
        return
      end
      for _, t in ipairs(db.threads) do
        if t.id == variables.t then
          local first = t.comments.nodes[1]
          local c = comment_node(state, fresh_id(db, 'COMMENT'), variables.r, {
            body = variables.b,
            path = t.path,
            line = first.line,
            originalLine = first.originalLine,
            commit = first.commit,
            originalCommit = first.originalCommit,
          })
          table.insert(t.comments.nodes, c)
          respond(cb, { addPullRequestReviewThreadReply = { comment = c } })
          return
        end
      end
      not_found(cb, variables.t)
      return
    end

    if query:find('addPullRequestReviewComment(', 1, true) then
      local db = pending_review(state, variables.r)
      if not db then
        not_found(cb, variables.r)
        return
      end
      local side, line = 'RIGHT', nil
      if state.repo_dir and state.merge_base then
        side, line = position_line(state, state.merge_base, variables.c, variables.p, variables.pos)
        if not side then
          gql_error(cb, 'UNPROCESSABLE', 'Line could not be resolved')
          return
        end
      end
      local commit = variables.c
      if state.repo_dir and db.head and commit ~= db.head then
        local hunks = side == 'RIGHT' and track_hunks(state, commit, db.head, variables.p)
        if side == 'LEFT' or (hunks and line and model.map_line(hunks, line)) then
          commit = db.head
        end
      end
      local c = comment_node(state, fresh_id(db, 'COMMENT'), variables.r, {
        body = variables.b,
        path = variables.p,
        line = line,
        originalLine = line,
        commit = { oid = commit },
        originalCommit = { oid = variables.c },
      })
      local tnode = thread_node(fresh_id(db, 'THREAD'), variables.p, side, c)
      table.insert(db.threads, tnode)
      respond(cb, { addPullRequestReviewComment = { comment = c } })
      return
    end

    if query:find('addPullRequestReviewThread(', 1, true) then
      local db = pending_review(state, variables.r)
      if not db then
        not_found(cb, variables.r)
        return
      end
      local ok, err = validate(state, db.head, variables.p, variables.s == 'LEFT' and 'old' or 'new', variables.sl or variables.l, variables.l)
      if not ok then
        gql_error(cb, 'UNPROCESSABLE', err)
        return
      end
      local c = comment_node(state, fresh_id(db, 'COMMENT'), variables.r, {
        body = variables.b,
        path = variables.p,
        line = variables.l,
        originalLine = variables.l,
        startLine = variables.sl,
        originalStartLine = variables.sl,
        commit = { oid = db.head },
        originalCommit = { oid = db.head },
      })
      local tid = fresh_id(db, 'THREAD')
      table.insert(db.threads, thread_node(tid, variables.p, variables.s, c))
      respond(cb, { addPullRequestReviewThread = { thread = { id = tid, comments = { nodes = { c } } } } })
      return
    end

    if query:find('addPullRequestReview(', 1, true) then
      local db = db_by_pr(variables.pr)
      if db.pending[state.viewer] then
        gql_error(cb, 'UNPROCESSABLE', 'User can only have one pending review per pull request')
        return
      end
      for _, input in ipairs(variables.t or {}) do
        local ok, err = validate(state, variables.c, input.path, input.side and (input.side == 'LEFT' and 'old' or 'new'), input.startLine or input.line, input.line)
        if not ok then
          gql_error(cb, 'UNPROCESSABLE', err)
          return
        end
      end
      local review_id = fresh_id(db, 'REVIEW')
      if variables.e then
        -- an event submits at once, as GitHub does
        table.insert(db.reviews, {
          id = review_id,
          author = { login = state.viewer },
          state = REVIEW_STATES[variables.e],
          body = variables.b,
          submittedAt = M.now(state),
          commit = { oid = variables.c },
        })
        respond(cb, { addPullRequestReview = { pullRequestReview = { id = review_id } } })
        return
      end
      db.pending[state.viewer] = { id = review_id, commitOID = variables.c }
      for _, input in ipairs(variables.t or {}) do
        local c = comment_node(state, fresh_id(db, 'COMMENT'), review_id, {
          body = input.body,
          path = input.path,
          line = input.line,
          originalLine = input.line,
          startLine = input.startLine,
          originalStartLine = input.startLine,
          commit = { oid = variables.c },
          originalCommit = { oid = variables.c },
        })
        table.insert(db.threads, thread_node(fresh_id(db, 'THREAD'), input.path, input.side, c))
      end
      respond(cb, { addPullRequestReview = { pullRequestReview = { id = review_id } } })
      return
    end

    if query:find('submitPullRequestReview(', 1, true) then
      local db, viewer = pending_review(state, variables.r)
      if not db then
        not_found(cb, variables.r)
        return
      end
      local p = db.pending[viewer]
      db.pending[viewer] = nil
      local at = M.now(state)
      for _, t in ipairs(db.threads) do
        for _, c in ipairs(t.comments.nodes) do
          if c.pullRequestReview and c.pullRequestReview.id == p.id and c.state == 'PENDING' then
            c.state = 'SUBMITTED'
            c.updatedAt = at
          end
        end
      end
      table.insert(db.reviews, {
        id = p.id,
        author = { login = viewer },
        state = REVIEW_STATES[variables.e],
        body = variables.b,
        submittedAt = at,
        commit = { oid = p.commitOID },
      })
      respond(cb, { submitPullRequestReview = { pullRequestReview = { id = p.id } } })
      return
    end

    -- `resolveReviewThread(` is a suffix of `unresolveReviewThread(`
    local resolve_name = query:find('unresolveReviewThread(', 1, true) and 'unresolveReviewThread'
      or query:find('resolveReviewThread(', 1, true) and 'resolveReviewThread'
    if resolve_name then
      local resolved = resolve_name == 'resolveReviewThread'
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.t then
            t.isResolved = resolved
            respond(cb, { [resolve_name] = { thread = { isResolved = resolved } } })
            return
          end
        end
      end
      not_found(cb, variables.t)
      return
    end

    fail(cb, 'fake_github: unrecognized query:\n' .. query)
  end
  return self
end

--- Load a `gh api graphql --input -`-recorded JSON file (the whole
--- `{data=...}` response) as the read fixture for PR `number`. Returns
--- `state` (created if not given).
function M.load_fixture(path, number, state)
  state = state or {}
  state.reads = state.reads or {}
  local text = table.concat(vim.fn.readfile(path), '\n')
  state.reads[number] = vim.json.decode(text, { luanil = { object = true, array = true } }).data
  return state
end

--- Point `review/github.lua` at a fake backed by `state` (`{}`: no PRs).
--- Returns the fake.
function M.install(state)
  local fake = M.new(state)
  local github = require('diffy.review.github')
  github.transport = fake.transport
  github.pr_view = fake.pr_view
  return fake
end

--- Answer the `gh pr view` calls `state.hold` kept waiting, and stop holding.
function M.release(state)
  state.hold = false
  local held = state.held or {}
  state.held = {}
  for _, f in ipairs(held) do
    f()
  end
end

--- Deliver the answers `state.hold_answers` kept back, and stop holding.
function M.release_answers(state)
  state.hold_answers = false
  local held = state.held_answers or {}
  state.held_answers = {}
  for _, f in ipairs(held) do
    f()
  end
end

return M
