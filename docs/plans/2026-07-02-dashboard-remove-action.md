# Dashboard `remove` Action Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a destructive `remove` action (key `d`, with a yes/no confirmation) to the bare-`wtr` worktree dashboard, alongside the existing `run` and `switch` actions.

**Tech Stack:** let-go (Clojure-like), tiny-tui (terminal UI), tiny-cli, lgx build tool.

---

## Design

### Context

The dashboard (`wtr.dashboard`, reached via a bare `wtr`) renders a full-screen tiny-tui `select` over the worktree names with two actions: `run` (`r`, also `enter`) and `switch` (`s`). This adds a third, `remove` (`d`), which deletes the highlighted worktree and its branch after a confirmation.

tiny-tui's `:actions` support a **destructive** flag: an action with `:destructive?` (or `:confirm?`) first opens a built-in yes/no confirmation *inside* `select`, configured by `:confirm-title` and `:confirm-message` (a string or a fn of the item). `select` only returns the action event once the user confirms; cancelling the confirmation returns to the list. So the confirmation UI is entirely tiny-tui's — the dashboard just sets the flags.

`cmds/remove` already takes a worktree name, refuses the main worktree, does a **safe** branch delete (keeps an unmerged branch with a "re-run with --force" note), prints the result, and handles its own errors (`os/exit 1` on failure). It does not `exec`. So the dashboard reuses it with a synthesized context — no new extraction (same pattern as `switch`).

`result->intent` already maps any `:action` result generically to `[(:action result) (:item result)]`, so it needs **no change** — `:remove` is handled for free.

### Flow

```
dashboard → tui/select (actions: run, switch, remove[destructive])
   ├─ enter / r  → [:run name]    → run-name!    → cmds/run-in-dir!
   ├─ s          → [:switch name] → switch-name! → cmds/switch
   ├─ d          → confirm y/n (tiny-tui) → [:remove name] → remove-name! → cmds/remove
   └─ q / esc / confirm-cancel → nothing
```

`tui/select` tears down the alternate screen before returning, so `cmds/remove`'s result — including the partial-failure "Kept branch … Re-run with --force" message — prints cleanly on the restored screen. The process then exits.

### Key decisions

- **Single-shot, no refresh loop.** Remove one worktree (with confirm), print the result, exit — uniform with `run`/`switch`. A refresh loop's next full-screen redraw would wipe `cmds/remove`'s result message (notably the "Kept branch …" partial-failure note), so single-shot is chosen to preserve that feedback.
- **Confirmation via tiny-tui's `:destructive?`.** Set `:destructive? true`, `:confirm-title`, and `:confirm-message` (a fn of the worktree name). No custom UI; the confirm/cancel flow lives inside `select`.
- **Safe remove, never `--force`.** The dashboard calls `cmds/remove` with no force, so an unmerged branch is kept (with the standard note) rather than force-deleted from a keypress.
- **Key `d`** (`r`=run, `s`=switch are taken). Footer auto-updates via tiny-tui to `↑/↓ navigate · enter select · r run · s switch · d remove · q quit`.
- **Removing the main token** (`master`/`main`) hits `cmds/remove`'s existing refusal — tiny-tui can't gate an action per-row, so the confirm appears and then remove declines (exit 1). Rare and harmless.
- **Reuse `cmds/remove`** via `{:args {:name name} :opts {}}`, the same DRY pattern `switch` uses.

### Implementation shape (`wtr.dashboard`)

- Add `remove-action`:
  ```
  {:id :remove :key "d" :label "remove"
   :destructive? true
   :confirm-title "Remove worktree?"
   :confirm-message (fn [name] (str "Remove worktree '" name "' and delete its branch?"))}
  ```
- Add private `remove-name!` → `(cmds/remove {:args {:name name} :opts {}})`.
- In `pick!`: register `:actions [run-action switch-action remove-action]`; read an injectable `:remove-fn` (default `remove-name!`) alongside `:run-fn`/`:switch-fn`; strip all three from the tiny-tui opts (`(dissoc opts :run-fn :switch-fn :remove-fn)`); add a `:remove` branch to the `case` dispatch.
- `result->intent` is unchanged (its `:action` branch already yields `[:remove name]`).

