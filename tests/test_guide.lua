-- The guide tab: a branch's guide.json matched to its diff, the tab next to
-- the files, a section's changes alone in the diff, and the agent writing it.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')
local guide = require('diffy.guide')

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local snapshot
local repo

-- the branch's one commit against main's f.lua (60 lines): three lines added
-- after line 10, lines 30-32 deleted, line 50 changed; and a new file
local function edited(cur)
  local out = {}
  for i, l in ipairs(cur) do
    if i == 50 then
      table.insert(out, 'CHANGED 50')
    elseif i < 30 or i > 32 then
      table.insert(out, l)
    end
    if i == 10 then
      vim.list_extend(out, { 'ADD a', 'ADD b', 'ADD c' })
    end
  end
  return out
end

local SECTIONS = {
  {
    title = 'Adds',
    body = 'Why the lines were added.',
    hunks = {
      { path = 'f.lua', start = 11, ['end'] = 13, note = 'three new lines' },
      { path = 'f.lua', start = 50, ['end'] = 50, note = 'one changed line' },
    },
  },
  { title = 'Removal', body = 'Why they went.', hunks = { { path = 'f.lua', side = 'old', start = 30, ['end'] = 32, note = 'gone' } } },
}

local function shas()
  return ui.git(repo.dir, { 'merge-base', 'main', 'HEAD' }), ui.git(repo.dir, { 'rev-parse', 'HEAD' })
end

local function write_guide(data)
  local dir = repo.dir .. '/.git/diffy/feat'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ vim.json.encode(data) }, dir .. '/guide.json')
end

local function open()
  child.fn.chdir(repo.dir)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
end

local function tree_texts()
  return vim.tbl_map(function(r)
    return vim.trim(r.text)
  end, ui.panel(child, 'tree'))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.o.lines, child.o.columns = 60, 160
      snapshot = leak.snapshot(child)
      repo = Repo.new()
      repo:commit('base', { ['f.lua'] = Repo.lines(60, 'f') })
      repo:branch('feat')
      repo:commit('C1', { ['f.lua'] = edited, ['h.lua'] = Repo.lines(4, 'h') })
    end,
    post_case = function()
      leak.check(child, snapshot)
      repo:destroy()
    end,
  },
})

-- ---------------------------------------------------------------------
-- matching a guide to the diff

local DIFF = table.concat({
  'diff --git a/f.lua b/f.lua',
  'index 1..2 100644',
  '--- a/f.lua',
  '+++ b/f.lua',
  '@@ -10,0 +11,3 @@ f10',
  '+a',
  '+b',
  '+c',
  '@@ -30,3 +32,0 @@ f29',
  '-x',
  '-y',
  '-z',
  '@@ -50 +50 @@ f49',
  '-f50',
  '+CHANGED',
  'diff --git a/img.png b/img.png',
  'index 3..4 100644',
  'Binary files a/img.png and b/img.png differ',
  'diff --git a/old.lua b/new.lua',
  'similarity index 100%',
  'rename from old.lua',
  'rename to new.lua',
}, '\n')

T['a range claims the changes it touches, a file\'s ranges one item; what no range touches is listed apart'] = function()
  local g = guide.parse({
    sections = {
      { title = 'Part', hunks = { { path = 'f.lua', start = 50, ['end'] = 50, note = 'changed' }, { path = 'gone.lua', start = 1, ['end'] = 2 }, { path = 'f.lua', start = 12, ['end'] = 12, note = 'added' } } },
      { title = 'Deletion', hunks = { { path = 'f.lua', side = 'old', start = 31, ['end'] = 31 } } },
      { title = 'Rename', hunks = { { path = 'new.lua' } } },
    },
  })
  local r = guide.resolve(g, guide.parse_diff(DIFF))
  local function starts(sec)
    return vim.tbl_map(function(it)
      return it.path .. ':' .. table.concat(vim.tbl_map(function(h)
        return h.new_start
      end, it.git), ',')
    end, sec.hunks)
  end
  -- line 12 is inside the three added lines: the whole addition is the part's,
  -- with line 50 in the same item, in file order
  eq(starts(r.sections[1]), { 'f.lua:11,50' })
  eq(vim.tbl_map(function(n)
    return n.text .. ':' .. n.git[1].new_start
  end, r.sections[1].hunks[1].notes), { 'changed:50', 'added:11' })
  eq({ r.sections[1].hunks[1].added, r.sections[1].hunks[1].removed }, { 4, 1 })
  eq(starts(r.sections[2]), { 'f.lua:32' })
  eq(starts(r.sections[3]), { 'new.lua:' })
  eq(r.sections[4].title, 'Not in the guide')
  eq(starts(r.sections[4]), { 'img.png:' })
  -- a range on a file outside the diff
  eq(r.dropped, 1)
