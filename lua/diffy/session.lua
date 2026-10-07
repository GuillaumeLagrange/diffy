-- One session per tabpage: registry, augroup, namespaces, buffer-local
-- keymap tracking, idempotent teardown.
--
-- Session fields:
--   id       unique integer, also used in buffer names (`diffy://<id>/…`)
--            and the augroup name (`diffy_session_<id>`)
--   tab      the owning tabpage handle
--   augroup  this session's augroup id; deleted whole on teardown
--   ns       name -> namespace id
--   wins     name -> window handle for every managed window
--   bufs     name -> buffer handle for every managed buffer
--   column   names of the views stacked in the left column (layout.lua)
--   floats   view name -> {win, preview, preview_buf} of each open float
--   keymaps  {buf, mode, lhs} list of buffer-local keymaps set via `M.map`
--   gen      bumped by `panels/tree.lua`'s `M.render` on every call; an
--            async continuation started for an earlier value is stale and
--            must no-op (`git/run.lua`'s `opts.gen`), so rapid selection
--            changes (J/K/...) end up showing the last one regardless of git
--            subprocess completion order
--   closed   set once teardown has run; guards re-entrancy and (via
--            `git/run.lua`'s `opts.session`) makes any async continuation
--            still in flight for this session a no-op
local M = {}

-- id -> session
M.sessions = {}
local next_id = 0

--- Session owning `tab`, or nil.
function M.for_tab(tab)
  for _, s in pairs(M.sessions) do
    if s.tab == tab then
      return s
    end
  end
  return nil
end

--- Session owning the current tabpage, or nil.
function M.current()
  return M.for_tab(vim.api.nvim_get_current_tabpage())
end

--- Namespace `name` for `session`, created on first use. Namespaces
--- themselves are never destroyed (nvim has no such API); teardown instead
--- clears every extmark placed in them, wherever the buffer lives.
function M.namespace(session, name)
  session.ns[name] = session.ns[name] or vim.api.nvim_create_namespace(('diffy/%d/%s'):format(session.id, name))
  return session.ns[name]
end

local function find_map(maps, lhsraw)
  for _, m in ipairs(maps) do
    if m.lhsraw == lhsraw and not (m.desc or ''):find('^diffy: ') then
      return m
    end
  end
end

--- Run keymap `m` (a `nvim_get_keymap` entry) as if `lhs` was typed; nil
--- means nvim's built-in `lhs`.
local function run_mapping(m, lhs)
  if not m then
    vim.api.nvim_feedkeys(vim.keycode(lhs), 'n', false)
    return
  end
  local keys
  if m.callback then
    keys = m.callback()
    if m.expr ~= 1 then
      return
    end
    if m.replace_keycodes == 1 and type(keys) == 'string' then
      keys = vim.keycode(keys)
    end
  else
    local rhs = m.rhs:gsub('<[Ss][Ii][Dd]>', ('<SNR>%d_'):format(m.sid))
    keys = m.expr == 1 and vim.api.nvim_eval(rhs) or vim.keycode(rhs)
  end
  if type(keys) == 'string' and keys ~= '' then
    vim.api.nvim_feedkeys(keys, m.noremap == 1 and 'n' or 'm', false)
  end
end

-- buf -> mode -> lhsraw -> { dispatch, shadowed, handlers = { [session] = fn } }.
-- A buffer has one map per key, and sessions in other tabs can show the same
-- buffer (a worktree file, a fugitive blob): each session's handler lives here,
-- and the map goes once no session has one left.
local shared = {}

local function shared_entry(buf, mode, lhsraw)
  local entry = vim.tbl_get(shared, buf, mode, lhsraw)
  if not entry then
    return nil
  end
  -- a wiped or unloaded buffer took the map with it
  for _, m in ipairs(vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_keymap(buf, mode) or {}) do
    if m.lhsraw == lhsraw and m.callback == entry.dispatch then
      return entry
    end
  end
  shared[buf][mode][lhsraw] = nil
  return nil
end

local function release(session, km)
  local entry = shared_entry(km.buf, km.mode, km.lhsraw)
  if not entry then
    return
  end
  entry.handlers[session] = nil
  if not next(entry.handlers) then
    shared[km.buf][km.mode][km.lhsraw] = nil
    pcall(vim.keymap.del, km.mode, km.lhs, { buffer = km.buf })
  end
end

--- Set a buffer-local keymap and record it for teardown/`unmap_buffer`.
--- `opts.buffer` is required. All diffy keymaps get a `diffy: ` prefixed
--- `desc`, which the leak check relies on to find stragglers.
--- In the tab of a session that mapped the key on this buffer, its `rhs`
--- runs. Elsewhere (the buffer shown in a `:tab split`), and with
--- `opts.fallback` when `rhs` returns false, the key does what it did
--- without diffy (the buffer-local map it shadowed, else the global one,
--- else the built-in).
function M.map(session, modes, lhs, rhs, opts)
  opts = vim.deepcopy(opts or {})
  local buf = opts.buffer
  assert(buf, 'session.map: opts.buffer is required')
  opts.desc = 'diffy: ' .. (opts.desc or lhs)
  local fallback = opts.fallback
  opts.fallback = nil
  local lhsraw = vim.keycode(lhs)
  local function handler()
    if not fallback then
      rhs()
      return true
    end
    return rhs()
  end
  for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
    local entry = shared_entry(buf, mode, lhsraw)
    if not entry then
      entry = { handlers = {}, shadowed = find_map(vim.api.nvim_buf_get_keymap(buf, mode), lhsraw) }
      function entry.dispatch()
        local owner = M.current()
        local h = owner and entry.handlers[owner]
        if not (h and h()) then
          run_mapping(entry.shadowed or find_map(vim.api.nvim_get_keymap(mode), lhsraw), lhs)
        end
      end
      shared[buf] = shared[buf] or {}
      shared[buf][mode] = shared[buf][mode] or {}
      shared[buf][mode][lhsraw] = entry
    end
    entry.handlers[session] = handler
    vim.keymap.set(mode, lhs, entry.dispatch, opts)
    table.insert(session.keymaps, { buf = buf, mode = mode, lhs = lhs, lhsraw = lhsraw })
  end
end

--- Remove every tracked keymap on `buf` (e.g. when a real-file buffer
--- leaves a diffy window).
function M.unmap_buffer(session, buf)
  for i = #session.keymaps, 1, -1 do
    local km = session.keymaps[i]
    if km.buf == buf then
      release(session, km)
      table.remove(session.keymaps, i)
    end
  end
end

-- Next tick: closing windows from a `WinClosed`/`BufWipeout` callback races
-- a `:tabclose`/`:qa` still closing this tab's windows (E444).
local function schedule_teardown(session, opts)
  return function()
    vim.schedule(function()
      M.teardown(session, opts)
    end)
  end
end

local function watch_close(session, win)
  local au_id = vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    callback = schedule_teardown(session, { keep_lone = true }),
  })
  session._win_watchers = session._win_watchers or {}
  session._win_watchers[win] = au_id
