local session = require('diffy.session')
local repo = require('diffy.git.repo')

local M = {}

M.config = {
  panel_width = 40,
  -- views stacked in the left column, top to bottom: 'tree' (files), 'log'
  -- (commits), 'threads' (review threads). Any other view opens in a float.
  column = { 'tree', 'log' },
  keymaps = {
    -- buffer-local in every diffy window: hide the panel column, or show it
    -- and go to the file tree
    toggle_panel = '<leader>e',
    -- in the diff windows: mark the file shown viewed, or unmark it
    toggle_viewed = '<leader>m',
    -- in the file tree: the same for the file, folder or section at the cursor
    tree_toggle_viewed = 'm',
  },
  -- copied to `+` by `:Diffy review submit` (local review); %s is the absolute path of review.md
  review_prompt = 'Read %s and address each review comment. Reply per comment id with what you changed, and tick its "- [ ] resolved" box in that file once it is handled.',
  -- GitHub avatars in comment headers, on terminals with the kitty graphics
  -- protocol (needs curl and ImageMagick)
  avatars = true,
  -- the GitHub layer: the open PR of the session's branch over `:Diffy` and
  -- `:Diffy branch`; `false` turns it off. `read_interval`: seconds between
  -- reads while the session's tab is current, 0 for no timer.
  github = { read_interval = 300 },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  -- a list is replaced, not merged index by index
  if opts and opts.column then
    M.config.column = vim.deepcopy(opts.column)
  end
end

--- subcommand name -> function(args: string[])
M.dispatch = {}

local function current_session(where)
  local s = session.current()
  if not s then
    vim.notify(('diffy: no session in %s'):format(where or 'the current tab'), vim.log.levels.WARN)
  end
  return s
end

local function review_ready(s)
  require('diffy.git.run').ready({ session = s.id, event = 'review' })
end

local function backend_supports(review, sub)
  if type(review.backend[sub]) == 'function' then
    return true
  end
  vim.notify(('diffy: `review %s` isn\'t available for %s'):format(sub, review.backend.name), vim.log.levels.WARN)
  return false
end

--- Callback for backend calls answering `(ok, warnings)`; `done_msg` is
--- notified on success when given.
local function report_remote(s, done_msg)
  return function(ok, warnings)
    for _, w in ipairs(warnings or {}) do
      vim.notify('diffy: ' .. w, vim.log.levels.WARN)
    end
    if ok and done_msg then
      vim.notify(done_msg)
    end
    review_ready(s)
  end
end

-- review events, in the order the submit prompt lists them
local VERDICTS = {
  { event = 'COMMENT', arg = 'comment', key = 'c', label = 'comment', title = 'Submit review' },
  { event = 'APPROVE', arg = 'approve', key = 'a', label = 'approve', title = 'Approve' },
  { event = 'REQUEST_CHANGES', arg = 'request_changes', key = 'r', label = 'request changes', title = 'Request changes' },
}

--- The VERDICTS entries GitHub offers in session `s`.
local function offered_verdicts(s, github)
  local events = github.verdicts(s)
  return vim.tbl_filter(function(v)
    return vim.tbl_contains(events, v.event)
  end, VERDICTS)
end

--- `:Diffy threads [file] [author=<name>] [state=…] [review=<id>]`: every
--- thread in the session, or the shown file's, in the threads view.
function M.dispatch.threads(args)
  local s = current_session()
  if not s then
    return
  end
  require('diffy.review.threads').open(s, args)
end

local review_subcommands = {}

function review_subcommands.clear(s, review)
  review.backend.clear(s)
  vim.notify('diffy: review cleared')
  review_ready(s)
end

function review_subcommands.push(s, review)
  review.backend.push(s, report_remote(s, 'diffy: pushed'))
end

function review_subcommands.pull(s, review)
  review.backend.pull(s, function()
    review_ready(s)
  end)
end

--- `:Diffy review submit [comment|approve|request_changes]`: a modal for
--- the review message. Without a PR it goes to the agent. With one, `a`
--- agent or `g` GitHub, then the review event (skipped when the argument
--- names it, which also means GitHub, or when only one applies).
function review_subcommands.submit(s, review, ui, args)
  local verdicts = review.pr and offered_verdicts(s, require('diffy.review.github')) or nil
  local preset = args[2]
  if preset then
    local match = vim.tbl_filter(function(v)
      return v.arg == preset
    end, verdicts or {})
    if #match == 0 then
      local expected = vim.tbl_map(function(v)
        return v.arg
      end, verdicts or {})
      vim.notify(
        #expected > 0 and ('diffy: `review submit` expects %s'):format(table.concat(expected, '|'))
          or "diffy: `review submit` takes no argument when the branch has no open PR",
        vim.log.levels.WARN
      )
      return
    end
    verdicts = match
  end
  local to_agent = function(body)
    require('diffy.review.local').submit(s, nil, body, report_remote(s))
  end
  if not verdicts then
    ui.open_submit_body(s, to_agent, { title = 'Send review to the agent', action = 'send' })
    return
  end
  local github_choice = {
    'g',
    'GitHub',
    'github',
    sub = vim.tbl_map(function(v)
      return { v.key, v.label, v.event }
    end, verdicts),
    sub_title = 'Submit as',
  }
  local choices = preset and { github_choice } or { { 'a', 'agent', 'agent' }, github_choice }
  ui.open_submit_body(s, function(body, value)
    if value == 'agent' then
      to_agent(body)
    else
      require('diffy.review.github').submit(s, value, body, report_remote(s, 'diffy: review submitted'))
    end
  end, { title = 'Submit review', action = 'submit', choices = choices, choose_title = 'Send to' })
end

local REVIEW_SUBCOMMANDS = { 'clear', 'pull', 'push', 'submit' }

--- `:Diffy review clear|submit` (local backend) and `push|pull|submit`
--- (GitHub backend).
function M.dispatch.review(args)
  local s = current_session()
  if not s then
    return
  end
  local ui = require('diffy.review.ui')
  local review = ui.ensure(s)
  if not review then
    vim.notify('diffy: review is only available in :Diffy and :Diffy branch', vim.log.levels.WARN)
    return
  end
  local sub = args[1]
  local handler = sub and review_subcommands[sub]
  if not handler then
    vim.notify(('diffy: `review` expects %s'):format(table.concat(REVIEW_SUBCOMMANDS, '|')), vim.log.levels.WARN)
    return
  end
  if backend_supports(review, sub) then
    handler(s, review, ui, args)
  end
end

function M.dispatch.close()
  local s = current_session()
  if not s then
    return
  end
  require('diffy.checkout').leave(s, function(ok)
    if ok then
      session.teardown(s)
      require('diffy.git.run').ready({ session = s.id, event = 'close' })
    end
  end)
end

--- `:Diffy viewed`: toggle the file shown; `:Diffy viewed clear` drops its marks.
function M.dispatch.viewed(args)
  local s = current_session()
  if not s then
    return
  end
  local tree = require('diffy.panels.tree')
  if args[1] == 'clear' then
    tree.clear_viewed_current(s)
  elseif args[1] == nil then
    tree.toggle_viewed_current(s)
  else
    vim.notify('diffy: `viewed` expects nothing or `clear`', vim.log.levels.WARN)
  end
end

--- `:Diffy panel`: hide/show the tree/log column.
function M.dispatch.panel()
  local s = current_session('this tab')
  if not s then
    return
  end
  require('diffy.layout').toggle_column(s)
end

--- `:Diffy feedback`: describe what you don't like in a modal; `<C-s>` hands it to the
--- `User DiffyFeedback` handlers (`data.text`), with the session as it was. Diffy doesn't store
--- it: a handler that wants the session's state calls `debug_state()`.
function M.dispatch.feedback()
  local s = current_session()
  if not s then
    return
  end
  if #vim.api.nvim_get_autocmds({ event = 'User', pattern = 'DiffyFeedback' }) == 0 then
    vim.notify('diffy: nothing handles feedback (no `User DiffyFeedback` autocmd)', vim.log.levels.WARN)
    return
  end
  require('diffy.review.ui').open_submit_body(s, function(body)
    local text = vim.trim(body)
    -- after the modal's `stopinsert` took effect, so the handler sees the session's own mode
    vim.schedule(function()
      if text == '' then
        vim.notify('diffy: empty feedback, nothing sent', vim.log.levels.WARN)
      else
        vim.api.nvim_exec_autocmds('User', { pattern = 'DiffyFeedback', data = { text = text } })
        vim.notify('diffy: feedback sent')
      end
      require('diffy.git.run').ready({ session = s.id, event = 'feedback' })
    end)
  end, { title = 'What bothers you here?', action = 'send' })
end

local function entry_key(e)
  return e.kind .. ':' .. (e.sha or '')
end

-- `R` and diffy's own mutations rebuild everything but keep the selection when
-- its endpoints still exist.
local function keep_selection(old_entries, old_sel, entries)
  if not (old_entries and old_sel) then
    return nil
  end
  local index = {}
  for i, e in ipairs(entries) do
    index[entry_key(e)] = i
  end
  local top = index[entry_key(old_entries[old_sel.top])]
  local bottom = index[entry_key(old_entries[old_sel.bottom])]
  if top and bottom and top <= bottom then
    return { top = top, bottom = bottom }
  end
  return nil
end

--- Build (or rebuild, on `R`/`:w`) the log/tree/diff-pair content for `s`
--- from its stored `s.root`/`s.range`: entries, default/kept selection, HEAD
--- and repo status, then the panels. Fires `User DiffyReady` once rendering
--- finishes, then `done()` if given. Never reads GitHub: an attached layer's
--- threads are placed again from what it last read.
function M.build(s, done)
  local log_panel = require('diffy.panels.log')
  local tree_panel = require('diffy.panels.tree')
  local run = require('diffy.git.run')
  local selection = require('diffy.selection')
  local github = require('diffy.review.github')

  local function build()
    local range = s.range
    if range.kind == 'branch' and not range.base and not range.pr_base and github.enabled(s) then
      local cache = github.load_cache(s.gitdir, s.branch)
      range.pr_base = cache and cache.pr.base
    end
    log_panel.build_entries(s.root, range, function(entries, err)
      if not entries then
        vim.notify('diffy: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      github.remeasure(s, function()
        entries = log_panel.with_layer(s, entries)
        local kept = keep_selection(s.entries, s.sel, entries)
        s.entries = entries
        s.follow_pathspec = entries.follow_pathspec
        s.sel = kept or log_panel.default_selection(entries, s.range)
        if not s.sel then
          vim.notify('diffy: nothing to show for this selection', vim.log.levels.WARN)
          return
        end
        repo.head_sha(s.root, function(head_sha)
          s.head_sha = head_sha
          repo.status(s.root, function(status_entries)
            s.status_entries = status_entries or {}
            s.pair = selection.resolve(s.entries, s.sel.top, s.sel.bottom)
            if not s.setup_done then
              log_panel.setup(s)
              tree_panel.setup(s)
              require('diffy.navigation').setup(s)
              require('diffy.diffpair').track_edits(s)
              require('diffy.diffpair').keep_bound_cursor_visible(s)
              s.setup_done = true
            end
            local function finish()
              require('diffy.layout').relayout(s)
              log_panel.render(s)
              tree_panel.render(s, function()
                run.ready({ session = s.id, event = 'render' })
                if done then
                  done()
                end
                -- the first render doesn't wait on GitHub
                github.start(s)
              end)
            end
            local review = require('diffy.review.ui').ensure(s)
            -- what the agent resolved in review.md since the last build
            if review and review.backend.sync then
              review.backend.sync(s)
            end
            require('diffy.review.track').prepare(s, finish, { fresh = true })
          end, s)
        end, s)
      end)
    end, s)
  end

  if s.branch then
    build()
    return
  end
  repo.head_sha(s.root, function(head_sha)
    s.head_sha = head_sha
    -- what the session's stores are keyed by; read once, since checkout mode detaches HEAD
    s.branch = require('diffy.review.local').branch(s)
    build()
  end, s)
end

local function relative_to(root, abspath)
  if abspath:sub(1, #root + 1) == root .. '/' then
    return abspath:sub(#root + 2)
  end
  return abspath
end

--- Open a new session for `spec` (`{kind='default'|'branch'|'range', ...}`,
--- see panels/log.lua). The tab skeleton is created synchronously so
--- teardown works immediately; the repo root and panels follow async.
function M.start(spec)
  local selection = require('diffy.selection')
  local log_panel = require('diffy.panels.log')
  local tree_panel = require('diffy.panels.tree')
  local run = require('diffy.git.run')

  local s = session.open({ range = spec })
  s.on_select = function(sess, done)
    require('diffy.checkout').before_select(sess, function()
      sess.pair = selection.resolve(sess.entries, sess.sel.top, sess.sel.bottom)
      log_panel.render(sess)
      tree_panel.render(sess, function()
        run.ready({ session = sess.id, event = 'select' })
        if done then
          done()
        end
      end)
    end)
  end
  s.refresh = function(sess, opts)
    M.build(sess)
    if opts and opts.read and sess.layer then
      require('diffy.review.github').read(sess)
    end
  end

  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      repo.notify_not_repo(err)
      session.teardown(s)
      return
    end
    s.root = root
    s.gitdir = vim.fn.FugitiveExtractGitDir(root)
    if spec.abspath then
      spec.path = relative_to(root, spec.abspath)
    end
    if require('diffy.checkout').pending(s.gitdir) then
      vim.notify('diffy: an interrupted full checkout is pending here — run `:Diffy restore`', vim.log.levels.WARN)
    end
    M.build(s)
  end, s)
end

function M.dispatch.branch(args)
  M.start({ kind = 'branch', base = args[1] })
end

--- `:Diffy pr`: `:Diffy branch` on the base of the branch's open PR; warns
--- (`DiffyReady` `pr`, no session) when there's none.
function M.dispatch.pr(_args)
  local run = require('diffy.git.run')
  local github = require('diffy.review.github')
  local function refuse(reason)
    vim.notify('diffy: `:Diffy pr` - ' .. reason, vim.log.levels.WARN)
    run.ready({ event = 'pr' })
  end
  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      repo.notify_not_repo(err)
      run.ready({ event = 'pr' })
      return
    end
    run.git({ 'branch', '--show-current' }, {
      cwd = root,
      notify_on_error = false,
      on_exit = function(res)
        local branch = vim.trim(res.stdout or '')
        if branch == '' then
          refuse('not on a branch')
          return
        end
        github.pr_view(root, branch, function(pr, ferr)
          if not (pr and pr.state == 'OPEN') then
            refuse(ferr or ('branch `%s` has no open PR'):format(branch))
            return
          end
          repo.base_ref(root, pr.baseRefName, function(base)
            M.start({ kind = 'branch', base = base })
          end)
        end)
      end,
    })
  end)
end

function M.dispatch.restore(args)
  require('diffy.checkout').restore(args)
end

--- `:Diffy file [path]`: log = commits touching `path` (`--follow`),
--- default selection the newest commit; `path` defaults to the current
--- buffer's file.
function M.dispatch.file(args)
  local abspath
  if args[1] then
    abspath = vim.fn.fnamemodify(args[1], ':p')
  else
    abspath = vim.api.nvim_buf_get_name(0)
    if abspath == '' then
      vim.notify('diffy: no path given and the current buffer has no file', vim.log.levels.WARN)
      return
    end
  end
  M.start({ kind = 'file', abspath = abspath })
end

--- `:Diffy conflicts`: the 4-window conflict view over every unmerged file,
--- tree-only (no log entries).
function M.dispatch.conflicts()
  require('diffy.conflict').start()
end

--- Bare `:Diffy`. Ranges (`A..B`) are routed by `M.command` before this, so
--- any argument here is unrecognized.
function M.open(args)
  if args and args[1] then
    vim.notify(('diffy: unrecognized argument `%s`'):format(args[1]), vim.log.levels.WARN)
    return
  end
  M.start({ kind = 'default' })
end

--- Entry point for the `:Diffy` command; `fargs` is the user command's
--- `opts.fargs`.
function M.command(fargs)
  local sub = fargs[1]
  if sub and M.dispatch[sub] then
    M.dispatch[sub](vim.list_slice(fargs, 2))
    return
  end
  if sub and sub:find('..', 1, true) then
    M.start({ kind = 'range', expr = sub })
    return
  end
  M.open(fargs)
end

local THREAD_STATES = { 'open', 'resolved', 'outdated', 'detached' }

--- The current tab's session and its review backend module (without
--- loading the review), or nil.
local function completion_backend()
  local s = session.current()
  if not s or not s.range then
    return nil, nil
  end
  if type(s.review) == 'table' then
    return s, s.review.backend
  end
  local kind = s.range.kind
  if kind == 'default' or kind == 'branch' then
    return s, require('diffy.review.local')
  end
  return s, nil
