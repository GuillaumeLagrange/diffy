-- A guide to the branch: the diff merge-base..HEAD told as ordered sections,
-- each a title, a body saying why that part of the change exists and what
-- deserves attention, and the line ranges it covers. Kept in
-- `.git/diffy/<branch>/guide.json`, written by `config.guide.agent` (`gG`,
-- `:Diffy guide`) or by anyone following the format in `:help diffy-guide`.
--
-- The ranges are the author's, cutting git's hunks as they see fit; diffy
-- matches them to `git diff -U0 base head` (`M.resolve`) and lists every
-- change no section claims under `Not in the guide`, so a guide can't hide
-- anything.
local run = require('diffy.git.run')
local store = require('diffy.review.store')

local M = {}

M.FILE = 'guide.json'
M.UNGUIDED = 'Not in the guide'

-- `--mode json` streams omp's events: what it's doing shows while it runs
local OMP = { 'omp', '-p', '--mode', 'json', '--no-session', '--no-title', '--tools', 'read,grep,glob,bash' }

function M.path(gitdir, branch)
  return store.path(gitdir, branch, M.FILE)
end

--- The agent's command (its prompt goes last), nil when none is configured.
function M.agent_cmd()
  local agent = (require('diffy').config.guide or {}).agent
  if agent == 'omp' then
    return vim.deepcopy(OMP)
  elseif type(agent) == 'table' and #agent > 0 then
    return vim.deepcopy(agent)
  end
  return nil
end

local function str(v)
  return type(v) == 'string' and v ~= '' and v or nil
end

local function int(v)
  return type(v) == 'number' and v >= 0 and math.floor(v) or nil
end

--- A decoded guide file as `{ base, head, sections = { { title, body, hunks =
--- { { path, side, start?, end?, note? } } } } }`, or nil and why.
function M.parse(data)
  if type(data) ~= 'table' or type(data.sections) ~= 'table' then
    return nil, 'no sections'
  end
  local out = { base = str(data.base), head = str(data.head), sections = {} }
  for _, s in ipairs(data.sections) do
    if type(s) == 'table' and str(s.title) then
      local sec = { title = vim.trim(s.title), body = str(s.body) or '', hunks = {} }
      for _, h in ipairs(type(s.hunks) == 'table' and s.hunks or {}) do
        if type(h) == 'table' and str(h.path) then
          local a, b = int(h.start), int(h['end'])
          if a and b and b < a then
            a, b = b, a
          end
          table.insert(sec.hunks, {
            path = h.path,
            side = h.side == 'old' and 'old' or 'new',
            start = a,
            ['end'] = b or a,
            note = str(h.note) and vim.trim((h.note:gsub('\n.*', ''))) or nil,
          })
        end
      end
      table.insert(out.sections, sec)
    end
  end
  if #out.sections == 0 then
    return nil, 'no sections'
  end
  return out
end

local function unquote(path)
  path = path:gsub('\t$', '')
  if path:sub(1, 1) == '"' then
    path = path:sub(2, -2):gsub('\\(.)', { t = '\t', n = '\n', ['"'] = '"', ['\\'] = '\\' })
  end
  return path
end

--- `git diff -U0 -M` output as `{ { path, old_path, hunks = { { old_start,
--- old_count, new_start, new_count, header } } } }`, one entry per file in
--- git's order. `path` is the new name, the old one for a deleted file.
function M.parse_diff(text)
  local files, cur = {}, nil
  for line in (text or ''):gmatch('[^\n]*') do
    local a, b = line:match('^diff %-%-git "?a/(.-)"? "?b/(.*)$')
    if a then
      cur = { path = unquote(b:gsub('"$', '')), old_path = unquote(a), hunks = {} }
      table.insert(files, cur)
    elseif cur then
      local os, oc, ns, nc, header = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$')
      if os then
        table.insert(cur.hunks, {
          old_start = tonumber(os),
          old_count = oc == '' and 1 or tonumber(oc),
          new_start = tonumber(ns),
          new_count = nc == '' and 1 or tonumber(nc),
          header = vim.trim(header),
          path = cur.path,
        })
      elseif #cur.hunks == 0 then
        local from, to = line:match('^rename from (.*)$'), line:match('^rename to (.*)$')
        local minus, plus = line:match('^%-%-%- a/(.*)$'), line:match('^%+%+%+ b/(.*)$')
        if from or minus then
          cur.old_path = unquote(from or minus)
        elseif to or plus then
          cur.path = unquote(to or plus)
        elseif line:match('^%+%+%+ /dev/null') then
          cur.deleted = true
        elseif line:match('^new file mode') then
          cur.added = true
        end
      end
    end
  end
  for _, f in ipairs(files) do
    if f.deleted then
      f.path = f.old_path
    end
  end
  return files
