-- Pure review data model: Thread/Comment/Anchor shapes, excerpt relocation,
-- rev<->commit-field mapping, ids, unified-diff hunk parsing and line
-- tracking: the one placement rule (`M.source`, `M.track`). Uses only vim.*
-- helpers (no vim.api, no subprocesses), so it's testable with plain tables.
--
--   Thread  { id, backend, anchor, comments = {}, resolved, outdated, view }
--   Comment { id, author, body, created_at, state = draft|pending|published|sent }
--   Anchor  { path, side = old|new, start_line, end_line, commit, excerpt, base_relative }
--
-- `commit` is 'worktree', 'index', or a commit-ish: the rev shown on `side`
-- when the comment was written, which it is tracked from. `excerpt` is the
-- array of lines that were anchored, used by `M.relocate` to re-find a
-- worktree or index comment. `base_relative`: an old-side GitHub comment,
-- whose lines are the merge-base's whatever its commit.
local M = {}

M.COMMENT_ICON = '\240\159\146\172'

--- Unified-diff `@@ -os[,oc] +ns[,nc] @@` header: the four numbers as
--- strings (counts '' when omitted), or nil if `line` isn't a header.
local function hunk_header(line)
  return line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
end

--- A pair's rev sentinels ('WORKTREE'/'INDEX'/'HEAD'/sha) -> an
--- Anchor's `commit` value ('worktree'/'index'/sha). `HEAD` resolves to the
--- concrete sha so an Anchor stays valid after new commits.
function M.rev_to_commit(rev, head_sha)
  if rev == 'WORKTREE' then
    return 'worktree'
  elseif rev == 'INDEX' then
    return 'index'
  elseif rev == 'HEAD' then
    return head_sha
  end
  return rev
end

--- The rev `thread` is tracked from: its anchor's commit, the merge-base for
--- an old-side GitHub comment. nil when it has none (GitHub found no local
--- commit for it, or the merge-base isn't known).
function M.source(thread, merge_base)
  if thread._has_source == false then
    return nil
  end
  local a = thread.anchor
  if a.side == 'old' and a.base_relative then
    return merge_base
  end
  return a.commit
end

--- Re-locate `anchor` against `lines` (the current content of its side):
--- search outward from the stored `start_line`, within +/-20 lines, for an
--- exact match of `anchor.excerpt`. Returns the matching `start_line,
--- end_line`, or nil (callers treat the thread as detached).
function M.relocate(anchor, lines)
  local excerpt = anchor.excerpt or {}
  local n = #excerpt
  if n == 0 or #lines < n then
    return nil
  end
  local function matches(start)
    if start < 1 or start + n - 1 > #lines then
      return false
    end
    for i = 1, n do
      if lines[start + i - 1] ~= excerpt[i] then
        return false
      end
    end
    return true
  end
  local origin = anchor.start_line
  if matches(origin) then
    return origin, origin + n - 1
  end
  for d = 1, 20 do
    for _, start in ipairs({ origin - d, origin + d }) do
      if matches(start) then
        return start, start + n - 1
      end
    end
  end
  return nil
end

--- A new thread/comment id: `prefix`, the time in ms and random bits, so two
--- nvims drafting at once never pick the same one.
function M.new_id(prefix)
  local sec, usec = vim.uv.gettimeofday()
  local rand = vim.uv.random(3)
  local hex = rand and rand:gsub('.', function(ch)
    return ('%02x'):format(ch:byte())
  end) or ('%06x'):format(math.random(0, 0xffffff))
  return ('%s%x%03x%s'):format(prefix, sec, math.floor(usec / 1000), hex)
end

--- One-line `virt_lines` summary: `💬 <first author>[ +N][ · resolved]`,
--- N being the number of comments beyond the first.
function M.summary_text(thread)
  local first = thread.comments[1]
  local text = M.COMMENT_ICON .. ' ' .. (first and first.author or 'unknown')
  local extra = #thread.comments - 1
  if extra > 0 then
    text = text .. (' +%d'):format(extra)
  end
  if thread.resolved then
    text = text .. ' \194\183 resolved'
  end
  return text
end

--- Seconds since the epoch of a comment's `created_at`: `os.time()` for
--- local drafts, an ISO 8601 UTC string from GitHub. nil if unparseable.
function M.epoch(t)
  if type(t) == 'number' then
    return t
  end
  local y, mo, d, h, mi, s = tostring(t or ''):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then
    return nil
  end
  local now = os.time()
  -- os.time reads a table as local time: add the local UTC offset back
  local offset = os.difftime(now, os.time(os.date('!*t', now)))
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }) + offset
end

