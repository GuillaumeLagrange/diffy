# Feature ideas

## Diff since last viewed

On demand, open a diff between the file I'm looking at and how it was the last time I marked it viewed.

- Useful on a `●` file (viewed, changed since): see only what moved since I last looked, not the whole change
  again.
- The data is already there: `viewed.json` keeps up to 5 marks per path as `{left, right, at}`; the newest
  mark's right blob is the version I last viewed.
- Open questions: where it opens (a float, a new tab, or swapping the left window of the current pair), and
  its key/command (`:Diffy viewed diff`?).
