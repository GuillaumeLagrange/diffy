-- JSON persistence in `.git/diffy/<branch>/`: one JSON object per file.
--
-- Several nvims can have sessions on the same branch: a change is applied to
-- a fresh read of the file (`M.update`) and written atomically, and the other
-- nvims reload when `M.watch` reports the file changed. Whole in-memory states
-- are never written back over the file, which would undo another nvim's
-- deletions.
local M = {}

-- path -> { sec, nsec, size } of this process's last write, so `M.watch`
-- can skip the events its own writes raise
local own_writes = {}

local function stamp(path)
  local st = vim.uv.fs_stat(path)
  return st and { st.mtime.sec, st.mtime.nsec, st.size } or nil
end

local function same_stamp(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

--- `<gitdir>/diffy/<branch>/<filename>`.
function M.path(gitdir, branch, filename)
  return ('%s/diffy/%s/%s'):format(gitdir, branch, filename)
end

--- Read `path` as a JSON object. Returns `nil` if the file is missing or
--- fails to parse, so callers just start fresh.
function M.load(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'), { luanil = { object = true, array = true } })
  end)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  return data
end

--- Write `data` to `path` as one JSON object, creating the parent directory.
--- Written to a temporary file then renamed over `path`, so a reader never
--- sees a partial write.
function M.save(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local tmp = ('%s.%d.tmp'):format(path, vim.uv.os_getpid())
  vim.fn.writefile({ vim.json.encode(data) }, tmp)
  vim.uv.fs_rename(tmp, path)
  own_writes[path] = stamp(path)
end

--- Apply one change to the file as it is now: `fn(data)` gets the freshly
--- read object (`{}` when there is none) and returns the object to write
--- (or mutates it in place and returns nothing). Returns what was written.
function M.update(path, fn)
  local data = M.load(path) or {}
  local out = fn(data)
  if out == nil then
    out = data
  end
  M.save(path, out)
  return out
end

--- Remove `path` if present (`:Diffy review clear`).
function M.delete(path)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
  own_writes[path] = nil
end

--- handle -> watched path, while the watch runs (the leak check reads it).
M.watched = {}

--- Call `cb()` (scheduled) whenever another process writes or deletes
--- `path`. The parent directory is watched, not the file: an atomic write
--- replaces the file's inode. Returns a handle for `M.unwatch`.
function M.watch(path, cb)
  local dir, name = vim.fn.fnamemodify(path, ':h'), vim.fn.fnamemodify(path, ':t')
  vim.fn.mkdir(dir, 'p')
  local handle = vim.uv.new_fs_event()
  if not handle then
    return nil
  end
  handle:start(dir, {}, function(err, filename)
    if err or filename ~= name then
      return
    end
    vim.schedule(function()
      if handle:is_closing() then
        return
      end
      if same_stamp(own_writes[path], stamp(path)) then
        return
      end
      cb()
    end)
  end)
  M.watched[handle] = path
  return handle
end

--- Stop a watch from `M.watch` (nil is fine).
function M.unwatch(handle)
  if handle and not handle:is_closing() then
    handle:stop()
    handle:close()
  end
  if handle then
    M.watched[handle] = nil
  end
end

return M
