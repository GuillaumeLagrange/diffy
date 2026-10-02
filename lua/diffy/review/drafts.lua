-- Your comments on a branch, in `.git/diffy/<branch>/threads.json`, whichever
-- backend they were written with. Published GitHub content isn't stored.
--
-- Sessions of one nvim on the same branch share one entry: a change made in
-- one updates and redraws them all. Every change goes through `store.update`
-- (a fresh read of the file, then an atomic write), and other nvims' writes
-- come in through `store.watch`. Session threads are their own objects
-- (placement is cached on them per session); `M.apply` brings them in line
-- with the entry, matching by id.
local store = require('diffy.review.store')
local model = require('diffy.review.model')

local M = {}

-- threads.json path -> { path, threads, sessions = { [session] = true }, watch }
local entries = {}

local function path_of(session)
  return store.path(session.gitdir, session.branch, 'threads.json')
end

local function stored_comment(c)
  return {
    id = c.id,
    author = c.author,
    body = c.body,
    created_at = c.created_at,
    state = c.state,
    agent_resolved = c.agent_resolved,
  }
end

local function stored_thread(t)
  return {
    id = t.id,
    backend = t.backend,
    anchor = vim.deepcopy(t.anchor),
    resolved = t.resolved,
    view = t.view,
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

--- Make `live` (a session's threads) match `stored`: stored comments are
--- updated, added or dropped by id; threads left without comments go;
--- stored threads not in `live` are added. Published comments stay.
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
      if src[c.id] then
        for k, v in pairs(stored_comment(src[c.id])) do
          c[k] = v
        end
        c.agent_resolved = src[c.id].agent_resolved
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
        if not have[c.id] then
          local n = stored_comment(c)
          n._stored = true
          table.insert(t.comments, n)
        end
      end
      t.anchor = vim.deepcopy(s.anchor)
      t.view = s.view
      -- a published thread's resolution is GitHub's
      if only_stored then
        t.resolved = s.resolved
      end
    end
    if #t.comments == 0 then
      table.remove(live, i)
    end
  end
  for _, s in ipairs(stored) do
    if not seen[s.id] then
      local n = stored_thread(s)
      for _, c in ipairs(s.comments) do
        local nc = stored_comment(c)
        nc._stored = true
        table.insert(n.comments, nc)
      end
      table.insert(live, n)
    end
  end
end

--- Apply one change to the file as it is now: `fn(threads)` mutates the
--- stored threads (plain tables) and returns false when it changed nothing.
--- Then every session of the branch follows; `opts.quiet` skips redrawing
--- `session` itself.
function M.change(session, fn, opts)
  local e = M.attach(session)
  local changed = true
  local written = store.update(e.path, function(data)
    data.threads = data.threads or {}
    changed = fn(data.threads) ~= false
  end)
  e.threads = written.threads
  if changed then
    broadcast(e, opts and opts.quiet and session or nil)
  end
  return changed
end

local function find(threads, id)
  for i, t in ipairs(threads) do
    if t.id == id then
      return t, i
    end
  end
  return nil
end

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
    t.comments[ci or (#t.comments + 1)] = stored_comment(comment)
  end, opts)
end

--- Drop `comments` (ids) from the store, and threads left empty. `opts` as
--- for `M.change`.
function M.remove(session, ids, opts)
  local drop = {}
  for _, id in ipairs(ids) do
    drop[id] = true
  end
  M.change(session, function(threads)
    local changed = false
    for i = #threads, 1, -1 do
      local t = threads[i]
      for j = #t.comments, 1, -1 do
        if drop[t.comments[j].id] then
          table.remove(t.comments, j)
          changed = true
        end
      end
      if #t.comments == 0 then
        table.remove(threads, i)
      end
    end
    return changed
  end, opts)
end

--- `:Diffy review clear`: every stored comment of the branch.
function M.clear(session)
  local e = M.attach(session)
  store.delete(e.path)
  e.threads = {}
  broadcast(e)
end

return M
