-- `branch` base resolution order: explicit arg, then the PR base from the
-- GitHub layer's cache, then `origin/HEAD` (local), then origin's default
-- branch (`gh repo view`); names through the local branch's upstream.
-- `gh` is faked via a PATH shim (no network); this is pure repo.lua logic,
-- no UI involved.
local repo = require('diffy.git.repo')

local T = MiniTest.new_set()

local function tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function fake_gh(behavior)
  local dir = tempdir()
  local script = { '#!/bin/sh' }
  vim.list_extend(script, behavior)
  vim.fn.writefile(script, dir .. '/gh')
  vim.fn.system({ 'chmod', '+x', dir .. '/gh' })
  return dir
end

local function with_path(dir, fn)
  local orig = vim.env.PATH
  vim.env.PATH = dir .. ':' .. orig
  local ok, err = pcall(fn)
  vim.env.PATH = orig
  if not ok then
    error(err, 0)
  end
end

local function resolve(root, explicit, pr_base)
  local result
  repo.resolve_base(root, explicit, function(ref, err)
    result = { ref = ref, err = err }
  end, nil, pr_base)
  vim.wait(2000, function()
    return result ~= nil
  end)
  return result
end

-- gh answering anything is a failure: these must not wait on the network
local NO_GH = { 'echo "gh called: $*" >&2', 'exit 1' }

local function git_repo()
  local dir = tempdir()
  vim.fn.system({ 'git', '-C', dir, 'init', '-q', '-b', 'main' })
  vim.fn.system({ 'git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'base' })
  return dir
end

T['an explicit base wins over the cached PR base'] = function()
  local result
  with_path(fake_gh(NO_GH), function()
    result = resolve(tempdir(), 'develop', 'release')
  end)
  MiniTest.expect.equality(result.ref, 'develop')
end

T['the cached PR base wins over origin/HEAD'] = function()
  local root = git_repo()
  vim.fn.system({ 'git', '-C', root, 'update-ref', 'refs/remotes/origin/main', 'HEAD' })
  vim.fn.system({ 'git', '-C', root, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main' })
  local result
  with_path(fake_gh(NO_GH), function()
    result = resolve(root, nil, 'release')
  end)
  MiniTest.expect.equality(result.ref, 'release')
end

T['without a cached PR base, origin/HEAD is used without asking gh'] = function()
  local root = git_repo()
  vim.fn.system({ 'git', '-C', root, 'update-ref', 'refs/remotes/origin/trunk', 'HEAD' })
  vim.fn.system({ 'git', '-C', root, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/trunk' })
  local result
  with_path(fake_gh(NO_GH), function()
    result = resolve(root, nil)
  end)
  MiniTest.expect.equality(result.ref, 'origin/trunk')
end

T['without origin/HEAD, falls back to origin default branch from gh'] = function()
  local root = git_repo()
  local shim = fake_gh({
    'if [ "$1" = "repo" ]; then echo "main"; exit 0; fi',
    'exit 1',
  })
  local result
  with_path(shim, function()
    result = resolve(root, nil)
  end)
  MiniTest.expect.equality(result.ref, 'main')
end

T['neither origin/HEAD nor origin default available surfaces an error'] = function()
  local result
  with_path(fake_gh({ 'exit 1' }), function()
    result = resolve(git_repo(), nil)
  end)
  MiniTest.expect.equality(result.ref, nil)
  MiniTest.expect.equality(type(result.err), 'string')
end

--- A repo whose `main` has one commit, plus a remote named `upstream`
--- (never contacted) holding `refs`, each a remote-tracking branch at HEAD.
--- Returns the repo dir and a `git(...)` runner in it.
local function repo_with_remote(refs)
  local dir = tempdir()
  local function git(...)
    local out = vim.fn.system(vim.list_extend({ 'git', '-C', dir }, { ... }))
    assert(vim.v.shell_error == 0, out)
  end
  git('init', '-q', '-b', 'main')
  git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'base')
  git('remote', 'add', 'upstream', dir .. '/nowhere')
  for _, ref in ipairs(refs) do
    git('update-ref', 'refs/remotes/upstream/' .. ref, 'HEAD')
  end
  return dir, git
end

--- `resolve` with `base` as the cached PR base.
local function resolve_pr_base(root, base)
  local result
  with_path(fake_gh(NO_GH), function()
    result = resolve(root, nil, base)
  end)
  return result.ref
end

T["a base branch with an upstream resolves to the upstream, whatever the remote's name"] = function()
  local root, git = repo_with_remote({ 'main' })
  git('branch', '-q', '--set-upstream-to=upstream/main', 'main')
  MiniTest.expect.equality(resolve_pr_base(root, 'main'), 'upstream/main')
end

T['a local base branch without an upstream is used as it is'] = function()
  local root = repo_with_remote({ 'main' })
  MiniTest.expect.equality(resolve_pr_base(root, 'main'), 'main')
end

T['a base branch that only exists on a remote resolves to its remote-tracking branch'] = function()
  local root = repo_with_remote({ 'release/v2' })
  MiniTest.expect.equality(resolve_pr_base(root, 'release/v2'), 'upstream/release/v2')
end

return T
