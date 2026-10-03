-- GitHub review backend: the PR of the checked-out branch. Reads threads,
-- reviews, description and the viewer's pending review, and pushes/pulls/
-- submits your drafts, which live in the branch's one store
-- (`review/drafts.lua`). Placement is `review/track.lua`'s, as for every
-- thread.
local model = require('diffy.review.model')
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local drafts = require('diffy.review.drafts')
local track = require('diffy.review.track')
local prompt = require('diffy.prompt')

local M = {}

M.name = 'github'
M.capabilities = { resolve = true, suggestions = true, people = true }

local cached_author
local avatars = {} -- login -> avatar URL, from every read

--- Viewer's GitHub login, cached for the process lifetime (the read query
--- fills it too).
function M.author(_root)
  if cached_author then
    return cached_author
  end
  local res = vim.system({ 'gh', 'api', 'user', '-q', '.login' }, { text = true }):wait()
  cached_author = vim.trim((res.code == 0 and res.stdout) or 'unknown')
  return cached_author
end

function M.avatar_url(login)
  return avatars[login]
end

local function remember_avatar(actor)
  if actor and actor.login and actor.avatarUrl then
    avatars[actor.login] = actor.avatarUrl
  end
end

M.save = drafts.put
M.clear = drafts.clear

--- The agent's ticks in `review.md`, as without a PR.
function M.sync(session)
  require('diffy.review.local').sync(session)
end

-- ---------------------------------------------------------------------
-- transport: every gh request goes through `M.transport`. Tests replace
-- this field with `tests/helpers/fake_github.lua`'s function.

--- `gh api graphql --input -` with the request on stdin, which avoids `-f`
--- quoting issues with multi-line bodies. `cb(data, err)`: `data` is the
--- response's `.data` object on success.
function M.transport(query, variables, cb)
  local input = vim.json.encode({ query = query, variables = variables })
  return vim.system({ 'gh', 'api', 'graphql', '--input', '-' }, { stdin = input, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil, vim.trim((res.stderr ~= '' and res.stderr) or res.stdout or ('gh exited %d'):format(res.code)))
        return
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout or '', { luanil = { object = true, array = true } })
      if not ok then
        cb(nil, 'invalid JSON from `gh api graphql`')
        return
      end
      if decoded.errors then
        cb(nil, vim.json.encode(decoded.errors))
        return
      end
      cb(decoded.data, nil)
    end)
  end)
end

--- `gh pr view <branch>`: the PR gh finds for the branch (its upstream,
--- forks included). `cb(pr, err)`; `pr = { number, url, state, baseRefName,
--- headRefOid }`, both nil when the branch has no PR. Tests replace this
--- field along with `M.transport`.
function M.pr_view(root, branch, cb)
  local cmd = { 'gh', 'pr', 'view', branch, '--json', 'number,url,state,baseRefName,headRefOid' }
  local ok, err = pcall(run.run, cmd, {
    cwd = root,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        local msg = vim.trim(res.stderr or '')
        if msg:find('no pull requests found', 1, true) then
          cb(nil, nil)
        else
          cb(nil, msg ~= '' and msg or 'gh pr view failed')
        end
        return
      end
      local dok, pr = pcall(vim.json.decode, res.stdout or '', { luanil = { object = true, array = true } })
      cb(dok and pr or nil, not dok and 'invalid JSON from `gh pr view`' or nil)
    end,
  })
  if not ok then
    vim.schedule(function()
      cb(nil, tostring(err)) -- no gh
    end)
  end
end

-- ---------------------------------------------------------------------
-- read: the PR, its conversation, reviews and threads, every connection
-- paginated (`M.page_size` per page; tests lower it).

M.page_size = 100

local PAGE = 'pageInfo { hasNextPage endCursor }'
local CONVERSATION = 'nodes { author { login avatarUrl(size: 64) } body createdAt }'
local REVIEW = 'nodes { id author { login } state body submittedAt commit { oid } }'
local COMMENT = [[nodes {
  id author { login avatarUrl(size: 64) } body createdAt diffHunk
  line originalLine startLine originalStartLine
  commit { oid } originalCommit { oid } pullRequestReview { id }
}]]
local THREAD = ('nodes { id isResolved path diffSide comments(first: $k) { %s %s } }'):format(PAGE, COMMENT)

local READ_QUERY = ([[
query DiffyRead($o: String!, $r: String!, $n: Int!, $k: Int!) {
  viewer { login avatarUrl(size: 64) }
  repository(owner: $o, name: $r) {
    pullRequest(number: $n) {
      id number title body createdAt state baseRefName headRefOid
      author { login avatarUrl(size: 64) }
      comments(first: $k) { %s %s }
      reviews(first: $k) { %s %s }
      pendingReviews: reviews(states: [PENDING], first: 1) {
        nodes { id comments(first: 100) { nodes { id path line originalLine startLine originalStartLine body commit { oid } originalCommit { oid } } } }
      }
      reviewThreads(first: $k) { %s %s }
    }
  }
}
]]):format(PAGE, CONVERSATION, PAGE, REVIEW, PAGE, THREAD)

local function more_query(name, field, nodes)
  return ([[
query %s($o: String!, $r: String!, $n: Int!, $k: Int!, $after: String) {
  repository(owner: $o, name: $r) { pullRequest(number: $n) { %s(first: $k, after: $after) { %s %s } } }
}
]]):format(name, field, PAGE, nodes)
end

