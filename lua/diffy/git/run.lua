-- Async vim.system wrapper for git/gh calls, so the UI never blocks on a
-- subprocess. Every caller passes `opts.cwd` (the repo root) and gets its
-- result via `opts.on_exit`, scheduled onto the main loop.
local M = {}

local RECENT_MAX = 50
--- The last `RECENT_MAX` commands, oldest first, for error reports
--- (`diffy.debug_state`). `code` stays nil while running; `dropped` is set
--- when the result was discarded as stale.
M.recent = {}

--- Run `git <args>` asynchronously.
--- @param opts { cwd: string, on_exit?: fun(res: vim.SystemCompleted), notify_on_error?: boolean, session?: table, gen?: integer }
--- @return vim.SystemObj
function M.git(args, opts)
  return M.run({ 'git', unpack(args) }, opts)
end

--- Run an arbitrary command asynchronously (`gh` calls use this directly).
--- On a nonzero exit, surfaces the failure via `vim.notify` unless
--- `opts.notify_on_error == false`.
---
--- `opts.session`, if given, makes the completion a no-op (no notify, no
--- `on_exit`) once the session is torn down (`session.closed`) or once a
--- newer render has superseded it (`opts.gen ~= session.gen`). Every git/gh
--- call goes through here, so a chained callback stops at the first link
--- and can't touch wiped buffers or clobber a fresher render.
--- @param cmd string[]
--- @param opts { cwd: string, on_exit?: fun(res: vim.SystemCompleted), notify_on_error?: boolean, session?: table, gen?: integer }
--- @return vim.SystemObj
function M.run(cmd, opts)
  opts = opts or {}
  local session, gen = opts.session, opts.gen
  local entry = { cmd = cmd, cwd = opts.cwd, session = session and session.id, gen = gen, at = os.date('%H:%M:%S') }
  local started = vim.uv.hrtime()
  table.insert(M.recent, entry)
  if #M.recent > RECENT_MAX then
    table.remove(M.recent, 1)
  end
  return vim.system(cmd, { cwd = opts.cwd, text = true }, function(res)
    entry.code = res.code
    entry.ms = math.floor((vim.uv.hrtime() - started) / 1e6)
    entry.stderr = res.code ~= 0 and (res.stderr or ''):sub(1, 2000) or nil
    vim.schedule(function()
      if session and (session.closed or (gen ~= nil and session.gen ~= gen)) then
        entry.dropped = true
        return
      end
      if res.code ~= 0 and opts.notify_on_error ~= false then
        vim.notify(
          ('diffy: `%s` failed (%d)\n%s'):format(table.concat(cmd, ' '), res.code, vim.trim(res.stderr or '')),
          vim.log.levels.ERROR
        )
      end
      if opts.on_exit then
        opts.on_exit(res)
      end
    end)
  end)
end

--- Fire `User DiffyReady` once a view (or refresh) has finished rendering.
--- Tests wait on this instead of sleeping. Scheduled so it always runs after
--- any in-flight work from the same event-loop tick.
--- @param data table|nil forwarded as the autocmd's `data`
function M.ready(data)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds('User', { pattern = 'DiffyReady', modeline = false, data = data })
  end)
end

return M