end

--- Candidates for the argument after `words` (the complete ones before it).
local function candidates(words, arg_lead)
  local sub = words[1]
  if not sub then
    local names = vim.tbl_keys(M.dispatch)
    table.sort(names)
    return names
  end
  if sub == 'review' then
    local s, backend = completion_backend()
    if #words == 1 then
      return vim.tbl_filter(function(name)
        return not backend or type(backend[name]) == 'function'
      end, REVIEW_SUBCOMMANDS)
    elseif #words == 2 and words[2] == 'submit' then
      if backend and type(backend.verdicts) ~= 'function' then
        return {}
      end
      local events = backend and backend.verdicts(s) or {}
      local out = {}
      for _, v in ipairs(VERDICTS) do
        if not backend or vim.tbl_contains(events, v.event) then
          table.insert(out, v.arg)
        end
      end
      return out
    end
  elseif sub == 'threads' then
    local key = arg_lead:match('^(%a+)=')
    if key == 'state' then
      return vim.tbl_map(function(v)
        return 'state=' .. v
      end, THREAD_STATES)
    elseif key == 'author' then
      local s = session.current()
      local seen, out = {}, {}
      for _, t in ipairs(s and type(s.review) == 'table' and s.review.threads or {}) do
        for _, c in ipairs(t.comments) do
          if c.author and not seen[c.author] then
            seen[c.author] = true
            table.insert(out, 'author=' .. c.author)
          end
        end
      end
      table.sort(out)
      return out
    end
    return { 'file', 'author=', 'state=', 'review=' }
  elseif sub == 'file' and #words == 1 then
    return vim.fn.getcompletion(arg_lead, 'file')
  elseif sub == 'viewed' and #words == 1 then
    return { 'clear' }
  elseif sub == 'branch' and #words == 1 then
    local res = vim.system({ 'git', 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes' }, { text = true }):wait()
    return res.code == 0 and vim.split(vim.trim(res.stdout), '\n', { trimempty = true }) or {}
  end
  return {}
end

--- `:Diffy` completion: subcommands, then what each takes (review
--- subcommands and events for the current session's backend, threads
--- filters, paths, branches).
function M.complete(arg_lead, cmdline, cursor_pos)
  local words = vim.split(cmdline:sub(1, cursor_pos), '%s+', { trimempty = true })
  -- the command itself, and the word being completed
  table.remove(words, 1)
  if arg_lead ~= '' then
    table.remove(words)
  end
  return vim.tbl_filter(function(c)
    return c:sub(1, #arg_lead) == arg_lead
  end, candidates(words, arg_lead))
end

--- Plain-data snapshot of every session and the recent git/gh commands, for
--- bug reports. Fields of a half-built session may be nil.
function M.debug_state()
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local sessions = {}
  for _, s in pairs(session.sessions) do
    local selected = {}
    if s.sel and s.entries then
      for i = s.sel.top, s.sel.bottom do
        local e = s.entries[i]
        if e then
          selected[#selected + 1] = { kind = e.kind, rev = e.rev, subject = e.subject }
        end
      end
    end
    local bufs = {}
    for name, buf in pairs(s.bufs or {}) do
      bufs[name] = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or '<wiped>'
    end
    local review = s.review
    if type(review) == 'table' then
      review = {
        backend = review.backend and review.backend.name,
        branch = review.branch,
        threads = review.threads and #review.threads,
      }
    end
    sessions[#sessions + 1] = {
      id = s.id,
      current = s.tab == cur_tab,
      root = s.root,
      range = s.range,
      sel = s.sel,
      selected = selected,
      entries = s.entries and #s.entries,
      current_path = s.current_path,
      current_file_line = s.current_file_line,
      hidden_side = s.hidden_side,
      panel_hidden = s.panel_hidden,
      conflict_active = s.conflict_active,
      conflict_path = s.conflict_path,
      checkout_sha = s.checkout_sha,
      gen = s.gen,
      wins = s.wins,
      bufs = bufs,
      review = review,
    }
  end
  return { sessions = sessions, commands = require('diffy.git.run').recent }
end

return M
