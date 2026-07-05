# Dashboard Create Opens a Shell Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the bare `wtr` dashboard, make the create action (`c`) drop straight into a shell in the newly created worktree instead of returning to the worktree list.

**Tech Stack:** let-go (Clojure-like), tiny-cli, tiny-tui, lgx build tooling.

---

## Design

### Motivation

The dashboard (`src/wtr/dashboard.lg`, shown on a bare `wtr`) has three actions on the highlighted worktree: create (`c`), switch (`s`), remove (`d`). Switch and remove stay in the loop via tiny-tui's `:on-action`. Create is different: `create-action` sets `:returns? true`, which exits `tui/select` so `pick!`'s outer `loop`/`recur` can prompt for a name, create the worktree, and **re-enter the list focused on the new worktree** — leaving the user to press `enter` to open a shell there.

We want create to behave like a terminal action: prompt → create → **open a shell in the new worktree immediately** (exactly what `enter` does on a worktree, and what `wtr create --sh` does on the CLI). Exiting that shell returns the user to their original terminal, not the dashboard — i.e. "do not return to the worktrees list."

### Approach

Create becomes "create, then do what `enter` does." The change stays entirely in `src/wtr/dashboard.lg` and its test — **no tiny-tui version bump, no inline-session refactor, no rendering change**.

Why no inline session: opening a shell `exec`s (replaces the process via `os/exec*`), so the full-screen TUI must be **fully torn down before the exec**, or the shell inherits a raw-mode terminal with a hidden cursor. `create-action`'s existing `:returns? true` already exits `select` before we prompt, so the current full-screen structure is exactly what this needs. An inline session cannot clean up after an `exec`, so it would be the wrong tool here.

### Behavior

- **Success:** `c` → prompt for a name (`create-name!`, unchanged: validates blank/existing-branch inline, then `cmds/create!`) → on `{:name …}`, call `run-fn` with the new name. `run-fn` (default `run-name!`) routes through `cmds/run-in-dir!`, which runs the mise-trust preflight and `exec`s an interactive shell in the worktree. Never returns.
- **Failure** (post-validation create error, e.g. a race): `create-name!` returns `{:status "<msg>"}` → re-enter the list showing that status line.
- **Cancel** (esc at the prompt): `create-name!` returns `{}` → re-enter the list unchanged.

Switch and remove are untouched. `show!`'s `interactive?` guard and static-list fallback are untouched.

### Key changes in `pick!`

The create branch changes from re-entering the loop to opening a shell on success:

```
(and (= :action (:type result)) (= :create (:action result)))
(let [r (create-fn)]
  (if (:name r)
    (run-fn (:name r))        ; created → open a shell (execs, never returns)
    (recur (:status r))))     ; failure → status; cancel → nil (clean re-entry)
```

Because create success no longer re-enters, nothing sets a cursor position anymore. Drop the now-unused `cursor-item` loop variable and the `:cursor-item` key from the `base` map (YAGNI). The loop becomes `(loop [status nil] …)`. A caller-supplied `:cursor-item` still flows through `select-opts` via the existing `merge`, so no override is lost.

### Testing strategy

Headless tests drive `pick!` with `:screen false` and scripted keys (`:read-key-fn`), injecting `:create-fn`/`:run-fn` so no real terminal or `exec` happens. Only the first `pick-create` case changes: create alone now opens the shell (no trailing `:enter`). The cancel and failure cases already exercise re-entry and keep working unchanged.

## File Structure

- Modify: `src/wtr/dashboard.lg`
  - `create-action` — keep `:returns? true`; update its comment to describe "prompt, create, open a shell" (drop "re-enter focused on the new worktree").
  - `create-name!` — logic unchanged; update its docstring (success now "opens a shell there", not "re-enters focused there").
  - `pick!` — rewrite the create branch to open a shell on success; simplify the loop (drop `cursor-item`); update its docstring.
- Modify: `test/wtr/dashboard_test.lg`
  - `pick-create` — update the first case to assert create opens a shell in the new worktree with no trailing `enter`. Leave the cancel and failure cases as-is.

## Task 1: Create action opens a shell

**Files:**
- Modify: `src/wtr/dashboard.lg`
- Test: `test/wtr/dashboard_test.lg`

- [ ] **Step 1: Update the failing test**
  In `test/wtr/dashboard_test.lg`, rewrite the first `pick-create` case (currently "c creates, then the cursor lands on the new worktree for enter"): rename it to "c creates, then opens a shell in the new worktree", change the scripted keys from `["c" :enter]` to `["c"]`, keep `:create-fn (fn [] (reset! created true) {:name "new-wt"})` and `:run-fn (fn [name] (reset! ran name))`, and assert `@created` is `true` and `@ran` is `"new-wt"`. Leave the "cancelling create…" and "a failed create…" cases unchanged.

- [ ] **Step 2: Run test to verify it fails**
  Run: `lgx test`
  Expected: FAIL — under the current code `["c"]` alone re-enters the loop, hits EOF, and never calls `run-fn`, so `@ran` is `nil` (asserted `"new-wt"`).

- [ ] **Step 3: Implement the create-opens-shell change**
  In `src/wtr/dashboard.lg`:
  - `pick!`: change the create `cond` branch so a successful create (`{:name …}`) calls `(run-fn (:name r))` and a non-success (`{:status …}` failure or `{}` cancel) does `(recur (:status r))`. Change the loop to `(loop [status nil] …)` and remove the `:cursor-item` entry from the `base` map.
  - `pick!` docstring: replace "`c` … creates a worktree, and re-enters focused on it" with wording that `c` prompts for a name, creates a worktree, and opens a shell in it (like `enter`).
  - `create-action` comment: replace the `:returns?` note about re-entering focused on the new worktree with "exits select so we can prompt for a name, create the worktree, then open a shell in it".
  - `create-name!` docstring: change the success line from "the dashboard re-enters focused there" to "the dashboard opens a shell there".

- [ ] **Step 4: Run test to verify it passes**
  Run: `lgx test`
  Expected: PASS (all dashboard tests, including the unchanged cancel/failure cases).

- [ ] **Step 5: Run all checks**
  Run: `lgx check`
  Expected: green — fmt clean, lint 0/0 on touched files, all tests pass.

- [ ] **Step 6: Commit**
  `git commit -m "feat: dashboard create action opens a shell in the new worktree"`

## Task 2: Verify end-to-end

**Files:** none (build + manual/pty drive; use the /verify skill).

- [ ] **Step 1: Build the binary**
  Run: `lgx build`
  Expected: `bin/wtr` built with no errors.

- [ ] **Step 2: Drive the create flow (never against the wtr checkout)**
  In a throwaway git repo, run `./bin/wtr`, press `c`, type a new worktree name, and submit.
  Expected: a shell opens **in the new worktree** — `pwd` shows the new worktree path and `git worktree list` (from another shell) lists it. Typing `exit` returns to the original terminal, not the dashboard.

- [ ] **Step 3: Spot-check the edge cases**
  In the same throwaway repo: pressing `c` then esc returns to the list unchanged; entering an existing branch name at the prompt shows the inline validator error; `s`/`d` still act in place and stay in the list.
  Expected: all behave as described; no raw-mode/hidden-cursor artifacts after the shell opens or after exit.