local MORE = {
  comments = more_query('DiffyConversation', 'comments', CONVERSATION),
  reviews = more_query('DiffyReviews', 'reviews', REVIEW),
  reviewThreads = more_query('DiffyThreads', 'reviewThreads', THREAD),
}

local MORE_THREAD_COMMENTS = ([[
query DiffyThreadComments($id: ID!, $k: Int!, $after: String) {
  node(id: $id) { ... on PullRequestReviewThread { comments(first: $k, after: $after) { %s %s } } }
}
]]):format(PAGE, COMMENT)

local function next_cursor(conn)
  return conn and conn.pageInfo and conn.pageInfo.hasNextPage and conn.pageInfo.endCursor or nil
end

--- Append the pages after `cursor` of a connection to `conn.nodes`.
--- `get(data)` finds the connection in a response. `cb(ok, err)`.
local function rest(query, vars, get, conn, cb)
  local cursor = next_cursor(conn)
  if not cursor then
    cb(true)
    return
  end
  M.transport(query, vim.tbl_extend('force', vars, { k = M.page_size, after = cursor }), function(data, err)
    local page = data and get(data)
    if not page then
      cb(false, err or 'unexpected response')
      return
    end
    vim.list_extend(conn.nodes, page.nodes)
    conn.pageInfo = page.pageInfo
    rest(query, vars, get, conn, cb)
  end)
end

--- Run `steps` (`fun(next)`) one after the other; `cb(ok, err)`.
local function chain(steps, cb)
  local i = 0
  local function go(ok, err)
    if ok == false then
      cb(false, err)
      return
    end
    i = i + 1
    if i > #steps then
      cb(true)
      return
    end
    steps[i](go)
  end
  go(true)
end

--- Everything the layer reads about PR `number` of `owner/name`.
--- `cb(read, err)`, `read = { pr = meta, nodes = raw reviewThreads nodes }`.
function M.fetch(owner, name, number, cb)
  local vars = { o = owner, r = name, n = number }
  M.transport(READ_QUERY, vim.tbl_extend('force', vars, { k = M.page_size }), function(data, err)
    local pr = data and data.repository and data.repository.pullRequest
    if not pr then
      cb(nil, err or ('PR #%d not found'):format(number))
      return
    end
    if data.viewer and data.viewer.login then
      cached_author = data.viewer.login
      remember_avatar(data.viewer)
    end
    local steps = {}
    for field, query in pairs(MORE) do
      table.insert(steps, function(next)
        rest(query, vars, function(d)
          return d.repository and d.repository.pullRequest and d.repository.pullRequest[field]
        end, pr[field], next)
      end)
    end
    -- thread comments page once every thread is listed
    table.insert(steps, function(next)
      local per_thread = {}
      for _, t in ipairs(pr.reviewThreads.nodes) do
        table.insert(per_thread, function(n2)
          rest(MORE_THREAD_COMMENTS, { id = t.id }, function(d)
            return d.node and d.node.comments
          end, t.comments, n2)
        end)
      end
      chain(per_thread, next)
    end)
    chain(steps, function(ok, perr)
      if not ok then
        cb(nil, perr)
        return
      end
      remember_avatar(pr.author)
      local meta = {
        id = pr.id,
        number = pr.number,
        state = pr.state,
        title = pr.title,
        body = pr.body,
        author = pr.author and pr.author.login,
        created_at = pr.createdAt,
        base = pr.baseRefName,
        head_sha = pr.headRefOid,
        conversation = {},
        reviews = {},
        pending = pr.pendingReviews.nodes[1],
      }
      for _, c in ipairs(pr.comments.nodes) do
        remember_avatar(c.author)
        table.insert(meta.conversation, { author = c.author and c.author.login, body = c.body, created_at = c.createdAt })
      end
      for _, rv in ipairs(pr.reviews.nodes) do
        table.insert(meta.reviews, {
          id = rv.id,
          author = rv.author and rv.author.login,
          state = rv.state,
          body = rv.body,
          submitted_at = rv.submittedAt,
          commit = rv.commit and rv.commit.oid,
        })
      end
      for _, t in ipairs(pr.reviewThreads.nodes) do
        for _, c in ipairs(t.comments.nodes) do
          remember_avatar(c.author)
        end
      end
      cb({ pr = meta, nodes = pr.reviewThreads.nodes }, nil)
    end)
  end)
end

--- `fetch` for the session's attached PR.
local function fetch_session(session, cb)
  local l = session.layer
  if not (l and l.repo) then
    cb(nil, 'no PR attached')
    return
  end
  M.fetch(l.repo.owner, l.repo.name, l.repo.number, cb)
end

--- Which of `shas` exist locally (a force-pushed-away commit may not).
--- `cb(exists)`, `exists[sha] == true` for present objects.
local function existing_shas(root, shas, cb)
  local uniq = {}
  for _, s in ipairs(shas) do
    if s then
      uniq[s] = true
    end
  end
  local list = {}
  for s in pairs(uniq) do
    table.insert(list, s)
  end
  if #list == 0 then
    cb({})
    return
  end
  vim.system(
    { 'git', 'cat-file', '--batch-check=%(objectname) %(objecttype)' },
    { cwd = root, stdin = table.concat(list, '\n') .. '\n', text = true },
    function(res)
      vim.schedule(function()
        local exists = {}
        for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
          local sha, kind = line:match('^(%x+) (%a+)')
          if sha and kind ~= 'missing' then
            exists[sha] = true
          end
        end
        cb(exists)
      end)
    end
  )
end

