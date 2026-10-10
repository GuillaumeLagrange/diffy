-- The log model -> (left rev, right rev) resolution and the real-file rule.
-- Pure functions operating on the entry list built by
-- panels/log.lua; no git calls, no buffer/window access.
--
-- An entry is one of:
--   { kind = 'worktree', rev = 'WORKTREE' }
--   { kind = 'commit', sha, parents, subject, merge, rev = sha }
--   { kind = 'pr' } / { kind = 'marker', reviews } (the GitHub layer's rows)
--   { kind = 'push', sha, base, label, rev = sha } (a commit rewritten out of
--     the branch, shown from `base`, its fork point: see `log.show_throwaway`)
--   { kind = 'since', base, rev, paths, label, from } (one file from the
--     version last marked viewed, a tree holding only that blob, to `rev`,
--     the right side of the view `from` it was opened in)
local M = {}

-- The two sections of a lone working tree selection; file rows carry one of
-- these tables as `row.pair` (compared by identity).
M.UNSTAGED = { left = 'INDEX', right = 'WORKTREE' }
M.STAGED = { left = 'HEAD', right = 'INDEX' }

-- git knows these trees without them being in the object store
local EMPTY_TREE = {
  [40] = '4b825dc642cb6eb9a060e54bf8d69288fbee4904',
  [64] = '6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321',
}

--- The rev a commit entry's own changes are diffed from: its first parent,
--- or the empty tree for a root commit (`sha^` doesn't resolve there).
function M.parent(entry)
  return #entry.parents == 0 and EMPTY_TREE[#entry.sha] or entry.sha .. '^'
end

--- Inclusive range `top_idx..bottom_idx` of `entries` (1 = newest row) ->
--- `{ left, right, top, bottom, top_idx, bottom_idx, split }`, with `left`/
--- `right` revs for `repo.diff_args`. Right is the top entry's rev; left is
--- the bottom entry's parent (working tree -> HEAD, commit -> `M.parent`), or the
--- merge-base `entries.base` when the range reaches the oldest commit of a
--- branch/PR view and its top contains the base. The working tree alone is
--- `split`: the tree shows it as the UNSTAGED and STAGED sections.
function M.resolve(entries, top_idx, bottom_idx)
  assert(top_idx <= bottom_idx, 'selection.resolve: top_idx must be <= bottom_idx')
  local top = entries[top_idx]
  local bottom = entries[bottom_idx]
  if top.kind == 'push' or top.kind == 'since' then
    return { left = top.base, right = top.rev, top = top, bottom = top, top_idx = top_idx, bottom_idx = bottom_idx }
  end

  local right = top.rev
  local left
  if bottom.kind == 'worktree' then
    left = 'HEAD'
  else
    left = M.parent(bottom)
    -- down to the oldest commit of a branch/PR view whose top contains the
    -- merged-in base: diff against the merge-base, as github.com does
    if entries.base and bottom_idx == M.last_selectable(entries) and (top.kind ~= 'commit' or top.has_base) then
      left = entries.base
    end
  end

  return {
    left = left,
    right = right,
    top = top,
    bottom = bottom,
    top_idx = top_idx,
    bottom_idx = bottom_idx,
    split = bottom.kind == 'worktree' or nil,
  }
end

--- Whether `entry` can be a range endpoint: not a merge, not a layer row.
function M.selectable(entry)
  return entry.kind == 'worktree' or (entry.kind == 'commit' and not entry.merge)
end
local selectable = M.selectable

--- Index of the first/last selectable entry in `entries`, or nil.
function M.first_selectable(entries)
  for i = 1, #entries do
    if selectable(entries[i]) then
      return i
    end
  end
  return nil
end

function M.last_selectable(entries)
  for i = #entries, 1, -1 do
    if selectable(entries[i]) then
      return i
    end
  end
  return nil
end

--- Whether the right side of the pair for `path` should be the real
--- worktree file (editable) rather than a read-only blob: the top of the
--- selection is the working tree, or it is HEAD (or the full-checkout commit passed
--- as `ctx.checkout_sha`) and `path` has no uncommitted changes.
--- @param sel table  result of `M.resolve`
--- @param path string
--- @param ctx { head_sha: string, checkout_sha: string|nil, is_clean: fun(path: string): boolean }
function M.right_is_real(sel, path, ctx)
  local top = sel.top
  if top.kind == 'worktree' or (top.kind == 'since' and sel.right == 'WORKTREE') then
    return true
  end
  local sha = (top.kind == 'commit' and top.sha) or (top.kind == 'since' and sel.right ~= 'INDEX' and sel.right)
  if sha and (sha == ctx.head_sha or (ctx.checkout_sha and sha == ctx.checkout_sha)) then
    return ctx.is_clean(path)
  end
  return false
end

return M