--- When a thread was started (its first comment), for ordering; 0 if unknown.
function M.started(thread)
  local first = thread.comments[1]
  return first and M.epoch(first.created_at) or 0
end

--- The code `thread` is on, for showing next to it: rows `{ n, text, kind =
--- 'add'|'del'|nil, range }` (`range`: one of the commented lines) and at
--- most one `{ gap = count }` where rows were cut. From the excerpt (drafts)
--- or else the first comment's diff hunk (GitHub, which ends on the
--- commented line), with up to 3 lines of context above the range; past
--- `max` rows the middle is cut. nil for file-level threads or when neither
--- is known.
function M.snippet(thread, max)
  local a = thread.anchor
  if not a.side or not a.start_line then
    return nil
  end
  local rows = {}
  local raw = thread._raw_comments and thread._raw_comments[1]
  if a.excerpt and #a.excerpt > 0 then
    for i, l in ipairs(a.excerpt) do
      rows[i] = { n = a.start_line + i - 1, text = l, range = true }
    end
  elseif raw and type(raw.diffHunk) == 'string' then
    local hunk, o, n = {}, nil, nil
    for _, l in ipairs(vim.split(raw.diffHunk, '\n', { plain = true })) do
      local old_s, _, new_s = hunk_header(l)
      if old_s then
        o, n = tonumber(old_s), tonumber(new_s)
      elseif o then
        local c, text = l:sub(1, 1), l:sub(2)
        if c == '+' then
          table.insert(hunk, { n = n, text = text, kind = 'add', side = 'new' })
          n = n + 1
        elseif c == '-' then
          table.insert(hunk, { n = o, text = text, kind = 'del', side = 'old' })
          o = o + 1
        elseif c == ' ' then
          table.insert(hunk, { n = a.side == 'old' and o or n, text = text })
          o, n = o + 1, n + 1
        end
      end
    end
    -- the range is the hunk's last lines on the commented side
    local want = (a.end_line or a.start_line) - a.start_line + 1
    local first, seen = #hunk + 1, 0
    for i = #hunk, 1, -1 do
      if seen == want then
        break
      end
      if not hunk[i].side or hunk[i].side == a.side then
        seen = seen + 1
      end
      first = i
    end
    for i = math.max(1, first - 3), #hunk do
      local h = hunk[i]
      table.insert(rows, { n = h.n, text = h.text, kind = h.kind, range = i >= first and (not h.side or h.side == a.side) })
    end
  end
  if #rows == 0 then
    return nil
  end
  if #rows > max then
    -- keep more of the end: GitHub hangs a comment on its range's last line
    local head = math.floor((max - 1) / 3)
    local tail = max - 1 - head
    local cut = vim.list_slice(rows, 1, head)
    table.insert(cut, { gap = #rows - head - tail })
    rows = vim.list_extend(cut, vim.list_slice(rows, #rows - tail + 1, #rows))
  end
  return rows
end

--- Parse one file's unified diff (`git diff -U*`) into hunks:
--- `{ old_start, old_count, new_start, new_count, lines (incl. @@ header) }[]`.
function M.parse_hunks(diff_text)
  local hunks = {}
  local cur
  for _, line in ipairs(vim.split(diff_text or '', '\n', { plain = true })) do
    local old_s, oc, new_s, nc = hunk_header(line)
    if old_s then
      cur = {
        old_start = tonumber(old_s),
        old_count = (oc ~= '' and tonumber(oc)) or 1,
        new_start = tonumber(new_s),
        new_count = (nc ~= '' and tonumber(nc)) or 1,
        lines = { line },
      }
      table.insert(hunks, cur)
    elseif cur then
      table.insert(cur.lines, line)
    end
  end
  return hunks
end

--- A hunk's `start, count` on `side` ('old'/'new').
local function side_range(h, side)
  if side == 'old' then
    return h.old_start, h.old_count
  end
  return h.new_start, h.new_count
end

--- The hunk (from `M.parse_hunks`) whose `side` ('old'/'new') range
--- overlaps `[start_line, end_line]`, or nil.
function M.find_hunk(hunks, side, start_line, end_line)
  for _, h in ipairs(hunks) do
    local s, c = side_range(h, side)
    if start_line <= s + c - 1 and end_line >= s then
      return h
    end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- GitHub backend line-tracking/placement helpers. `review/github.lua`
-- supplies the diff text; these only interpret it.

--- Split a multi-file unified diff (`git diff [-M] X Y`, any context width,
--- incl. `-U0`) into one record per file: `{ old_path, new_path, hunks }[]`
--- (`hunks` via `M.parse_hunks`). A rename's `diff --git a/old b/new`
--- header carries both names; every other file has `old_path == new_path`.
function M.parse_diff_files(diff_text)
  local files = {}
  local cur_lines
  for _, line in ipairs(vim.split(diff_text or '', '\n', { plain = true })) do
    local a, b = line:match('^diff %-%-git a/(.-) b/(.*)$')
    if a then
      cur_lines = {}
      table.insert(files, { old_path = a, new_path = b, lines = cur_lines })
    elseif cur_lines then
      table.insert(cur_lines, line)
    end
  end
  for _, f in ipairs(files) do
    f.hunks = M.parse_hunks(table.concat(f.lines, '\n'))
    f.lines = nil
  end
  return files
end

--- The hunks of the file named `path` on `side` ('old', the default, or
--- 'new') in `files` (from `M.parse_diff_files`), and the file's name on
--- the other side. A file absent from the diff is unchanged: returns
--- `path` itself and `{}`.
function M.diff_file_hunks(files, path, side)
  local new = side == 'new'
  for _, f in ipairs(files) do
    if (new and f.new_path or f.old_path) == path then
      return new and f.old_path or f.new_path, f.hunks
    end
  end
  return path, {}
end

--- Map one line from the diff's old side to its new side, `nil` if `line`
--- falls inside a changed hunk (unmappable). `hunks` sorted ascending by
--- `old_start` (git's own diff order). A zero-count hunk (`@@ -N,0 …@@`,
--- pure insertion after old line N) doesn't cover line `N` itself - only
--- lines strictly after it get this hunk's offset.
function M.map_line(hunks, line)
  local offset = 0
  for _, h in ipairs(hunks) do
    local old_end = h.old_start + h.old_count - 1
    local before_cutoff = h.old_count == 0 and h.old_start or (h.old_start - 1)
    if line <= before_cutoff then
      return line + offset
    elseif h.old_count > 0 and line <= old_end then
      return nil
    else
      offset = offset + (h.new_count - h.old_count)
    end
  end
  return line + offset
end

--- Map a range `[start_line, end_line]` the same way: both endpoints must
--- map (lines inside the range may still have changed).
function M.map_range(hunks, start_line, end_line)
  local s = M.map_line(hunks, start_line)
  local e = M.map_line(hunks, end_line)
  if not s or not e then
    return nil
  end
  return s, e
end

--- Where `anchor`'s range lands across one diff from its source: `files`
--- (from `M.parse_diff_files`) or the file's own `hunks`. `{ path,
--- start_line, end_line }`, `path` being the file's name on the far side,
--- or nil when either end falls in a changed hunk.
function M.track(anchor, files, hunks)
  local path = anchor.path
  if files then
    path, hunks = M.diff_file_hunks(files, anchor.path)
  end
  local s, e = M.map_range(hunks, anchor.start_line, anchor.end_line)
  if not s then
    return nil
  end
  return { path = path, start_line = s, end_line = e }
end

--- `-U0` hunks (as `M.parse_hunks` gives, without `lines`) between two line
--- arrays.
function M.line_hunks(a, b)
  local hunks = {}
  local text_a = #a > 0 and (table.concat(a, '\n') .. '\n') or ''
  local text_b = #b > 0 and (table.concat(b, '\n') .. '\n') or ''
  for _, h in ipairs(vim.diff(text_a, text_b, { result_type = 'indices' })) do
    table.insert(hunks, { old_start = h[1], old_count = h[2], new_start = h[3], new_count = h[4] })
  end
  return hunks
end

--- Whether `[start_line, end_line]` on `side` ('old'/'new') is a changed
--- line or within 3 context lines of one, i.e. commentable on GitHub.
--- `hunks` must come from a `-U0` diff of `merge-base...C`: this function
--- adds the ±3 window itself, so a wider diff would double-count context.
--- `nil` `side` (file-level comment) is always valid.
function M.anchor_valid(hunks, side, start_line, end_line)
  if not side then
    return true
  end
  for _, h in ipairs(hunks) do
    local s, c = side_range(h, side)
    local lo, hi = s - 3, s + math.max(c, 1) - 1 + 3
    if start_line <= hi and end_line >= lo then
      return true
    end
  end
  return false
end

--- GitHub's `position` for `addPullRequestReviewComment`: the 1-based index
--- of the diff line for `line` below the file's first `@@` header
--- (`diff_lines` is one file's section of a unified diff; later `@@`
--- headers count as lines too). `side` 'old' looks for `line` on the old
--- side, a `-` line first (a LEFT comment), else the unchanged line; the
--- default is the new side. `nil` if the diff doesn't show `line`.
function M.diff_position(diff_lines, line, side)
  local old = side == 'old'
  local pos, ol, nl = nil, nil, nil
  local context
  for _, l in ipairs(diff_lines) do
    local old_start, _, new_start = hunk_header(l)
    if new_start then
      pos = pos and (pos + 1) or 0
      ol, nl = tonumber(old_start) - 1, tonumber(new_start) - 1
    elseif pos and l:sub(1, 1) == '\\' then
      pos = pos + 1 -- `\ No newline at end of file`: a diff line, but on neither side
    elseif pos then
      pos = pos + 1
      local kind = l:sub(1, 1)
      if kind ~= '+' then
        ol = ol + 1
      end
      if kind ~= '-' then
        nl = nl + 1
      end
      if old then
        if ol == line and kind == '-' then
          return pos
        elseif ol == line and kind == ' ' then
          context = context or pos
        end
      elseif kind ~= '-' and nl == line then
        return pos
      end
    end
  end
  return context
end

--- Badges `{ text, hl }` for comment `c` in a card or a threads row: where
--- it stands on GitHub and against the agent, and its conflicts.
function M.comment_badges(c)
  if c._edit then
    return { { 'your edit', 'DiffyThreadStaged' } }
  end
  if c.state == 'published' then
    if c.staged_delete then
      return { { 'deletion staged', 'DiffyThreadStaged' } }
    elseif c.staged_conflict then
      return { { 'edited on github.com', 'DiffyThreadConflict' } }
    elseif c.staged_body then
      return { { 'edit staged', 'DiffyThreadStaged' } }
    end
    return {}
  end
  if c.origin then
    return { { c.origin, 'DiffyThreadConflict' } }
  end
  local out = {}
  if c.conflict then
    table.insert(out, { 'conflict', 'DiffyThreadConflict' })
  end
  if c.state == 'draft' then
    if c.gh then
      table.insert(out, { 'pending', 'DiffyThreadPending' })
    elseif c.blocked then
      table.insert(out, { 'local only: ' .. c.blocked, 'DiffyThreadDraft' })
    else
      table.insert(out, { 'draft', 'DiffyThreadDraft' })
    end
  elseif c.state == 'pending' then
    table.insert(out, { 'pending', 'DiffyThreadPending' })
  elseif c.state == 'sent' then
    table.insert(out, { 'sent', 'DiffyThreadSent' })
  end
  return out
end

--- Badges for the thread itself: a staged resolve.
function M.thread_badges(t)
  if t.resolve_staged then
    return { { t.resolved and 'unresolve staged' or 'resolve staged', 'DiffyThreadStaged' } }
  end
  return {}
end

--- Sync conflicts waiting for you in `t`.
function M.conflicts(t)
  local n = 0
  for _, c in ipairs(t.comments) do
    if c.conflict or c.staged_conflict then
      n = n + 1
    end
  end
  return n
end

return M
