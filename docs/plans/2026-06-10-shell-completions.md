# Shell Completions Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `wtr completion <shell>` (bash/zsh/fish) with dynamic completion of subcommands, flags, worktree names, and shell names via a hidden `wtr __complete` endpoint.

**Tech Stack:** let-go (lg), tiny-cli, resource files for shell scripts.

---

## Design

Two entry points:

1. **`wtr completion <shell>`** — a regular subcommand in the `app` map.
   Accepts `bash`, `zsh`, or `fish`; prints the matching script from
   `resources/completions/` to stdout (loaded with `io/resource`, same as
   `VERSION`). Unknown shell → error to stderr, exit 1.

2. **`wtr __complete <words…>`** — hidden dynamic endpoint the scripts call
   on TAB. The last argument is the word under the cursor (possibly empty).
   Prints one candidate per line, prefix-filtered. Always exits 0; on any
   error (not a git repo, broken config) prints nothing. Intercepted in
   `main.lg` before `cli/run!`, so it never appears in help and needs no
   tiny-cli changes.

Candidate logic lives in a pure function in `wtr/completion.lg`:
`(candidates app prev-words cur-word wts base-prefix)` (exact signature up to
the implementer; the point is no I/O — worktrees and config-derived prefix
are passed in):

- No subcommand yet → subcommand names from the app map plus `help`;
  cur-word starting with `-` → global flags (`--base-dir`, `--help`,
  `--version`).
- After `run`/`switch`/`remove`, first positional → worktree names plus
  `main`/`master`; cur-word starting with `-` → that command's flags from
  the app map (e.g. `--force`).
- After `completion` → `bash`, `zsh`, `fish`. After `help` → subcommand names.
- After `run <name>` → nothing (trailing words are the user's command; the
  shell falls back to file completion).

Worktree names: strip `{base-dir}/{project}/` from each non-main worktree
path, where base-dir comes from `config/read-config` (read-only — never
`ensure-config!`) and project is the basename of the main worktree. This
preserves namespaced names like `feature/bar`. Missing config or
non-matching prefix → fall back to the path's basename.

Shell scripts (each ~10–20 lines):

- `wtr.bash`: `_wtr_complete()` calls `wtr __complete` with
  `COMP_WORDS[1..COMP_CWORD]` and fills `COMPREPLY`; registered with
  `complete -o default -F _wtr_complete wtr` (`-o default` gives filename
  fallback when output is empty).
- `wtr.zsh`: starts with `#compdef wtr`; uses `words`/`CURRENT` and
  `compadd`. Works both sourced and as `_wtr` on `$fpath`.
- `wtr.fish`: one `complete -c wtr -a '(...)'` line calling
  `wtr __complete (commandline -opc)[2..] (commandline -ct)`.

Scripts invoke the binary by the name it was called as, so install location
does not matter.

## File Structure

- Create: `src/wtr/completion.lg` — pure candidate logic, `completion`
  command handler, `__complete` entry point.
- Create: `resources/completions/wtr.bash`, `resources/completions/wtr.zsh`,
  `resources/completions/wtr.fish`.
- Modify: `src/wtr/main.lg` — add `completion` command to the app map;
  intercept `__complete` before `cli/run!`.
- Create: `test/wtr/completion_test.lg`.
- Modify: `README.md` — "Shell completions" section under Installation.

## Implementation Steps

### Task 1: Pure candidate logic

**Files:**
- Create: `src/wtr/completion.lg`
- Test: `test/wtr/completion_test.lg`

- [x] **Step 1: Write focused tests for `candidates`**
  Cover: subcommand listing (including `help` and `completion`); prefix
  filtering (`sw` → `switch`); global flags when cur-word starts with `-`;
  per-command flags (`remove -` → `--force`); worktree names for
  `run`/`switch`/`remove` from a fake worktrees vector including a
  namespaced `feature/bar` and a basename fallback when the path does not
  match the base prefix; `main`/`master` included; shells after
  `completion`; empty result after `run <name>`.

