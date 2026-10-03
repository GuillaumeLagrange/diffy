-- Your comments on a branch, in `.git/diffy/<branch>/threads.json`, whichever
-- backend they were written with. Published GitHub content isn't stored, only
-- the changes you staged on it.
--
-- Sessions of one nvim on the same branch share one entry: a change made in
-- one updates and redraws them all. Every change goes through `store.update`
-- (a fresh read of the file, then an atomic write), and other nvims' writes
-- come in through `store.watch`. Session threads are their own objects
-- (placement is cached on them per session); `M.apply` brings them in line
-- with the entry, matching by id.
--
-- Stored comment fields beyond the comment itself:
--   gh          { id, body, updated_at }: mirrored into your pending review,
--               with the body and `updatedAt` it last synced
--   blocked     why GitHub can't take the draft yet ('worktree', …)
--   conflict    true on a draft whose pending copy was edited on both sides;
--               its github.com version is a sibling with `origin` and
--               `conflict_of` = its id
-- A published comment is stored only while it carries a staged change:
--   { id, state = 'published', staged_body?, staged_delete?, edited_at
--   (its `lastEditedAt` when staged), staged_conflict?, retry? }
-- Stored thread fields: `github` (a published GitHub thread), `gh_thread`
-- (the GitHub thread a mirrored draft thread became), `resolve_staged`,
-- `retry`. `data.mirror = { review, deleted = { {id, updated_at} } }`: the
-- pending review diffy mirrors into and the mirrored drafts you deleted that
-- GitHub still has.
local store = require('diffy.review.store')
local model = require('diffy.review.model')

local M = {}

-- threads.json path -> { path, threads, sessions = { [session] = true }, watch }
local entries = {}

--- `threads.json` of `branch`.
function M.path(gitdir, branch)
  return store.path(gitdir, branch, 'threads.json')
end

local function path_of(session)
  return M.path(session.gitdir, session.branch)
end

local COMMENT_FIELDS = { 'id', 'author', 'body', 'created_at', 'state', 'agent_resolved', 'gh', 'blocked', 'conflict', 'origin', 'conflict_of' }
-- what a stored published comment brings to the live one
local OVERLAY_FIELDS = { 'staged_body', 'staged_delete', 'edited_at', 'staged_conflict', 'retry' }

local function stored_comment(c)
  local out = {}
  for _, k in ipairs(c.state == 'published' and vim.list_extend({ 'id', 'state' }, OVERLAY_FIELDS) or COMMENT_FIELDS) do
    out[k] = vim.deepcopy(c[k])
  end
  return out
end

local function has_published(t)
  for _, c in ipairs(t.comments or {}) do
    if c.state == 'published' then
      return true
    end
  end
  return false
end

local function stored_thread(t)
  return {
    id = t.id,
    backend = t.backend,
    anchor = vim.deepcopy(t.anchor),
    resolved = t.resolved,
    view = t.view,
    github = (t.github or has_published(t)) or nil,
    gh_thread = t.gh_thread,
    resolve_staged = t.resolve_staged,
    retry = t.retry,
    comments = {},
  }
end

--- Whether `c` is yours to keep: published comments are GitHub's.
local function storable(c)
  return c.state ~= 'published'
end

--- Merge `local.json` and every `pr-<n>.json` next to `path` into it, then
--- delete them. `local.json` goes first so its ids, which `review.md` refers
--- to, are kept; a later colliding id gets a new one.
local function migrate(path)
  local dir = vim.fn.fnamemodify(path, ':h')
  local olds = {}
  if vim.fn.filereadable(dir .. '/local.json') == 1 then
    table.insert(olds, dir .. '/local.json')
  end
  vim.list_extend(olds, vim.fn.glob(dir .. '/pr-*.json', false, true))
  if #olds == 0 then
    return
  end
  store.update(path, function(data)
    if data.threads then
      return -- another nvim got there first
    end
    local threads, tids, cids = {}, {}, {}
    for _, old in ipairs(olds) do
      local from_pr = not old:match('/local%.json$')
      local d = store.load(old)
      for _, t in ipairs(d and d.threads or {}) do
        if tids[t.id] then
          t.id = model.new_id('t')
        end
        tids[t.id] = true
        t.comments = t.comments or {}
        for _, c in ipairs(t.comments) do
          if cids[c.id] then
            c.id = model.new_id('c')
          end
          cids[c.id] = true
        end
        -- a pulled GitHub comment's old-side lines are the merge-base's
        if from_pr and t.anchor and t.anchor.side == 'old' and not tostring(t.id):match('^t%d+$') then
          t.anchor.base_relative = true
        end
        table.insert(threads, t)
      end
    end
    data.threads = threads
  end)
  for _, old in ipairs(olds) do
    store.delete(old)
  end
end

local function read(path)
  local data = store.load(path)
  return data and data.threads or {}
end