end

--- A git hunk's lines on `side` as an inclusive range; an empty side (a pure
--- addition or deletion) is the point between `start` and `start + 1`.
local function span(h, side)
  local s, c = h[side .. '_start'], h[side .. '_count']
  if c == 0 then
    return s + 1, s
  end
  return s, s + c - 1
end

local function touches(h, side, a, b)
  local s, e = span(h, side)
  if e < s then
    -- the point between lines e and s
    return a <= s and b >= e
  end
  return a <= e and b >= s
end

local function sum(hunks)
  local added, removed = 0, 0
  for _, h in ipairs(hunks) do
    added, removed = added + h.new_count, removed + h.old_count
  end
  return added, removed
end

--- Match `guide`'s ranges to the diff's `files` (`M.parse_diff`). Returns
--- `{ sections = { { title, body, hunks = { { path, old_path, notes = { {
--- text, git } }, git = { git hunks }, added, removed, header } } } }, files
--- = { path -> file }, dropped = n }`: one item per file in a section, its
--- ranges' git hunks in file order, each note with its range's git hunks;
--- each git hunk gets `owners`, the sections claiming it; a range touching
--- no change is dropped. The last section, `Not in the guide`, holds the
--- changes no range touches (a file without hunks, a binary or a pure
--- rename).
function M.resolve(guide, files)
  local by_path = {}
  for _, f in ipairs(files) do
    by_path[f.path] = f
    if f.old_path and not by_path[f.old_path] then
      by_path[f.old_path] = f
    end
    for _, h in ipairs(f.hunks) do
      h.owners = {}
    end
  end
  local out, dropped, claimed_files = { sections = {}, files = {} }, 0, {}
  for _, f in ipairs(files) do
    out.files[f.path] = f
  end
  -- `git` joins the file's item in `sec`, made on its first range
  local function add(sec, f, git, note)
    local it = sec.by_file[f]
    if not it then
      it = { path = f.path, old_path = f.old_path, notes = {}, git = {} }
      sec.by_file[f] = it
      table.insert(sec.hunks, it)
    end
    for _, gh in ipairs(git) do
      if not vim.tbl_contains(it.git, gh) then
        table.insert(it.git, gh)
      end
    end
    if note then
      table.insert(it.notes, { text = note, git = git })
    end
  end
  local function finish(sec)
    for f, it in pairs(sec.by_file) do
      local order = {}
      for i, gh in ipairs(f.hunks) do
        order[gh] = i
      end
      table.sort(it.git, function(a, b)
        return order[a] < order[b]
      end)
      it.added, it.removed = sum(it.git)
      it.header = it.git[1] and it.git[1].header or nil
    end
    sec.by_file = nil
  end
  for si, s in ipairs(guide.sections) do
    local sec = { title = s.title, body = s.body, hunks = {}, index = si, by_file = {} }
    for _, h in ipairs(s.hunks) do
      local f = by_path[h.path]
      if f then
        local git = {}
        for _, gh in ipairs(f.hunks) do
          if not h.start or touches(gh, h.side, h.start, h['end']) then
            table.insert(git, gh)
            if not vim.tbl_contains(gh.owners, si) then
              table.insert(gh.owners, si)
            end
          end
        end
        if #git > 0 or (#f.hunks == 0 and not h.start) then
          claimed_files[f] = claimed_files[f] or #f.hunks == 0
          add(sec, f, git, h.note)
        else
          dropped = dropped + 1
        end
      else
        dropped = dropped + 1
      end
    end
    finish(sec)
    table.insert(out.sections, sec)
  end
  local rest = { title = M.UNGUIDED, body = '', hunks = {}, unguided = true, by_file = {} }
  for _, f in ipairs(files) do
    if #f.hunks == 0 then
      if not claimed_files[f] then
        add(rest, f, {})
      end
    else
      for _, gh in ipairs(f.hunks) do
        if #gh.owners == 0 then
          add(rest, f, { gh })
        end
      end
    end
  end
  finish(rest)
  if #rest.hunks > 0 then
    rest.index = #out.sections + 1
    table.insert(out.sections, rest)
    for _, it in ipairs(rest.hunks) do
      for _, gh in ipairs(it.git) do
        table.insert(gh.owners, rest.index)
      end
    end
  end
  out.dropped = dropped
  return out
end