end

T['focusing a section folds counterpart ranges on both sides, its context kept'] = function()
  local files = guide.parse_diff(DIFF)
  local add, del, mod = unpack(files[1].hunks)
  local function ranges(folds)
    return vim.tbl_map(function(f)
      return { f.old, f.new, #f.hunks }
    end, folds)
  end
  -- the addition and the change: the deletion between them folds with the
  -- unchanged lines around it, 32 old lines against 29 new ones
  eq(ranges(guide.regions(files[1].hunks, { [add] = true, [mod] = true }, 6, 60, 60)), {
    { { 1, 4 }, { 1, 4 }, 0 },
    { { 17, 43 }, { 20, 43 }, 1 },
    { { 57, 60 }, { 57, 60 }, 0 },
  })
  eq(ranges(guide.regions(files[1].hunks, { [del] = true }, 6, 60, 60)), {
    { { 1, 23 }, { 1, 26 }, 1 },
    { { 39, 60 }, { 39, 60 }, 1 },
  })
end

T['a fold starting on another section\'s added lines starts a line earlier, so the filler folds too'] = function()
  local files = guide.parse_diff(table.concat({
    'diff --git a/f b/f',
    '--- a/f',
    '+++ b/f',
    '@@ -10 +10 @@',
    '-a',
    '+b',
    '@@ -14,0 +15,2 @@',
    '+c',
    '+d',
  }, '\n'))
  local mod = files[1].hunks[1]
  local folds = guide.regions(files[1].hunks, { [mod] = true }, 6, 40, 42)
  eq(folds[#folds].old, { 14, 40 })
  eq(folds[#folds].new, { 14, 42 })
end

T['an agent answer with prose around a fenced block still gives the guide'] = function()
  local data = guide.extract_json('Here it is:\n```json\n{"sections": [{"title": "A", "hunks": []}]}\n```\nDone.')
  eq(guide.parse(data).sections[1].title, 'A')
end

-- ---------------------------------------------------------------------
-- the tab

T['the guide tab lists the sections, the files a <Tab> away'] = function()
  local base, head = shas()
  write_guide({ base = base, head = head, sections = SECTIONS })
  open()
  eq(ui.layout(child).bars[1]:find('Guide', 1, true) ~= nil, true)
  eq(tree_texts(), {
    '▾ 1 Adds                              1',
    'f.lua:11  f10                 +4 -1',
    '▾ 2 Removal                           1',
    'f.lua:30  f29                 +0 -3',
    '▾ Not in the guide                    1',
    'h.lua:1                       +4 -0',
  })
  ui.cursor_to(child, 'tree', 1)
  ui.arm_ready(child, 'guide')
  child.type_keys('<Tab>')
  ui.wait_ready(child)
  eq(tree_texts(), { 'M f.lua                           +4 -4', 'A h.lua                           +4 -0' })
  ui.arm_ready(child, 'guide')
  child.type_keys('<Tab>')
  ui.wait_ready(child)
  eq(tree_texts()[1], '▾ 1 Adds                              1')
end

--- The non-focusable float's rows as drawn (concealed text gone), trailing
--- blanks dropped.
local function float_screen()
  return child.lua([[
    vim.cmd('redraw')
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= '' and not c.focusable then
        local info = vim.fn.getwininfo(w)[1]
        local out = {}
        -- winrow/wincol are the frame's corner
        for r = info.winrow + 1, info.winrow + info.height do
          local s = {}
          for col = info.wincol + 1, info.wincol + info.width do
            table.insert(s, vim.fn.screenstring(r, col))
          end
          table.insert(out, (table.concat(s):gsub('%s+$', '')))
        end
        return out
      end
    end
    return vim.NIL
  ]])
end

T['resting on a guide section shows its body as markdown: markers hidden, list items wrapped under their text'] = function()
  local base, head = shas()
  local item = 'the `set` call ' .. ('moves up word '):rep(9)
  write_guide({
    base = base,
    head = head,
    sections = { { title = 'Adds', body = '**Why:** the `parser` dropped a token.\n\n- ' .. item, hunks = SECTIONS[1].hunks } },
  })
  open()
  ui.cursor_to(child, 'tree', 2)
  ui.arm_ready(child, 'commitmsg')
  child.type_keys(ui.lnum(child, 'tree', 1) .. 'G')
  ui.wait_ready(child)
  local rows = float_screen()
  eq(vim.list_slice(rows, 1, 3), { '1 Adds', '', 'Why: the parser dropped a token.' })
  -- the list item is longer than the float: its second row hangs under the text
  eq(rows[5]:sub(1, 16), '- the set call m')
  eq(rows[6]:match('^  %S') ~= nil, true)
end

local function record_agent()
  child.lua([[
    _G.sent = {}
    require('diffy').setup({ send_to_agent = function(text, ctx) table.insert(_G.sent, { text = text, ctx = ctx }) end })
  ]])
end

T['<leader>da on a guide item hands the agent its section and that change; in the diff, lines bring the section covering them'] = function()
  record_agent()
  local base, head = shas()
  write_guide({ base = base, head = head, sections = SECTIONS })
  open()
  -- the item `f.lua` of `Adds`: both its ranges
  ui.cursor_to(child, 'tree', 2)
  child.type_keys('\\da')
  local sent = child.lua_get('_G.sent')
  eq(sent[1].text, table.concat({
    'The branch guide\'s section 1, "Adds":',
    'Why the lines were added.',
    '',
    'About the change at `f.lua:11`: three new lines; one changed line',
  }, '\n'))
  eq(sent[1].ctx.section.items[1], { path = 'f.lua', line = 11, notes = { 'three new lines', 'one changed line' } })

  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  -- the added lines 11-13, and line 14 past them: only `Adds` covers them
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.type_keys('12G', 'V', '14G', '\\da')
  sent = child.lua_get('_G.sent')
  eq(sent[2].ctx.guide, { { index = 1, title = 'Adds', body = 'Why the lines were added.', notes = { 'three new lines' } } })
  eq(sent[2].text:find('\n```\n\nThe branch guide\'s section 1, "Adds":\nWhy the lines were added.\nNote on this change: three new lines$') ~= nil, true)
  -- a line no change touches has no guide
  child.type_keys('40G', '\\da')
  eq(child.lua_get('_G.sent[3].ctx.guide'), {})
end

-- the text of the closed fold at `lnum`, '' when the line isn't folded
local function fold_text(win, lnum)
  return child.lua(('return vim.api.nvim_win_call(%d, function() return vim.fn.foldclosed(%d) ~= -1 and vim.fn.foldtextresult(%d) or "" end)'):format(win, lnum, lnum))
end

local function notes(win)
  return child.lua(
    [[
    local win = ...
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), -1, 0, -1, { details = true })) do
      for _, l in ipairs(m[4].virt_lines or {}) do
        local text = l[1] and l[1][1] or ''
        if text:find('┊', 1, true) then
          table.insert(out, { m[2] + 1, text })
        end
      end
    end
    return out
  ]],
    { win }
  )
end

-- Every unchanged line on screen in both windows (same text) sits on the same
-- screen row; closed folds on the same rows too. `ui.aligned` counts filler,
-- which folds hide.
local function rows_line_up()
  return child.lua([[
    local s = require('diffy.session').current()
    local lw, rw = s.wins.left, s.wins.right
    vim.cmd('redraw')
    local function shown(win)
      return vim.api.nvim_win_call(win, function()
        local out, l = {}, vim.fn.line('w0')
        while l <= vim.fn.line('w$') do
          local fe = vim.fn.foldclosedend(l)
          local key = fe ~= -1 and ('fold ' .. (vim.fn.foldtextresult(l):match('· (.*)$') or l)) or vim.fn.getline(l)
          out[key] = vim.fn.screenpos(win, l, 1).row
          l = fe ~= -1 and fe + 1 or l + 1
        end
        return out
      end)
    end
    local left, right, seen = shown(lw), shown(rw), 0
    for key, row in pairs(left) do
      if right[key] then
        seen = seen + 1
        if right[key] ~= row then
          return key
        end
      end
    end
    return seen > 10
  ]])
end

T['opening a guide item shows the branch with only its section\'s changes unfolded'] = function()
  local base, head = shas()
  write_guide({ base = base, head = head, sections = SECTIONS })
  open()
  -- the item of `Removal`
  ui.cursor_to(child, 'tree', 4)
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  local lay = ui.layout(child)
  -- the branch's commits, not the working tree
  eq(lay.left.rev, base:sub(1, 7))
  eq(lay.right.rev, 'worktree')
  eq(ui.log_subjects(child, ui.rows_with(child, 'log', 'DiffySelection')), { 'C1' })
  local w = ui.wins(child)
  eq(fold_text(w.left, 1), '+-- 23 lines · 1 Adds')
  eq(fold_text(w.right, 1), '+-- 26 lines · 1 Adds')
  eq(fold_text(w.left, 30), '')
  eq(notes(w.left), { { 30, '┊ gone' } })
  eq(rows_line_up(), true)
  -- back to the files: diff mode's folds again
  ui.cursor_to(child, 'tree', 1)
  ui.arm_ready(child, 'guide')
  child.type_keys('<Tab>')
  ui.wait_ready(child)
  eq(fold_text(w.left, 1):find('·', 1, true), nil)
  eq(fold_text(w.left, 30), '')
  eq(ui.aligned(child), true)
end

T[']h/[h in the diff move through the focused section\'s changes; outside it, and once closed, the file\'s own ]h'] = function()
  local base, head = shas()
  write_guide({ base = base, head = head, sections = SECTIONS })
  child.fn.chdir(repo.dir)
  child.cmd('edit f.lua')
  child.lua([[
    _G.own = 0
    vim.keymap.set('n', ']h', function() _G.own = _G.own + 1 end, { buffer = 0 })
  ]])
  open()
  -- the first item of `Adds`, f.lua:11; `Removal`'s change sits between its two
  ui.cursor_to(child, 'tree', 2)
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  local w = ui.wins(child)
  local function cursor()
    return child.api.nvim_win_get_cursor(w.right)[1]
  end
  eq({ child.api.nvim_get_current_win(), cursor() }, { w.right, 11 })
  child.type_keys(']h')
  eq(cursor(), 50)
  eq(ui.rows_with(child, 'tree', 'DiffyCurrentFile'), { '    f.lua:11  f10                 +4 -1' })
  -- the last one: stays
  child.type_keys(']h')
  eq(cursor(), 50)
  child.type_keys('[h')
  eq(cursor(), 11)
  eq(child.lua_get('_G.own'), 0)

  -- the files tab leaves the section
  ui.cursor_to(child, 'tree', 1)
  ui.arm_ready(child, 'guide')
  child.type_keys('<Tab>')
  ui.wait_ready(child)
  child.api.nvim_set_current_win(w.right)
  child.type_keys(']h')
  eq({ cursor(), child.lua_get('_G.own') }, { 11, 1 })

  child.cmd('Diffy close')
  child.cmd('edit f.lua')
  child.type_keys(']h')
  eq(child.lua_get('_G.own'), 2)
end

T['a guide written for an older HEAD says so'] = function()
  local base = shas()
  write_guide({ base = base, head = base, sections = SECTIONS })
  open()
  eq(tree_texts()[1], ('⚠ written for %s'):format(base:sub(1, 7)))
end

T['gG has the configured agent write the guide for the branch'] = function()
  local answer = vim.fn.tempname()
  vim.fn.writefile({ 'Here is the guide:', '```json', vim.json.encode({ sections = SECTIONS }), '```' }, answer)
  child.lua(('require("diffy").setup({ guide = { agent = { "sh", "-c", "cat %s" } } })'):format(answer))
  open()
  ui.cursor_to(child, 'tree', 1)
  child.type_keys('gG')
  child.lua([[vim.wait(5000, function()
    local s = require('diffy.session').current()
    return s.guide ~= nil and s.guide.resolved ~= nil
  end)]])
  eq(tree_texts()[1], '▾ 1 Adds                              1')
  local base, head = shas()
  local saved = vim.json.decode(table.concat(vim.fn.readfile(repo.dir .. '/.git/diffy/feat/guide.json'), '\n'))
  eq({ saved.base, saved.head }, { base, head })
  vim.fn.delete(answer)
end

T['while an omp-style agent writes, its steps show, and its last message is the guide'] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local step = vim.json.encode({ type = 'tool_execution_start', toolName = 'read', intent = 'Reading f.lua' })
  local answer = vim.json.encode({
    type = 'message_end',
    message = { role = 'assistant', content = { { type = 'text', text = vim.json.encode({ sections = SECTIONS }) } } },
  })
  vim.fn.writefile({ step }, dir .. '/step')
  vim.fn.writefile({ answer }, dir .. '/answer')
  -- the answer waits for `release`, so the running state can be looked at
  local script = ('cat %s/step; while [ ! -e %s/release ]; do sleep 0.05; done; cat %s/answer'):format(dir, dir, dir)
  child.lua(('require("diffy").setup({ guide = { agent = { "sh", "-c", %q, "--mode", "json" } } })'):format(script))
  open()
  ui.cursor_to(child, 'tree', 1)
  child.type_keys('gG')
  child.lua([[vim.wait(5000, function()
    local s = require('diffy.session').current()
    return (s.guide_rows or {})[2] ~= nil and s.guide_rows[2].text:find('Reading', 1, true) ~= nil
  end)]])
  local rows = tree_texts()
  eq(rows[1]:match('^↻ writing the guide · 0:%d%d · 1 step$') ~= nil, true)
  eq(rows[2], 'Reading f.lua')
  eq(ui.layout(child).bars[1]:find('Guide ↻ 0:', 1, true) ~= nil, true)
  vim.fn.writefile({}, dir .. '/release')
  child.lua([[vim.wait(5000, function()
    local s = require('diffy.session').current()
    return s.guide ~= nil and s.guide.resolved ~= nil
  end)]])
  eq(tree_texts()[1], '▾ 1 Adds                              1')
  vim.fn.delete(dir, 'rf')
end

T['an omp-style agent printing long lines gives its guide without freezing nvim'] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  -- a tool's output in one 128 KB event line, as omp streams a big `git diff`
  local big = vim.json.encode({ type = 'tool_execution_end', toolName = 'bash', result = ('x'):rep(128 * 1024) })
  local answer = vim.json.encode({
    type = 'message_end',
    message = { role = 'assistant', content = { { type = 'text', text = vim.json.encode({ sections = SECTIONS }) } } },
  })
  vim.fn.writefile({ big, answer }, dir .. '/stream')
  child.lua(('require("diffy").setup({ guide = { agent = { "sh", "-c", %q, "--mode", "json" } } })'):format('cat ' .. dir .. '/stream'))
  open()
  ui.cursor_to(child, 'tree', 1)
  child.lua('_G.started = vim.uv.hrtime()')
  child.type_keys('gG')
  local ms = child.lua([[vim.wait(5000, function()
    local s = require('diffy.session').current()
    return s.guide ~= nil and s.guide.resolved ~= nil
  end)
  return (vim.uv.hrtime() - _G.started) / 1e6]])
  eq(ms < 2000, true)
  eq(tree_texts()[1], '▾ 1 Adds                              1')
  vim.fn.delete(dir, 'rf')
end

--- The branch `feat` has an open pull request on `main`.
local function with_pr()
  local base, head = shas()
  child.lua(([[
    local fake = require('tests.helpers.fake_github')
    fake.install({
      repo_dir = %q,
      merge_base = %q,
      reads = { [7] = { repository = { pullRequest = {
        id = 'PR_GUIDE', number = 7, title = 't', body = '',
        baseRefName = 'main', headRefOid = %q, author = { login = 'x' },
        comments = { nodes = {} }, reviews = { nodes = {} },
        pendingReviews = { nodes = {} },
        reviewThreads = { pageInfo = { hasNextPage = false }, nodes = {} },
      } } } },
      branches = { feat = 7 },
    })
  ]]):format(repo.dir, base, head))
end

--- `guide.auto` on, with an agent that answers SECTIONS and counts its runs
--- in the returned file.
local function auto_agent()
  local runs = vim.fn.tempname()
  local answer = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode({ sections = SECTIONS }) }, answer)
  local script = ('echo run >> %s; cat %s'):format(runs, answer)
  child.lua(('require("diffy").setup({ guide = { auto = true, agent = { "sh", "-c", %q } } })'):format(script))
  return runs