--- Bring each session of `e` in line with its threads and redraw it.
local function broadcast(e, except)
  for s in pairs(e.sessions) do
    if not s.closed and type(s.review) == 'table' then
      M.apply(s.review.threads, e.threads)
      if s ~= except then
        require('diffy.review.ui').redraw(s)
      end
    end
  end
end

--- Join `session` to its branch's entry, loading (and migrating) the file
--- and starting its watch for the first session. Returns the entry.
function M.attach(session)
  local path = path_of(session)
  local e = entries[path]
  if not e then
    if vim.fn.filereadable(path) == 0 then
      migrate(path)
    end
    e = { path = path, sessions = {}, threads = read(path) }
    e.watch = store.watch(path, function()
      e.threads = read(path)
      broadcast(e)
    end)
    entries[path] = e
  end
  e.sessions[session] = true
  return e
end

--- Leave the entry; the last session out stops its watch.
function M.detach(session)
  if not (session.gitdir and session.branch) then
    return
  end
  local e = entries[path_of(session)]
  if not (e and e.sessions[session]) then
    return
  end
  e.sessions[session] = nil
  if not next(e.sessions) then
    store.unwatch(e.watch)
    entries[e.path] = nil
  end
end

--- The other sessions sharing `session`'s entry, and itself.
function M.sessions(session)
  local e = entries[path_of(session)]
  return e and vim.tbl_keys(e.sessions) or { session }
end

local function draft_comments(s)
  for _, c in ipairs(s.comments) do
    if storable(c) then
      return true
    end
  end
  return false
end