--- Source anchor: the first comment's `commit`/`line` if that commit exists
--- locally, else `originalCommit`/`originalLine`, else `nil` (the thread is
--- then only listed by `:Diffy threads`).
--- GitHub reports old-side lines relative to the merge-base whichever commit
--- is picked, so tracking always starts from merge-base.
local function source_anchor(first, exists)
  local commit, line, start_line = first.commit and first.commit.oid, first.line, first.startLine
  if commit and exists[commit] and line then
    return commit, start_line or line, line
  end
  local ocommit, oline, ostart = first.originalCommit and first.originalCommit.oid, first.originalLine, first.originalStartLine
  if ocommit and exists[ocommit] then
    return ocommit, ostart or oline, oline
  end
  return nil
end

local function to_comment(c, state)
  return {
    id = c.id,
    author = c.author and c.author.login or 'unknown',
    body = c.body,
    created_at = c.createdAt,
    state = state,
  }
end

--- Build one `Thread` from a raw `reviewThreads` node. Comments belonging to
--- `pending_review_id` get `state = 'pending'`: GitHub already lists the
--- viewer's unsubmitted comments in `reviewThreads`, next to submitted ones.
local function build_thread(node, exists, pending_review_id)
  local comments = {}
  for _, c in ipairs(node.comments.nodes) do
    local pending = pending_review_id and c.pullRequestReview and c.pullRequestReview.id == pending_review_id
    table.insert(comments, to_comment(c, pending and 'pending' or 'published'))
  end
  local first = node.comments.nodes[1]
  local source_commit, start_line, end_line = source_anchor(first, exists)
  local side
  if first.line == nil and first.originalLine == nil then
    side = nil -- file-level: subjectType FILE, no line at all
  else
    side = node.diffSide == 'LEFT' and 'old' or 'new'
  end
  return {
    id = node.id,
    backend = 'github',
    review_id = first.pullRequestReview and first.pullRequestReview.id,
    resolved = node.isResolved,
    comments = comments,
    anchor = {
      path = node.path,
      side = side,
      start_line = start_line,
      end_line = end_line,
      commit = source_commit,
      excerpt = nil,
      base_relative = side == 'old' or nil,
    },
    outdated = false,
    _has_source = source_commit ~= nil,
    -- raw per-comment fields (originalCommit/originalLine/pullRequestReview),
    -- used by `M.pull` to rebuild original-anchored drafts.
    _raw_comments = node.comments.nodes,
  }
end

--- Where `thread` shows in the session's current pair/file, or `nil`.
function M.place(session, thread)
  return track.place(session, thread, session.file_pair or session.pair, session.current_path)
end

--- Where `thread` shows in `pair` (default: the current one), whichever
--- file is open, or nil.
function M.view_place(session, thread, pair)
  return track.place(session, thread, pair or session.pair)
end

--- Every commit (by subject, newest first) `thread` is visible in, plus
--- `'head'` for the full-PR view. Used by `:Diffy threads`.
function M.visible_in(session, thread)
  local review = session.review
  local out = {}
  if track.place(session, thread, { left = review.merge_base, right = session.head_sha }) then
    table.insert(out, 'head')
  end
  for _, e in ipairs(session.entries) do
    if e.kind == 'commit' and not e.merge then
      if track.place(session, thread, { left = e.sha .. '^', right = e.sha }) then
        table.insert(out, e.sha:sub(1, 7))
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------
-- the layer: attaches the branch's open PR to a `:Diffy`/`:Diffy branch`
-- session. `session.layer`: { attached, offline, cache, repo = {owner, name,
-- number}, standing, reach (review commit -> in the branch), reading,
-- queued, waiting (callbacks), read_at, timer }.

local function options()
  local c = require('diffy').config.github
  return c ~= false and (type(c) == 'table' and c or {}) or nil
end

--- Whether `session` gets a layer at all.
function M.enabled(session)
  local kind = session.range and session.range.kind
  return options() ~= nil and (kind == 'default' or kind == 'branch')
end

local function layer(session)
  session.layer = session.layer or { waiting = {} }
  return session.layer
end

--- The last read of `session`'s branch, from threads.json, or nil.
function M.load_cache(gitdir, branch)
  local data = require('diffy.review.store').load(drafts.path(gitdir, branch))
  return data and type(data.github) == 'table' and data.github.pr and data.github or nil
end

local function save_cache(session, cache)
  require('diffy.review.store').update(drafts.path(session.gitdir, session.branch), function(data)
    data.github = cache
  end)
end

local function repo_of(pr)
  local owner, name = (pr.url or ''):match('github%.com/([^/]+)/([^/]+)/pull/')
  return owner and { owner = owner, name = name, number = pr.number } or nil
end

--- Where the branch stands against the PR head (`2 unpushed`, `behind 1`,
--- `diverged`, `GitHub has newer commits`, nil when in sync), and for each
--- review commit whether the branch contains it. `cb()`.
local function measure(session, cb)
  local l = session.layer
  local pr = l.cache.pr
  local function git(args, on_exit)
    run.git(args, { cwd = session.root, session = session, notify_on_error = false, on_exit = on_exit })
  end
  local commits = {}
  for _, rv in ipairs(pr.reviews or {}) do
    if rv.commit and not vim.tbl_contains(commits, rv.commit) then
      table.insert(commits, rv.commit)
    end
  end
  local reach = {}
  local i = 0
  local function next_reach()
    i = i + 1
    if i > #commits then
      l.reach = reach
      cb()
      return
    end
    git({ 'merge-base', '--is-ancestor', commits[i], session.branch }, function(res)
      reach[commits[i]] = res.code == 0
      next_reach()
    end)
  end
  git({ 'rev-list', '--left-right', '--count', pr.head_sha .. '...' .. session.branch }, function(res)
    if res.code ~= 0 then
      -- the PR head isn't a local commit: diffy never fetches
      l.standing = 'GitHub has newer commits'
    else
      local behind, ahead = (res.stdout or ''):match('(%d+)%s+(%d+)')
      behind, ahead = tonumber(behind) or 0, tonumber(ahead) or 0
      if behind > 0 and ahead > 0 then
        l.standing = 'diverged'
      elseif ahead > 0 then
        l.standing = ('%d unpushed'):format(ahead)
      elseif behind > 0 then
        l.standing = ('behind %d'):format(behind)
      else
        l.standing = nil
      end
    end
    next_reach()
  end)
