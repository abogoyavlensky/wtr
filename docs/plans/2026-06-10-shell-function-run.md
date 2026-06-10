# Shell Function Run Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `wtr run <worktree> <shell-function>` work for zsh functions such as `lmcx`, and avoid blocked mise trust prompts when opening an interactive worktree shell.

**Tech Stack:** let-go, lgx, tiny-cli, zsh-compatible shell invocation, mise.

---

## Design

`wtr run` currently resolves a worktree and executes the requested command through a small `sh -c` wrapper that changes directory, shifts the directory argument, and then runs `exec "$@"`. This is correct for real executables on `PATH`, but it cannot see shell functions defined in `~/.zshrc`.

The change keeps that direct executable path for normal commands. When the requested command name is not executable on `PATH`, `wtr` will fall back to the user's shell in interactive-command mode:

```sh
$SHELL -ic 'cd "$1" || exit 1; shift; "$@"' wtr-shell <dir> <cmd> <args...>
```

This lets zsh source the user's interactive config and resolve functions such as `lmcx`, while still passing the original command arguments positionally. If no command is supplied, `wtr run <worktree>` will open `$SHELL -i` in the target directory.

Before shell-backed modes, `wtr` will try a best-effort mise preflight:

```sh
mise trust --yes --all --cd <target-worktree>
```

The preflight runs only when `mise` is available. A failure is ignored so `wtr` does not block users who do not use mise or who have an older mise version. This is a deliberate side effect: it trusts the target worktree's local mise config to prevent an interactive trust prompt during shell startup.

Error handling stays simple. Worktree lookup errors keep their current behavior. Direct commands still propagate the child exit code. Shell-backed commands propagate the shell's exit code. Command lookup uses a small `command -v` probe, so the fallback only runs when the first command token is not an executable available to a non-interactive POSIX shell.

## File Structure

- Modify: `src/wtr/commands.lg` - add command-mode helpers, mise preflight, and shell-backed execution.
- Modify: `test/wtr/commands_test.lg` - add focused tests for command-mode selection and shell command vectors.
- Modify: `README.md` - document that shell functions are supported through the interactive shell fallback and that shell modes may trust mise config.

## Implementation Steps

### Task 1: Command Mode Helpers

**Files:**
- Modify: `src/wtr/commands.lg`
- Test: `test/wtr/commands_test.lg`

- [x] **Step 1: Write focused tests**
  Test that empty commands select interactive shell mode, executable commands select direct mode, and unknown command names select shell-command mode.

- [x] **Step 2: Run the focused tests**
  Run: `lgx test`
  Result: FAIL before implementation because `wtr.commands/run-command-mode` was undefined.

- [x] **Step 3: Implement helper functions**
  Add helpers for resolving the user's shell, probing command executability, classifying command mode, and building the `os/exec*` argv vector.
  Codex review follow-up: shell builtins such as `cd` now fall back to shell mode instead of being treated as direct executables.
  Codex review follow-up: commands that have both builtin and executable forms, such as `pwd` and `true`, now stay on the direct path.

- [x] **Step 4: Run verification**
  Run: `lgx test`
  Result: PASS, 42 tests and 108 assertions.

### Task 2: Wire `wtr run`

**Files:**
- Modify: `src/wtr/commands.lg`
- Modify: `README.md`
- Test: `test/wtr/commands_test.lg`

- [x] **Step 1: Update the `run` handler**
  Use the helper-built argv vector for direct, shell-command, and interactive-shell modes. Run the mise trust preflight before shell-backed modes only.

- [x] **Step 2: Update README**
  Document executable command behavior, shell-function fallback, and the mise trust preflight.

- [x] **Step 3: Run all tests**
  Run: `lgx test`
  Result: PASS, 42 tests and 108 assertions.

- [x] **Step 4: Build and smoke-test**
  Run: `lgx build`
  Run: `./bin/wtr run new-feat ls`
  Run: `./bin/wtr run new-feat definitely-not-an-executable-for-wtr-smoke`
  Result: build succeeded, `pwd` and `ls` ran in the worktree through the direct path, the unknown command used the shell-backed path and exited 127, and a temporary bash function ran in the target worktree with arguments preserved.

## Completion Summary

Implemented. `wtr run` now keeps real executables on the direct `exec` path,
falls back to the user's interactive shell for non-executable command names
such as zsh functions, and runs a best-effort `mise trust --yes --all --cd`
preflight before shell-backed modes. Tests cover direct commands, shell
builtins, builtin-backed executable utilities, unknown command fallback, and
the generated argv vectors. Built binary smoke tests passed for direct
commands, unknown-command fallback, and a temporary bash function.

Second-opinion review found two probe edge cases during implementation:
pure shell builtins must not use direct exec, and utilities such as `pwd` and
`true` must stay direct when executable files exist on `PATH`. Both were fixed.
The final review pass found no actionable issues.