end

local function unwatch_close(session, win)
  local au = session._win_watchers and session._win_watchers[win]
  if au then
    pcall(vim.api.nvim_del_autocmd, au)
    session._win_watchers[win] = nil
  end
end

local function watch_wipe(session, buf)
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = session.augroup,
    buffer = buf,
    once = true,
    callback = schedule_teardown(session),
  })
end

--- Register a managed window under `name` (`session.wins[name]`). Closing
--- any managed window (`:q`, `:close`, …) tears down the whole session,
--- except `opts.transient` ones (floats), which teardown only closes.
function M.register_window(session, name, win, opts)
  session.wins[name] = win
  if not (opts and opts.transient) then
    watch_close(session, win)
  end
end

--- Stop `session.wins[name]` from tearing the session down when it closes,
--- keeping it registered (layout.lua hides the column that way).
function M.unwatch_window(session, name)
  local win = session.wins[name]
  if win then
    unwatch_close(session, win)
  end
end

--- Reverse of `register_window`: stop watching `session.wins[name]` for
--- auto-teardown and drop it from the registry, without closing it (the
--- caller closes it). Used when a window is replaced without ending the
--- session, e.g. the conflict layout reverting to the 2-window pair.
function M.unregister_window(session, name)
  local win = session.wins[name]
  if win then
    unwatch_close(session, win)
  end
  session.wins[name] = nil
end

--- Unregister `session.wins[name]` and close it.
function M.close_window(session, name)
  local win = session.wins[name]
  M.unregister_window(session, name)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

