-- Checkout mode (`X`): while on, the single selected log commit is checked
-- out onto the real worktree (the branch itself for its head, multi-commit or
-- worktree selections), so its right side is a real, LSP-navigable buffer.
-- Writes a recovery state file while HEAD is detached and restores the
-- original branch when the mode ends (`X` again, closing the tab, exit).
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local store = require('diffy.review.store')

local M = {}

-- session.id -> { root, gitdir, branch } for every active full checkout.
-- Independent of `session.sessions` (teardown may have emptied it before
-- `VimLeavePre` runs) so the exit handler doesn't depend on autocmd order.
local active = {}

local function state_path(gitdir)
  return gitdir .. '/diffy/checkout.json'
end

-- written atomically: a nvim killed mid-write would otherwise leave a file
-- the next start can't restore from
local function write_state(gitdir, state)
  store.save(state_path(gitdir), state)
end

local function read_state(gitdir)
  return store.load(state_path(gitdir))
end

local function delete_state(gitdir)
  store.delete(state_path(gitdir))
end

-- Check out `branch` and delete the state file on success; `cb(ok)` is optional.
local function checkout_branch(root, gitdir, branch, session, cb)
  run.git({ 'checkout', '--quiet', branch }, {
    cwd = root,
    session = session,
    on_exit = function(res)
      local ok = res.code == 0
      if ok then
        delete_state(gitdir)
      end
      if cb then
        cb(ok)
      end
    end,
  })
end

--- Whether an interrupted full checkout's state file exists for `gitdir`.
function M.pending(gitdir)
  return read_state(gitdir) ~= nil
end

local function current_branch(root, cb, session)
  run.git({ 'symbolic-ref', '--short', '-q', 'HEAD' }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      cb(res.code == 0 and vim.trim(res.stdout or '') or nil)
    end,
  })
end

local function winbar(session)
  local win = session.wins and session.wins.log
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local co = session.checkout
  local bar = co and ('⎇ checkout ' .. (co.commit and co.commit:sub(1, 7) or co.branch)) or ''
  if vim.wo[win].winbar ~= bar then
    vim.wo[win].winbar = bar
    require('diffy.layout').relayout(session)
  end
end

local function redraw(session)
  winbar(session)
  require('diffy.panels.tree').render(session, function()
    run.ready({ session = session.id, event = 'checkout' })
  end)
end

-- Commit the mode should have checked out for the current selection; nil
-- means the branch (multi-commit selection, worktree entries, branch head).
local function target(session)
  local sel = session.sel
  local entry = sel and sel.top == sel.bottom and session.entries[sel.top]
  if not entry or entry.kind ~= 'commit' or entry.sha == session.checkout.head then
    return nil
  end
  return entry.sha
end

local function refusal(clean, err)
  return clean == nil and ('git status failed: ' .. err) or 'tracked changes present, commit or stash them first'
end

-- Move HEAD to `sha` (nil: the branch). `cb(ok)`; a dirty tree refuses so
-- edits made in the checked-out files are never carried or lost.
local function switch(session, sha, cb)
  local co = session.checkout
  if sha == co.commit then
    cb(true)
    return
  end
  repo.is_clean(session.root, nil, function(clean, err)
    if not clean then
      vim.notify('diffy: keeping the current checkout — ' .. refusal(clean, err), vim.log.levels.WARN)
      cb(false)
      return
    end
    local function done(ok)
      if ok then
        co.commit = sha
        session.checkout_sha = sha
        -- the right side's real files changed on disk under loaded buffers
        vim.cmd('silent! checktime')
      end
      cb(ok)
    end
    if not sha then
      checkout_branch(session.root, session.gitdir, co.branch, session, done)
      return
    end
    write_state(session.gitdir, { branch = co.branch, head = co.head, commit = sha })
    run.git({ 'checkout', '--quiet', '--detach', sha }, {
      cwd = session.root,
      session = session,
      on_exit = function(res)
        if res.code ~= 0 and not co.commit then
          delete_state(session.gitdir)
        elseif res.code ~= 0 then
          write_state(session.gitdir, { branch = co.branch, head = co.head, commit = co.commit })
        end
        done(res.code == 0)
      end,
    })
  end, session)
end

--- `X` with the mode off: turn checkout mode on, checking out the selected
--- commit (or keeping the branch). Refuses with tracked changes.
function M.enter(session)
  repo.is_clean(session.root, nil, function(clean, err)
    if not clean then
      vim.notify('diffy: cannot check out — ' .. refusal(clean, err), vim.log.levels.ERROR)
      run.ready({ session = session.id, event = 'checkout' })
      return
    end
    current_branch(session.root, function(branch)
      local sel = session.sel or { top = 1, bottom = 1 }
      session.checkout = { branch = branch or session.head_sha, head = session.head_sha, sel = { top = sel.top, bottom = sel.bottom } }
      active[session.id] = { root = session.root, gitdir = session.gitdir, branch = session.checkout.branch }
      switch(session, target(session), function()
        redraw(session)
      end)
    end, session)
  end, session)