--- Make `live` (a session's threads) match `stored`: stored comments are
--- updated, added or dropped by id; threads left without comments go;
--- stored threads not in `live` are added when they hold drafts. A stored
--- published comment only lays its staged change over the live one.
function M.apply(live, stored)
  local by_id = {}
  for _, s in ipairs(stored) do
    by_id[s.id] = s
  end
  local seen = {}
  for i = #live, 1, -1 do
    local t = live[i]
    local s = by_id[t.id]
    local src = {}
    for _, c in ipairs(s and s.comments or {}) do
      src[c.id] = c
    end
    local have, only_stored = {}, true
    for j = #t.comments, 1, -1 do
      local c = t.comments[j]
      local sc = src[c.id]
      if c.state == 'published' and not c._stored then
        only_stored = false
        for _, k in ipairs(OVERLAY_FIELDS) do
          c[k] = sc and sc.state == 'published' and vim.deepcopy(sc[k]) or nil
        end
        have[c.id] = true
      elseif sc then
        for k in pairs(c) do
          if not k:match('^_') then
            c[k] = nil
          end
        end
        for k, v in pairs(stored_comment(sc)) do
          c[k] = v
        end
        c._stored = true
        have[c.id] = true
      elseif c._stored then
        table.remove(t.comments, j)
      else
        only_stored = false
      end
    end
    if s then
      seen[s.id] = true
      for _, c in ipairs(s.comments) do
        if not have[c.id] and storable(c) then
          local n = stored_comment(c)
          n._stored = true
          table.insert(t.comments, n)
        end
      end
      t.view = s.view
      t.gh_thread = s.gh_thread
      t.resolve_staged, t.retry = s.resolve_staged, s.retry
      -- a published thread's place and resolution are GitHub's
      if only_stored then
        t.anchor = vim.deepcopy(s.anchor)
        t.resolved = s.resolved
      end
    else
      t.resolve_staged, t.retry = nil, nil
    end
    if #t.comments == 0 then
      table.remove(live, i)
    end
  end
  for _, s in ipairs(stored) do
    if not seen[s.id] and draft_comments(s) then
      local n = stored_thread(s)
      for _, c in ipairs(s.comments) do
        if storable(c) then
          local nc = stored_comment(c)
          nc._stored = true
          table.insert(n.comments, nc)
        end
      end
      table.insert(live, n)
    end
  end
end

--- The whole file as it is now (`threads` and `mirror` always present).
function M.load(session)
  local data = store.load(path_of(session)) or {}
  data.threads = data.threads or {}
  data.mirror = data.mirror or {}
  data.mirror.deleted = data.mirror.deleted or {}
  return data
end

local function changed_hook(session, opts)
  if not (opts and opts.sync) then
    local ok, github = pcall(require, 'diffy.review.github')
    if ok and github.changed then
      github.changed(session)
    end
  end
end

--- Apply one change to the whole file as it is now: `fn(data)` mutates it
--- (`data.threads`, `data.mirror` always present) and returns false when it
--- changed nothing. Then every session of the branch follows; `opts.quiet`
--- skips redrawing `session` itself; `opts.sync` marks the background
--- sync's own writes, which don't schedule another. A closed session's
--- late write (a sync answer arriving after teardown) still lands, without
--- joining the entry again.
function M.update(session, fn, opts)
  local e = session.closed and entries[path_of(session)] or (not session.closed and M.attach(session)) or nil
  local changed = true
  local written = store.update(path_of(session), function(data)
    data.threads = data.threads or {}
    data.mirror = data.mirror or {}
    data.mirror.deleted = data.mirror.deleted or {}
    changed = fn(data) ~= false
    if not data.mirror.review and #data.mirror.deleted == 0 then
      data.mirror = nil
    end
  end)
  if e then
    e.threads = written.threads
    if changed then
      broadcast(e, opts and opts.quiet and session or nil)
    end
  end
  if changed and not session.closed then
    changed_hook(session, opts)
  end
  return changed
end

--- `M.update` on the threads only: `fn(threads)`.
function M.change(session, fn, opts)
  return M.update(session, function(data)
    return fn(data.threads)
  end, opts)
end

local function find(threads, id)
  for i, t in ipairs(threads) do
    if t.id == id then
      return t, i
    end
  end
  return nil
end
M.find = find

--- Store `comment` (new or edited) of `thread`, adding the thread if it
--- isn't stored. Without `comment`, only the thread's own fields (resolved,
--- anchor) of a stored thread: one another nvim deleted stays deleted.
--- `opts` as for `M.change`.
function M.put(session, thread, comment, opts)
  M.change(session, function(threads)
    local t = find(threads, thread.id)
    if not comment then
      if not t then
        return false
      end
      t.resolved, t.anchor = thread.resolved, vim.deepcopy(thread.anchor)
      return
    end
    if not storable(comment) then
      return false
    end
    if not t then
      t = stored_thread(thread)
      table.insert(threads, t)
    end
    local _, ci = find(t.comments, comment.id)
    local stored = stored_comment(comment)
    if ci then
      -- the sync's bookkeeping isn't the editor's to change
      local old = t.comments[ci]
      stored.gh, stored.blocked, stored.conflict, stored.origin, stored.conflict_of = old.gh, old.blocked, old.conflict, old.origin, old.conflict_of
    end
    t.comments[ci or (#t.comments + 1)] = stored
  end, opts)
end

--- Change the staged state of a published `thread` (`comment`: one of its
--- comments, else the thread's own flags): `fn(record)` edits the stored
--- record, created from the live one when missing. A record left with
--- nothing staged goes, and so does a thread left with nothing in it.
function M.stage(session, thread, comment, fn)
  M.change(session, function(threads)
    local t = find(threads, thread.id)
    if not t then
      t = stored_thread(thread)
      t.github = true
      table.insert(threads, t)
    end
    if comment then
      local r, ri = find(t.comments, comment.id)
      if not r then
        r = { id = comment.id, state = 'published' }
        table.insert(t.comments, r)
        ri = #t.comments
      end
      fn(r)
      if not (r.staged_body or r.staged_delete) then
        table.remove(t.comments, ri)
      end
    else
      fn(t)
    end
    if #t.comments == 0 and not t.resolve_staged then
      local _, i = find(threads, t.id)
      table.remove(threads, i)
    end
  end)
end

--- Drop `comments` (ids) from the store, and threads left empty. Deleting
--- one side of a conflict ends it, the other side staying in sync with
--- GitHub. Another mirrored draft leaves a tombstone, so the sync deletes it
--- from your pending review, unless `opts.forget` (its GitHub copy is gone
--- or handled). `opts` also as for `M.update`.
function M.remove(session, ids, opts)
  local drop = {}
  for _, id in ipairs(ids) do
    drop[id] = true
  end
  M.update(session, function(data)
    local changed = false
    for i = #data.threads, 1, -1 do
      local t = data.threads[i]
      for j = #t.comments, 1, -1 do
        local c = t.comments[j]
        if drop[c.id] then
          local partner
          for _, o in ipairs(t.comments) do
            if (c.conflict_of and o.id == c.conflict_of) or (c.conflict and o.conflict_of == c.id) then
              partner = o
            end
          end
          if partner and partner.conflict then
            -- the github.com version goes: yours overwrites it next sync
            partner.conflict = nil
            partner.gh = vim.tbl_extend('force', partner.gh or {}, { updated_at = c.gh and c.gh.updated_at })
          elseif partner then
            partner.origin, partner.conflict_of = nil, nil
          elseif c.gh and c.state ~= 'published' and not (opts and opts.forget) then
            table.insert(data.mirror.deleted, { id = c.gh.id, updated_at = c.gh.updated_at })
          end
          table.remove(t.comments, j)
          changed = true
        end
      end
      if #t.comments == 0 and not t.resolve_staged then
        table.remove(data.threads, i)
      end
    end
    return changed
  end, opts)
end

--- Every stored comment of the branch, staged changes and the mirror's
--- bookkeeping (the GitHub cache stays).
function M.clear(session)
  local e = M.attach(session)
  store.update(e.path, function(data)
    data.threads = nil
    data.mirror = nil
  end)
  e.threads = {}
  broadcast(e)
end

return M
