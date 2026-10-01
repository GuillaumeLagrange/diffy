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

--- Set a buffer-local keymap and record it for teardown/`unmap_buffer`.
--- `opts.buffer` is required. All diffy keymaps get a `diffy: ` prefixed
--- `desc`, which the leak check relies on to find stragglers.
--- `opts.fallback`: `rhs` returns true when it acted; otherwise the key does
--- what it did without diffy (the buffer-local map it shadowed, else the
--- global one, else the built-in).
function M.map(session, modes, lhs, rhs, opts)
  opts = vim.deepcopy(opts or {})
  assert(opts.buffer, 'session.map: opts.buffer is required')
  opts.desc = 'diffy: ' .. (opts.desc or lhs)
  local fallback = opts.fallback
  opts.fallback = nil
  for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
    local mode_rhs = rhs
    if fallback then
      local lhsraw = vim.keycode(lhs)
      local shadowed = find_map(vim.api.nvim_buf_get_keymap(opts.buffer, mode), lhsraw)
      mode_rhs = function()
        if not rhs() then
          run_mapping(shadowed or find_map(vim.api.nvim_get_keymap(mode), lhsraw), lhs)
        end
      end
    end
    vim.keymap.set(mode, lhs, mode_rhs, opts)
    table.insert(session.keymaps, { buf = opts.buffer, mode = mode, lhs = lhs })
  end
end

--- Remove every tracked keymap on `buf` (e.g. when a real-file buffer
--- leaves a diffy window).
function M.unmap_buffer(session, buf)
  for i = #session.keymaps, 1, -1 do
    local km = session.keymaps[i]
    if km.buf == buf then
      pcall(vim.keymap.del, km.mode, km.lhs, { buffer = km.buf })
      table.remove(session.keymaps, i)
    end
  end
end

-- Deferred to the next event-loop tick: a `WinClosed`/`BufWipeout` callback
-- can fire while a native multi-window closer (`:tabclose`, `:qa`) is still
-- midway through closing this same tab's other windows; force-closing them
-- from inside that nested callback races the native loop (nvim reports
-- E444 on a now-misnumbered tab). Scheduling runs teardown only once the
-- triggering command has fully finished, by which point a `:tabclose` has
-- already closed everything itself and teardown's window/tab steps are
-- no-ops, while a lone `:q` still has its siblings open for teardown to
-- close.
local function schedule_teardown(session)
  return function()
    vim.schedule(function()
      M.teardown(session)
    end)
  end
end

local function watch_close(session, win)
  local au_id = vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    callback = schedule_teardown(session),
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

  vim.api.nvim_set_current_win(left_win)

  M.sessions[session.id] = session
  return session
end

--- Idempotent teardown: closes managed windows/buffers, deletes the
--- augroup, removes tracked keymaps, clears extmarks in this session's
--- namespaces from every buffer, and closes the tab if still open. Windows
--- and the tab may already be gone.
function M.teardown(session)
  if not session or session.closed then
    return
  end
  session.closed = true
  M.sessions[session.id] = nil

  -- best-effort restore of an active full checkout; skipped while nvim is
  -- exiting, where checkout.lua's VimLeavePre handler does it synchronously.
  if session.checkout and vim.v.exiting == vim.NIL then
    require('diffy.checkout').leave_on_teardown(session)
  end

  pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  -- images are drawn on the terminal, outside any window
  if package.loaded['diffy.avatar'] then
    require('diffy.avatar').clear(session.id)
    require('diffy.avatar').clear(session.id .. ':summaries')
  end

  for _, km in ipairs(session.keymaps) do
    if km.buf and vim.api.nvim_buf_is_valid(km.buf) then
      pcall(vim.keymap.del, km.mode, km.lhs, { buffer = km.buf })
    end
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
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  if vim.api.nvim_tabpage_is_valid(session.tab) then
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