### Testing

- `result->intent`: `{:type :action :action :remove :item "feat-x"}` → `[:remove "feat-x"]` (confirms the generic mapping covers remove).
- `pick!` remove-with-confirm: scripted `[:down "d" "y"]` over `["main" "feat-x"]` invokes the injected `:remove-fn` with `"feat-x"` (destructive action confirmed with `y`).
- `pick!` confirm-cancel: scripted `[:down "d" "n"]` — the confirmation is dismissed, then EOF cancels, so `:remove-fn` is never called.
- Existing `run`/`switch`/cancel cases stay green.
- Manual: rebuilt `./bin/wtr` in an isolated sandbox repo — `d` → confirm → worktree + branch removed (item gone); cancelling the confirm removes nothing; footer shows `d remove`.

## File Structure

- Modify `src/wtr/dashboard.lg` — `remove-action`, `remove-name!`, register in `pick!` actions, `:remove` dispatch + `:remove-fn`.
- Modify `test/wtr/dashboard_test.lg` — remove intent case + confirm/confirm-cancel wiring tests.
- Modify `README.md` — add `d remove` to the dashboard footer example and note the confirmation.

---

### Task 1: Remove action in the dashboard

**Files:**
- Modify: `src/wtr/dashboard.lg`
- Test: `test/wtr/dashboard_test.lg`

- [ ] **Step 1: Write the failing tests**
  In `dashboard_test.lg`:
  - Extend `result->intent-maps-results` with `{:type :action :action :remove :item "feat-x" :index 1}` → `[:remove "feat-x"]`.
  - Add a `pick!` remove-with-confirm case: `{:items ["main" "feat-x"] :remove-fn <records to atom> :screen false :read-key-fn (scripted [:down "d" "y"]) :render-fn (fn [_] nil)}` → atom holds `"feat-x"`.
  - Add a `pick!` confirm-cancel case: same but `(scripted [:down "d" "n"])` → atom stays untouched.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — `remove` action is unregistered, so `"d"` is ignored, the confirm never appears, and `:remove-fn` is never called.

- [ ] **Step 3: Implement the remove action**
  In `src/wtr/dashboard.lg`: add `remove-action` (destructive + confirm config as in the design); add private `remove-name!` calling `(cmds/remove {:args {:name name} :opts {}})`; in `pick!` register `[run-action switch-action remove-action]`, read `:remove-fn` (default `remove-name!`), extend the `dissoc` to drop `:remove-fn`, and add `:remove (remove-fn (second intent))` to the `case`. Leave `result->intent` as-is.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS (new + existing dashboard tests green).

- [ ] **Step 5: Full check**
  Run: `lgx check`
  Expected: fmt clean, lint 0/0, tests PASS.

- [ ] **Step 6: Commit**
  `feat: add remove action to the worktree dashboard`

---

### Task 2: Docs and manual verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the dashboard section**
  In the `### \`wtr\` (no command)` section, add `d remove` to the footer line (`↑/↓ navigate   enter select   r run   s switch   d remove   q quit`) and mention that `d` removes the highlighted worktree and its branch after a confirmation (like `wtr remove <name>`, safe delete — unmerged branches are kept).

- [ ] **Step 2: Rebuild and manually verify (isolated sandbox)**
  Run: `lgx build`, then set up a throwaway git repo with an extra worktree and drive `./bin/wtr` under a pty (reuse the scratchpad pty driver). Confirm: footer shows `d remove`; `[:down "d" "y"]` removes the highlighted worktree and its branch (gone from `git worktree list`), with the result printed and exit 0; `[:down "d" "n"]` leaves the worktree in place. Do NOT run this against the wtr checkout itself.

- [ ] **Step 3: Commit**
  `docs: document the dashboard remove action`
