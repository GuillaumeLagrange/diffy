-- Comment bodies turned into readable card lines. GitHub bodies, bots' in
-- particular, mix markdown with HTML (headings, <details>, badge images,
-- links around megabyte-long URLs, entities): rendering keeps the markdown,
-- turns the HTML into its markdown equivalent, and moves URLs out of the
-- text into a per-line link table (`gx`). <details> become closed folds.
-- Display only: bodies are stored as written.
local M = {}

local BADGE_HL = { ['0'] = 'DiagnosticError', ['1'] = 'DiagnosticError', ['2'] = 'DiagnosticWarn', ['3'] = 'DiagnosticInfo' }

local ENTITIES = { nbsp = ' ', amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", ndash = '–', mdash = '—', hellip = '…', middot = '·', copy = '©', rarr = '→', larr = '←' }

-- tags stripped once their markdown equivalent (if any) is in place
local TAGS = {}
for _, t in ipairs({
  'a', 'abbr', 'b', 'blockquote', 'br', 'center', 'code', 'dd', 'del', 'details', 'div', 'dl', 'dt', 'em', 'font', 'h1', 'h2', 'h3',
  'h4', 'h5', 'h6', 'hr', 'i', 'img', 'ins', 'kbd', 'li', 'mark', 'ol', 'p', 'picture', 'pre', 's', 'samp', 'small', 'source',
  'span', 'strike', 'strong', 'sub', 'summary', 'sup', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'tt', 'u', 'ul', 'var',
}) do
  TAGS[t] = true
end

local OPEN, CLOSE = '\1', '\2'

local function attr(tag, name)
  return tag:match('%f[%w]' .. name .. '%s*=%s*"([^"]*)"') or tag:match('%f[%w]' .. name .. "%s*=%s*'([^']*)'")
    or tag:match('%f[%w]' .. name .. '%s*=%s*([^%s>"\']+)')
end

local function decode(s)
  return (
    s:gsub('&(#?)([xX]?)(%w+);', function(hash, x, name)
      if hash == '#' then
        local n = tonumber(name, x ~= '' and 16 or 10)
        return n and vim.fn.nr2char(n) or nil
      end
      return ENTITIES[name]
    end)
  )
end

--- Short text for a bare URL: its host, and the path's last part if short.
local function url_label(url)
  if #url <= 40 then
    return url:gsub('^https?://', '')
  end
  local host = url:match('^%a+://([^/%?#]+)') or url:sub(1, 30)
  local last = url:gsub('[%?#].*$', ''):match('/([^/]+)/?$')
  if last and #last <= 24 and not url:match('^%a+://[^/]+/?$') then
    return host .. '/…/' .. last
  end
  return host .. '/…'
end

local function fragment_only(url)
  return url == nil or url == '' or url:sub(1, 1) == '#'
end

--- Replace the markup of one line (outside code fences) with tokens and
--- markdown: returns a string where `\1n\2` stands for `tokens[n]`, with
--- `\n` where HTML breaks the line.
local function tokenize(s, tokens)
  local function token(t)
    table.insert(tokens, t)
    t.n = #tokens
    return OPEN .. #tokens .. CLOSE
  end
  s = s:gsub('<code>(.-)</code>', function(c)
    return '`' .. decode(c) .. '`'
  end)
  s = s:gsub('(`+)(.-)%1', function(ticks, c)
    return token({ text = ticks .. c .. ticks })
  end)
  -- escapes stay where unescaping would start a list, heading, quote or
  -- emphasis/link/table markup
  s = s:gsub('()\\(%p)', function(at, ch)
    if ch:match('[%*_`%[%]\\<>|]') or (ch:match('[-+#>=.)]') and s:sub(1, at - 1):match('^%s*%d*$')) then
      return nil
    end
    return token({ text = ch })
  end)
  s = s:gsub('<picture[^>]*>(.-)</picture>', '%1'):gsub('<source[^>]*>', '')
  s = s:gsub('<img%s[^>]*>', function(tag)
    return token({ img = true, alt = decode(attr(tag, 'alt') or ''), url = attr(tag, 'src'), right = attr(tag, 'align') == 'right' })
  end)
  s = s:gsub('!%[([^%]]*)%]%(<?([^%s%)>]+)>?[^%)]*%)', function(alt, url)
    return token({ img = true, alt = alt, url = url })
  end)
  s = s:gsub('<(https?://[^>%s]+)>', function(url)
    return token({ url = url, inner = url_label(url) })
  end)
  -- innermost first: the last opening tag before the first closing one
  while true do
    local close = s:find('</a>', 1, true)
    local open, open_end, a
    local from = 1
    while true do
      local o, oe, attrs = s:find('<a%s([^>]*)>', from)
      if not o or (close and o > close) then
        break
      end
      open, open_end, a, from = o, oe, attrs, oe + 1
    end
    if not (open and close) then
      break
    end
    local inner = s:sub(open_end + 1, close - 1)
    local t = { url = attr(a, 'href'), inner = vim.trim(inner) }
    local lone = tokens[tonumber(inner:match('^%s*' .. OPEN .. '(%d+)' .. CLOSE .. '%s*$') or 0)]
    if lone and lone.img and lone.right then
      lone.right, t.right = false, true
    end
    s = s:sub(1, open - 1) .. token(t) .. s:sub(close + 4)
  end
  s = s:gsub('%[([^%]]*)%]%(<?([^%s%)>]+)>?[^%)]*%)', function(inner, url)
    return token({ url = url, inner = inner })
  end)
  s = s:gsub('%f[%w]https?://[%w%-%._~:/%?#@!%$&%*%+,;=%%\']+', function(url)
    local tail = url:match('[.,;:!?\']+$') or ''
    url = url:sub(1, #url - #tail)
    return token({ url = url, inner = url_label(url) }) .. tail
  end)
  s = s:gsub('<h(%d)[^>]*>(.-)</h%1>', function(level, text)
    return '\n' .. ('#'):rep(tonumber(level)) .. ' ' .. vim.trim(text) .. '\n'
  end)
  s = s:gsub('<br%s*/?>', '\n'):gsub('<li[^>]*>', '\n- '):gsub('</?p[^>]*>', '\n'):gsub('<hr[^>]*>', '\n')
  s = s:gsub('</?strong>', '**'):gsub('</?b>', '**'):gsub('</?em>', '_'):gsub('</?i>', '_')
  s = s:gsub('</?del>', '~~'):gsub('</?strike>', '~~'):gsub('</?s>', '~~')
  s = s:gsub('<(/?)(%a%w*)([^>]*)>', function(_, name)
    if TAGS[name:lower()] then
      return ''
    end
  end)
  return decode(s)
end

--- One rendered line: `text` plus marks with byte columns.
local function new_line(text)
  return { text = text or '', links = {}, marks = {}, images = {} }
end

local function append(line, text)
  line.text = line.text .. text
end

--- Expand `s` (tokens included) at the end of `line`. `in_link`: images
--- inside a link are opened by it.
local function expand(line, s, tokens, in_link)
  local pos = 1
  local tail = {}
  while pos <= #s do
    local a, b, n = s:find(OPEN .. '(%d+)' .. CLOSE, pos)
    if not a then
      append(line, s:sub(pos))
      break
    end
    append(line, s:sub(pos, a - 1))
    local t = tokens[tonumber(n)]
    if t.right and not in_link then
      table.insert(tail, t)
    elseif t.img then
      local col = #line.text
      local alt = vim.trim(t.alt ~= '' and t.alt or 'image')
      append(line, '[' .. alt .. ']')
      local p = alt:match('^[Pp](%d)$')
      if p and BADGE_HL[p] then
        table.insert(line.marks, { col = col, end_col = #line.text, hl = BADGE_HL[p] })
      end
      local svg = t.url and t.url:gsub('[%?#].*$', ''):lower():match('%.svg$')
      -- a badge's own file isn't worth opening
      if t.url and not in_link and not svg then
        table.insert(line.links, { col = col, end_col = #line.text, url = t.url })
      end
      if svg then
        table.insert(line.images, { col = col, end_col = #line.text, url = t.url })
      end
    elseif t.inner then
      local col = #line.text
      local link = not fragment_only(t.url)
      expand(line, t.inner, tokens, link or in_link)
      if #line.text == col then
        append(line, '↗')
      end
      if link then
        table.insert(line.links, { col = col, end_col = #line.text, url = t.url })
      end
    else
      append(line, t.text)
    end
    pos = b + 1
  end
  for _, t in ipairs(tail) do
    append(line, line.text:match('%S$') and '  ' or '')
    t.right = false
    expand(line, OPEN .. t.n .. CLOSE, tokens, false)
    t.right = true
  end
end

local function shift(line, from, by)
  for _, list in ipairs({ line.links, line.marks, line.images }) do
    for _, m in ipairs(list) do
      if m.col >= from then
        m.col, m.end_col = m.col + by, m.end_col + by
      end
    end
  end
end

--- Displayed width of a table cell: the delimiters markdown conceals don't count.
local function cell_width(cell)
  return vim.fn.strdisplaywidth((cell:gsub('`', ''):gsub('%*%*', '')))
end

--- Pad the cells of the table rows `rows` (lines) so columns line up.
local function align_table(rows)
  local cells, widths = {}, {}
  for r, line in ipairs(rows) do
    cells[r] = {}
    local start = line.text:find('|', 1, true)
    local pos = start + 1
    while true do
      local bar = line.text:find('|', pos, true)
      while bar and line.text:sub(bar - 1, bar - 1) == '\\' do
        bar = line.text:find('|', bar + 1, true)
      end
      if not bar then
        break
      end
      local c = { s = pos, e = bar - 1, text = vim.trim(line.text:sub(pos, bar - 1)) }
      table.insert(cells[r], c)
      if not c.text:match('^:?%-+:?$') then
        widths[#cells[r]] = math.max(widths[#cells[r]] or 3, cell_width(c.text))
      end
      pos = bar + 1
    end
  end
  for r, line in ipairs(rows) do
    local text = line.text
    -- right to left, so earlier columns keep their offsets
    for i = #cells[r], 1, -1 do
      local c = cells[r][i]
      local w = widths[i] or 3
      local new
      if c.text:match('^:?%-+:?$') then
        new = ' ' .. (c.text:sub(1, 1) == ':' and ':' or '-') .. ('-'):rep(w - 2) .. (c.text:sub(-1) == ':' and ':' or '-') .. ' '
      else
        new = ' ' .. c.text .. (' '):rep(w - cell_width(c.text)) .. ' '
      end
      local lead = #(text:sub(c.s, c.e):match('^%s*'))
      shift(line, c.e + 1, #new - (c.e - c.s + 1))
      shift(line, c.s, 1 - lead)
      text = text:sub(1, c.s - 1) .. new .. text:sub(c.e + 1)
    end
    line.text = text
  end
end

local function fence_open(l)
  local indent, marker = l:match('^(%s*)(```+)')
  if not marker then
    indent, marker = l:match('^(%s*)(~~~+)')
  end
  if marker and #indent <= 3 then
    return marker, vim.trim(l:sub(#indent + #marker + 1))
  end
end

--- Lines outside fences, with <details>/<summary> tags split onto lines
--- of their own.
local function split_blocks(lines)
  local out, fence = {}, nil
  for _, l in ipairs(lines) do
    local marker = fence_open(l)
    if fence then
      table.insert(out, l)
      if marker and marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence and vim.trim(l):match('^[`~]+$') then
        fence = nil
      end
    elseif marker then
      fence = marker
      table.insert(out, l)
    else
      local s = l:gsub('%s*(<summary[^>]*>.-</summary>)%s*', '\n%1\n'):gsub('%s*(</?details[^>]*>)%s*', '\n%1\n')
      if s == l then
        table.insert(out, l)
      else
        for _, part in ipairs(vim.split(s, '\n', { plain = true })) do
          if vim.trim(part) ~= '' then
            table.insert(out, part)
          end
        end
      end
    end
  end
  return out
end

--- Render `body` for a card. Rows and byte columns are 0-based within the
--- returned `lines`:
--- - `links[row]`: `{ {col, end_col, url} }` for `gx`
--- - `marks`: `{ {row, col, end_col, hl} }` (badges without an image)
--- - `images`: `{ {row, col, end_col, url} }` (SVG badges, drawable over their marker)
--- - `folds`: `{ {start, stop, open} }`, from <details>, titled by their first line
--- - `code`: `{ {row, suggestion} }` lines inside fences; `labels`: `{ {row, empty} }`
---   for suggestion fences, `row` being the line before the fence (-1: above the body)
function M.body(body)
  local text = (body or ''):gsub('\r', ''):gsub('<!%-%-.-%-%->', '')
  -- an HTML button (`<a>` around a `<picture>`/`<img>`, one tag per indented
  -- line) is tokenized per line: fold it onto one, without the indent that
  -- would make it a code block
  text = text:gsub('<a%s[^>]*>%s*<picture.-</picture>%s*</a>', function(m)
    return (m:gsub('%s*\n%s*', ' '))
  end)
  text = text:gsub('<picture[^>]*>.-</picture>', function(m)
    return (m:gsub('%s*\n%s*', ' '))
  end)
  local src = split_blocks(vim.split(text, '\n', { plain = true }))
  local out = {} -- rendered line objects
  local res = { links = {}, marks = {}, images = {}, folds = {}, code = {}, labels = {} }
  local fence, stack, pending_title = nil, {}, false
  local tables = {}
  local function emit(line, verbatim)
    line.verbatim = verbatim
    table.insert(out, line)
  end
  local function start_fold(fold, title)
    local line = new_line('▾ ')
    expand(line, tokenize(title, fold.tokens), fold.tokens)
    line.title = true
    emit(line)
    fold.start = #out - 1
  end
  local function ensure_titles()
    for _, f in ipairs(stack) do
      if not f.start then
        start_fold(f, 'Details')
      end
    end
    pending_title = false
  end
  for _, l in ipairs(src) do
    local marker, info = fence_open(l)
    if fence then
      if marker and marker:sub(1, 1) == fence.char and #marker >= fence.len and vim.trim(l):match('^[`~]+$') then
        if fence.label then
          fence.label.empty = fence.empty
        end
        fence = nil
      else
        table.insert(res.code, { row = #out, suggestion = fence.label ~= nil })
        fence.empty = false
      end
      emit(new_line(l), true)
    elseif l:match('^%s*<details[^>]*>%s*$') then
      table.insert(stack, { open = l:match('%sopen[%s>=]') ~= nil, tokens = {} })
      pending_title = true
    elseif l:match('^%s*<summary[^>]*>.-</summary>%s*$') and #stack > 0 and not stack[#stack].start then
      local top = table.remove(stack)
      ensure_titles()
      table.insert(stack, top)
      start_fold(top, vim.trim(l:match('<summary[^>]*>(.-)</summary>')))
      pending_title = true
    elseif l:match('^%s*</details>%s*$') then
      local f = table.remove(stack)
      if f and f.start then
        local stop = #out - 1
        while stop > f.start and out[stop + 1].text:match('^%s*$') and not out[stop + 1].verbatim do
          stop = stop - 1
        end
        if stop > f.start then
          table.insert(res.folds, { start = f.start, stop = stop, open = f.open })
        end
      end
    elseif pending_title and vim.trim(l) == '' then
      -- GitHub needs a blank line after <summary>; the card doesn't
    else
      ensure_titles()
      if marker then
        fence = { char = marker:sub(1, 1), len = #marker, empty = true }
        if info == 'suggestion' then
          -- under the line before the fence: fence lines are concealed
          fence.label = { row = #out - 1 }
          table.insert(res.labels, fence.label)
        end
        emit(new_line(l), true)
      else
        local tokens = {}
        for _, part in ipairs(vim.split(tokenize(l, tokens), '\n', { plain = true })) do
          local line = new_line()
          expand(line, part, tokens)
          line.text = line.text:gsub('%s+$', '')
          local score = line.text:match('^#+ .-Confidence [Ss]core: ()%d/%d')
          if score then
            local n = tonumber(line.text:sub(score, score))
            table.insert(line.marks, { col = score - 1, end_col = score + 2, hl = n >= 4 and 'DiagnosticOk' or n == 3 and 'DiagnosticWarn' or 'DiagnosticError' })
          end
          emit(line)
        end
      end
    end
  end
  -- blank lines: none around the body, no runs of them
  local kept = {}
  for i, line in ipairs(out) do
    line.src_row = i - 1
    local blank = not line.verbatim and line.text:match('^%s*$')
    if not (blank and (#kept == 0 or kept[#kept].blank)) then
      line.blank = blank
      table.insert(kept, line)
    end
  end
  while #kept > 0 and kept[#kept].blank do
    table.remove(kept)
  end
  local row_of = {}
  for i, line in ipairs(kept) do
    row_of[line.src_row] = i - 1
  end
  -- a dropped row maps to the next kept one (fold ends: the previous)
  local function map_row(r, back)
    while r >= 0 and r < #out and not row_of[r] do
      r = r + (back and -1 or 1)
    end
    return row_of[r] or (back and #kept - 1 or r)
  end
  -- tables: a header row, a separator row, then rows
  local i = 1
  while i <= #kept do
    local l = kept[i]
    local sep = kept[i + 1]
    if not l.verbatim and l.text:match('^%s*|.*|%s*$') and sep and sep.text:match('^%s*|[%s:|%-]+|%s*$') then
      local rows = { l }
      local j = i + 1
      while kept[j] and not kept[j].verbatim and kept[j].text:match('^%s*|.*|%s*$') do
        table.insert(rows, kept[j])
        j = j + 1
      end
      align_table(rows)
      i = j
    else
      i = i + 1
    end
  end
  res.lines = {}
  for r, line in ipairs(kept) do
    res.lines[r] = line.text
    if #line.links > 0 then
      res.links[r - 1] = line.links
      for _, l in ipairs(line.links) do
        table.insert(res.marks, { row = r - 1, col = l.col, end_col = l.end_col, hl = 'DiffyThreadLink' })
      end
    end
    for _, m in ipairs(line.marks) do
      table.insert(res.marks, { row = r - 1, col = m.col, end_col = m.end_col, hl = m.hl })
    end
    for _, m in ipairs(line.images) do
      table.insert(res.images, { row = r - 1, col = m.col, end_col = m.end_col, url = m.url })
    end
  end
  for _, c in ipairs(res.code) do
    c.row = map_row(c.row)
  end
  for _, lb in ipairs(res.labels) do
    lb.row = lb.row < 0 and -1 or map_row(lb.row, true)
  end
  for _, f in ipairs(res.folds) do
    f.start, f.stop = map_row(f.start), map_row(f.stop, true)
  end
  return res
end

-- ---------------------------------------------------------------------
-- card buffers: links, folds and images of the bodies they show

local by_buf = {}

--- Record what `M.body` returned for the body put at 0-based `row`, one
--- `col` in, of `buf`.
function M.add(buf, res, row, col)
  local s = by_buf[buf]
  if not s then
    s = { links = {}, folds = {}, images = {} }
    by_buf[buf] = s
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function()
        by_buf[buf] = nil
      end,
    })
  end
  for r, list in pairs(res.links) do
    s.links[row + r] = s.links[row + r] or {}
    for _, l in ipairs(list) do
      table.insert(s.links[row + r], { col = l.col + col, end_col = l.end_col + col, url = l.url })
    end
  end
  for _, f in ipairs(res.folds) do
    table.insert(s.folds, { start = row + f.start, stop = row + f.stop, open = f.open })
  end
  for _, m in ipairs(res.images) do
    table.insert(s.images, { row = row + m.row, col = m.col + col, end_col = m.end_col + col, url = m.url })
  end
end

function M.reset(buf)
  by_buf[buf] = nil
end

--- The images of `buf` (`{row, col, end_col, url}`, 0-based).
function M.images(buf)
  return by_buf[buf] and by_buf[buf].images or {}
end

--- Blank out the markers of `buf`'s images that can be drawn (`ns` for the
--- extmarks), leaving just the image's width: the image goes over it.
--- Only images narrower than their marker are drawn.
function M.paint_images(buf, ns)
  local avatar = require('diffy.avatar')
  for _, im in ipairs(M.images(buf)) do
    local a = avatar.aspect(im.url)
    local text = vim.api.nvim_buf_get_text(buf, im.row, im.col, im.row, im.end_col, {})[1]
    local starts = vim.str_utf_pos(text)
    -- one row tall; cells are about twice as tall as wide
    local need = a and math.ceil(a * 2)
    if need and not im.painted and need <= #starts then
      im.painted = true
      -- per character, over markdown's own conceal of the brackets
      for i, s in ipairs(starts) do
        local e = (starts[i + 1] or #text + 1) - 1
        vim.api.nvim_buf_set_extmark(buf, ns, im.row, im.col + s - 1, {
          end_col = im.col + e,
          conceal = i <= need and ' ' or '',
          priority = 300,
        })
      end
    end
  end
end

--- `avatar.place` items for the painted images of `buf` visible in `win`.
function M.image_items(win, buf)
  local items = {}
  for _, im in ipairs(M.images(buf)) do
    if im.painted and vim.api.nvim_win_call(win, function()
      return vim.fn.foldclosed(im.row + 1)
    end) == -1 then
      local pos = vim.fn.screenpos(win, im.row + 1, im.col + 1)
      if pos.row > 0 then
        table.insert(items, { url = im.url, row = pos.row, col = pos.col })
      end
    end
  end
  return items
end

--- A closed <details> shows its title with the arrow turned.
function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  return (line:gsub('▾', '▸', 1))
end

--- The link covering (0-based) `col` of row `lnum` in `buf`, and the line's
--- links.
local function link_at(buf, lnum, col)
  local s = by_buf[buf]
  local links = s and s.links[lnum - 1] or {}
  for _, l in ipairs(links) do
    if col >= l.col and col < l.end_col then
      return l, links
    end
  end
  return nil, links
end

--- Open the link under the cursor of the card window `win`, or pick one of
--- its line's links.
local function open_link(win, buf)
  local cur = vim.api.nvim_win_get_cursor(win)
  local link, links = link_at(buf, cur[1], cur[2])
  link = link or (#links == 1 and links[1]) or nil
  if link then
    return vim.ui.open(link.url)
  end
  if #links == 0 then
    vim.notify('diffy: no link on this line', vim.log.levels.WARN)
    return
  end
  local text = vim.api.nvim_buf_get_lines(buf, cur[1] - 1, cur[1], false)[1] or ''
  vim.ui.select(links, {
    prompt = 'Open link',
    format_item = function(l)
      return ('%s  %s'):format(vim.trim(text:sub(l.col + 1, l.end_col)), l.url)
    end,
  }, function(l)
    if l then
      vim.ui.open(l.url)
    end
  end)
end

--- A mouse click on a card: open the link under the pointer, or toggle the
--- <details> fold whose title was clicked. Mapped in the cards and in the
--- diff windows, since the click arrives while the window under the cursor
--- is still the current one. Returns `true` when it landed on a card.
function M.click()
  local m = vim.fn.getmousepos()
  if m.winid == 0 or not vim.api.nvim_win_is_valid(m.winid) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(m.winid)
  if not by_buf[buf] or m.line == 0 then
    return false
  end
  local link = link_at(buf, m.line, math.max(m.column - 1, 0))
  if link then
    vim.ui.open(link.url)
    return true
  end
  vim.api.nvim_win_call(m.winid, function()
    if vim.fn.foldlevel(m.line) > 0 then
      vim.api.nvim_win_set_cursor(m.winid, { m.line, 0 })
      vim.cmd('normal! za')
    end
  end)
  return true
end

--- `<C-LeftMouse>`/`<2-LeftMouse>` on `buf`: `M.click`, else the default.
function M.map_click(session, buf)
  for _, lhs in ipairs({ '<C-LeftMouse>', '<2-LeftMouse>' }) do
    require('diffy.session').map(session, 'n', lhs, function()
      if not M.click() then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), 'n', false)
      end
    end, { buffer = buf, desc = 'open the link or fold under the mouse' })
  end
end

--- Set up the card window `win` showing `buf`: folds for <details>, `gx`.
--- Call again when `buf` is shown in another window.
function M.attach(session, win, buf)
  local s = by_buf[buf]
  local wo = vim.wo[win]
  wo.foldmethod = 'manual'
  wo.foldtext = "v:lua.require'diffy.review.render'.foldtext()"
  wo.foldminlines = 0
  wo.foldcolumn = '0'
  wo.fillchars = 'fold: ,eob: '
  -- soft wrap at words, list items hanging: right at any card width
  wo.wrap, wo.linebreak, wo.breakindent = true, true, true
  wo.breakindentopt = 'list:-1'
  vim.bo[buf].formatlistpat = [[^\s*\(\d\+[.)]\|[-*+]\)\s\+]]
  vim.api.nvim_win_call(win, function()
    vim.cmd('silent! normal! zE')
    -- inner <details> end first, so they're created first and nest
    for _, f in ipairs(s and s.folds or {}) do
      vim.cmd(('%d,%dfold'):format(f.start + 1, f.stop + 1))
    end
    for i = #(s and s.folds or {}), 1, -1 do
      if s.folds[i].open then
        vim.cmd(('%dfoldopen'):format(s.folds[i].start + 1))
      end
    end
  end)
  wo.foldenable = true
  local map = require('diffy.session').map
  map(session, 'n', 'gx', function()
    open_link(win, buf)
  end, { buffer = buf, desc = 'open link' })
  -- like a click: the link under the cursor, else the fold title's fold
  map(session, 'n', '<CR>', function()
    local cur = vim.api.nvim_win_get_cursor(0)
    if link_at(buf, cur[1], cur[2]) then
      open_link(win, buf)
    elseif vim.fn.foldlevel(cur[1]) > 0 then
      vim.cmd('normal! za')
    end
  end, { buffer = buf, desc = 'open the link or fold under the cursor' })
  M.map_click(session, buf)
end

return M
