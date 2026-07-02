# Dashboard `switch` Action Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `switch` action (key `s`) to the bare-`wtr` worktree dashboard, so the highlighted worktree can re-point the main worktree in place — alongside the existing `run` action.

**Tech Stack:** let-go (Clojure-like), tiny-tui (terminal UI), tiny-cli, lgx build tool.

---

## Design

### Context

The dashboard (`wtr.dashboard`, reached via a bare `wtr`) already renders a full-screen tiny-tui `select` over the worktree names with one action, `run` (key `r`, also `enter`). tiny-tui's `:actions` framework supports multiple actions out of the box, emitting `{:type :action :action <id> :item <name>}` on the action key. This adds a second action, `switch`.

`cmds/switch` already takes a worktree name, mutates the main worktree (re-attach for `master`/`main`, detach for others), prints a confirmation, and handles its own errors (printing to stderr and `os/exit 1` on failure). It does **not** `exec`. So the dashboard reuses it directly with a synthesized context — no new extraction is needed (unlike `run`, which needed `run-in-dir!` because `run` execs and the dashboard only had a name).

### Flow

```
dashboard → tui/select (actions: run, switch)
   ├─ enter / r  → [:run name]    → run-name!    → cmds/run-in-dir! (exec shell)
   ├─ s          → [:switch name] → switch-name! → cmds/switch {:args {:name name}}
   └─ q / esc    → :cancel        → nothing
```

`tui/select` returns *after* the alternate screen is torn down (`with-screen*` shuts down before returning), so `switch`'s confirmation prints cleanly on the restored screen. The process then exits.

### Key decisions

- **Single-shot, no refresh loop.** `switch` performs, prints, and the process exits — the same shape as `run`. Switching changes only the main worktree's HEAD, not the worktree *list*, so there is nothing to refresh; and in full-screen mode the confirmation lands on the restored screen. (A future `remove` action — where the list shrinks — is the one that would want a loop.)
- **No confirmation gate.** Matches `run`'s no-confirm UX; `switch` is reversible and already prints how to switch back. (tiny-tui's `:confirm?`/`:destructive?` remain available if a gate is wanted later.)
- **`enter` stays `run`** (primary action); `r` = run, `s` = switch. The footer auto-updates via tiny-tui to `↑/↓ navigate · enter select · r run · s switch · q quit`.
- **Same candidate list, no filtering.** The `master`/`main` token resolves to a re-attach and other names to a detach — exactly `wtr switch`'s existing semantics.
- **Reuse `cmds/switch`** via `{:args {:name name}}`, the same DRY pattern `show!` uses to call `cmds/list`.

### Implementation shape (`wtr.dashboard`)

- Add `switch-action` `{:id :switch :key "s" :label "switch"}` next to `run-action`.
- Generalize `result->intent`: for an `:action` result return `[(:action result) (:item result)]` (yields `[:run name]` or `[:switch name]`); `:select` stays `[:run name]`; `:cancel` stays `:cancel`.
- Add private `switch-name!` → `(cmds/switch {:args {:name name}})`.
- In `pick!`: register `:actions [run-action switch-action]`; read an injectable `:switch-fn` (default `switch-name!`) alongside `:run-fn`; strip both from the tiny-tui opts (`(dissoc opts :run-fn :switch-fn)`); dispatch the non-cancel intent by its head:
  ```
  (when-not (= :cancel intent)
    (case (first intent)
      :run    (run-fn (second intent))
      :switch (switch-fn (second intent))))
  ```

### Testing

- `result->intent`: `{:type :action :action :switch :item "feat-x"}` → `[:switch "feat-x"]` (plus the existing `:run`/`:select`/`:cancel` cases stay green).
- `pick!` wiring: scripted `["s"]` over `["main" "feat-x"]` invokes the injected `:switch-fn` with `"main"` (cursor at index 0); the existing `run-fn` cases stay green.
- Manual: rebuilt `./bin/wtr` under a pty — `s` on a highlighted worktree switches the main worktree (detached) and prints the confirmation; footer shows `s switch`; `run`/cancel paths unchanged.

## File Structure

- Modify `src/wtr/dashboard.lg` — `switch-action`, generalized `result->intent`, `switch-name!`, `pick!` dispatch.
- Modify `test/wtr/dashboard_test.lg` — switch intent case + `pick!` switch-wiring test.
- Modify `README.md` — add `s switch` to the dashboard footer example.

---

### Task 1: Switch action in the dashboard

**Files:**
- Modify: `src/wtr/dashboard.lg`
- Test: `test/wtr/dashboard_test.lg`

- [ ] **Step 1: Write the failing tests**
  In `dashboard_test.lg`:
  - Extend `result->intent-maps-results` with: `{:type :action :action :switch :item "feat-x" :index 1}` → `[:switch "feat-x"]`.
  - Add a `pick!` case: call with `{:items ["main" "feat-x"] :switch-fn <records to atom> :screen false :read-key-fn (scripted ["s"]) :render-fn (fn [_] nil)}` and assert the atom holds `"main"`. Keep a `run-fn` in the map (or a separate case) to confirm `run` still works.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — `switch` action is unregistered, so `["s"]` cancels (atom untouched) and `result->intent` has no `:switch` mapping.

- [ ] **Step 3: Implement the switch action**
  In `src/wtr/dashboard.lg`: add `switch-action`; generalize `result->intent`'s `:action` branch to `[(:action result) (:item result)]`; add private `switch-name!` calling `(cmds/switch {:args {:name name}})`; in `pick!` register `[run-action switch-action]`, read `:switch-fn` (default `switch-name!`), `dissoc` both `:run-fn`/`:switch-fn` from the merged opts, and dispatch `:run`/`:switch` via `case` on `(first intent)`.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS (new + existing dashboard tests green).

- [ ] **Step 5: Full check**
  Run: `lgx check`
  Expected: fmt clean, lint 0/0, tests PASS.

- [ ] **Step 6: Commit**
  `feat: add switch action to the worktree dashboard`

---

### Task 2: Docs and manual verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the dashboard footer example**
  In the `### \`wtr\` (no command)` section, add `s switch` to the footer line so it reads `↑/↓ navigate   enter select   r run   s switch   q quit`, and mention `s` switches the main worktree to the highlighted worktree (like `wtr switch <name>`).

- [ ] **Step 2: Rebuild and manually verify**
  Run: `lgx build`, then drive `./bin/wtr` under a pty (reuse the scratchpad pty driver): confirm the footer shows `s switch`, and that pressing `s` on a highlighted worktree runs `cmds/switch` (main worktree detaches at that branch, confirmation printed) and exits cleanly. Optionally switch back with `wtr switch master`.

- [ ] **Step 3: Commit**
  `docs: document the dashboard switch action`