end

--- What a rebuild redoes for an attached layer: the PR row's standing and
--- review reach. `cb()`.
function M.remeasure(session, cb)
  if session.layer and session.layer.attached then
    measure(session, cb)
  else
    cb()
  end
end

local function finish_read(session)
  local l = session.layer
  l.reading = false
  l.read_at = vim.uv.now()
  if l.queued then
    l.queued = false
    M.read(session)
    return
  end
  local waiting = l.waiting
  l.waiting = {}
  for _, cb in ipairs(waiting) do
    cb()
  end
  run.ready({ session = session.id, event = 'pr' })
end

--- Redraw the log (PR row, markers) and the threads.
local function redraw(session, cb)
  track.prepare(session, function()
    require('diffy.panels.log').apply_layer(session)
    require('diffy.review.ui').decorate(session)
    cb()
  end)
end

--- Attach (or refresh) the layer from `cache`: the PR row, markers and the
--- published threads, placed with your drafts. A different PR base than the
--- one `:Diffy branch` guessed rebuilds once on it. `cb()`.
local function attach(session, cache, offline, cb)
  local l = layer(session)
  local review = require('diffy.review.ui').ensure(session)
  if not review then
    cb()
    return
  end
  local root = session.root
  repo.base_ref(root, cache.pr.base, function(base_ref)
    repo.merge_base(root, base_ref, session.head_sha, function(mb)
      local shas = {}
      for _, n in ipairs(cache.nodes or {}) do
        local first = n.comments.nodes[1]
        table.insert(shas, first and first.commit and first.commit.oid)
        table.insert(shas, first and first.originalCommit and first.originalCommit.oid)
      end
      existing_shas(root, shas, function(exists)
        if session.closed then
          return
        end
        l.attached, l.offline, l.cache = true, offline, cache
        l.repo = repo_of(cache.pr)
        local threads = {}
        local pending_id = cache.pr.pending and cache.pr.pending.id
        for _, n in ipairs(cache.nodes or {}) do
          if n.comments.nodes[1] then
            table.insert(threads, build_thread(n, exists, pending_id))
          end
        end
        drafts.apply(threads, drafts.attach(session).threads)
        review.backend = M
        review.threads = threads
        review.pr = cache.pr
        review.merge_base = mb
        measure(session, function()
          local range = session.range
          local entries = session.entries or {}
          if range.kind == 'branch' and not range.base and not l.rebased and mb and entries.base and mb ~= entries.base then
            l.rebased = true
            range.pr_base = base_ref
            require('diffy').build(session, cb)
            return
          end
          redraw(session, cb)
        end)
      end)
    end, session)
  end, session)
end

--- Drop the layer: the PR row, markers and published threads go, and the
--- cache with them when `drop_cache`. Your drafts stay. `cb()`.
local function detach(session, drop_cache, cb)
  local l = layer(session)
  if drop_cache and M.load_cache(session.gitdir, session.branch) then
    save_cache(session, nil)
  end
  l.cache = nil
  if not l.attached then
    cb()
    return
  end
  l.attached, l.offline, l.repo = false, false, nil
  local review = session.review
  if type(review) == 'table' then
    review.backend = require('diffy.review.local')
    review.pr, review.merge_base = nil, nil
    review.threads = {}
    drafts.apply(review.threads, drafts.attach(session).threads)
  end
  redraw(session, cb)
end

--- Read the PR again: `gh pr view` on the session's branch, then the whole
--- PR. One read at a time; a trigger during a read queues one more. A failed
--- read falls back to the cache (`offline`); a PR merged, closed or gone
--- detaches. `cb()` (optional) runs after the read and any queued one;
--- `DiffyReady` `pr` fires then.
function M.read(session, cb)
  local l = layer(session)
  if cb then
    table.insert(l.waiting, cb)
  end
  if l.reading then
    l.queued = true
    return
  end
  l.reading = true
  local function done()
    if not session.closed then
      finish_read(session)
    end
  end
  local function offline()
    local cache = l.cache or M.load_cache(session.gitdir, session.branch)
    if cache then
      attach(session, cache, true, done)
    else
      done()
    end
  end
  M.pr_view(session.root, session.branch, function(info, err)
    if session.closed then
      return
    end
    if err then
      offline()
      return
    end
    local where = info and info.state == 'OPEN' and repo_of(info)
    if not where then
      detach(session, true, done)
      return
    end
    M.fetch(where.owner, where.name, where.number, function(read, rerr)
      if session.closed then
        return
      end
      if not read then
        offline()
        return
      end
      if read.pr.state ~= 'OPEN' then
        detach(session, true, done)
        return
      end
      read.pr.url = info.url
      save_cache(session, read)
      attach(session, read, false, done)
    end)
  end)
end

