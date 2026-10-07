-- GitHub review backend: the PR of the checked-out branch. Reads threads,
-- reviews, description and the viewer's pending review; mirrors your drafts
-- (in the branch's one store, `review/drafts.lua`) into that pending review
-- in the background, and submits. Placement is `review/track.lua`'s, as for
-- every thread.
local model = require('diffy.review.model')
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local drafts = require('diffy.review.drafts')
local track = require('diffy.review.track')
local prompt = require('diffy.prompt')
local selection = require('diffy.selection')

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
--- forks included). `cb(pr, err)`; `pr = { number, title, url, state,
--- baseRefName, headRefOid }`, both nil when the branch has no PR. Tests
--- replace this field along with `M.transport`.
function M.pr_view(root, branch, cb)
  local cmd = { 'gh', 'pr', 'view', branch, '--json', 'number,title,url,state,baseRefName,headRefOid' }
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
  id author { login avatarUrl(size: 64) } body createdAt updatedAt lastEditedAt diffHunk
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
      pendingReviews: reviews(states: [PENDING], first: 1) { nodes { id } }
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

--- `fn(item, next)` on each of `list` in turn, then `done()`.
local function each(list, fn, done)
  local i = 0
  local function step()
    i = i + 1
    if i > #list then
      done()
      return
    end
    fn(list[i], step)
  end
  step()
end

--- Everything the layer reads about PR `number` of `owner/name`.
--- `cb(read, err)`, `read = { pr = meta, nodes = raw reviewThreads nodes }`.
local function fetch(owner, name, number, cb)
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
    last_edited_at = c.lastEditedAt,
    state = state,
  }
end

--- Build one `Thread` from a raw `reviewThreads` node, or nil when every
--- comment is in `mine` (GitHub ids of your mirrored drafts, which the store
--- shows instead). Other comments of `pending_review_id` (not adopted yet)
--- get `state = 'pending'`: GitHub lists the viewer's unsubmitted comments
--- in `reviewThreads`, next to submitted ones.
local function build_thread(node, exists, pending_review_id, mine)
  local comments = {}
  for _, c in ipairs(node.comments.nodes) do
    if not mine[c.id] then
      local pending = pending_review_id and c.pullRequestReview and c.pullRequestReview.id == pending_review_id
      table.insert(comments, to_comment(c, pending and 'pending' or 'published'))
    end
  end
  if #comments == 0 then
    return nil
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
    -- the first one's `diffHunk` and `originalCommit`: the code as written
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
      if track.place(session, thread, { left = selection.parent(e), right = e.sha }) then
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
  local reach, commits = {}, {}
  for _, rv in ipairs(pr.reviews or {}) do
    if rv.commit and reach[rv.commit] == nil then
      reach[rv.commit] = false
      table.insert(commits, rv.commit)
    end
  end
  -- independent reads: all at once, `cb` after the last
  local left = #commits + 1
  local function settle()
    left = left - 1
    if left == 0 then
      l.reach = reach
      cb()
    end
  end
  for _, sha in ipairs(commits) do
    git({ 'merge-base', '--is-ancestor', sha, session.branch }, function(res)
      reach[sha] = res.code == 0
      settle()
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
    settle()
  end)
end

--- What a rebuild redoes for an attached layer: the PR row's standing and
--- review reach, then a sync (a commit can make a draft mirrorable). `cb()`.
function M.remeasure(session, cb)
  if session.layer and session.layer.attached then
    measure(session, function()
      cb()
      M.mirror(session)
    end)
  else
    cb()
  end
end

--- Redraw the log, whose PR row shows the sync's state (`M.sync_status`).
local function redraw_row(session)
  if not session.closed and session.entries then
    require('diffy.panels.log').render(session)
  end
end

--- ms between two frames of the loading PR row's spinner
local SPIN_INTERVAL = 100

--- Show the loading PR row (`l.loading`) until the read finishes: the PR
--- exists, its read hasn't come back yet.
local function start_loading(session, info)
  local l = session.layer
  l.loading = { number = info.number, title = info.title, frame = 0 }
  l.spin_timer = l.spin_timer or vim.uv.new_timer()
  l.spin_timer:start(SPIN_INTERVAL, SPIN_INTERVAL, vim.schedule_wrap(function()
    if l.loading and not session.closed then
      l.loading.frame = l.loading.frame + 1
      redraw_row(session)
    end
  end))
  if not session.closed and session.entries then
    require('diffy.panels.log').apply_layer(session)
  end
end

local function finish_read(session)
  local l = session.layer
  l.reading = false
  if l.loading then
    l.loading = nil
    l.spin_timer:stop()
  end
  -- an attach already replaced the loading row; without one it goes here
  if not l.attached and session.entries and session.entries[1] and session.entries[1].loading then
    require('diffy.panels.log').apply_layer(session)
  else
    redraw_row(session)
  end
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

--- GitHub ids of your mirrored drafts, and of those you deleted that GitHub
--- still has: the store shows them, not the read.
local function mirrored_ids(session)
  local data = drafts.load(session)
  local out = {}
  for _, t in ipairs(data.threads) do
    for _, c in ipairs(t.comments) do
      if c.gh and c.state ~= 'published' then
        out[c.gh.id] = true
      end
    end
  end
  for _, d in ipairs(data.mirror.deleted) do
    out[d.id] = true
  end
  return out
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
        local mine = mirrored_ids(session)
        for _, n in ipairs(cache.nodes or {}) do
          local t = n.comments.nodes[1] and build_thread(n, exists, pending_id, mine)
          if t then
            table.insert(threads, t)
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
  redraw_row(session)
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
    if not l.attached then
      start_loading(session, info)
    end
    fetch(where.owner, where.name, where.number, function(read, rerr)
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
      M.reconcile(session, read)
      attach(session, read, false, function()
        done()
        M.mirror(session)
      end)
    end)
  end)
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

--- Teardown: stop the timers.
function M.stop(session)
  local l = session.layer or {}
  for _, timer in pairs({ read = l.timer, sync = l.sync_timer, spin = l.spin_timer }) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

-- ---------------------------------------------------------------------
-- background sync: your drafts mirrored into your pending review, one
-- comment at a time. It only writes to that review, which only you see:
-- replies, resolves and changes to published comments wait for `M.submit`.

--- ms between the last local change and the sync it schedules (tests lower it)
M.sync_delay = 2000

local SYNCED = 'id body updatedAt lastEditedAt'