end

--- Turn checkout mode off (`X` again, closing the tab): restore the saved
--- branch and delete the state file. `cb(ok)`; on `false` (tree became dirty
--- since the checkout) HEAD stays on the checked-out commit.
function M.leave(session, cb)
  local co = session.checkout
  if not co then
    cb(true)
    return
  end
  local function off()
    session.checkout = nil
    session.checkout_sha = nil
    active[session.id] = nil
    cb(true)
  end
  if not co.commit then
    off()
    return
  end
  repo.is_clean(session.root, nil, function(clean, err)
    if not clean then
      vim.notify('diffy: cannot leave the checked-out commit — ' .. refusal(clean, err), vim.log.levels.ERROR)
      cb(false)
      return
    end
    checkout_branch(session.root, session.gitdir, co.branch, session, function(ok)
      if ok then
        vim.cmd('silent! checktime')
        off()
      else
        cb(false)
      end
    end)
  end, session)
end

--- `X`: toggle checkout mode.
function M.toggle(session)
  if session.checkout then
    M.leave(session, function(ok)
      if ok then
        redraw(session)
      end
    end)
  else
    M.enter(session)
  end
end

--- Hook for `session.on_select` (init.lua): in checkout mode, check out what
--- the new selection needs before it is drawn. `cb()` runs once HEAD matches;
--- on refusal (dirty tree) the selection snaps back and `cb` is not called.
function M.before_select(session, cb)
  local co = session.checkout
  if not co then
    cb()
    return
  end
  local sha = target(session)
  if sha == co.commit then
    co.sel = { top = session.sel.top, bottom = session.sel.bottom }
    cb()
    return
  end
  switch(session, sha, function(ok)
    if ok then
      co.sel = { top = session.sel.top, bottom = session.sel.bottom }
      winbar(session)
      run.ready({ session = session.id, event = 'checkout' })
      cb()
    else
      session.sel = { top = co.sel.top, bottom = co.sel.bottom }
      require('diffy.panels.log').render(session)
      run.ready({ session = session.id, event = 'checkout' })
    end
  end)
end

--- Best-effort restore when a session tears down with a checkout active
--- (not while exiting; see `VimLeavePre` below). Nothing is left to refuse
--- into: a dirty tree keeps the state file for `:Diffy restore`, with a
--- warning. `session` is not passed to git: it is already closed, which
--- would turn the callbacks into no-ops.
function M.leave_on_teardown(session)
  if not (session.checkout and session.checkout.commit) then
    active[session.id] = nil
    return
  end
  local root, gitdir, co = session.root, session.gitdir, session.checkout
  repo.is_clean(root, nil, function(clean, err)
    if not clean then
      local why = clean == nil and ('git status failed: ' .. err) or 'tracked changes present'
      vim.notify(
        ('diffy: left commit %s checked out (%s) — clean the tree and run `:Diffy restore`'):format(co.commit:sub(1, 7), why),
        vim.log.levels.WARN
      )
      return
    end
    checkout_branch(root, gitdir, co.branch)
  end)
  active[session.id] = nil
end

-- nvim is exiting: `VimLeavePre` handlers have no later event-loop turn to
-- run an async callback in, so git runs synchronously here, including the
-- clean-tree check.
local function restore_sync(info)
  local status = vim.system({ 'git', 'status', '--porcelain=v2', '-z' }, { cwd = info.root, text = true }):wait()
  if status.code ~= 0 then
    return
  end
  for _, e in ipairs(parse.status_v2(status.stdout or '')) do
    if e.kind ~= 'untracked' and e.kind ~= 'ignored' then
      return -- dirty: leave the state file for `:Diffy restore`
    end
  end
  local checkout = vim.system({ 'git', 'checkout', '--quiet', info.branch }, { cwd = info.root }):wait()
  if checkout.code == 0 then
    delete_state(info.gitdir)
  end
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('diffy_checkout_reaper', { clear = true }),
  callback = function()
    for _, info in pairs(active) do
      restore_sync(info)
    end
  end,
})

--- `:Diffy restore`: recover from an interrupted full checkout for the repo
--- at the current cwd - reads the state file, checks out the saved branch,
--- and deletes it. Works with no diffy session open, since nvim may have
--- been killed since the checkout.
function M.restore(_args)
  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      repo.notify_not_repo(err)
      run.ready({ event = 'restore' })
      return
    end
    local gitdir = vim.fn.FugitiveExtractGitDir(root)
    local state = read_state(gitdir)
    if not state then
      vim.notify('diffy: nothing to restore', vim.log.levels.WARN)
      run.ready({ event = 'restore' })
      return
    end
    checkout_branch(root, gitdir, state.branch, nil, function(ok)
      if ok then
        vim.notify('diffy: restored branch ' .. state.branch, vim.log.levels.INFO)
      end
      run.ready({ event = 'restore' })
    end)
  end)
end

return M
