-- Local review backend: comments meant to be fed to an LLM. Available in
-- `:Diffy` and `:Diffy branch`. Drafts live in the branch's one store
-- (`review/drafts.lua`); `:Diffy review submit` renders
-- `.git/diffy/<branch>/review.md`.
local drafts = require('diffy.review.drafts')
local model = require('diffy.review.model')
local track = require('diffy.review.track')
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local store = require('diffy.review.store')

local M = {}

M.name = 'local'
-- Suggestion blocks are a GitHub-only feature; every comment is the user's.
M.capabilities = { resolve = true, suggestions = false, people = false }

--- Current branch name, read from `<gitdir>/HEAD` without a subprocess
--- (`session.gitdir` already resolves worktrees whose `.git` is a file).
--- Falls back to a short HEAD sha (detached) or `'detached'`.
function M.branch(session)
  local head_path = session.gitdir .. '/HEAD'
  if vim.fn.filereadable(head_path) == 1 then
    local content = vim.fn.readfile(head_path)[1] or ''
    local name = content:match('^ref: refs/heads/(.+)$')
    if name then
      return name
    end
  end
  return (session.head_sha and session.head_sha:sub(1, 7)) or 'detached'
end

local cached_author
--- `git config user.name`, cached for the process lifetime. Synchronous,
--- but only runs the first time the user writes a comment.
function M.author(root)
  if cached_author then
    return cached_author
  end
  local res = vim.system({ 'git', 'config', 'user.name' }, { cwd = root, text = true }):wait()
  local name = res.code == 0 and vim.trim(res.stdout or '') or ''
  cached_author = name ~= '' and name or (vim.env.USER or 'unknown')
  return cached_author
end

local function review_md_path(session, branch)
  return store.path(session.gitdir, branch, 'review.md')
end

-- The line under each comment's heading in `review.md`; the agent ticks it
-- (`- [x] resolved`) once the comment is handled.
local RESOLVED_BOX = '- [ ] resolved'

--- Resolve the threads whose comments the agent ticked in `review.md`. Each
--- tick counts once (`agent_resolved`), so a thread you reopen stays open;
--- only `sent` comments count, since ids are only meaningful once sent.
function M.sync(session)
  local path = review_md_path(session, session.branch)
  if vim.fn.filereadable(path) == 0 then
    return
  end
  local ticked, current = {}, nil
  for _, l in ipairs(vim.fn.readfile(path)) do
    local id = l:match('^## (c%w+) ')
    if id or l:match('^## ') then
      current = id
    elseif current then
      local mark = l:match('^%s*[-*] %[([ xX])%]%s+[Rr]esolved')
      if mark then
        ticked[current] = mark ~= ' '
        current = nil
      end
    end
  end
  if not next(ticked) then
    return
  end
  drafts.change(session, function(threads)
    local changed = false
    for _, t in ipairs(threads) do
      for _, c in ipairs(t.comments) do
        if ticked[c.id] and c.state == 'sent' and not c.agent_resolved then
          c.agent_resolved = true
          t.resolved = true
          changed = true
        end
      end
    end
    return changed
  end, { quiet = true })
end

M.save = drafts.put
M.clear = drafts.clear

--- Where `thread` shows in the open file, tracked from where it was written.
function M.place(session, thread)
  return track.place(session, thread, session.file_pair or session.pair, session.current_path)
end

--- Where `thread` shows in `pair` (default: the current one), whichever
--- file is open, or nil.
function M.view_place(session, thread, pair)
  return track.place(session, thread, pair or session.pair)
end

-- ---------------------------------------------------------------------
-- submit: review.md

local function quiet_git(session, args, on_exit)
  run.git(args, { cwd = session.root, session = session, notify_on_error = false, on_exit = on_exit })
end

