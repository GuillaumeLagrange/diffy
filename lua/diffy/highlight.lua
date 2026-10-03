-- Panel highlight groups. All `default = true`, so a colorscheme or the
-- user can override any of them.
local M = {}

local LINKS = {
  DiffyAdded = 'Added',
  DiffyChanged = 'Changed',
  DiffyRemoved = 'Removed',
  -- a viewed file whose change changed since: the `●` before its name
  DiffyViewedChanged = 'DiagnosticWarn',
  DiffyConflict = 'DiagnosticError',
  DiffyFileAdded = 'DiffAdd',
  DiffyFileDeleted = 'DiffDelete',
  DiffyDirectory = 'Directory',
  DiffySha = 'Identifier',
  DiffyMerge = 'Comment',
  DiffyLabel = 'Title',
  DiffySelection = 'Visual',
  -- not CursorLine: the panel's own cursorline would make it invisible
  DiffyCurrentFile = 'Visual',
  DiffyThreadSummary = 'Comment',
  DiffyThreadSummaryResolved = 'NonText',
  -- the line numbers of the commented lines in thread previews
  DiffyThreadRange = 'PmenuSel',
  DiffyThreadTime = 'Comment',
  DiffyThreadKey = 'Special',
  DiffyThreadHint = 'Comment',
  DiffyThreadDraft = 'DiagnosticWarn',
  DiffyThreadPending = 'DiagnosticInfo',
  DiffyThreadSent = 'Comment',
  DiffyThreadConflict = 'DiagnosticError',
  DiffyThreadStaged = 'DiagnosticHint',
  DiffyThreadResolved = 'DiagnosticOk',
  DiffyThreadOutdated = 'DiagnosticWarn',
  DiffyThreadCodeBar = 'Comment',
  DiffyThreadSuggestion = 'Added',
  DiffyThreadLink = 'Underlined',
  DiffyThreadAuthor1 = 'Identifier',
  DiffyThreadAuthor2 = 'DiagnosticHint',
  DiffyThreadAuthor3 = 'Constant',
  DiffyThreadAuthor4 = 'Title',
  DiffyThreadAuthor5 = 'Function',
  DiffyThreadLane1 = 'DiagnosticError',
  DiffyThreadLane2 = 'DiagnosticWarn',
  DiffyThreadLane3 = 'DiagnosticInfo',
  DiffyThreadLane4 = 'DiagnosticHint',
  DiffyThreadLane5 = 'DiagnosticOk',
  DiffyThreadLane6 = 'Constant',
}

-- number of DiffyThreadAuthor<n> groups, picked by login
local AUTHOR_COLORS = 5

--- An author's name group, the same one everywhere.
function M.author(name)
  local sum = 0
  for i = 1, #name do
    sum = sum + name:byte(i)
  end
  return 'DiffyThreadAuthor' .. (sum % AUTHOR_COLORS + 1)
end

local LANE_COLORS = 6

--- A thread's colour index from its id: stable across files, sessions and
--- redraws.
local function lane_index(id)
  local h, s = 0, tostring(id)
  for i = 1, #s do
    h = (h * 31 + s:byte(i)) % 4294967296
  end
  return h % LANE_COLORS + 1
end

--- The colour group of a thread's range bar, summary dot and text.
function M.lane(id)
  return 'DiffyThreadLane' .. lane_index(id)
end

--- The frame group of a thread's float, in the thread's colour.
function M.lane_border(id)
  return 'DiffyThreadBorder' .. lane_index(id)
end

--- Status letter -> highlight group.
M.STATUS = {
  A = 'DiffyAdded',
  ['?'] = 'DiffyAdded',
  M = 'DiffyChanged',
  R = 'DiffyChanged',
  C = 'DiffyChanged',
  D = 'DiffyRemoved',
  U = 'DiffyConflict',
}

--- First `key` ('fg'/'bg') colour among `groups`.
local function color_of(key, ...)
  for _, g in ipairs({ ... }) do
    local h = vim.api.nvim_get_hl(0, { name = g, link = false })
    if h[key] then
      return h[key]
    end
  end
end

function M.setup()
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  vim.api.nvim_set_hl(0, 'DiffyCurrentFileName', { bold = true, default = true })
  -- background only: Normal/NormalFloat are often transparent, and linking
  -- to CursorLine or Pmenu would drag in their underline/foreground
  local card = color_of('bg', 'CursorLine', 'StatusLine', 'Pmenu')
  vim.api.nvim_set_hl(0, 'DiffyThread', { bg = card, default = true })
  vim.api.nvim_set_hl(0, 'DiffyThreadHeader', { bg = color_of('bg', 'Pmenu', 'Visual', 'StatusLine'), default = true })
  -- a separator-coloured line on the card's own background, so the frame
  -- belongs to the card and titles/footers sit on it without patches
  vim.api.nvim_set_hl(0, 'DiffyThreadBorder', { fg = color_of('fg', 'WinSeparator', 'FloatBorder', 'Comment'), bg = card, default = true })
  vim.api.nvim_set_hl(0, 'DiffyThreadAuthor', { bold = true, default = true })
  for i = 1, LANE_COLORS do
    vim.api.nvim_set_hl(0, 'DiffyThreadBorder' .. i, { fg = color_of('fg', 'DiffyThreadLane' .. i), bg = card, default = true })
  end
  -- weight only: the open thread's summary keeps its bar's colour
  vim.api.nvim_set_hl(0, 'DiffyThreadCurrent', { bold = true, default = true })