local Q = {
  comment = ('query DiffyComment($id: ID!) { node(id: $id) { ... on PullRequestReviewComment { %s } } }'):format(SYNCED),
  pending = [[query DiffyPendingReview($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $n) { reviews(states: [PENDING], first: 1) { nodes { id } } } } }]],
  recent = [[query DiffyRecentThreads($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $n) { reviewThreads(last: 20) { nodes { id comments(first: 1) { nodes { id } } } } } } }]],
}

local MUTATIONS = {
  create_review = [[mutation($pr: ID!, $c: GitObjectID!) { addPullRequestReview(input: {pullRequestId: $pr, commitOID: $c}) { pullRequestReview { id } } }]],
  delete_review = [[mutation($id: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $id}) { clientMutationId } }]],
  add_comment = ([[mutation($r: ID!, $c: GitObjectID!, $p: String!, $pos: Int!, $b: String!) { addPullRequestReviewComment(input: {pullRequestReviewId: $r, commitOID: $c, path: $p, position: $pos, body: $b}) { comment { %s } } }]]):format(SYNCED),
  add_thread = ([[mutation($r: ID!, $p: String!, $l: Int!, $s: DiffSide!, $sl: Int, $ss: DiffSide, $b: String!) { addPullRequestReviewThread(input: {pullRequestReviewId: $r, path: $p, line: $l, side: $s, startLine: $sl, startSide: $ss, body: $b}) { thread { id comments(first: 1) { nodes { %s } } } } }]]):format(SYNCED),
  add_reply = ([[mutation($r: ID!, $t: ID!, $b: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewId: $r, pullRequestReviewThreadId: $t, body: $b}) { comment { %s } } }]]):format(SYNCED),
  update = ([[mutation($id: ID!, $b: String!) { updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $b}) { pullRequestReviewComment { %s } } }]]):format(SYNCED),
  delete = [[mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { pullRequestReview { id comments { totalCount } } } }]],
  submit = [[mutation($r: ID!, $e: PullRequestReviewEvent!, $b: String) { submitPullRequestReview(input: {pullRequestReviewId: $r, event: $e, body: $b}) { pullRequestReview { id } } }]],
  review = [[mutation($pr: ID!, $c: GitObjectID!, $e: PullRequestReviewEvent!, $b: String) { addPullRequestReview(input: {pullRequestId: $pr, commitOID: $c, event: $e, body: $b}) { pullRequestReview { id } } }]],
  resolve = [[mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }]],
  unresolve = [[mutation($t: ID!) { unresolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }]],
}

local function warn(msg)
  vim.notify('diffy: ' .. msg, vim.log.levels.WARN)
end

--- A write the sync couldn't do: noted, and the PR row says `sync failed`
--- until a sync goes through.
local function fail(notes, msg)
  table.insert(notes, msg)
  notes.failed = notes.failed or msg
end

local function is_not_found(err)
  return err ~= nil and tostring(err):find('Could not resolve to a node', 1, true) ~= nil
end

local function is_one_pending(err)
  return err ~= nil and tostring(err):find('one pending review per pull request', 1, true) ~= nil
end

--- Whether a `deletePullRequestReviewComment` answer says the review is now
--- empty: GitHub then deletes it, though the payload still says PENDING.
local function emptied(data)
  local r = data and data.deletePullRequestReviewComment and data.deletePullRequestReviewComment.pullRequestReview
  return r ~= nil and r.comments ~= nil and r.comments.totalCount == 0
end

local function first_line(body)
  return vim.split(body or '', '\n', { plain = true })[1]
end

--- The stored thread, comment and its index holding comment `id`.
local function find_comment(threads, id)
  for _, t in ipairs(threads) do
    for j, c in ipairs(t.comments) do
      if c.id == id then
        return t, c, j
      end
    end
  end
  return nil
end

local function remove_comment(t, id)
  for j = #t.comments, 1, -1 do
    if t.comments[j].id == id then
      table.remove(t.comments, j)
    end
  end
end

--- A sync's own write: it doesn't schedule another.
local function write(session, fn)
  return drafts.update(session, fn, { sync = true })
end

local function repo_vars(session)
  local r = session.layer.repo
  return { o = r.owner, r = r.name, n = r.number }
end

--- The github.com version of `c` (stored at index `j` of `t`), next to it.
local function add_web_copy(t, j, c, node)
  c.conflict = true
  table.insert(t.comments, j + 1, {
    id = model.new_id('c'),
    author = c.author,
    body = node.body,
    created_at = node.updatedAt or c.created_at,
    state = 'draft',
    origin = 'github.com',
    conflict_of = c.id,
    gh = { id = node.id, body = node.body, updated_at = node.updatedAt },
  })
end

--- Where a pending comment GitHub wrote on `node`'s first comment was.
local function anchor_of(node)
  local first = node.comments.nodes[1]
  local side = (first.line or first.originalLine) and (node.diffSide == 'LEFT' and 'old' or 'new') or nil
  return {
    path = node.path,
    side = side,
    start_line = first.originalStartLine or first.originalLine,
    end_line = first.originalLine,
    commit = first.originalCommit and first.originalCommit.oid,
    base_relative = side == 'old' or nil,
  }
end

local function same_place(a, b)
  return a.originalLine == b.originalLine
    and a.originalStartLine == b.originalStartLine
    and (a.originalCommit and a.originalCommit.oid) == (b.originalCommit and b.originalCommit.oid)
end