end

T['with guide.auto, opening a pull request without a guide has the agent write it, the files staying shown'] = function()
  local runs = auto_agent()
  with_pr()
  child.fn.chdir(repo.dir)
  child.cmd('Diffy')
  child.lua([[vim.wait(5000, function()
    local s = require('diffy.session').current()
    return s and s.guide ~= nil and s.guide.resolved ~= nil
  end)]])
  eq(ui.layout(child).bars[1]:find('%#DiffyGuideTab#Files', 1, true) ~= nil, true)
  eq(tree_texts(), { '(no changes)' })
  ui.cursor_to(child, 'tree', 1)
  ui.arm_ready(child, 'guide')
  child.type_keys('<Tab>')
  ui.wait_ready(child)
  eq(tree_texts()[1], '▾ 1 Adds                              1')
  -- written for the pull request, merge-base..HEAD, from a `:Diffy` session
  local base, head = shas()
  local saved = vim.json.decode(table.concat(vim.fn.readfile(repo.dir .. '/.git/diffy/feat/guide.json'), '\n'))
  eq({ saved.base, saved.head }, { base, head })
end

T['with guide.auto, an agent that failed isn\'t run again on the next pull request read'] = function()
  local runs = vim.fn.tempname()
  child.lua(('require("diffy").setup({ guide = { auto = true, agent = { "sh", "-c", %q } } })'):format(('echo run >> %s; exit 1'):format(runs)))
  ui.capture_warnings(child)
  with_pr()
  child.fn.chdir(repo.dir)
  child.cmd('Diffy')
  child.lua(([[vim.wait(5000, function()
    local s = require('diffy.session').current()
    return s and s.gitdir and s.guide == nil and not require('diffy.guide').running(s.gitdir, 'feat') and vim.uv.fs_stat(%q) ~= nil
  end)]]):format(runs))
  child.cmd('Diffy close')
  ui.arm_ready(child, 'pr')
  child.cmd('Diffy')
  ui.wait_ready(child)
  eq(child.lua_get('require("diffy.guide").running(require("diffy.session").current().gitdir, "feat")'), false)
  eq(vim.fn.readfile(runs), { 'run' })
  child.cmd('Diffy close')
end

T['with guide.auto, a pull request that already has a guide, even a stale one, keeps it'] = function()
  local runs = auto_agent()
  local base = shas()
  write_guide({ base = base, head = base, sections = SECTIONS })
  with_pr()
  child.fn.chdir(repo.dir)
  ui.arm_ready(child, 'pr')
  child.cmd('Diffy')
  ui.wait_ready(child)
  eq(child.lua_get('require("diffy.guide").running(require("diffy.session").current().gitdir, "feat")'), false)
  eq(vim.fn.filereadable(runs), 0)
  child.cmd('Diffy close')
end

return T
