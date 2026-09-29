-- Pure review/render.lua: comment bodies to card lines. The cards
-- themselves (folds, gx) are covered through tests/test_github_read.lua.
local render = require('diffy.review.render')

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local function body(lines)
  return render.body(table.concat(lines, '\n'))
end

--- The text each link covers and its URL, in reading order.
local function link_texts(res)
  local out = {}
  for row = 0, #res.lines - 1 do
    for _, l in ipairs(res.links[row] or {}) do
      table.insert(out, { res.lines[row + 1]:sub(l.col + 1, l.end_col), l.url })
    end
  end
  return out
end

T["a greptile summary reads as a heading, one marked item per issue and a folded prompt, without URLs"] = function()
  local prompt = 'https://app.greptile.com/ide/claude-code?prompt=%23%23%23%20Issue%201%0Apackages'
  local res = body({
    '<!-- greptile_summary -->',
    '',
    '<h2><a href="https://app.greptile.com/api/retrigger?id=1"><picture><source media="(prefers-color-scheme: dark)" srcset="https://s3/RetriggerDark.svg?v=2"><img alt="Retrigger" src="https://s3/Retrigger.svg?v=2" align="right"></picture></a>Confidence Score: 4/5</h2>',
    '',
    '**[Medium risk]** Changes when debug information binds\\.',
    '',
    '<h2><a href="' .. prompt .. '"><picture><img alt="Fix All in Claude Code" src="https://s3/FixAllInClaude.svg?v=7" align="right"></picture></a>Findings</h2>',
    '',
    '1. <img alt="P2" src="https://s3/badges/p2.svg?v=9" align="top">&nbsp;**Repeated debug\\-info mapping work** <a href="https://github.com/o/r/pull/1#discussion_r2">▶</a>',
    '',
    '<details><summary>Fix with agent prompt</summary>',
    '',
    '`````markdown',
    '### Issue 1',
    '```rust',
    'let x = 1;',
    '```',
    '`````',
    '',
    '</details>',
    '',
    '<!-- greptile_confidence_score:4 -->',
    '',
    '<sub>Reviews (1) · Last reviewed commit: [929c9d5](https://github.com/o/r/commit/929c9d5)</sub>',
    '',
  })
  eq(res.lines, {
    '## Confidence Score: 4/5  [Retrigger]',
    '',
    '**[Medium risk]** Changes when debug information binds.',
    '',
    '## Findings  [Fix All in Claude Code]',
    '',
    '1. [P2] **Repeated debug-info mapping work** ▶',
    '',
    '▾ Fix with agent prompt',
    '`````markdown',
    '### Issue 1',
    '```rust',
    'let x = 1;',
    '```',
    '`````',
    '',
    'Reviews (1) · Last reviewed commit: 929c9d5',
  })
  eq(res.folds, { { start = 8, stop = 14, open = false } })
  eq(link_texts(res), {
    { '[Retrigger]', 'https://app.greptile.com/api/retrigger?id=1' },
    { '[Fix All in Claude Code]', prompt },
    { '▶', 'https://github.com/o/r/pull/1#discussion_r2' },
    { '929c9d5', 'https://github.com/o/r/commit/929c9d5' },
  })
  -- the score and the badge coloured by how bad they are
  eq(res.marks, {
    { row = 0, col = 21, end_col = 24, hl = 'DiagnosticOk' },
    { row = 6, col = 3, end_col = 7, hl = 'DiagnosticWarn' },
  })
  eq(vim.tbl_map(function(im)
    return { im.row, res.lines[im.row + 1]:sub(im.col + 1, im.end_col) }
  end, res.images), { { 0, '[Retrigger]' }, { 4, '[Fix All in Claude Code]' }, { 6, '[P2]' } })
end

T['code fences keep their text as written, HTML and a nested shorter fence included'] = function()
  local res = body({
    'before',
    '`````markdown',
    '<b>x</b> [a](https://e.com) \\- &amp;',
    '```',
    '`````',
    '<b>after</b>',
  })
  eq(res.lines, { 'before', '`````markdown', '<b>x</b> [a](https://e.com) \\- &amp;', '```', '`````', '**after**' })
  eq(res.code, { { row = 2, suggestion = false }, { row = 3, suggestion = false } })
  eq(res.links, {})
end

T["plain markdown comes out as written, escapes that would start markup included"] = function()
  local lines = {
    'A **bold** `code \\* <b>` and _em_.',
    '',
    '- item',
    '1\\. not a list, \\*not em\\*',
    '',
    '```suggestion',
    'new line',
    '```',
  }
  local res = body(lines)
  eq(res.lines, lines)
  eq(res.labels, { { row = 4, empty = false } })
  eq(res.code, { { row = 6, suggestion = true } })
end

T['links show their text; bare URLs a short label; fragment-only links none'] = function()
  local res = body({
    'See [the docs](https://example.com/docs/page "t") or https://github.com/o/r/pull/12345#discussion_r1.',
    '<a href="#"><img alt="P1" src="https://s3/p1.svg"></a> <a href="https://e.com/x"></a> <https://e.com>',
  })
  eq(res.lines, { 'See the docs or github.com/…/12345.', '[P1] ↗ e.com' })
  eq(link_texts(res), {
    { 'the docs', 'https://example.com/docs/page' },
    { 'github.com/…/12345', 'https://github.com/o/r/pull/12345#discussion_r1' },
    { '↗', 'https://e.com/x' },
    { 'e.com', 'https://e.com' },
  })
  eq(res.marks, { { row = 1, col = 0, end_col = 4, hl = 'DiagnosticError' } })
end

T['a non-SVG image is a marker opened by gx, not drawn'] = function()
  local res = body({ '![screen shot](https://user-images.example.com/1.png)' })
  eq(res.lines, { '[screen shot]' })
  eq(link_texts(res), { { '[screen shot]', 'https://user-images.example.com/1.png' } })
  eq(res.images, {})
end

T['HTML line breaks, lists and entities become markdown lines and characters'] = function()
  local res = body({ 'one<br>two<br/>&lt;tag&gt; &amp;lt; &#x2713; &#169;', '<ul><li>a</li><li><em>b</em></li></ul>' })
  eq(res.lines, { 'one', 'two', '<tag> &lt; ✓ ©', '', '- a', '- _b_' })
end

T['details nest as folds; one without a summary is titled Details, an open one starts open'] = function()
  local res = body({
    '<details>',
    'hidden',
    '<details open><summary>Inner</summary>',
    '',
    'deep',
    '</details>',
    '</details>',
    'after',
    '<details><summary>Empty</summary>',
    '</details>',
  })
  eq(res.lines, { '▾ Details', 'hidden', '▾ Inner', 'deep', 'after', '▾ Empty' })
  -- inner first: folds are created in this order so they nest
  eq(res.folds, { { start = 2, stop = 3, open = true }, { start = 0, stop = 3, open = false } })
end

T['table columns are padded to line up, links moving with their cell'] = function()
  local res = body({ '| a | long header |', '|---|:-:|', '| **x** | [link](https://e.com) |' })
  eq(res.lines, { '| a   | long header |', '| --- | :---------: |', '| **x**   | link        |' })
  eq(link_texts(res), { { 'link', 'https://e.com' } })
end

return T