--- Writes re-read once they land.
function M.refresh(session, cb)
  M.read(session, cb)
end

--- Start the layer on a freshly rendered session: the first read, then
--- reads on `FocusGained`, on entering the tab when the last read is older
--- than the interval, and every interval while the tab is current.
function M.start(session)
  local opts = options()
  if not M.enabled(session) or session.layer then
    return
  end
  layer(session)
  local interval = (opts.read_interval or 300) * 1000
  local function current()
    return not session.closed and vim.api.nvim_get_current_tabpage() == session.tab
  end
  vim.api.nvim_create_autocmd('FocusGained', {
    group = session.augroup,
    callback = function()
      if current() then
        M.read(session)
      end
    end,
  })
  if interval > 0 then
    vim.api.nvim_create_autocmd('TabEnter', {
      group = session.augroup,
      callback = function()
        local l = session.layer
        if current() and not l.reading and (not l.read_at or vim.uv.now() - l.read_at >= interval) then
          M.read(session)
        end
      end,
    })
    local timer = vim.uv.new_timer()
    session.layer.timer = timer
    timer:start(interval, interval, vim.schedule_wrap(function()
      if current() then
        M.read(session)
      end
    end))
  end
  M.read(session)
end

--- Teardown: stop the timer.
function M.stop(session)
  local timer = session.layer and session.layer.timer
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

-- ---------------------------------------------------------------------
-- writing: push/pull/submit, reply, resolve/unresolve.

local MUTATIONS = {
  delete_review = [[mutation($id: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $id}) { clientMutationId } }]],
  create_review = [[mutation($pr: ID!, $c: GitObjectID!, $t: [DraftPullRequestReviewThread]) { addPullRequestReview(input: {pullRequestId: $pr, commitOID: $c, threads: $t}) { pullRequestReview { id } } }]],
  add_comment = [[mutation($r: ID!, $c: GitObjectID!, $p: String!, $pos: Int!, $b: String!) { addPullRequestReviewComment(input: {pullRequestReviewId: $r, commitOID: $c, path: $p, position: $pos, body: $b}) { comment { id } } }]],
  add_thread = [[mutation($r: ID!, $p: String!, $l: Int!, $s: DiffSide!, $sl: Int, $ss: DiffSide, $b: String!) { addPullRequestReviewThread(input: {pullRequestReviewId: $r, path: $p, line: $l, side: $s, startLine: $sl, startSide: $ss, body: $b}) { thread { id } } }]],
  add_reply = [[mutation($r: ID!, $t: ID!, $b: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewId: $r, pullRequestReviewThreadId: $t, body: $b}) { comment { id } } }]],
  submit = [[mutation($r: ID!, $e: PullRequestReviewEvent!, $b: String) { submitPullRequestReview(input: {pullRequestReviewId: $r, event: $e, body: $b}) { pullRequestReview { id } } }]],
  review = [[mutation($pr: ID!, $c: GitObjectID!, $e: PullRequestReviewEvent!, $b: String) { addPullRequestReview(input: {pullRequestId: $pr, commitOID: $c, event: $e, body: $b}) { pullRequestReview { id } } }]],
  resolve = [[mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }]],
  unresolve = [[mutation($t: ID!) { unresolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }]],
}

--- Resolve/unresolve `thread` directly on GitHub; not part of the draft.
--- `cb(ok)`.
function M.resolve_thread(session, thread, resolved, cb)
  M.transport(resolved and MUTATIONS.resolve or MUTATIONS.unresolve, { t = thread.id }, function(data, err)
    if not data then
      vim.notify('diffy: ' .. tostring(err), vim.log.levels.WARN)
      cb(false)
      return
    end
    thread.resolved = resolved
    require('diffy.review.ui').decorate(session)
    cb(true)
  end)
end

local function raw_diff(root, extra_args, x, y, cb)
  local args = { 'diff', '-M' }
  vim.list_extend(args, extra_args)
  table.insert(args, x)
  table.insert(args, y)
  run.git(args, {
    cwd = root,
    notify_on_error = false,
    on_exit = function(res)
      cb(res.code == 0 and (res.stdout or '') or '')
    end,
  })
end