--- Register a managed buffer under `name` (`session.bufs[name]`),
--- `bufhidden=wipe` unless `opts.bufhidden`. `opts.panel = true` makes its
--- `:bwipe` tear the session down (tree/log); diff-content buffers are
--- swapped by every refresh and must not.
function M.register_buffer(session, name, buf, opts)
  opts = opts or {}
  session.bufs[name] = buf
  vim.bo[buf].bufhidden = opts.bufhidden or 'wipe'
  if opts.panel then
    watch_wipe(session, buf)
  end
end

--- Create a new, uniquely-named scratch buffer (`diffy://<id>/<name>/<n>`)
--- for panel/diff content. Each needs a fresh name: the outgoing buffer
--- (`bufhidden=wipe`) may still be alive until the window is actually
--- repointed at the new one.
function M.scratch_buf(session, name)
  session._buf_seq = (session._buf_seq or 0) + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/%s/%d'):format(session.id, name, session._buf_seq))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  return buf
end

--- Unbind `win` from the diff: a window opened while a diff window is
--- current copies its `scrollbind`/`cursorbind`, and a bound window drags
--- the diff's cursor along with its own.
function M.unbind(win)
  vim.wo[win].scrollbind = false
  vim.wo[win].cursorbind = false
end

--- Show `lines` in `name`, a non-focusable float laid over other windows (a
--- peek, the tree's hover, the commit message): opened at `cfg` with
--- `winhighlight` `winhl` the first time, moved to `cfg` after. Returns its
--- buffer, for the caller's highlights.
function M.overlay(session, name, cfg, lines, winhl)
  local win, buf = session.wins[name], session.bufs[name]
  if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    M.close_overlay(session, name)
    buf = M.scratch_buf(session, name)
    M.register_buffer(session, name, buf)
    win = vim.api.nvim_open_win(buf, false, cfg)
    M.register_window(session, name, win, { transient = true })
    M.unbind(win)
    vim.wo[win].diff = false
    vim.wo[win].wrap = false
    vim.wo[win].winhighlight = winhl
  else
    vim.api.nvim_win_set_config(win, cfg)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  return buf
end

--- Close the overlay `name` (its buffer is wiped with it).
function M.close_overlay(session, name)
  M.close_window(session, name)
  session.bufs[name] = nil
end

--- Make `win` a plain window again: a diff window the session lets go of,
--- or a copy of one (`:tab split`). `diffoff` puts back the folds and wrap
--- `diffthis` saved (a split copies them too); `statuscolumn` is the one
--- the review gutter replaced, if any.
function M.release(win, statuscolumn)
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, 'diffoff')
    vim.cmd('setlocal winbar<')
  end)
  M.unbind(win)
  if statuscolumn ~= nil then
    vim.api.nvim_set_option_value('statuscolumn', statuscolumn, { win = win, scope = 'local' })
  end
  vim.w[win].diffy_rev = nil
  vim.w[win].diffy_path = nil
  vim.w[win].diffy_statuscolumn = nil
end

M.PLACEHOLDER = { 'diffy: nothing loaded yet' }

