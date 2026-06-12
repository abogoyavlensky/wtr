# `wtr create --sh` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--sh` flag to `wtr create` that opens an interactive shell in the freshly created worktree, as if `wtr run <name>` ran immediately after.

**Tech Stack:** let-go, lgx, tiny-cli.

---

## Design

### Behavior

`wtr create --sh feature-x` creates the worktree exactly as today — same success
messages, same `--from` and `--base-dir` support, same validation errors — and
then immediately opens an interactive shell (`$SHELL`, falling back to
`/bin/sh`) in the new worktree. The result is identical to running
`wtr run feature-x` right after a plain `wtr create feature-x`: exiting the
shell returns the user to where they were, and the shell's exit code becomes
`wtr`'s exit code.

Without `--sh`, behavior is unchanged. When create fails (branch already
exists, directory already exists, git error), no shell opens and `wtr` exits 1
as today. `--sh` is shell-only by design: running an arbitrary command in the
new worktree stays out of scope (use `wtr run <name> <cmd>` afterwards).

### CLI surface

A boolean option on the `create` command spec in `main.lg`:

```clojure
{:key :sh :long "sh" :doc "Open an interactive shell in the new worktree."}
```

Shell completions derive flag candidates from the command spec
(`wtr.completion/long-flags` over `(:opts command)`), so `--sh` gets
tab-completion with no completion changes.

### Implementation

In `wtr.commands/create`, after the existing success `println`s, when
`(:sh opts)` is set:

1. `(os/setenv "LGX_RUN" "")` — same child-process hygiene as `run`: the child
   is run by wtr, not lgx, so a bundled lgx-built tool exec'd from the shell
   must not see an inherited `LGX_RUN`.
2. `(trust-mise-worktree! wt-path)` — best-effort mise trust preflight so a
   mise prompt cannot block shell startup.
3. `(os/exit (apply os/exec* (run-exec-argv wt-path (user-shell)
   :interactive-shell nil)))` — the same `:interactive-shell` argv that
   `wtr run <name>` uses.

All three helpers (`trust-mise-worktree!`, `user-shell`, `run-exec-argv`)
already exist in the `wtr.commands` namespace; the private ones are accessible
because `create` lives in the same namespace. No refactoring of `run`.

The exec call sits inside `create`'s existing `try`/`catch` — the same pattern
`run` uses; a failure to exec surfaces through the existing error path and
exits 1.

### Error handling

- Create-phase errors (branch exists, directory exists, git failure) behave
  exactly as today; `--sh` adds nothing before a successful create.
- The mise preflight ignores all failures (existing helper behavior).
- The shell's exit code is propagated via `os/exit`.

### Testing strategy

The exec path replaces the process, so it cannot be unit-tested directly. The
argv construction is the testable seam and is already covered for
`:interactive-shell` with an empty `cmd` vector. `create` passes `nil` as
`cmd`, so add a focused unit test locking in that `run-exec-argv` with
`:interactive-shell` and a `nil` cmd builds the same argv — guarding against a
future refactor that destructures `cmd` in that branch.

End-to-end behavior is verified manually with the built binary (under
`lgx run` the dev runner buffers stdio, so a nested shell is not interactive —
the same caveat `wtr run` documents).

## File Structure

- Modify: `main.lg` — add the `--sh` opt to the `create` command spec.
- Modify: `src/wtr/commands.lg` — open the interactive shell at the end of
  `create` when `:sh` is set.
- Modify: `test/wtr/commands_test.lg` — add the `nil`-cmd interactive-shell
  argv test.
- Modify: `README.md` — document `--sh` in the `wtr create` section.

---

### Task 1: `--sh` flag on `wtr create`

**Files:**
- Modify: `main.lg`
- Modify: `src/wtr/commands.lg`
- Test: `test/wtr/commands_test.lg`

- [ ] **Step 1: Write the failing-by-omission test**
  In the existing `run-exec-argv-builds-command-lines` deftest, assert that
  `(cmds/run-exec-argv "/tmp/wt" "/bin/zsh" :interactive-shell nil)` returns
  `["sh" "-c" cmds/direct-runner-script "sh" "/tmp/wt" "/bin/zsh" "-i"]` — the
  same argv as the existing empty-vector case. This locks in the `nil` cmd that
  `create --sh` will pass.

- [ ] **Step 2: Run tests**
  Run: `lgx test`
  Expected: PASS (the `case` branch ignores `cmd`; this test pins that
  behavior before `create` starts relying on it).

- [ ] **Step 3: Add the `--sh` option to the create spec**
  In `main.lg`, extend the `create` command's `:opts` with
  `{:key :sh :long "sh" :doc "Open an interactive shell in the new worktree."}`.

- [ ] **Step 4: Open the shell from `create`**
  In `wtr.commands/create`, destructure `:sh` from `opts`. After the existing
  success `println`s, when `:sh` is truthy: clear `LGX_RUN` via
  `(os/setenv "LGX_RUN" "")`, call `(trust-mise-worktree! wt-path)`, then
  `(os/exit (apply os/exec* (run-exec-argv wt-path (user-shell) :interactive-shell nil)))`.

- [ ] **Step 5: Run checks**
  Run: `lgx check`
  Expected: formatting clean, all tests PASS.

- [ ] **Step 6: Commit**
  `git commit -m "Add --sh flag to wtr create"`

### Task 2: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document `--sh`**
  In the `wtr create <name>` section, add a short example:

  ```
  # Create and jump straight into a shell in the new worktree
  $ wtr create --sh feature-x
  ```

  Note that it behaves like `wtr run feature-x` immediately after create
  (interactive `$SHELL`, mise trust preflight, exit returns you back), and
  that — as with `run` — an interactive shell needs the built binary, not the
  `lgx run` dev runner.

- [ ] **Step 2: Commit**
  `git commit -m "Document wtr create --sh"`

### Task 3: Manual verification with the built binary

**Files:** none (verification only)

- [ ] **Step 1: Build**
  Run: `lgx build`
  Expected: `bin/wtr` produced without errors.

- [ ] **Step 2: Smoke-test create + shell**
  Run: `echo 'pwd; exit 7' | SHELL=/bin/sh ./bin/wtr create --sh tmp-sh-smoke`
  (pin `SHELL=/bin/sh` so a piped non-interactive shell behaves predictably
  across user shells)
  Expected: "Created worktree at …/tmp-sh-smoke" and "Branch: tmp-sh-smoke"
  printed, `pwd` output is the new worktree path, and `echo $?` afterwards
  prints `7` (shell exit code propagated). A piped stdin shell is
  non-interactive but exercises the same cd + exec path.

- [ ] **Step 3: Smoke-test failure path**
  Run: `./bin/wtr create --sh tmp-sh-smoke`
  Expected: exit 1 with "Error: Branch 'tmp-sh-smoke' already exists" and no
  shell opened.

- [ ] **Step 4: Clean up**
  Run: `./bin/wtr remove tmp-sh-smoke`
  Expected: worktree and branch removed.