--- The raw lines of one file's section of a multi-file unified diff (from
--- `diff --git a/X b/Y` up to the next such header), matching `path`
--- against either name.
local function slice_file_section(raw_text, path)
  local lines = vim.split(raw_text, '\n', { plain = true })
  local start_i
  for i, line in ipairs(lines) do
    local a, b = line:match('^diff %-%-git a/(.-) b/(.*)$')
    if a then
      if start_i then
        return vim.list_slice(lines, start_i, i - 1)
      end
      if a == path or b == path then
        start_i = i
      end
    end
  end
  if start_i then
    return vim.list_slice(lines, start_i, #lines)
  end
  return nil
end

--- `M.refresh`, then re-decorate. `cb()` as for `M.refresh`.
local function refresh_and_decorate(session, cb)
  M.refresh(session, function()
    if not session.closed then
      require('diffy.review.ui').decorate(session)
    end
    cb()
  end)
end

--- Runs the mutations for a validated push: delete any existing pending
--- review, create the primary batch, drafts on other commits, draft
--- replies, then drop every pushed draft comment from the store (the next
--- `M.refresh` re-fetches them from GitHub). `cb(ok)`.
local function push_execute(session, plan, cb)
  local review = session.review
  local root = session.root

  local function finish(ok)
    local pushed = {}
    for _, group in ipairs({ plan.primary_threads, plan.other_drafts, plan.replies, plan.followups or {} }) do
      for _, d in ipairs(group) do
        if d._pushed then
          table.insert(pushed, d.comment.id)
        end
      end
    end
    drafts.remove(session, pushed, { quiet = true })
    refresh_and_decorate(session, function()
      cb(ok)
    end)
  end

  --- Transport callback: marks `d` pushed or records a warning, then `next_fn()`.
  local function record_push(d, next_fn)
    return function(data, err)
      if data then
        d._pushed = true
      else
        table.insert(plan.warnings, d.thread.id .. ': ' .. tostring(err))
      end
      next_fn()
    end
  end

  local function push_replies(review_id)
    local i = 0
    local function next_reply()
      i = i + 1
      if i > #plan.replies then
        finish(true)
        return
      end
      local d = plan.replies[i]
      M.transport(MUTATIONS.add_reply, { r = review_id, t = d.reply_to or d.thread.id, b = d.comment.body }, record_push(d, next_reply))
    end
    next_reply()
  end

  -- Find the threads this push just created (matched by path, first body and
  -- line within the new pending review) so their follow-up drafts become replies.
  local function push_followups(review_id)
    local pending = {}
    for _, f in ipairs(plan.followups or {}) do
      if f.root._pushed then
        table.insert(pending, f)
      end
    end
    if #pending == 0 then
      push_replies(review_id)
      return
    end
    fetch_session(session, function(read, rerr)
      local nodes = read and read.nodes
      do
        if not nodes then
          for _, f in ipairs(pending) do
            table.insert(plan.warnings, f.thread.id .. ": couldn't read the pushed threads: " .. tostring(rerr))
          end
          push_replies(review_id)
          return
        end
        -- Identical bodies on one file are common ("nit"): the line tells them
        -- apart, and a node taken by one root can't be another's.
        local taken = {}
        for _, f in ipairs(pending) do
          if not f.root._reply_to then
            local path = plan.head_path(f.thread.anchor.path)
            local line = f.root._gh_line or f.root._end_line
            for _, n in ipairs(nodes) do
              local first = n.comments.nodes[1]
              if not taken[n.id] and n.path == path and first and first.body == f.root.comment.body
                and first.originalLine == line
                and first.pullRequestReview and first.pullRequestReview.id == review_id then
                taken[n.id] = true
                f.root._reply_to = n.id
                break
              end
            end
          end
          f.reply_to = f.root._reply_to
          if f.reply_to then
            table.insert(plan.replies, f)
          else
            table.insert(plan.warnings, f.thread.id .. ": couldn't find the pushed thread to reply to")
          end
        end
        push_replies(review_id)
      end
    end)
  end

  local function push_other(review_id)
    local i = 0
    local function next_other()
      i = i + 1
      if i > #plan.other_drafts then
        push_followups(review_id)
        return
      end
      local d = plan.other_drafts[i]
      local anchor = d.thread.anchor
      if d._line == d._end_line then
        raw_diff(root, { '-U3' }, review.merge_base, d._commit, function(raw)
          local section = slice_file_section(raw, anchor.path)
          local pos = section and model.diff_position(section, d._line)
          if not pos then
            table.insert(plan.warnings, d.thread.id .. ": couldn't compute a diff position")
            next_other()
            return
          end
          M.transport(MUTATIONS.add_comment, {
            r = review_id,
            c = d._commit,
            p = plan.head_path(anchor.path),
            pos = pos,
            b = d.comment.body,
          }, record_push(d, next_other))
        end)
      else
        raw_diff(root, { '-U0' }, d._commit, session.head_sha, function(traw)
          local _, thunks = model.diff_file_hunks(model.parse_diff_files(traw), anchor.path)
          local hs, he = model.map_range(thunks, d._line, d._end_line)
          if not hs then
            table.insert(plan.warnings, d.thread.id .. ": multi-line comment on another commit couldn't be tracked to HEAD")
            next_other()
            return
          end
          d._gh_line = he
          M.transport(MUTATIONS.add_thread, {
            r = review_id,
            p = plan.head_path(anchor.path),
            l = he,
            s = 'RIGHT',
            sl = hs ~= he and hs or nil,
            ss = hs ~= he and 'RIGHT' or nil,
            b = d.comment.body,
          }, record_push(d, next_other))
        end)
      end
    end
    next_other()
  end

  local function create_primary()
    local threads_input = {}
    for _, d in ipairs(plan.primary_threads) do
      local anchor = d.thread.anchor
      local input = {
        path = plan.head_path(anchor.path),
        body = d.comment.body,
        side = anchor.side == 'old' and 'LEFT' or 'RIGHT',
        line = d._end_line,
      }
      if d._line ~= d._end_line then
        input.startLine = d._line
        input.startSide = input.side
      end
      table.insert(threads_input, input)
    end
    local function created(review_id)
      for _, d in ipairs(plan.primary_threads) do
        d._pushed = true
      end
      push_other(review_id)
    end
    M.transport(MUTATIONS.create_review, { pr = plan.pr_id, c = plan.primary_commit, t = threads_input }, function(data, err)
      if data then
        created(data.addPullRequestReview.pullRequestReview.id)
        return
      end
      -- A big review (35 threads) creates the review and every thread, then
      -- fails resolving the returned review with RESOURCE_LIMITS_EXCEEDED:
      -- check what landed before calling it a failure.
      do
        local function failed()
          vim.notify('diffy: push failed - ' .. tostring(err), vim.log.levels.ERROR)
          -- the next push must see, and replace, whatever half-landed
          M.refresh(session, function()
            cb(false)
          end)
        end
        fetch_session(session, function(read)
          local pending = read and read.pr.pending
          local landed = pending and #pending.comments.nodes or 0
          if pending and landed == math.min(#threads_input, 100) then
            created(pending.id)
          else
            failed()
          end
        end)
      end
    end)
  end

  if #plan.primary_threads + #plan.other_drafts + #plan.replies == 0 then
    finish(true)
    return
  end
  if plan.pending_review_id then
    M.transport(MUTATIONS.delete_review, { id = plan.pending_review_id }, function(_, err)
      if err then
        vim.notify('diffy: push failed - ' .. tostring(err), vim.log.levels.ERROR)
        cb(false)
        return
      end
      create_primary()
    end)
  else
    create_primary()
  end
end

-- Deleting the pending review removes its own comments but not published
-- ones. So a thread with no published comment (a new `t<N>` draft, or one
-- imported by `:Diffy review pull`) is gone after that delete and must be
-- recreated; a thread with a published root keeps its id and just gets
-- `addPullRequestReviewThreadReply`. Later drafts on a recreated thread
-- are replies to it (`followups`); its id is only known afterwards.
local function classify_drafts(threads)
  local roots, replies, followups = {}, {}, {}
  for _, t in ipairs(threads) do
    local has_published = false
    for _, c in ipairs(t.comments) do
      if c.state == 'published' then
        has_published = true
      end
    end
    local root_draft
    for i, c in ipairs(t.comments) do
      if c.state == 'draft' then
        if i == 1 and not has_published then
          root_draft = { thread = t, comment = c }
          table.insert(roots, root_draft)
        elseif has_published then
          table.insert(replies, { thread = t, comment = c })
        elseif root_draft then
          table.insert(followups, { thread = t, comment = c, root = root_draft })
        end
      end
    end
  end
  return roots, replies, followups
end

--- Split validated root drafts: invalid ones go to `warnings`; old-side
--- ones and new-side ones on the commit holding the most drafts
--- (`primary`, default `head_sha`) form the initial review batch, the rest
--- are `other_drafts`.
local function partition_roots(roots, head_sha, warnings)
  local new_side, old_side = {}, {}
  for _, d in ipairs(roots) do
    if d._invalid then
      table.insert(warnings, ('%s: %s'):format(d.thread.id, d._invalid))
    elseif d.thread.anchor.side == 'old' then
      table.insert(old_side, d)
    else
      new_side[d._commit] = new_side[d._commit] or {}
      table.insert(new_side[d._commit], d)
    end
  end
  local primary, best = head_sha, -1
  for c, list in pairs(new_side) do
    if #list > best then
      primary, best = c, #list
    end
  end
  local primary_threads = {}
  vim.list_extend(primary_threads, old_side)
  local other_drafts = {}
  for c, list in pairs(new_side) do
    if c == primary then
      vim.list_extend(primary_threads, list)
    else
      vim.list_extend(other_drafts, list)
    end
  end
  return primary, primary_threads, other_drafts
end

--- `:Diffy review push`: recreate the viewer's pending review from local
--- drafts (`state == 'draft'` comments are the source of truth).
--- GitHub rejects the whole review if one thread is invalid, so every draft
--- is validated against the `merge-base...C` diff (and old-side anchors
--- tracked from `C^` to merge-base) before any API call. A draft failing
--- either check stays local with a warning. `cb(ok, warnings)`.
function M.push(session, cb)
  local review = session.review
  if not (review and review.pr) then
    vim.notify('diffy: nothing to push - the branch has no open PR', vim.log.levels.WARN)
    cb(false, {})
    return
  end
  local root = session.root
  local merge_base = review.merge_base
  local head_sha = session.head_sha

  local roots, replies, followups = classify_drafts(review.threads)
  if #roots == 0 and #replies == 0 then
    vim.notify('diffy: no drafts to push')
    cb(true, {})
    return
  end

  local warnings = {}
  local diff_cache = {}
  local function commit_diff(c, cb2)
    if diff_cache[c] then
      cb2(diff_cache[c])
      return
    end
    -- `-U0`: `model.anchor_valid` adds the ±3 context window itself and
    -- expects hunks bounded to exactly the changed lines.
    raw_diff(root, { '-U0' }, merge_base, c, function(raw)
      local entry = { files = model.parse_diff_files(raw), raw = raw }
      diff_cache[c] = entry
      cb2(entry)
    end)
  end

  run.git({ 'diff', '-z', '-M', '--name-status', merge_base, head_sha }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      local rename_map = {}
      if res.code == 0 then
        for _, rec in ipairs(parse.name_status(res.stdout or '')) do
          if rec.status == 'R' then
            rename_map[rec.old_path] = rec.path
          end
        end
      end
      local function head_path(path)
        return rename_map[path] or path
      end

      local function after_validate()
        local primary, primary_threads, other_drafts = partition_roots(roots, head_sha, warnings)
        push_execute(session, {
          pr_id = review.pr.id,
          pending_review_id = review.pr.pending and review.pr.pending.id,
          primary_commit = primary,
          primary_threads = primary_threads,
          other_drafts = other_drafts,
          replies = replies,
          followups = followups,
          head_path = head_path,
          warnings = warnings,
        }, function(ok)
          cb(ok, warnings)
        end)
      end

      if #roots == 0 then
        after_validate()
        return
      end
      local remaining = #roots
      for _, d in ipairs(roots) do
        local anchor = d.thread.anchor
        local c = anchor.commit
        if anchor.side == 'old' then
          -- the full-PR view's left side is the merge-base itself
          c = anchor.commit == merge_base and head_sha or (anchor.commit:match('^(.+)%^$') or anchor.commit)
        end
        d._commit = c
        commit_diff(c, function(entry)
          local function done()
            remaining = remaining - 1
            if remaining == 0 then
              after_validate()
            end
          end
          if anchor.side == 'old' then
            raw_diff(root, { '-U0' }, anchor.commit, merge_base, function(traw)
              local mb_name, thunks = model.diff_file_hunks(model.parse_diff_files(traw), anchor.path)
              local mb_s, mb_e = model.map_range(thunks, anchor.start_line, anchor.end_line)
              if not mb_s then
                d._invalid = "old-side comment couldn't be tracked to the merge-base"
              else
                local _, vhunks = model.diff_file_hunks(entry.files, mb_name)
                if model.anchor_valid(vhunks, 'old', mb_s, mb_e) then
                  d._line, d._end_line = mb_s, mb_e
                else
                  d._invalid = 'line could not be resolved'
                end
              end
              done()
            end)
          else
            local _, vhunks = model.diff_file_hunks(entry.files, anchor.path, 'new')
            if model.anchor_valid(vhunks, 'new', anchor.start_line, anchor.end_line) then
              d._line, d._end_line = anchor.start_line, anchor.end_line
            else
              d._invalid = 'line could not be resolved'
            end
            done()
          end
        end)
      end
    end,
  })
end

--- `:Diffy review pull`: import the viewer's pending review into local
--- drafts, anchored at `originalCommit`/`originalLine` rather than the
--- live-tracked `commit`/`line`, so a later push recreates them faithfully.
--- Asks before replacing existing local drafts. `cb(ok)`.
function M.pull(session, cb)
  local review = session.review
  local pending = review and review.pr and review.pr.pending
  if not pending then
    vim.notify('diffy: no pending review to pull', vim.log.levels.WARN)
    cb(false)
    return
  end

  local imported, by_thread = {}, {}
  for _, t in ipairs(review.threads) do
    for _, c in ipairs(t._raw_comments or {}) do
      if c.pullRequestReview and c.pullRequestReview.id == pending.id then
        local entry = by_thread[t.id]
        if not entry then
          entry = {
            id = t.id,
            backend = 'github',
            anchor = {
              path = t.anchor.path,
              side = t.anchor.side,
              start_line = c.originalStartLine or c.originalLine,
              end_line = c.originalLine,
              commit = c.originalCommit and c.originalCommit.oid,
              excerpt = nil,
              base_relative = t.anchor.side == 'old' or nil,
            },
            comments = {},
            resolved = t.resolved,
          }
          by_thread[t.id] = entry
          table.insert(imported, entry)
        end
        table.insert(entry.comments, to_comment(c, 'draft'))
      end
    end
  end
  if #imported == 0 then
    vim.notify('diffy: the pending review has nothing importable', vim.log.levels.WARN)
    cb(false)
    return
  end

  local function apply()
    drafts.change(session, function(threads)
      for _, it in ipairs(imported) do
        local stored
        for _, s in ipairs(threads) do
          if s.id == it.id then
            stored = s
          end
        end
        if not stored then
          table.insert(threads, it)
        else
          stored.anchor = it.anchor
          for _, c in ipairs(it.comments) do
            local at = #stored.comments + 1
            for i, sc in ipairs(stored.comments) do
              if sc.id == c.id then
                at = i
              end
            end
            stored.comments[at] = c
          end
        end
      end
    end)
    vim.notify(('diffy: pulled %d thread(s) into local drafts'):format(#imported))
    cb(true)
  end

  if #drafts.attach(session).threads > 0 then
    prompt.confirm(session, {
      'Local drafts already exist for this PR and may differ from the',
      'pending review on GitHub. Replace them?',
    }, function(accepted)
      if accepted then
        apply()
      else
        cb(false)
      end
    end)
  else
    apply()
  end
end

--- Review events `:Diffy review submit` offers: GitHub refuses approving or
--- requesting changes on your own PR.
function M.verdicts(session)
  local pr = session.review and session.review.pr
  if pr and pr.author == M.author(session.root) then
    return { 'COMMENT' }
  end
  return { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }
end

--- `:Diffy review submit`: push the drafts, then submit the pending review
--- with `event`/`body`; with no drafts and no pending review, a review
--- with just `event`/`body` (approving without comments). The refresh at
--- the end reloads submitted comments as `published`. `cb(ok, warnings)`.
function M.submit(session, event, body, cb)
  local review = session.review
  local function done(warnings)
    return function(data, err)
      if not data then
        vim.notify('diffy: submit failed - ' .. tostring(err), vim.log.levels.ERROR)
        cb(false, warnings)
        return
      end
      refresh_and_decorate(session, function()
        cb(true, warnings)
      end)
    end
  end
  local function submit_pending(warnings)
    local pending = review.pr and review.pr.pending
    if pending then
      M.transport(MUTATIONS.submit, { r = pending.id, e = event, b = body }, done(warnings))
    else
      M.transport(MUTATIONS.review, { pr = review.pr.id, c = session.head_sha, e = event, b = body }, done(warnings))
    end
  end

  local roots, replies = classify_drafts(review and review.threads or {})
  if review and review.pr and #roots == 0 and #replies == 0 then
    submit_pending({})
    return
  end
  M.push(session, function(ok, warnings)
    if not ok then
      cb(false, warnings)
      return
    end
    submit_pending(warnings)
  end)
end

return M