--- Open a new session: its own tabpage with the column of views
--- (layout.lua) on the left and left/right diff windows filling the rest,
--- all holding placeholder buffers until content is rendered.
--- @param opts { root?: string, range?: table }  `root` is the repo root
---   (absolute path); `range` is the log range spec (see panels/log.lua's
---   `build_entries`).
function M.open(opts)
  opts = opts or {}
  next_id = next_id + 1
  local session = {
    id = next_id,
    tab = nil,
    prev_tab = vim.api.nvim_get_current_tabpage(),
    root = opts.root,
    gitdir = opts.root and vim.fn.FugitiveExtractGitDir(opts.root) or nil,
    range = opts.range,
    augroup = vim.api.nvim_create_augroup(('diffy_session_%d'):format(next_id), { clear = true }),
    ns = {},
    wins = {},
    bufs = {},
    keymaps = {},
    gen = 0,
    closed = false,
    column = require('diffy.layout').column_views(),
    floats = {},
  }

  -- open the tab on a diffy buffer so tabnew's listed [No Name] never exists
  local left_buf = M.scratch_buf(session, 'left')
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, M.PLACEHOLDER)
  vim.cmd(('tab sbuffer %d'):format(left_buf))
  session.tab = vim.api.nvim_get_current_tabpage()

  local left_win = vim.api.nvim_get_current_win()
  M.register_buffer(session, 'left', left_buf)
  M.register_window(session, 'left', left_win)

  local right_buf = M.scratch_buf(session, 'right')
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, M.PLACEHOLDER)
  local right_win = vim.api.nvim_open_win(right_buf, false, { win = left_win, split = 'right' })
  M.register_buffer(session, 'right', right_buf)
  M.register_window(session, 'right', right_win)
  -- both inherit the previous tab's jumplist and tag stack: `<C-o>` there
  -- would pull the user's pre-session buffers (a `[No Name]`) into the diff
  for _, win in ipairs({ left_win, right_win }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd('clearjumps')
    end)
    vim.fn.settagstack(win, { items = {} }, 'r')
  end

  local layout = require('diffy.layout')
  -- the file tree and the commit log always exist, shown or not: the
  -- diff's navigation and the conflict list are drawn in them
  layout.buffer(session, 'tree')
  layout.buffer(session, 'log')
  require('diffy.highlight').setup()
  layout.open_column(session)
  -- unmapped placeholders turn `]f` into nvim's `gf` on "diffy" (E447)
  local diffpair = require('diffy.diffpair')
  diffpair.set_nav_keymaps(session, left_buf)
  diffpair.set_nav_keymaps(session, right_buf)
  vim.api.nvim_create_autocmd('VimResized', {
    group = session.augroup,
    callback = function()
      layout.relayout(session)
    end,
  })
  -- a split across the tab (a toggled terminal) takes its rows from, and
  -- gives them back to, whichever column window nvim picks. Detected in the
  -- event (the window may be gone by the next tick), refitted once after.
  local function splits()
    local n = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
      if vim.api.nvim_win_get_config(w).relative == '' then
        n = n + 1
      end
    end
    return n
  end
  local split_count = splits()
  local refit_pending = false
  vim.api.nvim_create_autocmd({ 'WinNew', 'WinClosed' }, {
    group = session.augroup,
    callback = function(args)
      if session.closed or not vim.api.nvim_tabpage_is_valid(session.tab) then
        return
      end
      local n = splits()
      if args.event == 'WinClosed' then
        local win = tonumber(args.match)
        if
          win
          and vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_win_get_tabpage(win) == session.tab
          and vim.api.nvim_win_get_config(win).relative == ''
        then
          n = n - 1
        end
      end
      if n == split_count or refit_pending then
        split_count = n
        return
      end
      split_count = n
      refit_pending = true
      vim.schedule(function()
        refit_pending = false
        if not session.closed and vim.api.nvim_tabpage_is_valid(session.tab) then
          layout.fit_column(session)
        end
      end)
    end,
  })
  -- A window opened from a diff window (a picker, a plugin float) copies its
  -- scrollbind/cursorbind/diff: bound to the diff, its cursor gets dragged
  -- to the diff's column as you type in it. Only diffy's own windows stay bound.
  vim.api.nvim_create_autocmd('WinNew', {
    group = session.augroup,
    callback = function()
      vim.schedule(function()
        if session.closed or not (session.tab and vim.api.nvim_tabpage_is_valid(session.tab)) then
          return
        end
        local own = {}
        for _, w in pairs(session.wins) do
          own[w] = true
        end
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
          if not own[w] then
            for _, opt in ipairs({ 'scrollbind', 'cursorbind', 'diff' }) do
              if vim.wo[w][opt] then
                vim.api.nvim_set_option_value(opt, false, { win = w, scope = 'local' })
              end
            end
          end
        end
      end)
    end,
  })
  -- A split leaves its source window (WinLeave), then fires WinNew and
  -- WinEnter in the copy. One copied from a diff window into another tab
  -- (`:tab split`) carries diff mode, diff folds and the winbar.
  local split_from
  vim.api.nvim_create_autocmd({ 'WinLeave', 'WinEnter' }, {
    group = session.augroup,
    callback = function(args)
      local win = vim.api.nvim_get_current_win()
      split_from = args.event == 'WinLeave' and (win == session.wins.left or win == session.wins.right) and win or nil
    end,
  })
  vim.api.nvim_create_autocmd('WinNew', {
    group = session.augroup,
    callback = function()
      local src, win = split_from, vim.api.nvim_get_current_win()
      if not src or vim.api.nvim_win_get_tabpage(win) == session.tab then
        return
      end
      local statuscolumn = vim.w[src].diffy_statuscolumn
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          M.release(win, statuscolumn)
        end
      end)
    end,
  })

  vim.api.nvim_set_current_win(left_win)

  M.sessions[session.id] = session
  return session