end

--- Truncate `s` to at most `width` display cells, ending in '…' if cut.
function M.truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  if width <= 0 then
    return ''
  end
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width - 1 then
      break
    end
    table.insert(out, ch)
    w = w + cw
  end
  return table.concat(out) .. '…'
end

-- what a cut name keeps at least before the directories give way to '…/'
local MIN_NAME = 5

local function abbreviate(dir)
  -- `.github` -> `.g`: the dot alone says nothing
  local dot = dir:sub(1, 1) == '.' and '.' or ''
  return dot .. vim.fn.strcharpart(dir:sub(#dot + 1), 0, 1)
end

--- Fit a path to `width` cells: its directories shrink to their first
--- character, outermost first (`a/b/long_dir/name`); still too long, the
--- end of the last component is cut (`a/b/c/na…`); only when that leaves
--- the name under `MIN_NAME` cells do the directories become '…/'.
function M.truncate_path(s, width)
  local sw = vim.fn.strdisplaywidth
  if sw(s) <= width then
    return s
  end
  local dirs = vim.split(s, '/', { plain = true })
  local name = table.remove(dirs)
  for i, dir in ipairs(dirs) do
    dirs[i] = abbreviate(dir)
    local out = table.concat(dirs, '/') .. '/' .. name
    if sw(out) <= width then
      return out
    end
  end
  local prefix = #dirs > 0 and (table.concat(dirs, '/') .. '/') or ''
  if width - sw(prefix) >= MIN_NAME then
    return prefix .. M.truncate(name, width - sw(prefix))
  end
  if #dirs > 0 and width - 2 >= MIN_NAME then
    return '…/' .. M.truncate(name, width - 2)
  end
  return M.truncate(name, width)
end

--- Usable text width of `win` (window width minus number/sign columns).
function M.text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

--- Width to render a side panel at: `win`'s text width minus one spare
--- column, or `cached` (else `config.panel_width`) when `win` is gone.
function M.panel_width(win, cached)
  if win and vim.api.nvim_win_is_valid(win) then
    return M.text_width(win) - 1
  end
  return cached or require('diffy').config.panel_width
end

--- `winhighlight` of a card float: its own background inside a thin frame.
M.CARD_HL = table.concat({
  'NormalFloat:DiffyThread',
  'FloatBorder:DiffyThreadBorder',
  'FloatTitle:DiffyThreadHeader',
  'FloatFooter:DiffyThreadBorder',
  'FoldColumn:DiffyThread',
  'EndOfBuffer:DiffyThread',
}, ',')

--- `CARD_HL` framed in `thread`'s lane colour, or plain once it's resolved.
function M.card_hl(thread)
  if thread.resolved then
    return M.CARD_HL
  end
  local frame = M.lane_border(thread.id)
  return (M.CARD_HL:gsub('FloatBorder:DiffyThreadBorder', 'FloatBorder:' .. frame)
    :gsub('FloatFooter:DiffyThreadBorder', 'FloatFooter:' .. frame))
end

--- Key hints for a float's footer, `{ {key, label, drop = n}, ... }`. Hints
--- with a `drop` rank go, lowest first, until the rest fit `width`.
function M.key_hints(keys, width)
  local shown = vim.list_extend({}, keys)
  local function size()
    local n = 2
    for i, k in ipairs(shown) do
      n = n + vim.fn.strdisplaywidth(k[1] .. ' ' .. k[2]) + (i < #shown and 3 or 0)
    end
    return n
  end
  while width and size() > width do
    local worst
    for i, k in ipairs(shown) do
      if k.drop and (not worst or k.drop < shown[worst].drop) then
        worst = i
      end
    end
    if not worst then
      break
    end
    table.remove(shown, worst)
  end
  -- title/footer chunks don't take the border's background: stack it in
  local chunks = { { ' ', 'DiffyThread' } }
  for i, k in ipairs(shown) do
    table.insert(chunks, { k[1], { 'DiffyThread', 'DiffyThreadKey' } })
    table.insert(chunks, { ' ' .. k[2] .. (i < #shown and '   ' or ' '), { 'DiffyThread', 'DiffyThreadHint' } })
  end
  return chunks
end

return M
