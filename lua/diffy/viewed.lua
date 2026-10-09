-- Viewed marks: a file marked viewed stays out of the way while the view
-- shows the same (left blob, right blob) pair it was marked with.
--
-- `viewed.json` in the branch's store directory maps a path to
-- `{ marks = { {left, right, at}, … } }`. Sessions of
-- one nvim on the same branch share one in-memory copy; every change goes
-- through `store.update` and other nvims reload on `store.watch`.
local store = require('diffy.review.store')

local M = {}

local MAX_MARKS = 5

-- store path -> { data, handle, sessions = { [session] = true } }
local states = {}

local function state(session)
  return session.viewed_file and states[session.viewed_file]
end

--- Redraw the tree of every session using `file`.
local function redraw_all(file)
  local st = states[file]
  for s in pairs(st and st.sessions or {}) do
    if not s.closed then
      require('diffy.panels.tree').refresh_viewed(s)
    end
  end
end

--- Start using the branch's marks in `session` (loads and watches them once per nvim).
function M.attach(session)
  if session.viewed_file or not (session.gitdir and session.branch) then
    return
  end
  local file = store.path(session.gitdir, session.branch, 'viewed.json')
  local st = states[file]
  if not st then
    st = { data = store.load(file) or {}, sessions = {} }
    st.handle = store.watch(file, function()
      st.data = store.load(file) or {}
      redraw_all(file)
    end)
    states[file] = st
  end
  st.sessions[session] = true
  session.viewed_file = file
end

--- Stop using the marks; the watch stops with the last session.
function M.detach(session)
  local file = session.viewed_file
  local st = file and states[file]
  session.viewed_file = nil
  if not st then
    return
  end
  st.sessions[session] = nil
  if not next(st.sessions) then
    store.unwatch(st.handle)
    states[file] = nil
  end
end

--- Whether `entry` carries both ids (a conflicted or unhashable file doesn't).
function M.markable(entry)
  return entry and entry.status ~= 'U' and entry.left_id ~= nil and entry.right_id ~= nil
end

local function candidates(entry)
  if entry.status == 'R' and entry.old_path then
    return { entry.path, entry.old_path }
  end
  return { entry.path }
end

local function same_pair(a, entry)
  return a and a.left == entry.left_id and a.right == entry.right_id
end

local function marked_in(rec, entry)
  for _, m in ipairs(rec and rec.marks or {}) do
    if same_pair(m, entry) then
      return true
    end
  end
  return false
end

function M.is_viewed(session, entry)
  local st = state(session)
  if not (st and M.markable(entry)) then
    return false
  end
  for _, p in ipairs(candidates(entry)) do
    if marked_in(st.data[p], entry) then
      return true
    end
  end
  return false
end

--- `●`: not viewed, but the path has marks (for another pair): it stays until
--- the file is marked again or its marks are cleared.
function M.changed(session, entry)
  local st = state(session)
  if not (st and M.markable(entry)) or M.is_viewed(session, entry) then
    return false
  end
  for _, p in ipairs(candidates(entry)) do
    local rec = st.data[p]
    if rec and #(rec.marks or {}) > 0 then
      return true
    end
  end
  return false
end

local function apply(session, fn)
  local file = session.viewed_file
  local st = states[file]
  st.data = store.update(file, fn)
  redraw_all(file)
end

--- Mark every entry of `entries` viewed (`on`) or remove the marks matching
--- their current pairs.
function M.set(session, entries, on)
  if not state(session) then
    return
  end
  local at = os.date('!%Y-%m-%dT%H:%M:%SZ')
  apply(session, function(data)
    for _, e in ipairs(entries) do
      if M.markable(e) then
        if on then
          local rec = data[e.path] or {}
          rec.marks = rec.marks or {}
          if not marked_in(rec, e) then
            table.insert(rec.marks, { left = e.left_id, right = e.right_id, at = at })
            while #rec.marks > MAX_MARKS do
              table.remove(rec.marks, 1)
            end
          end
          data[e.path] = rec
        else
          for _, p in ipairs(candidates(e)) do
            local rec = data[p]
            if rec and rec.marks then
              rec.marks = vim.tbl_filter(function(m)
                return not same_pair(m, e)
              end, rec.marks)
              if #rec.marks == 0 then
                data[p] = nil
              end
            end
          end
        end
      end
    end
  end)
end

--- Drop every mark of `entry`'s path (and a rename's old path).
function M.clear(session, entry)
  if not state(session) then
    return
  end
  apply(session, function(data)
    for _, p in ipairs(candidates(entry)) do
      data[p] = nil
    end
  end)
end

return M