--- Bring the store in line with a fresh read: your pending review's
--- comments against your mirrored drafts (edits from github.com, deletions,
--- conflicts, comments diffy didn't write, which are adopted), and your
--- staged changes against the published comments they change.
function M.reconcile(session, read)
  local pid = read.pr.pending and read.pr.pending.id
  local pend, published, nodes, node_of = {}, {}, {}, {}
  for _, n in ipairs(read.nodes or {}) do
    nodes[n.id] = n
    for _, c in ipairs(n.comments.nodes) do
      node_of[c.id] = n
      if pid and c.pullRequestReview and c.pullRequestReview.id == pid then
        pend[c.id] = c
      else
        published[c.id] = c
      end
    end
  end
  local me = cached_author
  local notes, adopted, foreign = {}, 0, false
  write(session, function(data)
    local before = vim.deepcopy(data)
    local m = data.mirror
    foreign = pid ~= nil and m.review ~= pid
    m.review = pid
    -- a deleted thread takes your drafts on it along
    for _, t in ipairs(data.threads) do
      if t.github and not nodes[t.id] then
        for j = #t.comments, 1, -1 do
          local c = t.comments[j]
          if c.state == 'draft' then
            table.insert(notes, ('the thread of your draft reply was deleted, dropped: %s'):format(c.body))
            table.remove(t.comments, j)
          elseif c.state == 'published' then
            if c.staged_body then
              table.insert(notes, ('the thread of your staged edit was deleted, dropped: %s'):format(c.staged_body))
            end
            table.remove(t.comments, j)
          end
        end
        t.resolve_staged, t.retry = nil, nil
      end
    end
    local tracked, seen = {}, {}
    for _, t in ipairs(data.threads) do
      for j = #t.comments, 1, -1 do
        local c = t.comments[j]
        if c.gh and c.state ~= 'published' and not c.origin then
          local p = pend[c.gh.id]
          seen[c.gh.id] = true
          local web
          for _, o in ipairs(t.comments) do
            if o.conflict_of == c.id then
              web = o
            end
          end
          if published[c.gh.id] then
            -- submitted from elsewhere: GitHub's now
            remove_comment(t, c.id)
            if web then
              remove_comment(t, web.id)
            end
          elseif not p then
            -- gone from github.com: yours goes too, unless you edited it since
            if web then
              remove_comment(t, web.id)
            end
            if c.state == 'draft' and c.body == c.gh.body and not c.conflict then
              remove_comment(t, c.id)
            else
              c.gh, c.conflict = nil, nil
            end
          elseif web then
            web.body, web.gh = p.body, { id = p.id, body = p.body, updated_at = p.updatedAt }
          elseif p.updatedAt ~= c.gh.updated_at then
            if p.body == c.body or c.body == c.gh.body then
              c.body, c.gh = p.body, { id = p.id, body = p.body, updated_at = p.updatedAt }
            else
              add_web_copy(t, j, c, p)
              table.insert(notes, ('sync conflict, both versions kept: %s'):format(first_line(c.body)))
            end
          end
          if c.gh and pend[c.gh.id] then
            tracked[c.gh.id] = true
            local n = node_of[c.gh.id]
            if n.comments.nodes[1].id == c.gh.id and not t.github then
              t.gh_thread = n.id
            end
          end
        end
      end
    end
    for i = #m.deleted, 1, -1 do
      local d = m.deleted[i]
      local p = pend[d.id]
      if not p then
        table.remove(m.deleted, i)
      elseif p.updatedAt ~= d.updated_at then
        -- an edit beats a delete: adopted again below
        table.remove(m.deleted, i)
        table.insert(notes, ('a comment you deleted was edited on github.com, kept: %s'):format(first_line(p.body)))
      else
        seen[d.id] = true
      end
    end
    local function duplicate(c, n)
      for id in pairs(tracked) do
        local o, on = pend[id], node_of[id]
        if id ~= c.id and o.body == c.body and on.path == n.path then
          local roots = on.comments.nodes[1].id == id and n.comments.nodes[1].id == c.id
          if on == n or (roots and on.diffSide == n.diffSide and same_place(o, c)) then
            return true
          end
        end
      end
      return false
    end
    for _, n in ipairs(read.nodes or {}) do
      for _, c in ipairs(n.comments.nodes) do
        if pend[c.id] and not seen[c.id] then
          seen[c.id] = true
          if duplicate(c, n) then
            -- two nvims mirrored the same draft: one copy goes
            table.insert(m.deleted, { id = c.id, updated_at = c.updatedAt })
          else
            local on_published = false
            for _, o in ipairs(n.comments.nodes) do
              if published[o.id] then
                on_published = true
              end
            end
            local t
            if on_published then
              t = drafts.find(data.threads, n.id)
              if not t then
                t = { id = n.id, backend = 'github', github = true, anchor = anchor_of(n), resolved = n.isResolved, comments = {} }
                table.insert(data.threads, t)
              end
            else
              for _, s in ipairs(data.threads) do
                if s.gh_thread == n.id then
                  t = s
                end
              end
              if not t then
                t = { id = model.new_id('t'), backend = 'github', gh_thread = n.id, anchor = anchor_of(n), resolved = n.isResolved, comments = {} }
                table.insert(data.threads, t)
              end
            end
            table.insert(t.comments, {
              id = model.new_id('c'),
              author = c.author and c.author.login or me,
              body = c.body,
              created_at = c.createdAt,
              state = 'draft',
              gh = { id = c.id, body = c.body, updated_at = c.updatedAt },
            })
            tracked[c.id] = true
            adopted = adopted + 1
          end
        end
      end
    end
    for ti = #data.threads, 1, -1 do
      local t = data.threads[ti]
      local n = nodes[t.id]
      if n then
        for j = #t.comments, 1, -1 do
          local r = t.comments[j]
          if r.state == 'published' then
            local live = published[r.id]
            if not live then
              if r.staged_body then
                t.comments[j] = { id = model.new_id('c'), author = me, body = r.staged_body, created_at = os.time(), state = 'draft' }
                table.insert(notes, ('a comment you were editing was deleted on github.com; your edit is a draft reply now: %s'):format(first_line(r.staged_body)))
              else
                table.remove(t.comments, j)
              end
            elseif live.lastEditedAt ~= r.edited_at then
              if r.staged_delete then
                table.remove(t.comments, j)
                table.insert(notes, ('deletion cancelled, the comment was edited on github.com: %s'):format(first_line(live.body)))
              elseif not r.staged_conflict then
                r.staged_conflict = true
                table.insert(notes, ('your staged edit conflicts with an edit on github.com: %s'):format(first_line(live.body)))
              end
            end
          end
        end
      end
      if #t.comments == 0 and not t.resolve_staged then
        table.remove(data.threads, ti)
      end
    end
    if vim.deep_equal(before, data) then
      return false
    end
  end)
  if adopted > 0 and foreign then
    vim.notify(('diffy: adopted your pending review from GitHub (%d comment%s)'):format(adopted, adopted == 1 and '' or 's'))
  end
  for _, n in ipairs(notes) do
    warn(n)
  end
end

--- Per branch store: one sync at a time across the nvim's sessions on it.
local syncs = {} -- threads.json path -> { running, again, held, waiting }

local function sync_state(session)
  local p = drafts.path(session.gitdir, session.branch)
  syncs[p] = syncs[p] or { waiting = {} }
  return syncs[p]
end

-- No `session` for `run.git`: a sync outlives its session, or its branch's
-- sync slot stays taken and nothing mirrors again in this nvim.
local function git_cb(root, args, cb)
  run.git(args, { cwd = root, notify_on_error = false, on_exit = cb })
end

--- `git diff -M <context> x y`, run once per sync (`ctx.raw`).
local function raw_diff(ctx, context, x, y, cb)
  local key = ('%s %s %s'):format(context, x, y)
  if ctx.raw[key] then
    cb(ctx.raw[key])
    return
  end
  git_cb(ctx.session.root, { 'diff', '-M', context, x, y }, function(res)
    ctx.raw[key] = res.code == 0 and (res.stdout or '') or ''
    cb(ctx.raw[key])
  end)
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

--- `-U0` files of `merge-base...c`, once per sync.
local function mb_files(ctx, c, cb)
  if ctx.diffs[c] then
    cb(ctx.diffs[c])
    return
  end
  raw_diff(ctx, '-U0', ctx.mb, c, function(raw)
    ctx.diffs[c] = model.parse_diff_files(raw)
    cb(ctx.diffs[c])
  end)
end

--- `path` at the PR head (GitHub wants a renamed file's new name).
local function head_path(ctx, path, cb)
  if ctx.renames then
    cb(ctx.renames[path] or path)
    return
  end
  git_cb(ctx.session.root, { 'diff', '-z', '-M', '--name-status', ctx.mb, ctx.head }, function(res)
    ctx.renames = {}
    if res.code == 0 then
      for _, rec in ipairs(parse.name_status(res.stdout or '')) do
        if rec.status == 'R' then
          ctx.renames[rec.old_path] = rec.path
        end
      end
    end
    cb(ctx.renames[path] or path)
  end)
end

--- How GitHub can take the first draft of thread `t`: `cb(target)` with
--- `{ kind = 'thread', path, side, start, line }` (at the PR head) or
--- `{ kind = 'legacy', commit, path, pos }` (one line of an older commit),
--- else `cb(nil, why)`: 'worktree' (no commit), 'unpushed' (a commit GitHub
--- doesn't have), 'outside the diff' (beyond the changes and 3 lines of
--- context of merge-base...commit).
local function place_root(ctx, t, cb)
  local a = t.anchor
  if not a.commit or a.commit == 'worktree' or a.commit == 'index' then
    cb(nil, 'worktree')
    return
  end
  if not a.side then
    cb(nil, 'file comment')
    return
  end
  local old = a.side == 'old'
  local gh_side = old and 'LEFT' or 'RIGHT'
  local c = a.commit
  if old and not a.base_relative then
    -- the full view's left side is the merge-base itself
    c = c == ctx.mb and ctx.head or (c:match('^(.+)%^$') or c)
  end
  local function pushed(on_known)
    if ctx.pushed[c] ~= nil then
      on_known(ctx.pushed[c])
      return
    end
    git_cb(ctx.session.root, { 'merge-base', '--is-ancestor', c, ctx.head }, function(res)
      ctx.pushed[c] = res.code ~= 1
      on_known(ctx.pushed[c])
    end)
  end
  pushed(function(is_pushed)
    if not is_pushed then
      cb(nil, 'unpushed')
      return
    end
    -- `s`/`e`: lines of `c`'s new side, or of the merge-base for the old side
    local function with_lines(path, s, e)
      mb_files(ctx, c, function(files)
        local _, hunks = model.diff_file_hunks(files, path, not old and 'new' or nil)
        if not model.anchor_valid(hunks, a.side, s, e) then
          cb(nil, 'outside the diff')
          return
        end
        head_path(ctx, a.path, function(hp)
          if c == ctx.head then
            cb({ kind = 'thread', path = hp, side = gh_side, start = s, line = e })
            return
          end
          if s == e then
            raw_diff(ctx, '-U3', ctx.mb, c, function(raw)
              local section = slice_file_section(raw, a.path)
              local pos = section and model.diff_position(section, e, a.side)
              if pos then
                cb({ kind = 'legacy', commit = c, path = a.path, pos = pos })
              else
                cb(nil, 'outside the diff')
              end
            end)
            return
          end
          -- a legacy position is one line: a range on an older commit goes at head
          local function at_head(hs, he)
            mb_files(ctx, ctx.head, function(hfiles)
              local _, hh = model.diff_file_hunks(hfiles, old and path or hp, not old and 'new' or nil)
              if hs and model.anchor_valid(hh, a.side, hs, he) then
                cb({ kind = 'thread', path = hp, side = gh_side, start = hs, line = he })
              else
                cb(nil, 'outside the diff')
              end
            end)
          end
          if old then
            at_head(s, e)
            return
          end
          raw_diff(ctx, '-U0', c, ctx.head, function(traw)
            local _, th = model.diff_file_hunks(model.parse_diff_files(traw), a.path)
            at_head(model.map_range(th, s, e))
          end)
        end)
      end)
    end
    if old and not a.base_relative then
      raw_diff(ctx, '-U0', a.commit, ctx.mb, function(traw)
        local mb_name, th = model.diff_file_hunks(model.parse_diff_files(traw), a.path)
        local s, e = model.map_range(th, a.start_line, a.end_line)
        if not s then
          cb(nil, 'outside the diff')
        else
          with_lines(mb_name, s, e)
        end
      end)
    else
      with_lines(a.path, a.start_line, a.end_line)
    end
  end)
end

local function set_blocked(ctx, cid, why)
  write(ctx.session, function(data)
    local _, c = find_comment(data.threads, cid)
    if not c or c.blocked == why then
      return false
    end
    c.blocked = why
  end)
end

local function forget_review(session, id)
  write(session, function(data)
    if data.mirror.review ~= id then
      return false
    end
    data.mirror.review = nil
  end)
end

--- Take stored comment `c` out of the pending review. `cb(err)`: nil once
--- it's gone from GitHub.
local function unmirror(session, c, cb)
  M.transport(MUTATIONS.delete, { id = c.gh.id }, function(data, err)
    if not (data or is_not_found(err)) then
      cb(err)
      return
    end
    write(session, function(d)
      local _, sc = find_comment(d.threads, c.id)
      if sc then
        sc.gh = nil
      end
      if emptied(data) then
        d.mirror.review = nil
      end
    end)
    cb(nil)
  end)
end

--- The pending review to mirror into: the known one, else a new one, else
--- (another nvim or github.com made one meanwhile) the one GitHub has.
--- `cb(id)` or `cb(nil, err)`.
local function ensure_review(ctx, cb)
  local id = drafts.load(ctx.session).mirror.review
  if id then
    cb(id)
    return
  end
  local function keep(rid)
    write(ctx.session, function(data)
      data.mirror.review = rid
    end)
    cb(rid)
  end
  M.transport(MUTATIONS.create_review, { pr = ctx.pr.id, c = ctx.head }, function(data, err)
    local made = data and data.addPullRequestReview and data.addPullRequestReview.pullRequestReview
    if made then
      ctx.created = made.id
      keep(made.id)
      return
    end
    if not is_one_pending(err) then
      cb(nil, err)
      return
    end
    M.transport(Q.pending, repo_vars(ctx.session), function(d, perr)
      local pr = d and d.repository and d.repository.pullRequest
      local node = pr and pr.reviews.nodes[1]
      if not node then
        cb(nil, perr or err)
        return
      end
      ctx.adopted = true
      keep(node.id)
    end)
  end)
end

--- Mirror one draft (`it = { t, c, reply_to? }`) to `target`, then `next()`.
local function send(ctx, it, target, next, retried)
  ensure_review(ctx, function(review_id, rerr)
    if not review_id then
      fail(ctx.notes, ("couldn't create your pending review: %s"):format(tostring(rerr)))
      next()
      return
    end
    local body = it.c.body
    local function landed(x, gh_thread)
      ctx.landed = true
      local gh = { id = x.id, body = body, updated_at = x.updatedAt }
      write(ctx.session, function(data)
        local t, c = find_comment(data.threads, it.c.id)
        if not c then
          -- deleted while on its way
          table.insert(data.mirror.deleted, { id = gh.id, updated_at = gh.updated_at })
          return
        end
        c.gh, c.blocked = gh, nil
        if gh_thread and not t.github then
          t.gh_thread = gh_thread
        end
      end)
      next()
    end
    -- `err` nil: `addPullRequestReviewThread` answers a thread GitHub can't
    -- anchor with `thread: null` and no error
    local function failed(err)
      if err and is_not_found(err) and err:find(review_id, 1, true) and not retried then
        -- deleted with its last comment, or on github.com
        forget_review(ctx.session, review_id)
        send(ctx, it, target, next, true)
        return
      end
      if not err or err:find('thread position is invalid', 1, true) or err:find('thread path is invalid', 1, true) then
        set_blocked(ctx, it.c.id, 'outside the diff')
      else
        fail(ctx.notes, ("couldn't mirror a draft: %s"):format(err))
      end
      next()
    end
    if target.kind == 'reply' then
      M.transport(MUTATIONS.add_reply, { r = review_id, t = it.reply_to, b = body }, function(data, err)
        local x = data and data.addPullRequestReviewThreadReply and data.addPullRequestReviewThreadReply.comment
        if x then
          landed(x)
        else
          failed(err)
        end
      end)
    elseif target.kind == 'thread' then
      local range = target.start ~= target.line
      M.transport(MUTATIONS.add_thread, {
        r = review_id,
        p = target.path,
        l = target.line,
        s = target.side,
        sl = range and target.start or nil,
        ss = range and target.side or nil,
        b = body,
      }, function(data, err)
        local th = data and data.addPullRequestReviewThread and data.addPullRequestReviewThread.thread
        local x = th and th.comments.nodes[1]
        if x then
          landed(x, th.id)
        else
          failed(err)
        end
      end)
    else
      M.transport(MUTATIONS.add_comment, { r = review_id, c = target.commit, p = target.path, pos = target.pos, b = body }, function(data, err)
        local x = data and data.addPullRequestReviewComment and data.addPullRequestReviewComment.comment
        if not x then
          failed(err)
          return
        end
        -- the legacy mutation doesn't say which thread it made
        M.transport(Q.recent, repo_vars(ctx.session), function(rd)
          local pr = rd and rd.repository and rd.repository.pullRequest
          local tid
          for _, n in ipairs(pr and pr.reviewThreads.nodes or {}) do
            if n.comments.nodes[1] and n.comments.nodes[1].id == x.id then
              tid = n.id
            end
          end
          landed(x, tid)
        end)
      end)
    end
  end)
end

--- Mirrored drafts you deleted: out of the pending review, unless edited on
--- github.com since (an edit beats a delete; the next read adopts it).
local function sync_deleted(ctx, nx)
  each(drafts.load(ctx.session).mirror.deleted, function(d, next)
    local function forget(empty)
      write(ctx.session, function(data)
        for i = #data.mirror.deleted, 1, -1 do
          if data.mirror.deleted[i].id == d.id then
            table.remove(data.mirror.deleted, i)
          end
        end
        if empty then
          data.mirror.review = nil
        end
      end)
    end
    M.transport(Q.comment, { id = d.id }, function(data, err)
      local node = data and data.node
      if not node then
        if is_not_found(err) then
          forget(false)
        end
        next()
        return
      end
      if node.updatedAt ~= d.updated_at then
        forget(false)
        ctx.reread = true
        next()
        return
      end
      M.transport(MUTATIONS.delete, { id = d.id }, function(res, derr)
        if res or is_not_found(derr) then
          forget(emptied(res))
        end
        next()
      end)
    end)
  end, nx)
end

--- Drafts sent to the agent leave the pending review: each comment has one
--- destination.
local function sync_sent(ctx, nx)
  local list = {}
  for _, t in ipairs(drafts.load(ctx.session).threads) do
    for _, c in ipairs(t.comments) do
      if c.gh and c.state ~= 'draft' and c.state ~= 'published' then
        table.insert(list, c)
      end
    end
  end
  each(list, function(c, next)
    unmirror(ctx.session, c, next)
  end, nx)
end

--- Drafts edited since they were mirrored: re-read first; changed on
--- github.com too is a conflict (both kept), deleted there means yours is
--- mirrored again.
local function sync_edits(ctx, nx)
  local list = {}
  for _, t in ipairs(drafts.load(ctx.session).threads) do
    for _, c in ipairs(t.comments) do
      if c.state == 'draft' and c.gh and not c.conflict and not c.origin and c.body ~= c.gh.body then
        table.insert(list, c)
      end
    end
  end
  each(list, function(it, next)
    local function store_gh(gh)
      write(ctx.session, function(d)
        local _, c = find_comment(d.threads, it.id)
        if not c then
          return false
        end
        c.gh = gh
      end)
    end
    M.transport(Q.comment, { id = it.gh.id }, function(data, err)
      local node = data and data.node
      if not node then
        if is_not_found(err) then
          store_gh(nil)
        end
        next()
        return
      end
      if node.updatedAt ~= it.gh.updated_at and node.body ~= it.gh.body then
        write(ctx.session, function(d)
          local t, c, j = find_comment(d.threads, it.id)
          if not c then
            return false
          end
          if node.body == c.body then
            c.gh = { id = node.id, body = node.body, updated_at = node.updatedAt }
          else
            add_web_copy(t, j, c, node)
            table.insert(ctx.notes, ('sync conflict, both versions kept: %s'):format(first_line(c.body)))
          end
        end)
        next()
        return
      end
      M.transport(MUTATIONS.update, { id = it.gh.id, b = it.body }, function(res, uerr)
        local x = res and res.updatePullRequestReviewComment and res.updatePullRequestReviewComment.pullRequestReviewComment
        if x then
          store_gh({ id = x.id, body = it.body, updated_at = x.updatedAt })
        elseif is_not_found(uerr) then
          store_gh(nil)
        else
          fail(ctx.notes, ("couldn't update a mirrored draft: %s"):format(tostring(uerr)))
        end
        next()
      end)
    end)
  end, nx)
end

--- Drafts not mirrored yet: new threads where GitHub can take them, replies
--- once their thread is on GitHub.
local function sync_new(ctx, nx)
  local work = {}
  for _, t in ipairs(drafts.load(ctx.session).threads) do
    for i, c in ipairs(t.comments) do
      if c.state == 'draft' and not c.gh and not c.origin then
        if t.github then
          table.insert(work, { t = t, c = c, reply_to = t.id })
        else
          -- `gh_thread` only holds while the thread's first comment is mirrored
          table.insert(work, { t = t, c = c, root = i == 1 })
        end
      end
    end
  end
  each(work, function(it, next)
    if it.reply_to then
      send(ctx, it, { kind = 'reply' }, next)
      return
    end
    if not it.root then
      -- a reply on a draft thread follows its first comment
      local t = drafts.find(drafts.load(ctx.session).threads, it.t.id)
      if t and t.gh_thread and t.comments[1].gh then
        it.reply_to = t.gh_thread
        send(ctx, it, { kind = 'reply' }, next)
      else
        set_blocked(ctx, it.c.id, t and t.comments[1] and t.comments[1].blocked)
        next()
      end
      return
    end
    place_root(ctx, it.t, function(target, why)
      if not target then
        set_blocked(ctx, it.c.id, why)
        next()
        return
      end
      send(ctx, it, target, next)
    end)
  end, nx)
end

--- Apply staged changes to published comments and threads, re-reading each
--- comment first: changed on github.com since is a conflict (an edit beats a
--- delete), deleted there turns a staged edit into a draft reply. A change
--- that fails stays staged, marked for the next sync to retry.
--- `list`: `{ kind = 'edit'|'delete'|'resolve'|'unresolve', thread_id, comment_id }`.
local function apply_staged(session, list, notes, cb)
  local function edit_record(item, fn)
    write(session, function(d)
      local t = drafts.find(d.threads, item.thread_id)
      if not t then
        return false
      end
      local r, ri
      if item.comment_id then
        r, ri = select(2, find_comment({ t }, item.comment_id))
        if not r then
          return false
        end
      end
      fn(t, r, ri)
      if r and t.comments[ri] == r and r.state == 'published' and not (r.staged_body or r.staged_delete) then
        table.remove(t.comments, ri)
      end
      if #t.comments == 0 and not t.resolve_staged then
        local _, i = drafts.find(d.threads, t.id)
        table.remove(d.threads, i)
      end
    end)
  end
  each(list, function(item, next)
    if item.kind == 'resolve' or item.kind == 'unresolve' then
      M.transport(MUTATIONS[item.kind], { t = item.thread_id }, function(data, err)
        edit_record(item, function(t)
          if data then
            t.resolve_staged, t.retry = nil, nil
          else
            t.retry = true
          end
        end)
        if not data then
          fail(notes, ("couldn't %s a thread, staged for the next sync: %s"):format(item.kind, tostring(err)))
        end
        next()
      end)
      return
    end
    M.transport(Q.comment, { id = item.comment_id }, function(data, err)
      local node = data and data.node
      local record = drafts.find(drafts.load(session).threads, item.thread_id)
      local r = record and select(2, find_comment({ record }, item.comment_id))
      if not r then
        next()
        return
      end
      if not node then
        if not is_not_found(err) then
          edit_record(item, function(_, rec)
            rec.retry = true
          end)
          fail(notes, ("couldn't check a comment, staged for the next sync: %s"):format(tostring(err)))
        else
          edit_record(item, function(t, rec, ri)
            if rec.staged_body then
              t.comments[ri] = { id = model.new_id('c'), author = cached_author, body = rec.staged_body, created_at = os.time(), state = 'draft' }
              table.insert(notes, ('a comment you were editing was deleted on github.com; your edit is a draft reply now: %s'):format(first_line(rec.staged_body)))
            else
              rec.staged_delete = nil
            end
          end)
        end
        next()
        return
      end
      if node.lastEditedAt ~= r.edited_at then
        edit_record(item, function(_, rec)
          if rec.staged_delete then
            rec.staged_delete = nil
            table.insert(notes, ('deletion cancelled, the comment was edited on github.com: %s'):format(first_line(node.body)))
          else
            rec.staged_conflict = true
            table.insert(notes, ('your staged edit conflicts with an edit on github.com: %s'):format(first_line(node.body)))
          end
        end)
        next()
        return
      end
      local mutation, vars = MUTATIONS.update, { id = item.comment_id, b = r.staged_body }
      if r.staged_delete then
        mutation, vars = MUTATIONS.delete, { id = item.comment_id }
      end
      M.transport(mutation, vars, function(res, merr)
        edit_record(item, function(_, rec)
          if res then
            rec.staged_body, rec.staged_delete, rec.retry = nil, nil, nil
          else
            rec.retry = true
          end
        end)
        if not res then
          fail(notes, ("couldn't apply a staged change, staged for the next sync: %s"):format(tostring(merr)))
        end
        next()
      end)
    end)
  end, cb)
end

--- Staged changes a failed submit left behind.
local function sync_retry(ctx, nx)
  local changes, resolves = {}, {}
  for _, t in ipairs(drafts.load(ctx.session).threads) do
    for _, c in ipairs(t.comments) do
      if c.state == 'published' and c.retry then
        table.insert(changes, { kind = c.staged_delete and 'delete' or 'edit', thread_id = t.id, comment_id = c.id })
      end
    end
    if t.retry and t.resolve_staged then
      table.insert(resolves, { kind = t.resolve_staged, thread_id = t.id })
    end
  end
  apply_staged(ctx.session, vim.list_extend(changes, resolves), ctx.notes, nx)
end

local function run_sync(session, done)
  local l = session.layer
  local ctx = {
    session = session,
    pr = l.cache.pr,
    mb = session.review.merge_base,
    head = l.cache.pr.head_sha,
    diffs = {},
    raw = {},
    pushed = {},
    notes = {},
  }
  local steps = vim.tbl_map(function(step)
    return function(nx)
      step(ctx, nx)
    end
  end, { sync_deleted, sync_sent, sync_edits, sync_new, sync_retry })
  chain(steps, function()
    local function finish()
      for _, n in ipairs(ctx.notes) do
        warn(n)
      end
      session.layer.sync_error = ctx.notes.failed
      if not session.closed then
        require('diffy.panels.log').apply_layer(session)
        if ctx.adopted or ctx.reread then
          -- the review another nvim or github.com made: its comments join yours
          M.read(session)
        end
      end
      done()
    end
    if ctx.created and not ctx.landed then
      -- created for a draft GitHub then refused: don't leave it empty
      M.transport(MUTATIONS.delete_review, { id = ctx.created }, function()
        forget_review(session, ctx.created)
        finish()
      end)
      return
    end
    finish()
  end)
end

--- Mirror your drafts into your pending review now (one sync at a time per
--- branch; a request during one queues another). No-op without an attached,
--- online layer. `cb()` (optional) runs after it; `DiffyReady` `sync` fires.
function M.mirror(session, cb)
  local st = sync_state(session)
  if cb then
    table.insert(st.waiting, cb)
  end
  if st.running or st.held then
    st.again = session
    return
  end
  local l = session.layer
  local function flush()
    local waiting = st.waiting
    st.waiting = {}
    for _, w in ipairs(waiting) do
      w()
    end
    if not session.closed then
      run.ready({ session = session.id, event = 'sync' })
    end
  end
  if session.closed or not (l and l.attached) or l.offline or type(session.review) ~= 'table' or not session.review.merge_base then
    flush()
    return
  end
  st.running = true
  -- this sync takes whatever the pending delay was waiting for
  if l.sync_timer then
    l.sync_timer:stop()
  end
  l.sync_pending = false
  redraw_row(session)
  run_sync(session, function()
    st.running = false
    redraw_row(session)
    local again = st.again
    st.again = nil
    if again and not again.closed then
      M.mirror(again)
      return
    end
    flush()
  end)
end

--- A local change to your comments: mirror it `M.sync_delay` after the
--- last one. Offline, the next successful read does.
function M.changed(session)
  local l = session.layer
  if session.closed or not (l and l.attached) then
    return
  end
  l.sync_timer = l.sync_timer or vim.uv.new_timer()
  l.sync_timer:stop()
  l.sync_pending = true
  redraw_row(session)
  l.sync_timer:start(M.sync_delay, 0, vim.schedule_wrap(function()
    l.sync_pending = false
    if not session.closed then
      M.mirror(session)
    end
  end))
end

--- The sync's state for the PR row: `syncing` (a read or a mirror running, or
--- one about to), `offline` (the last read failed), `sync failed` (the last
--- sync couldn't write something), nil when idle and in sync.
function M.sync_status(session)
  local l = session.layer
  if not (l and l.attached) then
    return nil
  end
  if l.reading or l.sync_pending or sync_state(session).running then
    return 'syncing'
  elseif l.offline then
    return 'offline'
  elseif l.sync_error then
    return 'sync failed'
  end
  return nil
end

-- ---------------------------------------------------------------------
-- staged changes: kept in the store until a GitHub submit.

--- `x` on a published thread: stage resolving (or unresolving) it; again
--- cancels.
function M.toggle_resolve(session, thread)
  drafts.stage(session, thread, nil, function(t)
    if t.resolve_staged then
      t.resolve_staged, t.retry = nil, nil
    else
      t.resolve_staged = thread.resolved and 'unresolve' or 'resolve'
    end
  end)
end

--- `e` on your published `comment`: stage `body` as its edit (its own body
--- cancels it).
function M.stage_edit(session, thread, comment, body)
  drafts.stage(session, thread, comment, function(r)
    r.staged_delete, r.staged_conflict, r.retry = nil, nil, nil
    if body == comment.body then
      r.staged_body = nil
    else
      r.staged_body = body
      r.edited_at = comment.last_edited_at
    end
  end)
end

--- Drop the staged edit of `comment`.
function M.drop_edit(session, thread, comment)
  drafts.stage(session, thread, comment, function(r)
    r.staged_body, r.staged_conflict, r.retry = nil, nil, nil
  end)
end

--- `dd` on your published `comment`: stage its deletion; again cancels.
function M.toggle_delete(session, thread, comment)
  drafts.stage(session, thread, comment, function(r)
    if r.staged_delete then
      r.staged_delete, r.retry = nil, nil
    else
      r.staged_delete, r.staged_body, r.staged_conflict, r.retry = true, nil, nil, nil
      r.edited_at = comment.last_edited_at
    end
  end)
end

-- ---------------------------------------------------------------------
-- submitting

--- Review events `:Diffy review github` offers: GitHub refuses approving or
--- requesting changes on your own PR.
function M.verdicts(session)
  local pr = session.review and session.review.pr
  if pr and pr.author == M.author(session.root) then
    return { 'COMMENT' }
  end
  return { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }
end

--- What a GitHub submit would send: `items` (`{ kind, thread, comment?,
--- text }`, kinds 'new thread', 'reply', 'edit', 'delete', 'resolve',
--- 'unresolve'), `stay` (drafts GitHub can't take, with why) and
--- `conflicts` (their count).
local function submit_plan(session)
  local plan = { items = {}, stay = {}, conflicts = 0 }
  for _, t in ipairs(session.review.threads) do
    local where = t.anchor.end_line and ('%s:%d'):format(t.anchor.path, t.anchor.end_line) or t.anchor.path
    local function add(kind, c, body)
      table.insert(plan.items, { kind = kind, thread = t, comment = c, text = ('%-10s %s  %s'):format(kind, where, first_line(body)) })
    end
    for i, c in ipairs(t.comments) do
      plan.conflicts = plan.conflicts + ((c.conflict or c.staged_conflict) and 1 or 0)
      if c.state == 'draft' and not c.origin and not c.conflict then
        if c.gh then
          add((i == 1 and not t.github) and 'new thread' or 'reply', c, c.body)
        else
          table.insert(plan.stay, ('%s  %s (%s)'):format(where, first_line(c.body), c.blocked or 'not mirrored yet'))
        end
      elseif c.state == 'published' and c.staged_delete then
        add('delete', c, c.body)
      elseif c.state == 'published' and c.staged_body and not c.staged_conflict then
        add('edit', c, c.staged_body)
      end
    end
    if t.resolve_staged then
      add(t.resolve_staged, nil, t.comments[1] and t.comments[1].body)
    end
  end
  return plan
end

--- The submit itself: excluded drafts out of the pending review, the
--- review, the staged edits and deletions, then the staged resolves.
--- `cb(ok, warnings)`.
local function execute(session, plan, excluded, event, body, cb)
  local notes = {}
  local dropped = {}
  for i, it in ipairs(plan.items) do
    if excluded[i] and it.kind == 'new thread' then
      dropped[it.thread] = true -- its replies stay out with it
    end
  end
  local out_drafts, kept_drafts, changes, resolves = {}, {}, {}, {}
  for i, it in ipairs(plan.items) do
    local going = not excluded[i] and not dropped[it.thread]
    local staged = { kind = it.kind, thread_id = it.thread.id, comment_id = it.comment and it.comment.id }
    if it.kind == 'new thread' or it.kind == 'reply' then
      table.insert(going and out_drafts or kept_drafts, it.comment)
    elseif going and (it.kind == 'edit' or it.kind == 'delete') then
      table.insert(changes, staged)
    elseif going then
      table.insert(resolves, staged)
    end
  end
  each(kept_drafts, function(c, next)
    unmirror(session, c, function(err)
      if err then
        table.insert(notes, ("couldn't leave a draft out: %s"):format(tostring(err)))
      end
      next()
    end)
  end, function()
    local review_id = drafts.load(session).mirror.review
    local function staged_changes()
      apply_staged(session, changes, notes, function()
        apply_staged(session, resolves, notes, function()
          cb(true, notes)
        end)
      end)
    end
    local function submitted(data, err)
      if not data then
        warn('submit failed - ' .. tostring(err))
        cb(false, notes)
        return
      end
      -- published now: the read brings them back as GitHub's
      local ids = vim.tbl_map(function(c)
        return c.id
      end, out_drafts)
      drafts.remove(session, ids, { forget = true, sync = true })
      write(session, function(d)
        d.mirror.review = nil
      end)
      staged_changes()
    end
    if review_id and #out_drafts > 0 then
      M.transport(MUTATIONS.submit, { r = review_id, e = event, b = body }, submitted)
    elseif vim.trim(body or '') ~= '' or event ~= 'COMMENT' or #changes + #resolves == 0 then
      -- no comment going: the message alone (approving without comments)
      local pr = session.review.pr
      M.transport(MUTATIONS.review, { pr = pr.id, c = pr.head_sha, e = event, b = body }, submitted)
    else
      staged_changes()
    end
  end)
end

--- What `:Diffy review github` sends, once what's left is mirrored:
--- `cb(rows, blocked, plan)`, `rows` (`{ text, value? }`) listing everything
--- going out (value: its index in `plan.items`, excludable), what stays
--- behind and unpushed commits; `blocked` says why it can't go yet (sync
--- conflicts to settle). Not called once the session is closed.
function M.submit_recap(session, cb)
  M.mirror(session, function()
    if session.closed then
      return
    end
    local plan = submit_plan(session)
    local rows = {}
    for i, it in ipairs(plan.items) do
      table.insert(rows, { text = it.text, value = i })
    end
    if #plan.items == 0 then
      table.insert(rows, { text = 'no comments or staged changes: only the message' })
    end
    for _, s in ipairs(plan.stay) do
      table.insert(rows, { text = 'stays behind: ' .. s })
    end
    local standing = session.layer and session.layer.standing
    if standing and (standing:find('unpushed', 1, true) or standing == 'diverged') then
      table.insert(rows, { text = 'branch: ' .. standing })
    end
    local blocked
    if plan.conflicts > 0 then
      blocked = ('settle the %d sync conflict%s first: `dd` the version you drop'):format(plan.conflicts, plan.conflicts == 1 and '' or 's')
      table.insert(rows, 1, { text = blocked })
    end
    cb(rows, blocked, plan)
  end)
end

--- Send `plan` (`M.submit_recap`'s) but its `excluded` items as an `event`
--- review with `body`. `cb(ok, warnings)`.
function M.submit(session, plan, excluded, event, body, cb)
  local st = sync_state(session)
  st.held = true
  execute(session, plan, excluded, event, body, function(ok, notes)
    st.held = false
    -- the read brings the published comments, then syncs (excluded drafts
    -- go into a fresh pending review)
    M.read(session, function()
      cb(ok, notes)
    end)
  end)
end

--- `:Diffy review clear`: asks, then drops your drafts and staged changes and
--- deletes your pending review on GitHub, adopted comments included.
--- `cb(done)`.
function M.clear(session, cb)
  prompt.confirm(session, {
    'Drop your drafts and staged changes, and delete',
    'your pending review on GitHub (adopted comments too)?',
  }, function(ok)
    if not ok then
      cb(false)
      return
    end
    local st = sync_state(session)
    st.held = true
    local l = session.layer or {}
    local id = drafts.load(session).mirror.review or (l.cache and l.cache.pr.pending and l.cache.pr.pending.id)
    local function wipe()
      drafts.clear(session)
      st.held = false
      M.read(session)
      cb(true)
    end
    if not (id and l.attached and not l.offline) then
      wipe()
      return
    end
    M.transport(MUTATIONS.delete_review, { id = id }, function(_, err)
      if err and not is_not_found(err) then
        warn("couldn't delete your pending review: " .. tostring(err))
      end
      wipe()
    end)
  end)
end

return M