--- Current buffer lines for `commit`/`path` if a loaded buffer already has
--- them (a live worktree edit), else read from disk (`worktree`) or a git
--- blob (`index`/a sha). `cb(lines|nil)`.
local function read_side(session, commit, path, cb)
  if commit == 'worktree' then
    local abspath = session.root .. '/' .. path
    -- Not bufnr(): it treats the name as a file pattern (`[id]` matches `d`).
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == abspath then
        cb(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        return
      end
    end
    if vim.fn.filereadable(abspath) == 1 then
      cb(vim.fn.readfile(abspath))
    else
      cb(nil)
    end
    return
  end
  local object = commit == 'index' and (':0:' .. path) or (commit .. ':' .. path)
  quiet_git(session, { 'show', object }, function(res)
    if res.code ~= 0 then
      cb(nil)
      return
    end
    cb(vim.split(res.stdout or '', '\n', { plain = true }))
  end)
end

--- The (left, right) rev pair whose diff produced the comment: the view it
--- was written in (`thread.view`), or for drafts saved before that was
--- recorded, a guess from the anchor's commit and side.
local function hunk_pair(thread)
  if thread.view then
    return thread.view.left, thread.view.right
  end
  local commit, side = thread.anchor.commit, thread.anchor.side
  if commit == 'worktree' then
    return 'INDEX', 'WORKTREE'
  elseif commit == 'index' then
    return side == 'old' and 'INDEX' or 'HEAD', side == 'old' and 'WORKTREE' or 'INDEX'
  end
  return commit .. '^', commit
end

local function short_commit(commit)
  if commit == 'worktree' or commit == 'index' then
    return commit
  end
  return commit:sub(1, 7)
end

local function lines_key(commit, path)
  return commit .. '\0' .. path
end

local function diff_key(thread)
  local left, right = hunk_pair(thread)
  return left .. '\0' .. right .. '\0' .. thread.anchor.path
end

local function range_text(s, e)
  return s == e and tostring(s) or ('%d-%d'):format(s, e)
end

--- 3 lines of context around `[start_line, end_line]` in `lines`, numbered.
--- Returns an array of lines (`writefile` mangles embedded `\n` within a
--- single list entry into NUL bytes rather than real line breaks).
local function numbered_excerpt(lines, start_line, end_line)
  local lo = math.max(1, start_line - 3)
  local hi = math.min(#lines, end_line + 3)
  local out = {}
  for l = lo, hi do
    table.insert(out, ('%d  %s'):format(l, lines[l] or ''))
  end
  return out
end

--- Join independently-async `jobs` (`fun(done: fun())[]`), calling `done()`
--- once every job has called its own `done`.
local function join(jobs, done)
  if #jobs == 0 then
    done()
    return
  end
  local remaining = #jobs
  for _, job in ipairs(jobs) do
    job(function()
      remaining = remaining - 1
      if remaining == 0 then
        done()
      end
    end)
  end
end

local function unsent_comments(_session, threads)
  local pending = {}
  for _, thread in ipairs(threads) do
    for _, comment in ipairs(thread.comments) do
      if comment.state ~= 'sent' then
        table.insert(pending, { thread = thread, comment = comment })
      end
    end
  end
  return pending
end

--- Where `item`'s lines are read from: its location now, else the commit
--- it was written on.
local function shown_side(item)
  local a = item.thread.anchor
  if item.now then
    return a.commit == 'index' and 'index' or 'worktree', item.now.path
  end
  return a.commit, a.path
end

--- Async-fetch every side's lines and every view's hunks that `pending`
--- needs, deduped; `done(side_lines, diff_hunks)` keyed by
--- `lines_key`/`diff_key`.
local function fetch_sources(session, pending, done)
  local sides, diffs = {}, {}
  for _, item in ipairs(pending) do
    local commit, path = shown_side(item)
    sides[lines_key(commit, path)] = { commit = commit, path = path }
    local left, right = hunk_pair(item.thread)
    diffs[diff_key(item.thread)] = { left = left, right = right, path = item.thread.anchor.path }
  end

  local side_lines, diff_hunks = {}, {}
  local jobs = {}
  for key, s in pairs(sides) do
    table.insert(jobs, function(job_done)
      read_side(session, s.commit, s.path, function(lines)
        side_lines[key] = lines or {}
        job_done()
      end)
    end)
  end
  for key, d in pairs(diffs) do
    table.insert(jobs, function(job_done)
      local args = { 'diff', '-U3' }
      vim.list_extend(args, repo.diff_args(d.left, d.right))
      vim.list_extend(args, { '--', d.path })
      quiet_git(session, args, function(res)
        diff_hunks[key] = model.parse_hunks(res.code == 0 and res.stdout or '')
        job_done()
      end)
    end)
  end
  join(jobs, function()
    done(side_lines, diff_hunks)
  end)
end

--- Append one comment's `review.md` section to `out`, its lines relocated
--- against `lines` for a worktree or index comment.
local function render_comment(out, item, lines, hunks)
  local thread, comment = item.thread, item.comment
  local a = thread.anchor
  local s, e = model.relocate(a, lines)
  if not s then
    s, e = a.start_line, a.end_line
  end
  local side_label = a.side == 'old' and 'old side' or 'new side'
  table.insert(
    out,
    ('## %s \226\128\148 %s:%s (%s) \194\183 commit %s'):format(comment.id, a.path, range_text(s, e), side_label, short_commit(a.commit))
  )
  table.insert(out, RESOLVED_BOX)
  table.insert(out, '```' .. (vim.filetype.match({ filename = a.path }) or ''))
  vim.list_extend(out, numbered_excerpt(lines, s, e))
  table.insert(out, '```')

  local hunk = model.find_hunk(hunks, a.side, a.start_line, a.end_line)
  table.insert(out, '<details><summary>diff hunk</summary>')
  table.insert(out, '')
  table.insert(out, '```diff')
  if hunk then
    vim.list_extend(out, hunk.lines)
  else
    -- no changed hunk covers this anchor (a comment on unchanged
    -- context): synthesize a context-only pseudo-hunk from the excerpt.
    local excerpt = a.excerpt or {}
    local count = #excerpt
    table.insert(out, ('@@ -%d,%d +%d,%d @@'):format(a.start_line, count, a.start_line, count))
    for _, l in ipairs(excerpt) do
      table.insert(out, ' ' .. l)
    end
  end
  table.insert(out, '```')
  table.insert(out, '</details>')
  table.insert(out, '')
  vim.list_extend(out, vim.split(comment.body, '\n', { plain = true }))
  table.insert(out, '')
end

--- `review.md`'s title lines. `base_sha` nil when there's no upstream.
local function export_header(session, branch, base_sha, base_ref)
  local base_line
  if base_sha then
    base_line = ('base: %s (%s)'):format(base_sha:sub(1, 7), base_ref)
  else
    base_line = 'base: (no upstream)'
  end
  local head_sha = session.head_sha or '?'
  local function rev_label(rev)
    return short_commit(model.rev_to_commit(rev, head_sha))
  end
  local range_desc = ('%s..%s'):format(rev_label(session.pair.left), rev_label(session.pair.right))
  return {
    '# Review of ' .. branch,
    ('%s \194\183 head: %s \194\183 range: %s'):format(base_line, head_sha:sub(1, 7), range_desc),
    '',
    ('Tick `%s` under a comment once it is handled.'):format((RESOLVED_BOX:gsub('%[ %]', '[x]'))),
    '',
  }
end

--- `cb(base_sha, upstream)`: merge-base of HEAD with its upstream, or
--- `cb(nil, nil)` if either lookup fails.
local function upstream_base(session, cb)
  quiet_git(session, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, function(res)
    if res.code ~= 0 then
      cb(nil, nil)
      return
    end
    local upstream = vim.trim(res.stdout or '')
    quiet_git(session, { 'merge-base', upstream, 'HEAD' }, function(res2)
      if res2.code ~= 0 then
        cb(nil, nil)
      else
        cb(vim.trim(res2.stdout or ''), upstream)
      end
    end)
  end)
end

--- `:Diffy review submit`: render `review.md` with `body` (the overall
--- message, may be blank) and every non-`sent` comment, mark them `sent`,
--- save, and copy the prompt to `+`. `cb(ok, warnings)`.
function M.submit(session, _event, body, cb)
  local review = session.review
  -- the ticks in the review.md about to be replaced
  M.sync(session)
  track.prepare(session, function()
    local pending = unsent_comments(session, review.threads)
    local message = vim.trim(body or '')
    if #pending == 0 and message == '' then
      vim.notify('diffy: nothing to send - no new comments and no message', vim.log.levels.WARN)
      cb(false, {})
      return
    end

    fetch_sources(session, pending, function(side_lines, diff_hunks)
      local function key(item)
        local where = item.now or item.thread.anchor
        return where.path, where.start_line
      end
      table.sort(pending, function(a, b)
        local pa, la = key(a)
        local pb, lb = key(b)
        if pa ~= pb then
          return pa < pb
        end
        return la < lb
      end)

      local out = {}
      if message ~= '' then
        table.insert(out, '## Overall')
        table.insert(out, '')
        vim.list_extend(out, vim.split(message, '\n', { plain = true }))
        table.insert(out, '')
      end
      for _, item in ipairs(pending) do
        render_comment(out, item, side_lines[lines_key(shown_side(item))] or {}, diff_hunks[diff_key(item.thread)] or {})
      end

      upstream_base(session, function(base_sha, base_ref)
        local branch = review.branch
        local lines = export_header(session, branch, base_sha, base_ref)
        vim.list_extend(lines, out)
        local path = review_md_path(session, branch)
        vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
        vim.fn.writefile(lines, path)

        local sent = {}
        for _, item in ipairs(pending) do
          sent[item.comment.id] = true
        end
        drafts.change(session, function(threads)
          for _, t in ipairs(threads) do
            for _, c in ipairs(t.comments) do
              if sent[c.id] then
                c.state = 'sent'
              end
            end
          end
        end)

        vim.fn.setreg('+', require('diffy').config.review_prompt:format(path))
        vim.notify(('diffy: review written to %s, prompt copied to +'):format(path))
        cb(true, {})
      end)
    end)
  end)
end

return M
