-- Repository-level helpers: locating the root, merge-base and branch-base
-- resolution, cleanliness checks, and translating a (left, right) rev pair
-- into `git diff` arguments.
--
-- Every function below takes an optional trailing `session`, forwarded to
-- `run.git`/`run.run`, so the callback no-ops once that session is torn
-- down. Callers with no diffy session open omit it.
local run = require('diffy.git.run')
local parse = require('diffy.git.parse')

local M = {}

--- `run.git` without error notification: these lookups report failure to
--- their caller instead.
local function quiet(root, args, session, on_exit)
  run.git(args, { cwd = root, session = session, notify_on_error = false, on_exit = on_exit })
end

--- `git rev-parse --show-toplevel` for `cwd`. `on_exit(root, err)`.
function M.root(cwd, on_exit, session)
  quiet(cwd, { 'rev-parse', '--show-toplevel' }, session, run.parsed(vim.trim, on_exit))
end

function M.notify_not_repo(err)
  vim.notify('diffy: not a git repository (' .. tostring(err) .. ')', vim.log.levels.ERROR)
end

--- Current `HEAD` sha, or `nil` on an unborn branch. `on_exit(sha, err)`.
function M.head_sha(root, on_exit, session)
  quiet(root, { 'rev-parse', 'HEAD' }, session, run.parsed(vim.trim, on_exit))
end

--- `git merge-base a b`. `on_exit(sha, err)`.
function M.merge_base(root, a, b, on_exit, session)
  quiet(root, { 'merge-base', a, b }, session, run.parsed(vim.trim, on_exit))
end

--- The ref to diff against for a base branch GitHub names: the local
--- branch's upstream (usually `origin/<name>`; the local branch is often
--- behind, which would diff against an old merge-base), else the local
--- branch, else the one remote-tracking branch of that name, else `name`
--- as given. `on_exit(ref)`.
function M.base_ref(root, name, on_exit, session)
  local function git(args, cb)
    quiet(root, args, session, cb)
  end
  git({ 'rev-parse', '--abbrev-ref', '--symbolic-full-name', name .. '@{upstream}' }, function(res)
    local upstream = vim.trim(res.stdout or '')
    if res.code == 0 and upstream ~= '' then
      on_exit(upstream)
      return
    end
    git({ 'show-ref', '--verify', '--quiet', 'refs/heads/' .. name }, function(local_res)
      if local_res.code == 0 then
        on_exit(name)
        return
      end
      git({ 'for-each-ref', '--format=%(refname:short)', 'refs/remotes/*/' .. name }, function(remote_res)
        local refs = vim.split(vim.trim(remote_res.stdout or ''), '\n', { trimempty = true })
        on_exit(#refs == 1 and refs[1] or name)
      end)
    end)
  end)
end

--- `:Diffy branch` base resolution, never waiting on the network when it
--- can help it: `explicit` as given, else `pr_base` (the PR base from the
--- layer's cache), else `origin/HEAD` (local), else `origin`'s default
--- branch (`gh repo view`); names through `M.base_ref`. `on_exit(ref, err)`.
function M.resolve_base(root, explicit, on_exit, session, pr_base)
  if explicit and explicit ~= '' then
    on_exit(explicit, nil)
    return
  end
  local function found(name)
    M.base_ref(root, name, function(ref)
      on_exit(ref, nil)
    end, session)
  end
  if pr_base then
    found(pr_base)
    return
  end
  quiet(root, { 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' }, session, function(res)
    local ref = vim.trim(res.stdout or '')
    if res.code == 0 and ref ~= '' then
      on_exit(ref, nil)
      return
    end
    run.run({ 'gh', 'repo', 'view', '--json', 'defaultBranchRef', '-q', '.defaultBranchRef.name' }, {
      cwd = root,
      session = session,
      notify_on_error = false,
      on_exit = function(res2)
        local default_branch = vim.trim(res2.stdout or '')
        if res2.code == 0 and default_branch ~= '' then
          found(default_branch)
        else
          on_exit(nil, 'diffy: could not resolve branch base (' .. vim.trim(res2.stderr or '') .. ')')
        end
      end,
    })
  end)
end

--- Parsed `git status --porcelain=v2 -z --untracked-files=all` entries for
--- the whole repo (untracked tree entries, per-file cleanliness lookups).
--- `--untracked-files=all` is load-bearing: without it, git reports a
--- brand-new untracked directory as a single `?? dir/` entry instead of its
--- files individually, so the tree can't group them like any other
--- directory. `on_exit(entries, err)`.
function M.status(root, on_exit, session)
  quiet(
    root,
    { 'status', '--porcelain=v2', '-z', '--untracked-files=all' },
    session,
    run.parsed(parse.status_v2, on_exit)
  )
end

--- Whether `root`'s tree has no staged/unstaged changes to tracked files
--- (untracked/ignored files don't count). `path`, if given, restricts the
--- check to that pathspec. `on_exit(clean, err)`.
function M.is_clean(root, path, on_exit, session)
  local args = { 'status', '--porcelain=v2', '-z' }
  if path then
    vim.list_extend(args, { '--', path })
  end
  quiet(
    root,
    args,
    session,
    run.parsed(function(stdout)
      for _, e in ipairs(parse.status_v2(stdout)) do
        if e.kind ~= 'untracked' and e.kind ~= 'ignored' then
          return false
        end
      end
      return true
    end, on_exit)
  )
end

--- Default commit range for bare `:Diffy`: `@{u}..HEAD` if the current
--- branch has an upstream, else the last 20 commits. `on_exit(spec)` where
--- `spec` is `{ expr = 'A..B' }` or `{ n = 20 }` (passed to `git log` as a
--- rev range or a `-n` limit respectively).
function M.default_range(root, on_exit, session)
  quiet(root, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, session, function(res)
    on_exit(res.code == 0 and { expr = '@{u}..HEAD' } or { n = 20 })
  end)
end

--- Args to append to `git diff [flags]` for the pair `(left, right)`, where
--- each is `'INDEX'`, `'WORKTREE'`, `'HEAD'`, or a commit sha. The unstaged
--- and staged sections collapse to a plain/`--cached` diff with no explicit revs.
function M.diff_args(left, right)
  if right == 'WORKTREE' then
    if left == 'INDEX' then
      return {}
    end
    return { left }
  elseif right == 'INDEX' then
    if left == 'HEAD' then
      return { '--cached' }
    end
    return { '--cached', left }
  else
    return { left, right }
  end
end

return M