- [x] **Step 2: Run the focused test**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx test`
  Expected: new tests fail (namespace not implemented yet).

- [x] **Step 3: Implement `candidates` and worktree-name derivation**
  Pure functions only; no `os/sh`, no config reads in this namespace's
  logic core.

- [x] **Step 4: Run verification**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx test`
  Expected: all tests pass.

### Task 2: Shell script resources and `completion` command

**Files:**
- Create: `resources/completions/wtr.bash`, `resources/completions/wtr.zsh`,
  `resources/completions/wtr.fish`
- Modify: `src/wtr/completion.lg`, `src/wtr/main.lg`
- Test: `test/wtr/completion_test.lg`

- [x] **Step 1: Write the three completion scripts as resources**
  Per the design above; each calls `wtr __complete`.

- [x] **Step 2: Add the `completion` command handler**
  Reads the script via `io/resource`, prints to stdout; unknown shell →
  `Error: …` to stderr, exit 1. Register the command in the `app` map in
  `main.lg` with an arg spec for `shell`.

- [x] **Step 3: Add a test that `bash` script output is non-empty and
  mentions `__complete`**
  Test the resource-loading helper, not the process exit.

- [x] **Step 4: Run verification**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx test`
  Expected: all tests pass.

### Task 3: `__complete` interception and wiring

**Files:**
- Modify: `src/wtr/main.lg`, `src/wtr/completion.lg`

- [x] **Step 1: Intercept `__complete` in `main`**
  After `cli-argv` stripping, when the first token is `__complete`, call the
  completion entry point with the remaining tokens and exit 0 — before
  `cli/run!`. Wrap the whole handler in try/catch: on any error, print
  nothing, exit 0. This entry point performs the I/O (`git/worktrees`,
  `config/read-config`) and passes results to the pure `candidates`.

- [x] **Step 2: Run verification**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx test`
  Expected: all tests pass.

- [x] **Step 3: Manual smoke check**
  Build the binary, then in bash: `source <(bin/wtr completion bash)` and
  check `bin/wtr __complete ""` lists subcommands, `bin/wtr __complete sw`
  → `switch`, `bin/wtr __complete remove ""` lists worktrees of this repo,
  and `__complete` outside a git repo prints nothing and exits 0.

### Task 4: README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Add a "Shell completions" section under Installation**
  One snippet per shell: bash `source <(wtr completion bash)` in
  `~/.bashrc`; zsh `wtr completion zsh > ~/.zfunc/_wtr` (plus `fpath`
  note) or `source <(wtr completion zsh)`; fish
  `wtr completion fish > ~/.config/fish/completions/wtr.fish`.

- [x] **Step 2: Run full checks**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx check`
  Expected: formatting and tests pass.

---

## Status: Completed (2026-06-10)

All four tasks implemented and verified.

**What was built:** `wtr completion <shell>` prints bash/zsh/fish scripts
bundled as resources; a hidden `wtr __complete` endpoint (intercepted in
`main.lg` before tiny-cli) returns prefix-filtered candidates: subcommands,
flags from the app map, worktree names (namespaced names preserved via the
config base-dir prefix, basename fallback), `main`/`master` aliases, and
shell names. `__complete` swallows all errors and exits 0 so completion can
never break a shell.

**Deviations from the plan:**
- Codex review (Task 1): flags are no longer offered after a positional —
  tiny-cli rejects options there for non-variadic commands.
- Codex review (Task 3): the fish script was rewritten to the two-rule
  pattern — quoted `"$cur"` so the empty boundary word survives, and a
  `complete -F` fallback rule so file completion still works where wtr
  offers nothing.
- The plan's `LGX_LG=...let-go/lg` commands were replaced with the
  mise-installed `lgx` (the repo-local `lg` is a macOS arm64 binary; this
  session ran on Linux).
- Drive-by fix: removed a doubled ```` ```sh ```` fence in README's manual
  install snippet.

**Verification:** 40 tests / 99 assertions pass; `lgx check` (fmt + tests)
green; bash flow tested end to end against the built binary. zsh/fish were
not installed in the dev environment — scripts follow standard patterns
(kubectl/Cobra style) but deserve a quick interactive TAB test.
