-- BufWinEnter-driven pair swapping when a diff window shows a buffer diffy
-- didn't put there: a jump to another file already in the current list
-- (go-to-definition, `gf`, `:e`) swaps both sides and highlights it in the
-- tree; a jump outside the list leaves diff mode with a placeholder. A jump
-- in the left window is moved to the right one, which owns navigation.
local M = {}

--- `buf`'s path relative to `session.root`, or `nil` if it isn't under it
--- (a scratch buffer, another repo entirely, or an unnamed buffer). A
--- fugitive blob of this repo (`<C-o>`/`<C-t>` land on the blobs of earlier
--- pairs) resolves to the path it shows.
local function relative_path(session, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  if name:match('^fugitive://') then
    local object, dir = unpack(vim.fn.FugitiveParse(name))
    if dir ~= session.gitdir then
      return nil
    end
    return object:match('^:%d+:(.+)$') or object:match('^[^:]+:(.+)$')
  end
  local abs = vim.fn.fnamemodify(name, ':p')
  local root = vim.fn.fnamemodify(session.root, ':p')
  if abs:sub(1, #root) ~= root then
    return nil
  end
  return abs:sub(#root + 1)
end

--- React to the right window's buffer becoming `buf`: swap in the matching
--- pair if its path is in the current file list, otherwise leave diff mode
--- with an "outside diff" placeholder.
local function handle(session, buf)
  local path = relative_path(session, buf)
  if not (path and require('diffy.panels.tree').open_path(session, path)) then
    require('diffy.diffpair').leave(session)
  end
end

--- The left window navigated to `buf` (`:e`, `<C-o>`, a definition): show it
--- in the right window instead, with a jumplist/tagstack entry there so
--- `<C-o>`/`<C-t>` go back to the pair.
local function redirect(session, left, buf)
  local diffpair = require('diffy.diffpair')
  local pos = vim.api.nvim_win_get_cursor(left)
  diffpair.restore(session)
  local right = session.wins.right
  local from_pos = vim.api.nvim_win_get_cursor(right)
  local from = { vim.api.nvim_win_get_buf(right), from_pos[1], from_pos[2] + 1, 0 }
  local tagname = vim.fn.expand('<cword>')
  vim.api.nvim_set_current_win(right)
  vim.cmd("normal! m'")
  vim.fn.settagstack(right, { items = { { tagname = tagname, from = from } } }, 't')
  session._nav_guard = (session._nav_guard or 0) + 1
  local ok, err = pcall(vim.api.nvim_win_set_buf, right, buf)
  session._nav_guard = session._nav_guard - 1
  if not ok then
    error(err, 0)
  end
  handle(session, buf)
  if vim.api.nvim_win_is_valid(right) then
    pcall(vim.api.nvim_win_set_cursor, right, pos)
  end
end

--- Arm the `BufWinEnter` autocmd on the session augroup, scoped to the diff
--- windows. Ignores buffer changes made by diffy itself (`_nav_guard`).
function M.setup(session)
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = session.augroup,
    callback = function(args)
      if (session._nav_guard or 0) > 0 then
        return
      end
      local win = vim.api.nvim_get_current_win()
      local react
      if win == session.wins.right then
        react = handle
      elseif win == session.wins.left and args.buf ~= session.bufs.left then
        react = function()
          redirect(session, win, args.buf)
        end
      else
        return
      end
      -- Once the jump is over: the event's other handlers (diffchar.vim
      -- tracks each tab's diff buffers) still expect the pair as it was, and
      -- the swap's own events must fire, which they don't inside an autocmd.
      -- A jump in the left window also moves its cursor, and `:edit` its
      -- focus, after BufWinEnter.
      vim.schedule(function()
        if not session.closed and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == args.buf then
          react(session, args.buf)
        end
      end)
    end,
  })
  -- A picker jump re-sets 'foldmethod' after the pair is swapped in (snacks'
  -- "fix folds" hack schedules `foldmethod=expr`): with diff mode's
  -- foldlevel=0 that folds the whole file.
  vim.api.nvim_create_autocmd('OptionSet', {
    group = session.augroup,
    pattern = 'foldmethod',
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if (win == session.wins.left or win == session.wins.right) and vim.wo[win].diff and vim.wo[win].foldmethod ~= 'diff' then
        vim.wo[win].foldmethod = 'diff'
      end
    end,
  })
end

return M