--- Folds for showing only `focus`'s changes (a set of git hunks) in a file
--- with `hunks` (sorted, `-U0`): every line further than `context` from a
--- focused hunk, other hunks included. Each fold is `{ old = {a, b}, new =
--- {a, b}, hunks = { git hunks inside } }`, counterpart ranges so both
--- windows fold alike; a stretch with no line on one side isn't folded.
function M.regions(hunks, focus, context, old_len, new_len)
  -- pieces: alternating unchanged stretches and hunks, both sides' ranges
  local pieces, o, n = {}, 1, 1
  for _, h in ipairs(hunks) do
    local os, oe = span(h, 'old')
    local ns, ne = span(h, 'new')
    if os > o then
      table.insert(pieces, { old = { o, os - 1 }, new = { n, ns - 1 } })
    end
    table.insert(pieces, { old = { os, oe }, new = { ns, ne }, hunk = h, focus = focus[h] or false })
    o, n = oe + 1, ne + 1
  end
  if o <= old_len or n <= new_len then
    table.insert(pieces, { old = { o, old_len }, new = { n, new_len } })
  end
  -- what of each unchanged stretch stays open: `context` lines beside a focused hunk
  local folds, cur = {}, nil
  local function hide(old, new, hunk)
    if old[2] < old[1] and new[2] < new[1] then
      return
    end
    if not cur then
      cur = { old = { old[1], old[2] }, new = { new[1], new[2] }, hunks = {} }
      -- a hunk empty on one side has its filler above its next line: start
      -- on the unchanged line before it so the filler is inside the fold
      if hunk and (old[2] < old[1] or new[2] < new[1]) and old[1] > 1 and new[1] > 1 then
        cur.old[1], cur.new[1] = old[1] - 1, new[1] - 1
      end
    else
      cur.old[2], cur.new[2] = old[2], new[2]
    end
    if hunk then
      table.insert(cur.hunks, hunk)
    end
  end
  local function close()
    if cur and cur.old[2] >= cur.old[1] and cur.new[2] >= cur.new[1] then
      table.insert(folds, cur)
    end
    cur = nil
  end
  for i, p in ipairs(pieces) do
    if p.hunk then
      if p.focus then
        close()
      else
        hide(p.old, p.new, p.hunk)
      end
    else
      local len = p.old[2] - p.old[1] + 1
      local before = pieces[i - 1] and pieces[i - 1].focus and context or 0
      local after = pieces[i + 1] and pieces[i + 1].focus and context or 0
      if before + after >= len then
        close()
      else
        if before > 0 then
          close()
        end
        hide({ p.old[1] + before, p.old[2] - after }, { p.new[1] + before, p.new[2] - after })
        if after > 0 then
          close()
        end
      end
    end
  end
  close()
  return folds
end

