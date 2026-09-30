-- The review layer's UI and local backend -
-- compose/sign/summary/alignment, persistence across restarts, excerpt
-- relocation on edit/delete, review.md (review submit), and namespace scoping.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local repo

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      -- pinned: the local backend's author comes from `git config user.name`
      child.lua([[vim.env.GIT_CONFIG_GLOBAL = '/dev/null'; vim.env.GIT_CONFIG_NOSYSTEM = '1']])
      repo = Repo.new()
      repo:commit('base', { ['f.txt'] = Repo.lines(30) })
      -- so the default `Unstaged` selection has a file to show
      vim.fn.writefile(Repo.edit(3, 'uncommitted')(vim.fn.readfile(repo.dir .. '/f.txt')), repo.dir .. '/f.txt')
      child.fn.chdir(repo.dir)
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
      end
    end,
  },
})

local function open_default()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
end

local function arm_ready_raw(event)
  ui.arm_ready_raw(child, event)
end

--- Press `keys` and wait for the comment box they open.
local function compose(...)
  arm_ready_raw('compose')
  child.type_keys(...)
  ui.wait_ready_raw(child)
end

--- `<C-s>` in a comment box, waiting for the review to redraw.
local function save()
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  ui.wait_ready_raw(child)
end

--- `R` from the right diff window, waiting for the render.
local function refresh()
  child.api.nvim_set_current_win(ui.wins(child).right)
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)
end

--- Path of `name` in the current branch's `.git/diffy/<branch>/` dir.
local function review_file(name)
  local branch = ui.git(repo.dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  return repo.dir .. '/.git/diffy/' .. branch .. '/' .. name
end

--- `gc` on line `lnum` of `win` (lines `lnum`..`last` when given), type
--- `body`, then `<C-s>` to save the draft.
local function write_comment(win, lnum, body, last)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
  if last then
    -- a range selected across a closed diff fold would take the whole fold
    compose('zR', 'V', ('%dG'):format(last), 'gc')
  else
    compose('gc')
  end
  child.type_keys(body, '<Esc>')
  save()
end

--- `:Diffy review submit`, type `message` (may be empty), `<C-s>` to send
--- the review to the agent.
local function send_review(message)
  arm_ready_raw('compose')
  child.cmd('Diffy review submit')
  ui.wait_ready_raw(child)
  if message ~= '' then
    child.type_keys(message)
  end
  child.type_keys('<Esc>')
  save()
end

T['gc + <C-s> shows a range bar and summary, mirrored as blank lines on the other side, staying aligned'] = function()
  child.o.columns = 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'needs a null check')

  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality(#visible, 1)
  MiniTest.expect.equality(visible[1].line, 5)
  MiniTest.expect.equality(visible[1].summary:find('●', 1, true), 1)
  -- the dot takes the colour of the thread's bar
  local bar = ui.thread_bars(child, 'right')['5']
  MiniTest.expect.equality(visible[1].dot[visible[1].summary], bar.hl[1])
  -- the summary names the comment by its first line, so threads can be told apart
  MiniTest.expect.equality(visible[1].summary:find('needs a null check', 1, true) ~= nil, true)

  -- the left window got a matching blank virt_lines block at the
  -- counterpart line, so cursorbind/scrollbind alignment still holds
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(10, 1)')
  MiniTest.expect.equality(ui.aligned(child), true)

  child.cmd('Diffy close')
end

T['stacked threads pad both sides to the larger count and open one at a time, switched with ]t/[t'] = function()
  child.o.columns = 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'right one')
  write_comment(w.right, 5, 'right two')
  write_comment(w.left, 5, 'left one')

  -- two summary rows on each side at line 5: the left pads its one summary
  -- with a blank, the right needs no padding
  local right = ui.threads_visible(child, 'right')
  local left = ui.threads_visible(child, 'left')
  MiniTest.expect.equality({ right[1].line, right[1].count, right[1].blanks }, { 5, 2, 0 })
  MiniTest.expect.equality({ left[1].line, left[1].count, left[1].blanks }, { 5, 1, 1 })
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(10, 1)')
  MiniTest.expect.equality(ui.aligned(child), true)

  -- how `body`'s summary is drawn: 'open' (bold), 'near' (in its bar's
  -- colour) or 'plain'
  local function look(body)
    local v = ui.threads_visible(child, 'right')[1]
    for text, hl in pairs(v.hl) do
      if text:find(body, 1, true) then
        return hl == 'DiffyThreadCurrent' and 'open' or hl == v.dot[text] and 'near' or 'plain'
      end
    end
  end

  child.type_keys('5G')
  local float = ui.thread_float(child)
  MiniTest.expect.equality(table.concat(float.text, '\n'):find('right one', 1, true) ~= nil, true)
  MiniTest.expect.equality(table.concat(float.text, '\n'):find('right two', 1, true), nil)
  MiniTest.expect.equality({ look('right one'), look('right two') }, { 'open', 'near' })

  child.type_keys(']t')
  float = ui.thread_float(child)
  MiniTest.expect.equality(table.concat(float.text, '\n'):find('right two', 1, true) ~= nil, true)
  MiniTest.expect.equality({ look('right one'), look('right two') }, { 'near', 'open' })

  child.type_keys('[t')
  MiniTest.expect.equality(table.concat(ui.thread_float(child).text, '\n'):find('right one', 1, true) ~= nil, true)

  child.type_keys('10G')
  MiniTest.expect.equality(ui.thread_float(child), vim.NIL)
  MiniTest.expect.equality({ look('right one'), look('right two') }, { 'plain', 'plain' })

  child.cmd('Diffy close')
end

