-- The diff windows' folds of unchanged lines: a closed fold names the
-- scopes the change below it sits in, and opening one keeps the change next
-- to it where it was on screen.
local M = {}

--- The first line from `lnum` on that differs from the other side (a
--- changed or added line, or one under filler).
local function next_change(lnum)
  for l = lnum, vim.fn.line('$') do
    if vim.fn.diff_hlID(l, 1) ~= 0 or vim.fn.diff_filler(l) > 0 then
      return l
    end
  end
end

--- The header lines (trimmed, outermost first) of the treesitter nodes
--- holding 0-based `row` that open on a line before `above`. A node opens
--- a scope when it starts with a token (`type`, `fn`, `{`, `if`): one
--- starting with a named child (a block's first statement, a doc comment)
--- starts on a line that isn't its header.
function M.scopes(buf, row, above)
  local parser = vim.treesitter.get_parser(buf, nil, { error = false })
  local tree = parser and parser:parse()[1]
  if not tree then
    return {}
  end
  local function line(r)
    return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1]
  end
  local col = #line(row):match('^%s*')
  local node = tree:root():named_descendant_for_range(row, col, row, col)
  local rows, seen = {}, {}
  while node and node:parent() do
    local start = node:start()
    local first = node:child(0)
    if start < above and first and not first:named() and not seen[start] then
      seen[start] = true
      table.insert(rows, 1, start)
    end
    node = node:parent()
  end
  return vim.tbl_map(function(r)
    return vim.trim(line(r))
  end, rows)
end

--- 'foldtext' of the diff windows: nvim's own, with the fold's first line
--- replaced by the scopes of the change below it, the outer ones dropped
--- when they don't fit.
function M.foldtext()
  local default = vim.fn.foldtext()
  local fe = vim.v.foldend
  if not vim.wo.diff or fe >= vim.fn.line('$') then
    return default
  end
  local change = next_change(fe + 1)
  local scopes = change and M.scopes(vim.api.nvim_get_current_buf(), change - 1, fe) or {}
  if #scopes == 0 then
    return default
  end
  local prefix = default:match('^.-: ') or ''
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local room = info.width - info.textoff - vim.fn.strdisplaywidth(prefix)
  local first = 1
  local function text()
    return (first > 1 and '… › ' or '') .. table.concat(scopes, ' › ', first)
  end
  while first < #scopes and vim.fn.strdisplaywidth(text()) > room do
    first = first + 1
  end
  return prefix .. text()
end

M.FOLDTEXT = "v:lua.require'diffy.folds'.foldtext()"

--- `key` (`zo`, `zO`, `za`, `zA`) in a diff window. A closed fold opens
--- around the change next to it: the change below stays put when the fold
--- is in the window's top half (or at the top of the file), the cursor
--- landing on the fold's last line; else the change above, the cursor on
--- its first line.
function M.open(key)
  local count = vim.v.count1
  local lnum = vim.fn.line('.')
  local fs, fe = vim.fn.foldclosed(lnum), vim.fn.foldclosedend(lnum)
  local row = vim.fn.winline()
  vim.cmd('normal! ' .. count .. key)
  if fs == -1 or not vim.wo.diff or vim.fn.foldclosed(lnum) ~= -1 then
    return
  end
  local up = fe < vim.fn.line('$') and (fs == 1 or row <= vim.api.nvim_win_get_height(0) / 2)
  if not up then
    vim.fn.winrestview({ lnum = fs })
    return
  end
  -- scroll up a line at a time until the fold's last line is back at `row`
  local top = fe
  vim.fn.winrestview({ lnum = fe, topline = top, topfill = 0 })
  while top > 1 and vim.fn.winline() < row do
    top = top - 1
    vim.fn.winrestview({ topline = top, topfill = 0 })
  end
end

return M