--- The JSON object in an agent's answer: the whole text, else what a
--- ```json fence holds, else from the first `{` to the last `}`.
function M.extract_json(text)
  text = vim.trim(text or '')
  local fenced = text:match('```json%s*\n(.-)\n```') or text:match('```%s*\n(.-)\n```')
  local candidates = { text, fenced or false, text:match('^.-(%b{}).-$') or false, text:match('(%{.*%})') or false }
  for _, c in ipairs(candidates) do
    local ok, data = false, nil
    if c then
      ok, data = pcall(vim.json.decode, c, { luanil = { object = true, array = true } })
    end
    if ok and type(data) == 'table' then
      return data
    end
  end
  return nil
end

function M.prompt(base, head)
  return table.concat({
    'You are writing a review guide for the changes in this git repository between the merge-base '
      .. base
      .. ' and the branch head '
      .. head
      .. ('. Run `git log --reverse %s..%s` and `git diff %s %s`, and read whatever code you need to understand the change.'):format(base, head, base, head),
    '',
    'The guide gives a human reviewer the high-level context the diff alone does not: why each part of the change exists, and what deserves attention (risky logic, behaviour changes, edge cases, missing handling). It does not narrate the diff: the reviewer reads the code, and asks about details separately.',
    'A body is one to three short lines: the why in one sentence, then at most a few terse bullets of what to check. Never describe what the code does step by step, nor list its options, env vars or mechanics.',
    'Group the changes into sections, the core of the change first; supporting changes (plumbing, renames, tests, docs) go in later sections. Split or merge git hunks as the explanation needs: a range may cover part of a hunk or several.',
    '',
    'Answer with one JSON object and nothing else:',
    '{"sections": [{"title": "short title", "body": "markdown, one to three short lines: why, then what to check", "hunks": [{"path": "path/in/head", "side": "new", "start": 12, "end": 30, "note": "a few words: what to look at"}]}]}',
    '',
    'start/end are 1-based line numbers in the file at ' .. head .. ' (side "new"). Use side "old" with line numbers in the file at ' .. base .. ' only for code that was removed and has no new lines. Omit start/end to mean the whole file. Every changed line should belong to a section.',
  }, '\n')
end

-- guide path -> `{ started, steps, activity? }` while an agent writes it
local running = {}

--- The agent run writing this guide, nil when none is.
function M.progress(gitdir, branch)
  return running[M.path(gitdir, branch)]
end

function M.running(gitdir, branch)
  return M.progress(gitdir, branch) ~= nil
end

--- Whether `cmd` answers omp's `--mode json` event stream.
local function json_events(cmd)
  for i = 1, #cmd - 1 do
    if cmd[i] == '--mode' and cmd[i + 1] == 'json' then
      return true
    end
  end
  return false
end

local function message_text(message)
  local parts = {}
  for _, c in ipairs(type(message.content) == 'table' and message.content or {}) do
    if c.type == 'text' and type(c.text) == 'string' then
      table.insert(parts, c.text)
    end
  end
  return table.concat(parts)
end

--- One line of omp's event stream: a tool starting is a step (its intent is
--- the activity), an assistant message is the answer so far.
local function on_event(st, line)
  local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not (ok and type(ev) == 'table') then
    return false
  end
  if ev.type == 'tool_execution_start' then
    st.steps = st.steps + 1
    st.activity = type(ev.intent) == 'string' and ev.intent or ev.toolName
    return true
  elseif ev.type == 'message_end' and type(ev.message) == 'table' and ev.message.role == 'assistant' then
    local text = message_text(ev.message)
    if text ~= '' then
      st.answer = text
    end
  end
  return false
end

--- Ask the agent for a guide to `base..head` and save it; `cb(ok, err)`.
--- `on_progress()` runs when the agent starts a new step. Not bound to a
--- session: the guide is the branch's, whoever asked.
function M.generate(root, gitdir, branch, base, head, cb, on_progress)
  local cmd = M.agent_cmd()
  local path = M.path(gitdir, branch)
  if not cmd then
    cb(false, 'no agent configured (`guide.agent`)')
    return
  elseif running[path] then
    cb(false, 'already running')
    return
  end
  local st = { started = vim.uv.now(), steps = 0 }
  running[path] = st
  local events = json_events(cmd)
  table.insert(cmd, M.prompt(base, head))
  -- the pieces of the line not ended yet: a line can be tens of KB (tool
  -- output, the run's summary), so only each new chunk is searched
  local out, partial = {}, {}
  run.run(cmd, {
    cwd = root,
    notify_on_error = false,
    on_stdout = function(chunk)
      if not events then
        table.insert(out, chunk)
        return
      end
      local moved, from = false, 1
      while true do
        local nl = chunk:find('\n', from, true)
        if not nl then
          break
        end
        table.insert(partial, chunk:sub(from, nl - 1))
        moved = on_event(st, table.concat(partial)) or moved
        partial = {}
        from = nl + 1
      end
      if from <= #chunk then
        table.insert(partial, chunk:sub(from))
      end
      if moved and on_progress then
        on_progress()
      end
    end,
    on_exit = function(res)
      running[path] = nil
      if res.code ~= 0 then
        cb(false, ('the agent failed (%d): %s'):format(res.code, vim.trim(res.stderr or ''):sub(1, 500)))
        return
      end
      if events and #partial > 0 then
        on_event(st, table.concat(partial))
      end
      local data = M.extract_json(events and st.answer or table.concat(out))
      local guide, err = M.parse(data)
      if not guide then
        cb(false, 'the agent answered no guide (' .. err .. ')')
        return
      end
      data.base, data.head = base, head
      store.save(path, data)
      cb(true, nil, vim.uv.now() - st.started)
    end,
  })
end

--- Read the branch's guide and match it to its diff: `cb(state)`, `state` nil
--- without a guide file, else `{ guide, resolved?, error? }`.
function M.load(root, gitdir, branch, cb, session)
  local path = M.path(gitdir, branch)
  local data = store.load(path)
  if not data then
    cb(vim.fn.filereadable(path) == 1 and { error = 'guide.json is not valid JSON' } or nil)
    return
  end
  local guide, err = M.parse(data)
  if not guide then
    cb({ error = 'guide.json: ' .. err })
    return
  elseif not (guide.base and guide.head) then
    cb({ error = 'guide.json: no base/head' })
    return
  end
  run.git({ '-c', 'core.quotePath=false', 'diff', '-U0', '-M', '--no-color', '--no-ext-diff', guide.base, guide.head }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        cb({ guide = guide, error = 'git diff failed: ' .. vim.trim(res.stderr or '') })
        return
      end
      cb({ guide = guide, resolved = M.resolve(guide, M.parse_diff(res.stdout)) })
    end,
  })
end

return M