end

--- The diff window left alone in the session's tab, if it shows a file:
--- every other window closed around it (`<C-w>o`, `:only`).
local function lone_file_window(session)
  if not vim.api.nvim_tabpage_is_valid(session.tab) then
    return nil
  end
  local splits = vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative == ''
  end, vim.api.nvim_tabpage_list_wins(session.tab))
  local win = splits[1]
  if #splits ~= 1 or (win ~= session.wins.left and win ~= session.wins.right) then
    return nil
  end
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find('^diffy://') then
    return nil
  end
  return win
end

-- A fugitive blob is one buffer per name, so another session can show it too.
-- Deleting it closes that session's window, silently from a TabClosed callback:
-- no WinClosed for its teardown nor for diffchar.vim, which then errors on it.
local function shown_elsewhere(session, buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_tabpage(win) ~= session.tab then
      return true
    end
  end
  return false
end

--- Idempotent teardown: closes managed windows/buffers, deletes the
--- augroup, removes tracked keymaps, clears extmarks in this session's
--- namespaces from every buffer, and closes the tab if still open. Windows
--- and the tab may already be gone. `opts.keep_lone`: a diff window left
--- alone with a file stays, as a plain window in a plain tab.
function M.teardown(session, opts)
  if not session or session.closed then
    return
  end
  session.closed = true
  M.sessions[session.id] = nil

  local keep = opts and opts.keep_lone and lone_file_window(session)
  if keep then
    local buf = vim.api.nvim_win_get_buf(keep)
    for name, w in pairs(session.wins) do
      if w == keep then
        session.wins[name] = nil
      end
    end
    for name, b in pairs(session.bufs) do
      if b == buf then
        session.bufs[name] = nil
      end
    end
    vim.b[buf].diffy_title = nil
  end

  -- best-effort restore of an active full checkout; skipped while nvim is
  -- exiting, where checkout.lua's VimLeavePre handler does it synchronously.
  if session.checkout and vim.v.exiting == vim.NIL then
    require('diffy.checkout').leave_on_teardown(session)
  end

  pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  if package.loaded['diffy.viewed'] then
    require('diffy.viewed').detach(session)
  end
  if package.loaded['diffy.review.drafts'] then
    require('diffy.review.drafts').detach(session)
  end
  if package.loaded['diffy.review.github'] then
    require('diffy.review.github').stop(session)
  end
  -- images are drawn on the terminal, outside any window
  if package.loaded['diffy.avatar'] then
    require('diffy.avatar').clear(session.id)
    require('diffy.avatar').clear(session.id .. ':summaries')
  end

  for _, km in ipairs(session.keymaps) do
    release(session, km)
  end
  session.keymaps = {}

  if next(session.ns) then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      for _, ns in pairs(session.ns) do
        pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
      end
    end
  end

  for _, win in pairs(session.wins) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in pairs(session.bufs) do
    if vim.api.nvim_buf_is_valid(buf) and not shown_elsewhere(session, buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  if keep then
    if package.loaded['diffy.review.ui'] then
      require('diffy.review.ui').fit_gutter(keep, nil)
    end
    M.release(keep)
  elseif vim.api.nvim_tabpage_is_valid(session.tab) then
    local ok, tabnr = pcall(vim.api.nvim_tabpage_get_number, session.tab)
    if ok then
      pcall(vim.cmd, tabnr .. 'tabclose')
    end
  end
end

-- Plugin-wide, independent of any session. No `diffy_session_` prefix so the
-- leak check never flags it.
local reaper_group = vim.api.nvim_create_augroup('diffy_reaper', { clear = true })

vim.api.nvim_create_autocmd('TabClosed', {
  group = reaper_group,
  desc = 'diffy: reap sessions whose tab closed directly (:tabclose, :qa)',
  callback = function()
    for _, s in pairs(M.sessions) do
      if not vim.api.nvim_tabpage_is_valid(s.tab) then
        M.teardown(s)
      end
    end
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = reaper_group,
  desc = 'diffy: tear down every open session before exiting',
  callback = function()
    for _, s in pairs(M.sessions) do
      M.teardown(s)
    end
  end,
})

return M
