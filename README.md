# diffy

A diff viewer for Neovim built on git and fugitive, with a review layer: comment on diffs, then either
hand the comments to an LLM agent or submit them as a GitHub pull request review.

Each session lives in its own tab: the changed files and the commits in a column on the left, a
side-by-side diff in native diff mode on the right. Select commits to choose what the diff shows; stage,
mark files viewed and comment from there.

The full documentation is in [`doc/diffy.txt`](doc/diffy.txt): `:help diffy`.

## Requirements

- Neovim ≥ 0.12, git ≥ 2.36
- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- Optional: [`gh`](https://cli.github.com), authenticated, for GitHub pull requests; a terminal with the
  kitty graphics protocol, `curl` and ImageMagick for avatars

## Install

With a plugin manager, or by hand:

```lua
vim.opt.rtp:prepend('/path/to/diffy')
```

then `:helptags /path/to/diffy/doc`. `require('diffy').setup({...})` is optional; see `:help diffy.config`.

## Usage

| Command | Opens |
|---|---|
| `:Diffy` | your uncommitted changes and unpushed commits (`@{u}..HEAD`) |
| `:Diffy branch [base]` | the current branch since it forked off `base` (default: the PR base or `origin/HEAD`) |
| `:Diffy pr` | the current branch's open pull request |
| `:Diffy A..B` | a range of commits |
| `:Diffy file [path]` | the history of a file |
| `:Diffy conflicts` | the conflicted files, in a 4-window merge view |

In a session:

| Key | Where | |
|---|---|---|
| `<CR>`, `J`/`K`, `v` + `<CR>` | commits | select a commit, the next/previous one, a range |
| `<CR>`, `]f`/`[f` | files, diff | open a file, the next/previous one |
| `s`/`u`, `-` | files | stage/unstage a file |
| `m` / `<leader>dm` | files / diff | mark a file viewed |
| `gc` | diff | comment on the line or the visual range |
| `<CR>`, `]t`/`[t` | diff | enter the thread under the cursor, go to the next/previous one |
| `<leader>dc` | diff, column | every review thread |
| `R` | diff, column | refresh |

`:Diffy review agent` sends your comments to your agent (a markdown file and a prompt in the `+`
register); `:Diffy review github` submits them as a review on the branch's open pull request. Closing
the tab ends the session.
