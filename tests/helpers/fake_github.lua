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
local model = require('diffy.review.model')

local M = {}

-- what a submitted review's `state` reads for each event
local REVIEW_STATES = { COMMENT = 'COMMENTED', APPROVE = 'APPROVED', REQUEST_CHANGES = 'CHANGES_REQUESTED' }

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
  if pr and pr.pendingReviews and pr.pendingReviews.nodes[1] then
    local pid = pr.pendingReviews.nodes[1].id
    db.pending[state.viewer] = { id = pid, commitOID = db.head }
    for _, t in ipairs(db.threads) do
      for _, c in ipairs(t.comments.nodes) do
        if c.pullRequestReview and c.pullRequestReview.id == pid then
          t._pending_review_id = pid
        end
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
  return { pageInfo = { hasNextPage = last < #nodes, endCursor = tostring(last) }, nodes = out }
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

--- Real `git diff -U0 -M merge_base commitOID` hunks for `path` (`-U0`:
--- `model.anchor_valid` adds the ±3 context itself), or nil when
--- `state.repo_dir`/`state.merge_base` aren't configured.
local function validation_hunks(state, commit_oid, path)
  if not (state.repo_dir and state.merge_base) then
    return nil
  end
  local res = vim
    .system({ 'git', 'diff', '-U0', '-M', state.merge_base, commit_oid }, { cwd = state.repo_dir, text = true })
    :wait()
  if res.code ~= 0 then
    return nil, 'Path could not be resolved'
  end
  local files = model.parse_diff_files(res.stdout or '')
  for _, f in ipairs(files) do
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

--- Inverse of `model.diff_position`: the new-side line `position` (1-based,
--- below the file's first `@@`) refers to.
local function line_at_position(diff_lines, position)
  local pos, nl = nil, nil
  for _, line in ipairs(diff_lines) do
    local new_start = line:match('^@@ %-%d+,?%d* %+(%d+)')
    if new_start then
      pos = pos and (pos + 1) or 0
      nl = tonumber(new_start) - 1
    elseif pos then
      pos = pos + 1
      if line:sub(1, 1) ~= '-' then
        nl = nl + 1
      end
      if pos == position then
        return nl
      end
    end
  end
  return nil
end

--- The new-side line a legacy `position` on `path` meant, in
--- `git diff -U3 -M base commit`, or nil.
local function position_line(repo_dir, base, commit, path, position)
  local res = vim.system({ 'git', 'diff', '-U3', '-M', base, commit }, { cwd = repo_dir, text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local lines = vim.split(res.stdout or '', '\n', { plain = true })
  local start_i
  for i, l in ipairs(lines) do
    if l:match('^diff %-%-git') then
      if start_i then
        break
      end
      local a, b = l:match('^diff %-%-git a/(.-) b/(.*)$')
      if a == path or b == path then
        start_i = i
      end
    end
  end
  if not start_i then
    return nil
  end
  local section = {}
  for i = start_i, #lines do
    if i > start_i and lines[i]:match('^diff %-%-git') then
      break
    end
    table.insert(section, lines[i])
  end
  return line_at_position(section, position)
end

--- GitHub moves a legacy-position comment to head at once when its line is
--- trackable. Returns `head_sha, head_line`, else nil.
local function eager_remap(state, db, commit_oid, path, position)
  if not (state.repo_dir and db.head) or commit_oid == db.head then
    return nil
  end
  local orig_line = position_line(state.repo_dir, state.merge_base or commit_oid, commit_oid, path, position)
  if not orig_line then
    return nil
  end
  local track = vim.system({ 'git', 'diff', '-U0', '-M', commit_oid, db.head }, { cwd = state.repo_dir, text = true }):wait()
  if track.code ~= 0 then
    return nil
  end
  local files = model.parse_diff_files(track.stdout or '')
  local hunks = {}
  for _, f in ipairs(files) do
    if f.old_path == path or f.new_path == path then
      hunks = f.hunks
      break
    end
  end
  local mapped = model.map_line(hunks, orig_line)
  if not mapped then
    return nil
  end
  return db.head, mapped
end

local function thread_node(id, path, side, first_comment)
  return { id = id, isResolved = false, path = path, diffSide = side, comments = { nodes = { first_comment } } }
end

--- Build `{ transport = fun(query, variables, cb), pr_view = fun(root,
--- branch, cb) }` backed by `state`. Matches the query/mutation by a
--- distinctive substring of the exact shapes this codebase sends.
function M.new(state)
  state.viewer = state.viewer or 'diffy-test-user'
  local self = { state = state }

  local function respond(cb, data)
    data = vim.deepcopy(data)
    vim.schedule(function()
      cb(data, nil)
    end)
  end
  local function fail(cb, message)
    vim.schedule(function()
      cb(nil, message)
    end)
  end

  -- `gh pr view <branch> --json number,url,state,baseRefName,headRefOid`
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
    respond(cb, { number = number, url = URL:format(number), state = db.state, baseRefName = db.base, headRefOid = db.head })
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

  self.transport = function(query, variables, cb)
    if state.offline then
      fail(cb, 'error connecting to api.github.com')
      return
    end
    local k = variables.k

    if query:find('query DiffyRead(', 1, true) then
      local db = db_for(state, variables.n)
      local pending_nodes = {}
      for _, p in pairs(db.pending) do
        for _, t in ipairs(db.threads) do
          if t._pending_review_id == p.id then
            for _, c in ipairs(t.comments.nodes) do
              if c.pullRequestReview and c.pullRequestReview.id == p.id then
                table.insert(pending_nodes, c)
              end
            end
          end
        end
      end
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
            pendingReviews = { nodes = db.pending[state.viewer] and { { id = db.pending[state.viewer].id, comments = { nodes = pending_nodes } } } or {} },
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
      fail(cb, 'no such thread')
      return
    end

    if query:find('deletePullRequestReview(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for viewer, p in pairs(db.pending) do
          if p.id == variables.id then
            db.pending[viewer] = nil
            -- GitHub deletes only this review's own comments: a thread with
            -- a surviving published comment keeps its id and other comments
            for i = #db.threads, 1, -1 do
              local t = db.threads[i]
              local kept = {}
              for _, c in ipairs(t.comments.nodes) do
                if not (c.pullRequestReview and c.pullRequestReview.id == p.id) then
                  table.insert(kept, c)
                end
              end
              t.comments.nodes = kept
              if t._pending_review_id == p.id then
                t._pending_review_id = nil
              end
              if #kept == 0 then
                table.remove(db.threads, i)
              end
            end
            respond(cb, { deletePullRequestReview = { clientMutationId = nil } })
            return
          end
        end
      end
      fail(cb, 'no such pending review')
      return
    end

    if query:find('addPullRequestReviewThreadReply(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.t then
            local id = fresh_id(db, 'COMMENT')
            table.insert(t.comments.nodes, {
              id = id,
              author = { login = state.viewer },
              body = variables.b,
              createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
              diffHunk = '',
              line = t.comments.nodes[1].line,
              originalLine = t.comments.nodes[1].originalLine,
              startLine = nil,
              originalStartLine = nil,
              commit = t.comments.nodes[1].commit,
              originalCommit = t.comments.nodes[1].originalCommit,
              pullRequestReview = { id = variables.r },
            })
            respond(cb, { addPullRequestReviewThreadReply = { comment = { id = id } } })
            return
          end
        end
      end
      fail(cb, 'no such thread')
      return
    end

    if query:find('addPullRequestReviewComment(', 1, true) then
      local db
      for _, d in pairs(state._db or {}) do
        for _, p in pairs(d.pending) do
          if p.id == variables.r then
            db = d
          end
        end
      end
      if not db then
        fail(cb, 'no such pending review')
        return
      end
      local orig_line
      if state.repo_dir and state.merge_base then
        orig_line = position_line(state.repo_dir, state.merge_base, variables.c, variables.p, variables.pos)
      end
      local ok, err = validate(state, variables.c, variables.p, 'new', orig_line, orig_line)
      if not ok then
        fail(cb, err)
        return
      end
      local id = fresh_id(db, 'COMMENT')
      local commit, line = variables.c, orig_line
      local remapped_commit, remapped_line = eager_remap(state, db, variables.c, variables.p, variables.pos)
      if remapped_commit then
        commit, line = remapped_commit, remapped_line
      end
      local first = {
        id = id,
        author = { login = state.viewer },
        body = variables.b,
        createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        diffHunk = '',
        line = line,
        originalLine = orig_line,
        startLine = nil,
        originalStartLine = nil,
        commit = { oid = commit },
        originalCommit = { oid = variables.c },
        pullRequestReview = { id = variables.r },
      }
      local tnode = thread_node(fresh_id(db, 'THREAD'), variables.p, 'RIGHT', first)
      tnode._pending_review_id = variables.r
      table.insert(db.threads, tnode)
      respond(cb, { addPullRequestReviewComment = { comment = { id = id } } })
      return
    end

    if query:find('addPullRequestReviewThread(', 1, true) then
      local db
      for _, d in pairs(state._db or {}) do
        for _, p in pairs(d.pending) do
          if p.id == variables.r then
            db = d
          end
        end
      end
      if not db then
        fail(cb, 'no such pending review')
        return
      end
      local id = fresh_id(db, 'COMMENT')
      local first = {
        id = id,
        author = { login = state.viewer },
        body = variables.b,
        createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        diffHunk = '',
        line = variables.l,
        originalLine = variables.l,
        startLine = variables.sl,
        originalStartLine = variables.sl,
        commit = { oid = db.head },
        originalCommit = { oid = db.head },
        pullRequestReview = { id = variables.r },
      }
      local tid = fresh_id(db, 'THREAD')
      local tnode = thread_node(tid, variables.p, variables.s, first)
      tnode._pending_review_id = variables.r
      table.insert(db.threads, tnode)
      respond(cb, { addPullRequestReviewThread = { thread = { id = tid } } })
      return
    end

    if query:find('addPullRequestReview(', 1, true) then
      local number
      for n, d in pairs(state._db or {}) do
        if d.id == variables.pr then
          number = n
        end
      end
      if not number then
        for n in pairs(state.reads or {}) do
          number = n
          break
        end
      end
      local db = db_for(state, number)
      for _, input in ipairs(variables.t or {}) do
        local ok, err = validate(state, variables.c, input.path, input.side and (input.side == 'LEFT' and 'old' or 'new'), input.startLine or input.line, input.line)
        if not ok then
          fail(cb, err)
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
          submittedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
          commit = { oid = variables.c },
        })
        respond(cb, { addPullRequestReview = { pullRequestReview = { id = review_id } } })
        return
      end
      db.pending[state.viewer] = { id = review_id, commitOID = variables.c }
      for _, input in ipairs(variables.t or {}) do
        local id = fresh_id(db, 'COMMENT')
        local first = {
          id = id,
          author = { login = state.viewer },
          body = input.body,
          createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
          diffHunk = '',
          line = input.line,
          originalLine = input.line,
          startLine = input.startLine,
          originalStartLine = input.startLine,
          commit = { oid = variables.c },
          originalCommit = { oid = variables.c },
          pullRequestReview = { id = review_id },
        }
        local tnode = thread_node(fresh_id(db, 'THREAD'), input.path, input.side, first)
        tnode._pending_review_id = review_id
        table.insert(db.threads, tnode)
      end
      -- GitHub creates a big review, then fails returning it (measured: 20
      -- threads fine, 35 RESOURCE_LIMITS_EXCEEDED with all 35 created)
      if #(variables.t or {}) > 30 then
        fail(cb, 'Resource limits for this query exceeded.')
        return
      end
      respond(cb, { addPullRequestReview = { pullRequestReview = { id = review_id } } })
      return
    end

    if query:find('submitPullRequestReview(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for viewer, p in pairs(db.pending) do
          if p.id == variables.r then
            db.pending[viewer] = nil
            for _, t in ipairs(db.threads) do
              if t._pending_review_id == p.id then
                t._pending_review_id = nil
                for _, c in ipairs(t.comments.nodes) do
                  if c.pullRequestReview and c.pullRequestReview.id == p.id then
                    c.pullRequestReview = { id = p.id }
                  end
                end
              end
            end
            table.insert(db.reviews, {
              id = p.id,
              author = { login = viewer },
              state = REVIEW_STATES[variables.e],
              body = variables.b,
              submittedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
              commit = { oid = p.commitOID },
            })
            respond(cb, { submitPullRequestReview = { pullRequestReview = { id = p.id } } })
            return
          end
        end
      end
      fail(cb, 'no such pending review')
      return
    end

    if query:find('unresolveReviewThread(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.t then
            t.isResolved = false
            respond(cb, { unresolveReviewThread = { thread = { isResolved = false } } })
            return
          end
        end
      end
      fail(cb, 'no such thread')
      return
    end

    if query:find('resolveReviewThread(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.t then
            t.isResolved = true
            respond(cb, { resolveReviewThread = { thread = { isResolved = true } } })
            return
          end
        end
      end
      fail(cb, 'no such thread')
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

return M
