-- Where threads show: every thread is tracked from its source
-- (`model.source`) to the rev a view shows on its side. Commits through
-- `git diff -M -U0 <source> <target>`, the index through `git diff --cached`,
-- the worktree through `vim.diff` on the loaded buffer (live, as you type)
-- else `git diff -U0 <source>`. Worktree and index comments are found by
-- their excerpt instead, and become HEAD comments once HEAD has it.
--
-- `M.prepare` fetches every diff the session's views can need, so `M.place`
-- (called while rendering) only does lookups. Cached on `review._track`.
local model = require('diffy.review.model')
local run = require('diffy.git.run')
local selection = require('diffy.selection')

local M = {}

local SEP = '\30'

local function cache(session)
  local review = session.review
  review._track = review._track or { diffs = {}, blobs = {}, exists = {}, live = {}, worktree = {} }
  return review._track
end

local function merge_base(session)
  local review = type(session.review) == 'table' and session.review or {}
  return review.merge_base or (session.entries and session.entries.base)
end

function M.source(session, thread)
  return model.source(thread, merge_base(session))
end

local function movable(rev)
  return rev == 'worktree' or rev == 'index'
end

--- The commit a commit-ish names (`sha^` -> `sha`), for existence checks.
local function commit_of(rev)
  return (rev:gsub('[~^]%d*$', ''))
end