--- The thread float's frame on screen, over the left diff window: `{ width
--- = text columns inside the frame, left = gap between the window's text
--- and the frame, right = gap after it }`, read from the drawn corners.
local function float_frame()
  child.cmd('redraw')
  return child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    local info = vim.fn.getwininfo(s.wins.left)[1]
    local first, last = info.wincol + info.textoff, info.wincol + info.width - 1
    for r = info.winrow, info.winrow + info.height do
      local open, close
      for c = first, last do
        local ch = vim.fn.screenstring(r, c)
        open = open or (ch == '╭' and c or nil)
        close = ch == '╮' and c or close
      end
      if open and close then
        return { width = close - open - 1, left = open - first, right = last - close }
      end
    end
  ]])
end

T['the thread float is centred over the other side, at most 100 wide, and refitted when the editor is resized'] = function()
  child.o.columns = 300
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'centred')
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  arm_ready_raw('thread')
  child.type_keys('K')
  ui.wait_ready_raw(child)
  local frame = float_frame()
  MiniTest.expect.equality(frame.width, 100)
  MiniTest.expect.equality(math.abs(frame.left - frame.right) <= 1, true)

  -- narrower than the limit: the window's text width, still centred
  arm_ready_raw('thread')
  child.o.columns = 150
  ui.wait_ready_raw(child)
  frame = float_frame()
  MiniTest.expect.equality(frame.width < 100, true)
  MiniTest.expect.equality(math.abs(frame.left - frame.right) <= 1, true)
  MiniTest.expect.equality(ui.thread_float(child).focused, true)

  child.cmd('Diffy close')
end

T['K opens the thread on a commented line and falls through to the buffer\'s K elsewhere'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'here')
  child.cmd([[command! -nargs=1 KwProbe let g:kw = <q-args>]])
  child.api.nvim_set_current_win(w.right)
  child.bo.keywordprg = ':KwProbe'
  child.fn.win_execute(w.right, 'call cursor(8, 1)')
  child.type_keys('K')
  MiniTest.expect.equality(child.g.kw, child.fn.expand('<cword>'))
  MiniTest.expect.equality(ui.thread_float(child), vim.NIL)

  child.g.kw = nil
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  arm_ready_raw('thread')
  child.type_keys('K')
  ui.wait_ready_raw(child)
  MiniTest.expect.equality(ui.thread_float(child).focused, true)
  MiniTest.expect.equality(child.g.kw, vim.NIL)
  child.type_keys('q')
  child.cmd('Diffy close')
end

T['hovering a commented line previews it over the other diff window with its bar at full weight'] = function()
  open_default()
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  compose('V', '2j', 'gc')
  child.type_keys('covers three lines', '<Esc>')
  save()
  local function heavy()
    local rows = {}
    for key, b in pairs(ui.thread_bars(child, 'right')) do
      if b.text:find('┃', 1, true) or b.text:find('┗', 1, true) then
        table.insert(rows, key)
      end
    end
    table.sort(rows)
    return rows
  end

  child.type_keys('1G', '6G')
  local float = ui.thread_float(child)
  MiniTest.expect.equality(table.concat(float.text, '\n'):find('covers three lines', 1, true) ~= nil, true)
  MiniTest.expect.equality({ float.over, float.focused }, { 'left', false })
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.right)
  MiniTest.expect.equality(heavy(), { '5', '6', '7', '7+1' })
  -- the float is framed in the bar's colour
  local frame_fg = child.lua([[
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        local group = vim.wo[w].winhighlight:match('FloatBorder:([%w_]+)')
        return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
      end
    end
  ]])
  local bar_group = ui.thread_bars(child, 'right')['5'].hl[1]
  MiniTest.expect.equality(frame_fg, child.api.nvim_get_hl(0, { name = bar_group, link = false }).fg)

  child.type_keys('12G')
  MiniTest.expect.equality(ui.thread_float(child), vim.NIL)
  MiniTest.expect.equality(heavy(), {})

  -- K enters the thread; q leaves it and returns to the diff, on the same
  -- commented line, where the hover shows it again
  child.type_keys('5G', 'K')
  MiniTest.expect.equality(ui.thread_float(child).focused, true)
  child.type_keys('q')
  MiniTest.expect.equality(ui.thread_float(child).focused, false)
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.right)
  MiniTest.expect.equality(child.api.nvim_win_get_cursor(w.right)[1], 5)

  child.cmd('Diffy close')
end

T['<Esc> closes the hover card and keeps it closed on that line until the cursor leaves or <Tab>/K ask for it'] = function()
  open_default()
  local w = ui.wins(child)
  -- line 3 reads `uncommitted`: room to move along it
  write_comment(w.right, 3, 'covers two lines', 4)

  child.type_keys('1G', '3G')
  MiniTest.expect.equality(ui.thread_float(child) ~= vim.NIL, true)
  child.type_keys('<Esc>')
  MiniTest.expect.equality(ui.thread_float(child), vim.NIL)
  -- moving along the same line doesn't bring it back
  child.type_keys('$')
  MiniTest.expect.equality(ui.thread_float(child), vim.NIL)
  child.type_keys('j', 'k')
  MiniTest.expect.equality(ui.thread_float(child).focused, false)

  child.type_keys('<Esc>', '<Tab>')
  MiniTest.expect.equality(ui.thread_float(child).focused, false)
  child.type_keys('<Esc>', 'K')
  MiniTest.expect.equality(ui.thread_float(child).focused, true)
  child.type_keys('q')
  -- nothing open: <Esc> is a no-op
  child.type_keys('<Esc>', '<Esc>')
  MiniTest.expect.equality(ui.thread_float(child), vim.NIL)
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.right)

  child.cmd('Diffy close')
end

T['each comment in the thread float is headed by who wrote it, when, and its state; only applicable keys are offered'] = function()
  child.o.columns = 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'first point')
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  child.type_keys('K')
  compose('r')
  child.type_keys('drop them<CR><CR>```suggestion<CR>```', '<Esc>')
  save()

  -- saving the reply went back into the thread
  local float = ui.thread_float(child)
  MiniTest.expect.equality(float.focused, true)
  local text = table.concat(float.text, '\n')
  MiniTest.expect.equality(float.text[1], 'You  just now  draft')
  MiniTest.expect.equality(float.text[2], 'first point')
  MiniTest.expect.equality(float.text[3], 'You  just now  draft')
  -- an empty suggestion block would render as nothing at all
  MiniTest.expect.equality(text:find('Suggested change: remove these lines', 1, true) ~= nil, true)
  MiniTest.expect.equality(float.footer:find('e edit', 1, true) ~= nil, true)
  MiniTest.expect.equality(float.footer:find('dd delete', 1, true) ~= nil, true)
  child.type_keys('q')

  send_review('')
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  child.type_keys('K')
  float = ui.thread_float(child)
  MiniTest.expect.equality({ float.text[1], float.text[3] }, { 'You  just now  sent', 'You  just now  sent' })
  -- a sent comment can't be edited or deleted any more
  MiniTest.expect.equality(float.footer:find('e edit', 1, true), nil)
  MiniTest.expect.equality(float.footer:find('r reply', 1, true) ~= nil, true)
  child.type_keys('q')

  child.cmd('Diffy close')
end

--- The reply box's first text row and the thread float's last one, on screen.
local function reply_layout()
  return child.lua([[
    local out = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      if name:find('/compose/', 1, true) then
        out.reply_top = vim.fn.screenpos(w, 1, 1).row
        out.reply_focused = w == vim.api.nvim_get_current_win()
      elseif name:find('/thread/', 1, true) then
        out.thread_bottom = vim.fn.screenpos(w, vim.fn.line('w$', w), 1).row
      end
    end
    return out
  ]])
end

T['replying keeps the thread in view above the reply box, then goes back into it'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'first point')
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  child.type_keys('K')
  compose('r')

  local float = ui.thread_float(child)
  MiniTest.expect.equality(float ~= vim.NIL and float.text[2], 'first point')
  local layout = reply_layout()
  MiniTest.expect.equality(layout.reply_focused, true)
  MiniTest.expect.equality(layout.reply_top > layout.thread_bottom, true)

  -- cancelling goes back into the thread, unchanged
  child.type_keys('<Esc>', 'q')
  float = ui.thread_float(child)
  MiniTest.expect.equality({ float.focused, #float.text }, { true, 2 })

  compose('r')
  child.type_keys('second point', '<Esc>')
  save()
  float = ui.thread_float(child)
  MiniTest.expect.equality({ float.focused, float.text[#float.text] }, { true, 'second point' })
  child.type_keys('q')

  child.cmd('Diffy close')
end

T['leaving a comment box or the thread float puts the diff cursor back where it was'] = function()
  open_default()
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)
  child.type_keys('12G', 'l')
  local function cursor()
    return { child.api.nvim_get_current_win() == w.right, child.api.nvim_win_get_cursor(w.right) }
  end

  compose('gc')
  child.type_keys('<Esc>', 'q')
  MiniTest.expect.equality(cursor(), { true, { 12, 1 } })

  compose('gc')
  child.type_keys('first point<CR>more<CR>and more', '<Esc>')
  save()
  MiniTest.expect.equality(cursor(), { true, { 12, 1 } })

  child.type_keys('K', 'G', 'q')
  MiniTest.expect.equality(cursor(), { true, { 12, 1 } })

  child.cmd('Diffy close')
end

T['e and dd in the thread float act on the draft under the cursor'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'first point')
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  child.type_keys('K')
  compose('r')
  child.type_keys('second point', '<Esc>')
  save()

  child.type_keys('gg')
  compose('e')
  MiniTest.expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'first point' })
  -- in normal mode, on the draft's last character
  MiniTest.expect.equality(child.api.nvim_get_mode().mode, 'n')
  MiniTest.expect.equality(child.api.nvim_win_get_cursor(0), { 1, #'first point' - 1 })
  child.type_keys('a, edited', '<Esc>')
  save()

  -- back into the thread, on the edited card
  local float = ui.thread_float(child)
  MiniTest.expect.equality({ float.focused, float.text[2], float.text[4] }, { true, 'first point, edited', 'second point' })
  MiniTest.expect.equality(child.api.nvim_win_get_cursor(0)[1], 1)

  child.type_keys('dd')
  child.fn.win_execute(w.right, 'call cursor(5, 1)')
  child.api.nvim_set_current_win(w.right)
  child.type_keys('K')
  MiniTest.expect.equality(ui.thread_float(child).text, { 'You  just now  draft', 'second point' })
  child.type_keys('q')

  child.cmd('Diffy close')
end

T['on an added file the thread and its edit box leave the commented lines visible'] = function()
  child.o.lines = 50
  vim.fn.writefile(Repo.lines(40), repo.dir .. '/new.txt')
  open_default()
  ui.open_tree_row(child, 'new.txt', '<CR>', 'open_row')
  local w = ui.wins(child)
  local win = w.right or w.left
  child.api.nvim_set_current_win(win)
  child.type_keys('10G', 'V15j')
  compose('gc')
  child.type_keys('too much text here', '<Esc>')
  save()
  write_comment(win, 35, 'another thread')

  -- screen rows (1-based) covered by floats, commented lines 10-25 on screen
  local function overlaps()
    return child.lua([[
      vim.cmd('redraw')
      local win = ...
      local lines = {}
      for l = 10, 25 do
        lines[vim.fn.screenpos(win, l, 1).row] = true
      end
      local hit = {}
      for _, f in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(f).relative ~= '' then
          local top = vim.api.nvim_win_get_position(f)[1] + 1
          for r = top, top + vim.api.nvim_win_get_height(f) + 1 do
            if lines[r] then
              hit[#hit + 1] = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(f)):match('diffy://%d+/(%a+)')
            end
          end
        end
      end
      return hit
    ]], { win })
  end

  child.api.nvim_set_current_win(win)
  child.type_keys('25G')
  MiniTest.expect.equality(ui.thread_float(child).focused, false)
  MiniTest.expect.equality(overlaps(), {})
  -- the float is in this window: the open thread's summary would stick out
  -- past its right edge, so it's blanked while the float is open; the
  -- others stay
  local side = w.right and 'right' or 'left'
  MiniTest.expect.equality(vim.tbl_map(function(v) return v.line end, ui.threads_visible(child, side)), { 35 })
  child.type_keys('K')
  MiniTest.expect.equality(ui.thread_float(child).focused, true)
  MiniTest.expect.equality(overlaps(), {})

  compose('e')
  MiniTest.expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'too much text here' })
  MiniTest.expect.equality(overlaps(), {})
  child.type_keys('<Esc>', 'q')
  MiniTest.expect.equality(ui.thread_float(child).focused, true)
  child.type_keys('q')
  -- off the thread, no float: the summary is back
  child.type_keys('1G')
  MiniTest.expect.equality(#ui.threads_visible(child, side), 2)

  child.cmd('Diffy close')
end

T['threads stacked on a line are drawn oldest first; the hover opens the leftmost (oldest) and ]t walks right'] = function()
  child.o.columns = 160
  open_default()
  local w = ui.wins(child)
  -- written newest first, so the drawing order can't come from creation order
  write_comment(w.right, 5, 'third thread')
  write_comment(w.right, 5, 'second thread')
  write_comment(w.right, 5, 'first thread')
  child.cmd('Diffy close')

  local path = review_file('local.json')
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  local ages = { ['first thread'] = 7200, ['second thread'] = 3600, ['third thread'] = 60 }
  for _, t in ipairs(data.threads) do
    t.comments[1].created_at = os.time() - ages[t.comments[1].body]
    t.resolved = t.comments[1].body == 'first thread'
  end
  vim.fn.writefile({ vim.json.encode(data) }, path)

  open_default()
  w = ui.wins(child)
  local summary = ui.threads_visible(child, 'right')[1].summary
  local first, second, third = summary:find('first thread', 1, true), summary:find('second thread', 1, true), summary:find('third thread', 1, true)
  MiniTest.expect.equality(first < second and second < third, true)

  local function shown()
    local text = table.concat(ui.thread_float(child).text, '\n')
    return text:match('(%a+) thread')
  end
  child.api.nvim_set_current_win(w.right)
  child.type_keys('1G', '5G')
  -- the leftmost bar is the oldest one, resolved or not
  MiniTest.expect.equality(shown(), 'first')
  child.type_keys(']t')
  MiniTest.expect.equality(shown(), 'second')
  child.type_keys(']t')
  MiniTest.expect.equality(shown(), 'third')
  child.type_keys('[t', '[t')
  MiniTest.expect.equality(shown(), 'first')

  child.cmd('Diffy close')
end

T['resolved threads read ✓ inline, <leader>dr hides them and <leader>ds keeps only the range bars'] = function()
  child.o.columns = 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'still open')
  write_comment(w.right, 10, 'settled')
  child.api.nvim_set_current_win(w.right)
  child.type_keys('10G', 'K', 'x', 'q')

  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality({ visible[1].line, visible[2].line }, { 5, 10 })
  MiniTest.expect.equality(visible[1].summary:find('●', 1, true), 1)
  MiniTest.expect.equality(visible[2].summary:find('✓', 1, true), 1)
  -- drawn apart from open ones, not only told by the text
  MiniTest.expect.equality(visible[2].hl[visible[2].summary] ~= visible[1].hl[visible[1].summary], true)
  -- the colour of each buffer line's bar
  local function bars()
    local out = {}
    for key, b in pairs(ui.thread_bars(child, 'right')) do
      if b.hl then
        out[key] = b.hl[1] == 'DiffyThreadSummaryResolved' and 'resolved' or 'open'
      end
    end
    return out
  end
  MiniTest.expect.equality(bars(), { ['5'] = 'open', ['10'] = 'resolved' })

  child.type_keys('\\dr')
  MiniTest.expect.equality(vim.tbl_map(function(v) return v.line end, ui.threads_visible(child, 'right')), { 5 })
  MiniTest.expect.equality(bars(), { ['5'] = 'open' })
  child.type_keys('1G', '10G')
  MiniTest.expect.equality(ui.thread_float(child), vim.NIL)
  child.type_keys('\\dr')
  MiniTest.expect.equality(#ui.threads_visible(child, 'right'), 2)

  child.type_keys('\\ds')
  MiniTest.expect.equality(ui.threads_visible(child, 'right'), {})
  MiniTest.expect.equality(bars(), { ['5'] = 'open', ['10'] = 'resolved' })
  -- no summaries means no padding either: the sides stay aligned
  MiniTest.expect.equality(ui.aligned(child), true)
  child.type_keys('1G', '5G')
  MiniTest.expect.equality(table.concat(ui.thread_float(child).text, '\n'):find('still open', 1, true) ~= nil, true)
  child.type_keys('\\ds')
  MiniTest.expect.equality(#ui.threads_visible(child, 'right'), 2)

  child.cmd('Diffy close')
end

T['<leader>dt off deletes the summary avatars from the terminal, on draws them again'] = function()
  child.o.columns = 160
  -- a kitty terminal: answers the graphics query, records what it's sent
  child.lua([[
    local png = vim.fn.tempname() .. '.png'
    vim.fn.system({ 'magick', '-size', '4x4', 'xc:red', 'PNG32:' .. png })
    local url = 'https://example.test/me.png'
    local path = vim.fn.stdpath('cache') .. '/diffy/avatars/' .. vim.fn.sha256(url) .. '.png'
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.uv.fs_copyfile(png, path)
    require('diffy.review.local').avatar_url = function() return url end
    vim.api.nvim_list_uis = function() return { { stdout_tty = true } } end
    _G.sent = {}
    vim.api.nvim_ui_send = function(data)
      table.insert(_G.sent, data)
      local id = data:match('^\27_Gi=(%d+),s=1,v=1,a=q')
      if id then
        vim.schedule(function()
          vim.api.nvim_exec_autocmds('TermResponse', { data = { sequence = '\27_Gi=' .. id .. ';OK\27\\' } })
        end)
      end
    end
  ]])
  -- placements the terminal holds: `a=p` adds one, `a=d,d=i` deletes it
  local function shown(n)
    return vim.wait(3000, function()
      return child.lua_get([[(function()
        local live = {}
        for _, data in ipairs(_G.sent) do
          for p in data:gmatch('a=p,i=%d+,p=(%d+)') do live[p] = true end
          for p in data:gmatch('a=d,d=i,i=%d+,p=(%d+)') do live[p] = nil end
        end
        return vim.tbl_count(live)
      end)()]]) == n
    end, 20)
  end
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'with a face')
  -- off the commented line: no hover card whose closing redraws the images
  child.type_keys('1G')
  MiniTest.expect.equality(shown(1), true)

  child.type_keys('\\dt')
  MiniTest.expect.equality(shown(0), true)
  child.type_keys('\\dt')
  MiniTest.expect.equality(shown(1), true)

  child.cmd('Diffy close')
end

T['overlapping comment ranges get side-by-side bars that keep their column and their colour'] = function()
  child.o.lines, child.o.columns = 40, 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 10, 'outer', 14)
  local outer = ui.thread_bars(child, 'right')['10'].hl[1]
  write_comment(w.right, 12, 'inner', 17)
  -- lane 1 is free again once `outer` ends
  write_comment(w.right, 16, 'late')
  child.type_keys('1G')

  local bars = ui.thread_bars(child, 'right')
  local text = vim.tbl_map(function(b) return b.text end, bars)
  MiniTest.expect.equality(text, {
    ['10'] = '│ ', ['11'] = '│ ', ['12'] = '││', ['13'] = '││', ['14'] = '││',
    -- each bar ends on its summary, turning right across the bars going on
    ['14+1'] = '╰┼',
    -- a blank lane keeps `inner` in the second column
    ['15'] = ' │', ['16'] = '││', ['16+1'] = '╰┼', ['17'] = ' │', ['17+1'] = ' ╰',
  })
  -- a thread's colour comes from the thread, not from the others around it
  MiniTest.expect.equality(bars['14'].hl[1], outer)
  local inner, late = bars['13'].hl[2], bars['16'].hl[1]
  for _, v in ipairs(ui.threads_visible(child, 'right')) do
    for summary, dot in pairs(v.dot) do
      local want = summary:find('outer', 1, true) and outer or summary:find('inner', 1, true) and inner or late
      MiniTest.expect.equality(dot, want)
    end
  end

  child.cmd('Diffy close')
end

T["a bar runs on through the other side's summary padding inside its range"] = function()
  child.o.columns = 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'right side')
  write_comment(w.left, 4, 'left range', 6)
  child.type_keys('1G')

  local text = vim.tbl_map(function(b) return b.text end, ui.thread_bars(child, 'left'))
  MiniTest.expect.equality(text, { ['4'] = '│', ['5'] = '│', ['5+1'] = '│', ['6'] = '│', ['6+1'] = '╰' })
  MiniTest.expect.equality(ui.aligned(child), true)

  child.cmd('Diffy close')
end

T["<Tab> cycles a line's threads left to right, ]t/[t walk them by first line then larger range"] = function()
  child.o.lines, child.o.columns = 40, 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 10, 'outer', 14)
  write_comment(w.right, 12, 'inner', 13)
  -- starts with `inner` but covers more: drawn left of it
  write_comment(w.right, 12, 'wide', 16)
  -- which lane of line 13 is drawn heavy: the open thread's
  local function open_lane()
    return ui.thread_bars(child, 'right')['13'].text
  end

  -- the hover opens the leftmost
  child.type_keys('1G', '13G')
  MiniTest.expect.equality(open_lane(), '┃││')
  child.type_keys('<Tab>')
  MiniTest.expect.equality(open_lane(), '│┃│')
  child.type_keys('<Tab>')
  MiniTest.expect.equality(open_lane(), '││┃')
  child.type_keys('<Tab>')
  MiniTest.expect.equality(open_lane(), '┃││')
  child.type_keys('<S-Tab>')
  MiniTest.expect.equality(open_lane(), '││┃')
  -- the cursor stays on its line
  MiniTest.expect.equality(child.fn.line('.'), 13)

  child.type_keys('1G', '13G')
  child.type_keys(']t')
  MiniTest.expect.equality(open_lane(), '│┃│')
  child.type_keys(']t')
  MiniTest.expect.equality(open_lane(), '││┃')
  -- past the last one: stays
  child.type_keys(']t')
  MiniTest.expect.equality(open_lane(), '││┃')
  child.type_keys('[t', '[t')
  MiniTest.expect.equality(open_lane(), '┃││')

  child.type_keys('20G')
  MiniTest.expect.equality(open_lane(), '│││')

  child.cmd('Diffy close')
end

--- `:Diffy threads …` in a float, its rows grouped (`ui.thread_groups`).
local function threads(cmd)
  child.cmd(cmd)
  local view = ui.threads_view(child)
  MiniTest.expect.equality(view.float, true)
  return ui.thread_groups(view), view
end

--- Put the threads view's cursor on the row with `needle` and press `key`,
--- waiting for `event` if given.
local function press_on_row(needle, key, event)
  local view = ui.threads_view(child)
  for i, l in ipairs(view.rows) do
    if l:find(needle, 1, true) then
      child.api.nvim_win_set_cursor(ui.wins(child).threads, { i, 0 })
    end
  end
  if event then
    arm_ready_raw(event)
  end
  child.type_keys(key)
  if event then
    ui.wait_ready_raw(child)
  end
end

T[':Diffy threads lists every thread in a float, `file` those of the file in the diff; <CR> selects what shows one'] = function()
  child.o.columns = 160
  vim.fn.writefile(Repo.lines(10), repo.dir .. '/g.txt')
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'about f')
  ui.open_tree_row(child, 'g.txt', '<CR>', 'review')
  write_comment(w.right, 3, 'about g')

  local groups, view = threads('Diffy threads')
  MiniTest.expect.equality(#groups, 1)
  MiniTest.expect.equality({ groups[1].group, groups[1].count }, { 'Open', 2 })
  MiniTest.expect.equality(groups[1].rows[1]:match('f%.txt:5') ~= nil, true)
  MiniTest.expect.equality(groups[1].rows[2]:match('g%.txt:3') ~= nil, true)
  -- the preview beside it shows the thread under the cursor, the first one
  MiniTest.expect.equality(view.preview_title, 'f.txt:5')
  MiniTest.expect.equality(table.concat(view.preview, '\n'):find('about f', 1, true) ~= nil, true)
  child.type_keys('j')
  view = ui.threads_view(child)
  MiniTest.expect.equality(view.preview_title, 'g.txt:3')
  child.type_keys('q')
  MiniTest.expect.equality(ui.threads_view(child), vim.NIL)

  groups = threads('Diffy threads file')
  MiniTest.expect.equality(#groups[1].rows, 1)
  MiniTest.expect.equality(groups[1].rows[1]:match('g%.txt:3') ~= nil, true)
  child.type_keys('q')

  -- a commit doesn't show comments written on the worktree: still listed,
  -- and <CR> goes back to the selection that shows it
  ui.select_log_row(child, 'base')
  groups = threads('Diffy threads')
  MiniTest.expect.equality(groups[1].count, 2)
  press_on_row('f.txt:5', '<CR>', 'thread')
  MiniTest.expect.equality(ui.threads_view(child), vim.NIL)
  MiniTest.expect.equality(ui.log_subjects(child, ui.rows_with(child, 'log', 'DiffySelection')), { 'Working tree' })
  local float = ui.thread_float(child)
  MiniTest.expect.equality(float.focused, true)
  MiniTest.expect.equality(table.concat(float.text, '\n'):find('about f', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['the threads view groups open, detached, then resolved threads (folded); x resolves the one under the cursor'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'keep open')
  write_comment(w.right, 10, 'to resolve')
  write_comment(w.right, 20, 'about line 20')
  child.api.nvim_buf_set_lines(child.api.nvim_win_get_buf(w.right), 19, 20, false, {})
  refresh()

  local groups = threads('Diffy threads')
  MiniTest.expect.equality(vim.tbl_map(function(g)
    return { g.group, g.count, #g.rows }
  end, groups), { { 'Open', 2, 2 }, { 'Detached', 1, 1 } })

  press_on_row('f.txt:10', 'x', 'review')
  groups = ui.thread_groups(ui.threads_view(child))
  MiniTest.expect.equality(vim.tbl_map(function(g)
    return { g.group, g.count, #g.rows }
  end, groups), { { 'Open', 1, 1 }, { 'Detached', 1, 1 }, { 'Resolved', 1, 0 } })

  -- <Tab> unfolds the group under the cursor
  press_on_row('Resolved', '<Tab>')
  groups = ui.thread_groups(ui.threads_view(child))
  MiniTest.expect.equality(groups[3].rows[1]:find('f.txt:10', 1, true) ~= nil, true)
  child.type_keys('q')
  child.cmd('Diffy close')
end

T['config.column puts the threads view in the column, compact, kept by :Diffy panel, <CR> going to the thread'] = function()
  child.lua([[require('diffy').setup({ column = { 'tree', 'threads', 'log' } })]])
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'in the column')

  local view = ui.threads_view(child)
  MiniTest.expect.equality(view.float, false)
  MiniTest.expect.equality(view.preview, nil)
  local groups = ui.thread_groups(view)
  MiniTest.expect.equality({ groups[1].group, #groups[1].rows }, { 'Open', 1 })
  MiniTest.expect.equality(groups[1].rows[1]:find('in the column', 1, true) ~= nil, true)
  -- the column still holds the file tree and the commit log, in that order
  local rows = child.lua_get([[(function()
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    return vim.tbl_map(function(n) return vim.fn.win_screenpos(s.wins[n])[1] end, { 'tree', 'threads', 'log' })
  end)()]])
  MiniTest.expect.equality(rows[1] < rows[2] and rows[2] < rows[3], true)

  child.cmd('Diffy panel')
  MiniTest.expect.equality(ui.threads_view(child), vim.NIL)
  child.cmd('Diffy panel')
  MiniTest.expect.equality(ui.thread_groups(ui.threads_view(child))[1].count, 1)

  -- `:Diffy threads` goes to the column's view instead of a float
  child.cmd('Diffy threads')
  view = ui.threads_view(child)
  MiniTest.expect.equality(view.float, false)
  press_on_row('in the column', '<CR>', 'thread')
  MiniTest.expect.equality(ui.threads_view(child).float, false)
  MiniTest.expect.equality(ui.thread_float(child).focused, true)

  child.cmd('Diffy close')
end

T['drafts survive restarting nvim'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'first draft')
  child.cmd('Diffy close')

  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[vim.env.GIT_CONFIG_GLOBAL = '/dev/null'; vim.env.GIT_CONFIG_NOSYSTEM = '1']])
  child.fn.chdir(repo.dir)
  open_default()

  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality(vim.tbl_map(function(v) return v.line end, visible), { 5 })
  child.api.nvim_set_current_win(ui.wins(child).right)
  child.type_keys('1G', '5G')
  MiniTest.expect.equality(table.concat(ui.thread_float(child).text, '\n'):find('first draft', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['editing lines above an anchor moves it with its excerpt'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 20, 'about line 20')

  -- a buffer edit, not a disk write: the loaded worktree buffer wouldn't
  -- see the latter
  child.api.nvim_buf_set_lines(child.api.nvim_win_get_buf(w.right), 0, 0, false, { 'inserted a', 'inserted b' })
  refresh()

  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality(vim.tbl_map(function(v) return v.line end, visible), { 22 })

  child.cmd('Diffy close')
end

T["deleting an anchor's lines detaches it and lists it in :Diffy threads"] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 20, 'about line 20')

  child.api.nvim_buf_set_lines(child.api.nvim_win_get_buf(w.right), 19, 20, false, {})
  refresh()

  MiniTest.expect.equality(ui.threads_visible(child, 'right'), {})

  local groups = threads('Diffy threads')
  MiniTest.expect.equality(#groups, 1)
  MiniTest.expect.equality({ groups[1].group, #groups[1].rows }, { 'Detached', 1 })
  child.type_keys('q')

  child.cmd('Diffy close')
end

T["moving the cursor after the worktree buffer shrank under a summary doesn't error"] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 28, 'about line 28')

  -- like `:e` reloading a shorter file: no render in between
  child.api.nvim_buf_set_lines(child.api.nvim_win_get_buf(w.right), 10, -1, false, {})
  child.v.errmsg = ''
  child.api.nvim_set_current_win(w.right)
  child.type_keys('gg', 'j')
  MiniTest.expect.equality(child.v.errmsg, '')

  child.cmd('Diffy close')
end

T[':Diffy completes subcommands, then what the session review and threads take'] = function()
  local function complete(line)
    return child.fn.getcompletion(line, 'cmdline')
  end
  MiniTest.expect.equality(complete('Diffy re'), { 'restore', 'review' })
  -- no session yet: every review subcommand
  MiniTest.expect.equality(complete('Diffy review '), { 'clear', 'pull', 'push', 'submit' })
  open_default()
  write_comment(ui.wins(child).right, 5, 'a comment')
  -- the local review has no push/pull and no review events
  MiniTest.expect.equality(complete('Diffy review '), { 'clear', 'submit' })
  MiniTest.expect.equality(complete('Diffy review submit '), {})
  MiniTest.expect.equality(complete('Diffy threads state=o'), { 'state=open', 'state=outdated' })
  child.cmd('Diffy close')
end

T['review submit writes review.md for worktree, index and commit views, marks sent, prompt in +'] = function()
  repo:commit('second', { ['f.txt'] = Repo.edit(15, 'second: line 15') })
  -- so `Unstaged` has a diff to comment on
  vim.fn.writefile(Repo.edit(3, 'second uncommitted')(vim.fn.readfile(repo.dir .. '/f.txt')), repo.dir .. '/f.txt')

  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 3, 'worktree comment')

  ui.git(repo.dir, { 'add', '-A' })
  -- re-selecting refreshes: f.txt is now only in the Staged section, index on the right
  ui.select_log_row(child, 1)
  write_comment(w.right, 3, 'staged comment')

  -- the tip commit alone, with a staged edit on top: a blob view, not the worktree
  ui.select_log_row(child, 2)
  write_comment(w.right, 15, 'commit comment')

  -- back to the working tree, for a predictable header range label
  ui.select_log_row(child, 1)
  local branch = ui.git(repo.dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })

  send_review('')

  local review_md = review_file('review.md')
  MiniTest.expect.equality(vim.fn.filereadable(review_md), 1)
  local text = table.concat(vim.fn.readfile(review_md), '\n')
  -- raw bytes: `readfile()` turns NUL back into NL, hiding a `writefile()`
  -- of an entry with an embedded `\n`; other tools read review.md as bytes
  local raw = io.open(review_md, 'rb'):read('*a')
  MiniTest.expect.equality(raw:find('\0', 1, true), nil)

  MiniTest.expect.equality(text:find('# Review of ' .. branch, 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('worktree comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('staged comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('commit comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('```diff', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('<details>', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('commit worktree', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('commit index', 1, true) ~= nil, true)
  -- worktree/index/sha, like the per-comment `commit` field, not a 7-char
  -- truncation ("worktre")
  local head7 = ui.git(repo.dir, { 'rev-parse', '--short=7', 'HEAD' })
  MiniTest.expect.equality(text:find('range: ' .. head7 .. '..worktree', 1, true) ~= nil, true)

  local reg = child.fn.getreg('+')
  MiniTest.expect.equality(reg:find(review_md, 1, true) ~= nil, true)

  -- sent comments are `sent`: the next submit carries only newer ones
  ui.select_log_row(child, 2)
  write_comment(w.right, 5, 'later comment')
  send_review('also bump the version')
  local again = table.concat(vim.fn.readfile(review_md), '\n')
  MiniTest.expect.equality(again:find('later comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(again:find('worktree comment', 1, true), nil)
  -- the message comes first, before the comments
  local overall = again:find('## Overall\n\nalso bump the version\n', 1, true)
  MiniTest.expect.equality(overall ~= nil and overall < again:find('later comment', 1, true), true)

  -- nothing new to send: a message alone still goes
  send_review('ship it after that')
  local only = table.concat(vim.fn.readfile(review_md), '\n')
  MiniTest.expect.equality(only:find('ship it after that', 1, true) ~= nil, true)
  MiniTest.expect.equality(only:find('later comment', 1, true), nil)

  child.cmd('Diffy close')
end

T['a comment the agent ticks resolved in review.md shows resolved, on R and on the next open, once'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'fix this')
  write_comment(w.right, 10, 'and this')
  send_review('')
  local review_md = review_file('review.md')
  local text = table.concat(vim.fn.readfile(review_md), '\n')
  MiniTest.expect.equality(text:find('\n## c1 [^\n]*\n%- %[ %] resolved\n') ~= nil, true)
  MiniTest.expect.equality(text:find('\n## c2 [^\n]*\n%- %[ %] resolved\n') ~= nil, true)

  -- what the agent does: tick the box of the comment it handled
  local function tick(id)
    local lines, current = vim.fn.readfile(review_md), nil
    for i, l in ipairs(lines) do
      current = l:match('^## (c%d+) ') or current
      if current == id and l == '- [ ] resolved' then
        lines[i] = '- [x] resolved'
      end
    end
    vim.fn.writefile(lines, review_md)
  end
  local function groups()
    local out = {}
    for _, g in ipairs(ui.all_threads(child, 'Diffy threads')) do
      out[g.group] = vim.tbl_map(function(row)
        return row:match('f%.txt:%d+')
      end, g.rows)
    end
    child.type_keys('q')
    return out
  end

  tick('c1')
  refresh()
  MiniTest.expect.equality(groups(), { Open = { 'f.txt:10' }, Resolved = { 'f.txt:5' } })
  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality(visible[1].summary:find('✓', 1, true) ~= nil, true)

  -- ticked while diffy is closed: read when the review opens
  child.cmd('Diffy close')
  tick('c2')
  open_default()
  MiniTest.expect.equality(groups(), { Resolved = { 'f.txt:5', 'f.txt:10' } })

  -- reopened by hand: the tick, still in the file, doesn't resolve it again
  ui.all_threads(child, 'Diffy threads')
  press_on_row('f.txt:5', 'x', 'review')
  child.type_keys('q')
  refresh()
  MiniTest.expect.equality(groups(), { Open = { 'f.txt:5' }, Resolved = { 'f.txt:10' } })

  child.cmd('Diffy close')
end

T['review submit quotes a bracketed path from its own file, not a loaded file its name pattern-matches'] = function()
  -- `a[b].txt` read as a file pattern matches `ab.txt`
  repo:commit('brackets', { ['a[b].txt'] = Repo.lines(10), ['ab.txt'] = Repo.lines(10) })
  vim.fn.writefile(Repo.edit(5, 'bracket edit')(Repo.lines(10)), repo.dir .. '/a[b].txt')
  child.lua('local b = vim.fn.bufadd(...); vim.fn.bufload(b); vim.api.nvim_buf_set_lines(b, 0, -1, false, { "WRONG FILE" })',
    { repo.dir .. '/ab.txt' })
  open_default()
  local w = ui.wins(child)
  MiniTest.expect.equality(child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(w.right)), repo.dir .. '/a[b].txt')
  write_comment(w.right, 5, 'bracket comment')

  send_review('')
  local text = table.concat(vim.fn.readfile(review_file('review.md')), '\n')
  MiniTest.expect.equality(text:find('bracket comment', 1, true) ~= nil, true)
  -- the quoted excerpt (above the diff hunk) is the commented file's own line
  local excerpt = text:match('```text\n([^`]*)```') or ''
  MiniTest.expect.equality(excerpt:find('bracket edit', 1, true) ~= nil, true)
  child.cmd('Diffy close')
  child.cmd('bwipeout! ' .. vim.fn.fnameescape(repo.dir .. '/ab.txt'))
end

T['the previewed thread stays level with its lines when the diff scrolls under it'] = function()
  child.o.lines, child.o.columns = 40, 160
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 8, 'a long range', 16)
  -- float's top row minus the thread's first line's row, as drawn
  local function offset()
    return child.lua([[
      local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
      vim.cmd('redraw')
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(w).relative ~= '' then
          return vim.fn.win_screenpos(w)[1] - vim.fn.screenpos(s.wins.right, 8, 1).row
        end
      end
    ]])
  end
  child.type_keys('1G', '12G')
  local before = offset()
  child.type_keys('<C-e>', '<C-e>', '<C-e>')
  MiniTest.expect.equality(child.fn.line('.'), 12)
  MiniTest.expect.equality(ui.thread_float(child) ~= vim.NIL, true)
  MiniTest.expect.equality(offset(), before)

  child.cmd('Diffy close')
