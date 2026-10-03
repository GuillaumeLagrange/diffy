-- `make test-gh`: per-case real PRs on the sandbox repo.
-- Every call here is synchronous and runs in the test process, not the child.
local M = {}

M.REPO = 'GuillaumeLagrange/diffy-tests'
M.enabled = vim.env.DIFFY_TESTGH == '1'
-- Ready/poll timeout: the real API is much slower than the fake.
M.timeout = M.enabled and 60000 or 5000

local function run(cmd, opts)
  local res = vim.system(cmd, vim.tbl_extend('force', { text = true }, opts or {})):wait()
  assert(res.code == 0, table.concat(cmd, ' ') .. '\n' .. (res.stderr or '') .. (res.stdout or ''))
  return vim.trim(res.stdout or '')
end

function M.graphql(query, variables)
  local out = run({ 'gh', 'api', 'graphql', '--input', '-' }, { stdin = vim.json.encode({ query = query, variables = variables or vim.empty_dict() }) })
  local data = vim.json.decode(out)
  assert(not data.errors, vim.inspect(data.errors))
  return data.data
end

--- A fresh clone of the sandbox's `base/<name>` and `sandbox/<name>` history
--- from git bundle `bundle` (exact shas, offline) with `sandbox/<name>`
--- checked out, and `origin/HEAD` at `base/<name>` (what `:Diffy branch`
--- diffs against before the layer answers). `origin` is never fetched from:
--- live mode pushes to it.
function M.clone_sandbox(bundle, name)
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  local function git(args)
    run(vim.list_extend({ 'git' }, args), { cwd = d })
  end
  git({ 'init', '-q', '-b', 'main' })
  git({ 'config', 'user.name', 'diffy' })
  git({ 'config', 'user.email', 'diffy@example.com' })
  git({ 'remote', 'add', 'origin', 'https://github.com/' .. M.REPO .. '.git' })
  git({
    'fetch',
    '-q',
    bundle,
    ('refs/remotes/origin/base/%s:refs/heads/base/%s'):format(name, name),
    ('refs/remotes/origin/sandbox/%s:refs/heads/sandbox/%s'):format(name, name),
  })
  git({ 'checkout', '-q', 'sandbox/' .. name })
  git({ 'update-ref', 'refs/remotes/origin/base/' .. name, 'base/' .. name })
  git({ 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/base/' .. name })
  return d
end

local counter = 0

--- Push `base_sha`/`head_sha` of repo `dir` to fresh uniquely-named
--- branches, open a PR, and check out the head branch locally (also creating
--- the base branch locally). Returns `{ number, id, base, head }`; always
--- pair with `M.close`.
function M.open_pr(dir, base_sha, head_sha)
  counter = counter + 1
  local tag = ('%d-%d-%d'):format(os.time(), vim.fn.getpid(), counter)
  local pr = { base = 'test-gh-base-' .. tag, head = 'test-gh-head-' .. tag }
  M.current = pr
  run({ 'git', 'push', '-q', 'origin', base_sha .. ':refs/heads/' .. pr.base, head_sha .. ':refs/heads/' .. pr.head }, { cwd = dir })
  pr.pushed = true
  run({ 'git', 'branch', '-f', pr.base, base_sha }, { cwd = dir })
  run({ 'git', 'checkout', '-q', '-b', pr.head, head_sha }, { cwd = dir })
  local url = run({
    'gh', 'pr', 'create', '--repo', M.REPO, '--base', pr.base, '--head', pr.head,
    '--title', 'diffy make test-gh ' .. tag, '--body', 'Automated `make test-gh` case; closed automatically.',
  })
  pr.number = tonumber(url:match('(%d+)$'))
  local owner, name = M.REPO:match('(.+)/(.+)')
  pr.id = M.graphql('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){id}}}', { o = owner, r = name, n = pr.number }).repository.pullRequest.id
  return pr
end

--- Close the current case's PR and delete its branches. Safe to call when
--- `open_pr` failed half-way; never raises.
function M.close()
  local pr = M.current
  M.current = nil
  if not pr then
    return
  end
  if pr.number then
    vim.system({ 'gh', 'pr', 'close', tostring(pr.number), '--repo', M.REPO }):wait()
  end
  if pr.pushed then
    for _, b in ipairs({ pr.head, pr.base }) do
      vim.system({ 'gh', 'api', '-X', 'DELETE', ('repos/%s/git/refs/heads/%s'):format(M.REPO, b) }):wait()
    end
  end
end

--- GitHub's legacy `position` of new-side line `line` in `merge-base...commit`
--- (1-based index below the first `@@`; later `@@` lines count).
function M.position(dir, merge_base, commit, path, line)
  local diff = run({ 'git', 'diff', '-U3', merge_base, commit, '--', path }, { cwd = dir })
  local pos, new, started = 0, nil, false
  for l in (diff .. '\n'):gmatch('(.-)\n') do
    local s = l:match('^@@ %-%d+,?%d* %+(%d+)')
    if s then
      if started then
        pos = pos + 1
      end
      started, new = true, tonumber(s)
    elseif started then
      pos = pos + 1
      if l:sub(1, 1) ~= '-' then
        if new == line then
          return pos
        end
        new = new + 1
      end
    end
  end
  error(('line %d not in the diff of %s'):format(line, path))
end

--- Session actions on `child`, waiting up to `M.timeout`.
function M.bind(child)
  local ui = require('tests.helpers.ui')
  local b = {}
  function b.wins()
    return ui.wins(child)
  end
  --- `:Diffy branch`, waiting for the GitHub layer's first read.
  function b.open_pr()
    ui.arm_ready(child, 'pr')
    child.cmd('Diffy branch')
    ui.wait_ready(child, M.timeout)
  end
  function b.open_file(path)
    ui.open_tree_row(child, path, '<CR>', 'review', M.timeout)
  end
  --- Select the `idx`-th commit of the log (1-based, newest first), skipping
  --- the working tree and the GitHub layer's rows.
  function b.select_commit(idx)
    local row, n = nil, 0
    for i, l in ipairs(ui.layout(child).log) do
      if l:match('^%S*%s+%x%x%x%x%x%x%x ') or l:match('^%x%x%x%x%x%x%x ') then
        n = n + 1
        if n == idx then
          row = i
        end
      end
    end
    assert(row, 'no commit row ' .. idx)
    ui.cursor_to(child, 'log', row)
    ui.arm_ready(child, 'select')
    child.type_keys('<CR>')
    ui.wait_ready(child, M.timeout)
  end
  function b.lines_with_signs(side)
    return ui.thread_lines(child, side)
  end
  return b
end

return M