--- A blob's lines (`git show` output, its final newline not a line).
function M.split_blob(text)
  local lines = vim.split(text or '', '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

--- The loaded buffer of worktree file `path`, or nil.
function M.loaded_buf(session, path)
  local abspath = session.root .. '/' .. path
  -- Not bufnr(): it treats the name as a file pattern (`[id]` matches `d`).
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == abspath then
      return buf
    end
  end
  return nil
end

--- `path`'s lines in the worktree (its buffer when loaded) or the index.
--- Worktree lines are cached per changedtick, or per mtime and size on
--- disk: placement runs for every thread on every edit.
local function movable_lines(session, rev, path)
  local c = cache(session)
  if rev == 'index' then
    return c.blobs[':0:' .. path]
  end
  local buf = M.loaded_buf(session, path)
  local sig
  if buf then
    sig = 'b' .. buf .. ':' .. vim.api.nvim_buf_get_changedtick(buf)
  else
    local st = vim.uv.fs_stat(session.root .. '/' .. path)
    if not st or st.type ~= 'file' then
      return false
    end
    sig = ('f%d.%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
  end
  local hit = c.worktree[path]
  if not (hit and hit.sig == sig) then
    local lines = buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or vim.fn.readfile(session.root .. '/' .. path)
    hit = { sig = sig, lines = lines }
    c.worktree[path] = hit
  end
  return hit.lines
end

--- Hunks from `source`'s blob to the loaded buffer, cached per changedtick.
local function live_hunks(c, source, path, buf, blob)
  local key = source .. ':' .. path
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local hit = c.live[key]
  if not (hit and hit.buf == buf and hit.tick == tick) then
    hit = { buf = buf, tick = tick, hunks = model.line_hunks(blob, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) }
    c.live[key] = hit
  end
  return hit.hunks
end

--- Where `thread`'s range lands on `target`: `{ path, start_line, end_line }`,
--- or nil and why: 'detached' (no source), 'unknown' (not fetched yet) or
--- nil (its lines changed).
function M.map(session, thread, target)
  local a = thread.anchor
  local source = M.source(session, thread)
  if not source then
    return nil, 'detached'
  end
  local c = cache(session)
  if movable(source) then
    if not movable(target) then
      return nil
    end
    local lines = movable_lines(session, target, a.path)
    if lines == nil then
      return nil, 'unknown'
    end
    local s, e
    if lines then
      s, e = model.relocate(a, lines)
    end
    return s and { path = a.path, start_line = s, end_line = e } or nil
  end
  if c.exists[commit_of(source)] == false then
    return nil, 'detached'
  end
  if source == target then
    return { path = a.path, start_line = a.start_line, end_line = a.end_line }
  end
  local files = c.diffs[source .. SEP .. target]
  if files == 'failed' then
    return nil
  end
  if target == 'worktree' then
    local path = files and model.diff_file_hunks(files, a.path) or a.path
    local buf, blob = M.loaded_buf(session, path), c.blobs[source .. ':' .. a.path]
    if buf and blob then
      local hit = model.track(a, nil, live_hunks(c, source, a.path, buf, blob))
      if hit then
        hit.path = path
      end
      return hit
    end
  end
  if not files then
    return nil, 'unknown'
  end
  return model.track(a, files)
end

local function place_in(session, thread, pair, path)
  local a = thread.anchor
  if not a.side then
    -- file-level: pinned at the top of the new side
    if (not path or a.path == path) and M.source(session, thread) then
      return { win = 'right', start_line = 1, end_line = 1 }
    end
    return nil
  end
  local win = a.side == 'old' and 'left' or 'right'
  local hit = M.map(session, thread, model.rev_to_commit(pair[win], session.head_sha))
  if hit and (not path or hit.path == path) then
    return { win = win, start_line = hit.start_line, end_line = hit.end_line }
  end
  return nil
end

--- `{ win, start_line, end_line }` where `thread` shows in `pair` (both
--- sections of a `split` one), for `path` (any file when nil), or nil.
function M.place(session, thread, pair, path)
  if pair.split then
    local sel = require('diffy.selection')
    return place_in(session, thread, sel.UNSTAGED, path) or place_in(session, thread, sel.STAGED, path)
  end
  return place_in(session, thread, pair, path)
end

--- Where an old-side comment is now: the left of the whole-branch view.
local function old_now(session)
  return merge_base(session) or session.head_sha
end

--- Set `thread.outdated` (can't be mapped to the worktree, or for an
--- old-side comment the merge-base) and `thread._detached` (nothing to map
--- from). Not-yet-fetched diffs count as neither.
function M.status(session, thread)
  local a = thread.anchor
  local source = M.source(session, thread)
  thread.outdated, thread._detached = false, false
  if not source then
    thread._detached = true
  elseif not a.side then
    return
  elseif movable(source) then
    local hit, why = M.map(session, thread, source)
    thread._detached = not hit and why ~= 'unknown'
  else
    local hit, why = M.map(session, thread, a.side == 'old' and old_now(session) or 'worktree')
    if why == 'detached' then
      thread._detached = true
    elseif not hit and why ~= 'unknown' then
      thread.outdated = true
    end
  end
end

--- Where `thread` is in the worktree now (see `M.status`), or nil.
function M.now(session, thread)
  local a = thread.anchor
  if not a.side then
    return nil
  end
  local source = M.source(session, thread)
  return M.map(session, thread, (movable(source or '') and source) or (a.side == 'old' and old_now(session)) or 'worktree')
end

local function git(session, args, cb)
  run.git(args, {
    cwd = session.root,
    session = session,
    notify_on_error = false,
    on_exit = cb,
  })
end

--- Run `jobs` (`fun(done)`) at once, `cb()` after the last.
function M.join(jobs, cb)
  local left = #jobs
  if left == 0 then
    cb()
    return
  end
  for _, job in ipairs(jobs) do
    job(function()
      left = left - 1
      if left == 0 then
        cb()
      end
    end)
  end
end

local function blob_job(session, c, key, object)
  return function(done)
    git(session, { 'show', object }, function(res)
      c.blobs[key] = res.code == 0 and M.split_blob(res.stdout) or false
      done()
    end)
  end
end

--- Which source commits exist, and the HEAD and index blobs of worktree and
--- index comments.
local function first_pass(session, threads, cb)
  local c = cache(session)
  local jobs, check = {}, {}
  for _, t in ipairs(threads) do
    local source = M.source(session, t)
    if source and movable(source) then
      for _, key in ipairs({ session.head_sha .. ':' .. t.anchor.path, ':0:' .. t.anchor.path }) do
        if c.blobs[key] == nil then
          c.blobs[key] = false
          table.insert(jobs, blob_job(session, c, key, key))
        end
      end
    elseif source and c.exists[commit_of(source)] == nil then
      check[commit_of(source)] = true
    end
  end
  local list = vim.tbl_keys(check)
  if #list > 0 then
    table.insert(jobs, function(done)
      vim.system(
        { 'git', 'cat-file', '--batch-check=%(objectname) %(objecttype)' },
        { cwd = session.root, stdin = table.concat(list, '\n') .. '\n', text = true },
        function(res)
          vim.schedule(function()
            for _, sha in ipairs(list) do
              c.exists[sha] = false
            end
            for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
              local sha, kind = line:match('^(%x+) (%a+)')
              if sha and kind == 'commit' then
                c.exists[sha] = true
              end
            end
            done()
          end)
        end
      )
    end)
  end
  M.join(jobs, cb)
end

--- Worktree and index comments whose excerpt HEAD has become HEAD comments
--- at those lines, persisted in one write.
local function settle_on_head(session, threads)
  local c = cache(session)
  local settled = {}
  for _, t in ipairs(threads) do
    local a = t.anchor
    local source = M.source(session, t)
    local head = source and movable(source) and c.blobs[session.head_sha .. ':' .. a.path]
    if head and a.side then
      local s, e = model.relocate(a, head)
      if s then
        a.commit, a.start_line, a.end_line = session.head_sha, s, e
        table.insert(settled, t)
      end
    end
  end
  if #settled == 0 then
    return
  end
  local drafts = require('diffy.review.drafts')
  drafts.change(session, function(stored)
    local changed = false
    for _, t in ipairs(settled) do
      local st = drafts.find(stored, t.id)
      if st then
        st.anchor = vim.deepcopy(t.anchor)
        changed = true
      end
    end
    return changed
  end, { quiet = true })
end

--- Every revision a view of the session can put on `side`.
local function targets(session, side)
  local out = { session.head_sha, 'index' }
  table.insert(out, side == 'old' and old_now(session) or 'worktree')
  for _, e in ipairs(session.entries or {}) do
    if e.kind == 'commit' then
      table.insert(out, side == 'old' and selection.parent(e) or e.sha)
    end
  end
  local pair = session.file_pair or session.pair
  if pair and not pair.split then
    table.insert(out, model.rev_to_commit(side == 'old' and pair.left or pair.right, session.head_sha))
  end
  return out
end

--- Fetch what placing the session's threads needs, then `cb()`. The index
--- is read again every time (staging doesn't rebuild); `opts.fresh` (a
--- rebuild) forgets what was read from the worktree too.
function M.prepare(session, cb, opts)
  local review = session.review
  if session.closed or type(review) ~= 'table' or not session.head_sha then
    cb()
    return
  end
  local c = cache(session)
  local fresh = opts and opts.fresh
  for key in pairs(c.diffs) do
    local target = key:match(SEP .. '(.*)$')
    if target == 'index' or (fresh and target == 'worktree') then
      c.diffs[key] = nil
    end
  end
  for key in pairs(c.blobs) do
    if key:sub(1, 3) == ':0:' then
      c.blobs[key] = nil
    end
  end
  if fresh then
    c.live = {}
  end
  local threads = review.threads
  first_pass(session, threads, function()
    if session.closed then
      return
    end
    settle_on_head(session, threads)
    local jobs = {}
    for _, t in ipairs(threads) do
      local source = M.source(session, t)
      if source and t.anchor.side and not movable(source) and c.exists[commit_of(source)] ~= false then
        for _, target in ipairs(targets(session, t.anchor.side)) do
          local key = source .. SEP .. target
          if target and target ~= source and c.diffs[key] == nil then
            c.diffs[key] = false
            local args = { 'diff', '-M', '-U0', source }
            if target == 'index' then
              args = { 'diff', '--cached', '-M', '-U0', source }
            elseif target ~= 'worktree' then
              table.insert(args, target)
            end
            table.insert(jobs, function(done)
              git(session, args, function(res)
                c.diffs[key] = res.code == 0 and model.parse_diff_files(res.stdout or '') or 'failed'
                done()
              end)
            end)
          end
        end
        local key = source .. ':' .. t.anchor.path
        if c.blobs[key] == nil then
          c.blobs[key] = false
          table.insert(jobs, blob_job(session, c, key, key))
        end
      end
    end
    M.join(jobs, function()
      if not session.closed then
        cb()
      end
    end)
  end)
end

return M