end

T["a float opened from a diff window isn't bound to the diff"] = function()
  open_default()
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)
  child.type_keys('10G')
  -- what a picker does: a prompt float opened from the diff window, typed in
  child.lua([[
    _G.__buf = vim.api.nvim_create_buf(false, true)
    _G.__float = vim.api.nvim_open_win(_G.__buf, true, { relative = 'editor', row = 1, col = 1, width = 30, height = 1 })
  ]])
  child.type_keys('i', 'abcdef', '<Esc>')
  MiniTest.expect.equality(child.lua_get('vim.api.nvim_buf_get_lines(_G.__buf, 0, -1, false)'), { 'abcdef' })
  -- a bound float would drag the diff's cursors to its own line
  MiniTest.expect.equality(child.api.nvim_win_get_cursor(w.right), { 10, 0 })

  child.lua('vim.api.nvim_win_close(_G.__float, true); vim.api.nvim_buf_delete(_G.__buf, { force = true })')
  child.cmd('Diffy close')
end

T["comment decorations don't show in a window outside the session showing the same file"] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'a comment')
  MiniTest.expect.equality(#ui.threads_visible(child, 'right'), 1)

  -- same buffer, but the review namespace is scoped to the session's
  -- windows (`nvim__ns_set`)
  child.cmd('tabnew ' .. vim.fn.fnameescape(repo.dir .. '/f.txt'))
  local rows = vim.tbl_map(function(row) return table.concat(row) end, child.get_screenshot().text)
  local screen = table.concat(rows, '\n')
  MiniTest.expect.equality(screen:find('●', 1, true), nil)
  MiniTest.expect.equality(screen:find('│', 1, true), nil)

  child.cmd('tabclose')
  child.cmd('Diffy close')
end

T['screenshot: nested comment ranges draw side by side, their summaries dotted in the bar colour'] = function()
  child.o.lines, child.o.columns = 24, 80
  -- the screenshot embeds the worktree's absolute path: keep it stable
  local fixed_dir = '/tmp/diffy-review-screenshot-fixture'
  vim.fn.delete(fixed_dir, 'rf')
  vim.fn.rename(repo.dir, fixed_dir)
  repo.dir = fixed_dir
  child.fn.chdir(repo.dir)

  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 4, 'covers four lines', 7)
  write_comment(w.right, 5, 'needs a null check')
  -- off the thread: no hover preview over the mirrored blank line
  child.type_keys('1G')
  MiniTest.expect.reference_screenshot(child.get_screenshot())

  child.cmd('Diffy close')
end

T['gc on the empty-diff placeholder opens no composer and sends nothing'] = function()
  ui.git(repo.dir, { 'checkout', '--', 'f.txt' })
  open_default()
  local w = ui.wins(child)
  MiniTest.expect.equality(ui.layout(child).right.path, nil)

  child.api.nvim_set_current_win(w.right)
  ui.capture_warnings(child)
  child.type_keys('gc')
  vim.wait(2000, function() return #ui.warnings(child) > 0 end, 10)
  -- whatever gc opened, try to save a draft from it
  child.type_keys('Aorphan', '<Esc>', '<C-s>', '<Esc>')
  local floats = child.lua_get([[#vim.tbl_filter(function(x)
    return vim.api.nvim_win_get_config(x).relative ~= '' end, vim.api.nvim_list_wins())]])
  MiniTest.expect.equality(floats, 0)
  MiniTest.expect.equality(ui.threads_visible(child, 'right'), {})

  send_review('')
  local mds = vim.fn.glob(repo.dir .. '/.git/diffy/*/review.md', false, true)
  for _, p in ipairs(mds) do
    MiniTest.expect.equality(table.concat(vim.fn.readfile(p), '\n'):find('f.txt', 1, true), nil)
  end
  child.cmd('Diffy close')
end

return T
