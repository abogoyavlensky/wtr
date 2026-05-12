# wtr list — implementation plan

Re-implement the `list` subcommand of `wtr` in let-go. Replaces the existing
placeholder in `src/wtr/commands.lg`. See `docs/INITIAL_DESIGN.md` for the
broader tool vision.

## Goals

- Parse `git worktree list --porcelain`, render our own formatted output.
- Mark the current worktree with `*`.
- Show paths relative to the main worktree's parent directory.

Out of scope: the other subcommands (`create`, `switch`, `cd`, `run`),
configuration, completion. Those follow in later plans.

## Output

```
$ wtr list
* unison                     463de25  master
  worktrees/unison/chat-dot  463de25  agent/chat-dot
  worktrees/unison/fix-auth  1a2b3c4  agent/fix-auth
```

Columns: `<marker> <relpath>  <short-sha>  <branch-or-state>`.

- `marker`: `*` for the current worktree, two spaces otherwise.
- `relpath`: worktree path made relative to the main worktree's parent.
  - `/Users/andrew/Projects/unison` → `unison`.
  - `/Users/andrew/Projects/worktrees/unison/chat-dot` →
    `worktrees/unison/chat-dot`.
  - Paths outside the parent fall back to absolute.
- `short-sha`: first seven characters of `HEAD`. Seven dashes for bare.
- `branch-or-state`: `refs/heads/` stripped from branch name. `(detached)`
  for detached HEAD, `(bare)` for bare. Append ` [locked]` / ` [prunable]`
  if those flags are set in porcelain output.

Column widths computed in one pass from the rendered rows. Two-space gutter
between columns.

## Current-worktree detection

Resolve `cwd` via `os/cwd`. A worktree at `p` is current when `cwd == p` or
`cwd` starts with `p + "/"`. (Substring match; no symlink resolution.)

## Errors

- Non-zero `git` exit → write git's stderr to `*err*`, exit 1.
- Empty parsed list (shouldn't happen if we're inside a repo, but be safe)
  → print `(no worktrees)`, exit 0.

## Code layout

Three namespaces; the existing `wtr.commands/list` calls into the other
two. Splitting parsing from formatting lets `wtr.git` be reused by future
`switch` / `cd` / `run` commands.

### `src/wtr/git.lg` (new)

```clojure
(defn worktrees
  "Run `git worktree list --porcelain -z`, return a vector of maps:
   [{:path \"/abs/path\" :head \"sha\" :branch \"refs/heads/foo\"
     :detached? false :bare? false :locked? false :prunable? false}]
   First entry is always the main worktree.
   Throws ex-info on non-zero git exit; caller prints + exits."
  [])
```

Uses `os/sh "git" "worktree" "list" "--porcelain" "-z"`. The `-z` flag
makes git separate lines with NUL inside a record and use double NUL
between records — robust against spaces in paths. Parse into records, then
into the map shape above.

### `src/wtr/format.lg` (new)

```clojure
(defn render-list
  "Returns the formatted multi-line string for `wtr list`.
   `wts` is the vector from wtr.git/worktrees; `cwd` is os/cwd."
  [wts cwd])
```

Internal helpers: `relativize` (string-prefix check; let-go has no
`filepath` namespace), `short-sha`, `branch-label`, `pad-column`.

### `src/wtr/commands.lg` (edit)

```clojure
(defn list [_context]
  (try
    (let [wts (git/worktrees)
          cwd (os/cwd)]
      (println (fmt/render-list wts cwd)))
    (catch :default e
      (write! *err* (or (:stderr (ex-data e)) (str e)))
      (os/exit 1))))
```

## Verification

Smoke checks (no formal tests yet). Run from this repo, using the local
let-go and lgx builds:

```
LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx run main.lg list
```

- Plain run from the main worktree → marker on the main row.
- Run from inside a created worktree → marker moves to that row.
- Run from `/tmp` → non-zero exit, git's "not a git repository" message
  printed.

## Risks and notes

- `os/sh` buffers all output. Fine here — `git worktree list` finishes
  quickly and the output is small.
- No symlink resolution in the current-worktree check. If the user
  navigates via a symlinked path, the marker may land on the wrong row.
  Acceptable for v1; revisit if it bites.
- Porcelain format is stable across git versions we care about. If git
  adds new fields, our parser ignores unknown keys.
