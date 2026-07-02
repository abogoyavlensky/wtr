# On-Action Live-Manager Dashboard Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt tiny-tui's `:on-action` so the bare-`wtr` dashboard is a persistent manager: `run` on `enter` (exits + exec), `switch`/`remove` run in-loop with a status line, `remove` refreshes the list live, and removing the main worktree becomes a graceful in-loop refusal.

**Tech Stack:** let-go (Clojure-like), tiny-tui (terminal UI, now pinned at `53ea484` with `:on-action`), tiny-cli, lgx build tool.

---

## Design

### Context

The dashboard (`wtr.dashboard`, bare `wtr`) currently makes one `tui/select` call with three returning actions (`run`/`switch`/`remove`) and dispatches after it exits (single-shot). tiny-tui `53ea484` adds **`:on-action`** (`core.lg:124-166`): a handler `(fn [action-event] -> {:items new-items :status "..."})` runs *inside* the loop — it swaps in any returned `:items` (cursor/filter preserved), shows a transient `:status` line until the next key, and keeps browsing. `enter` (`:select`) and cancel still exit. This turns the dashboard into a live manager.

### New interaction model

```
dashboard → tui/select (actions: switch, remove[destructive]; :on-action handler)
   ├─ enter   → {:type :select} → select EXITS → run-name! (exec shell)   ← the only "leave into a worktree"
   ├─ s       → on-action → switch! → {:status "Switched main to …"}       (stays; list unchanged)
   ├─ d       → confirm y/n → on-action → remove! → {:items <fresh>, :status "Removed …"}  (stays; list refreshes)
   └─ q / esc → {:type :cancel} → exit
```

### Key decisions

- **`run` moves to `enter`-only; the `r` action is dropped.** `:on-action` is global (fires for *every* action key) and runs while the screen is up, but `run` execs (replaces the process), which cannot happen mid-loop. So `run` is the `enter`/`:select` path — `select` exits and tears down the screen first, then `run-name!` execs. This is forced by the architecture, not a preference.
- **Extract silent `cmds/switch!` and `cmds/remove!`** returning result maps (no `print`, no `os/exit`), because on-action handlers must do neither. The CLI `switch`/`remove` commands become thin wrappers over them, sharing the exact message strings (DRY). CLI success output is unchanged; CLI failure output stays equivalent (routed through `error-exit`, i.e. `Error: <message>` + exit 1) — the only shift is that a git-failure message is normalized to a single cleaned line (via the existing `first-nonblank-line`) instead of raw multi-line stderr.
- **Live status + refresh, transient.** `remove` returns fresh `:items` so the row disappears at once; both actions surface `:message` as the status line (clears on the next key). The rich `remove` note — *"kept branch 'x' (unmerged) — re-run with --force"* — rides in that status line (the list already reflects the removal).
- **Main-worktree remove → graceful in-loop refusal.** `remove!` returns `{:ok? false :removed? false :message "Refusing to remove the main worktree: …"}`, so `d` on the `main`/`master` row confirms, shows that status, and *stays* — replacing the old confirm→exit-1 (retires the accepted [P2] wart from the remove work).
- **`pick!` simplifies.** `result->intent` is deleted (actions no longer return through `select`); `pick!` only does `enter → run-name!`, with everything else handled by the on-action handler.
- **No filtering / multi-select.** `:filterable?` would shadow the `s`/`d` letter keys (forcing ctrl-bindings); not worth it. Out of scope.

### Silent helper shapes (`wtr.commands`)

- `switch!` `[name]` → `{:ok? bool :message str}`: resolve via `resolve-switch-target`; nil → `{:ok? false :message "Worktree not found: <name>"}`; else `git/switch-ref!` then build the existing detach/reattach message; wrap in try/catch → `{:ok? false :message (first-nonblank-line stderr ex-message)}`.
- `remove!` `[name force?]` → `{:ok? bool :removed? bool :message str}`: resolve via `resolve-remove-target`; nil → not-found; `:main?` → refusal (`:removed? false`); else `git/remove-worktree!` + safe `git/delete-branch!` then the existing removed/kept-branch/no-branch message (`:removed? true`); try/catch → failure map.
- CLI `switch`/`remove` become: call the `!` helper; on `:ok?` `(println (:message …))`, else `(error-exit (:message …))`. `resolve-*-target`, `main-return-branch`, `first-nonblank-line`, and the `git/*` fns are reused unchanged.

### Dashboard shape (`wtr.dashboard`)

- Drop `run-action` and `result->intent`.
- Add private `on-switch`/`on-remove` `(fn [event] …)`: call `cmds/switch!`/`cmds/remove!` with `(:item event)`; `on-switch` → `{:status (:message res)}`; `on-remove` → `{:items (completion/worktree-name-candidates nil) :status (:message res)}` when `:removed?`, else `{:status (:message res)}`.
- `pick!`: read injectable `:run-fn`/`:switch-fn`/`:remove-fn` (defaults `run-name!`/`on-switch`/`on-remove`); build `:on-action (fn [event] (case (:action event) :switch (switch-fn event) :remove (remove-fn event)))`; register `:actions [switch-action remove-action]`; `dissoc` the three fns from the tiny-tui opts; after `tui/select`, `(when (= :select (:type result)) (run-fn (:item result)))`.
- `switch-action`/`remove-action` keep keys `s`/`d`; `remove-action` keeps its `:destructive?`/confirm config.

### Testing

- **Unit** (`dashboard_test.lg`, headless via `:screen false` + scripted keys + injected fns):
  - `enter` runs: `(scripted [:down :enter])` → `:run-fn` gets `"feat-x"`.
  - `s` switches in-loop: `:switch-fn` records `(:item event)`, `(scripted ["s" "q"])` → `"main"`.
  - `d` confirmed removes: `:remove-fn` records `(:item event)` and returns `{:items ["main"] :status "…"}`, `(scripted [:down "d" "y" "q"])` → `"feat-x"`.
  - `d` cancelled removes nothing: `(scripted [:down "d" "n" "q"])` → recorder untouched.
  - Delete the obsolete `result->intent` tests.
- **Integration** (isolated sandbox, pty): `s` shows a status and stays; `d`+`y` removes and the row vanishes live with a status; `d`+`n` removes nothing; `d` on the main row shows the graceful refusal and stays; `enter` drops into a shell; `q` quits. CLI `wtr switch`/`wtr remove` still behave as before.
- `commands_test.lg` stays green (only pure `resolve-*`/`run-*` helpers are tested; they're unchanged).

## File Structure

- Modify `src/wtr/commands.lg` — add public `switch!`/`remove!`; rewrite `switch`/`remove` command fns as thin wrappers.
- Modify `src/wtr/dashboard.lg` — drop `run-action`/`result->intent`; add `on-switch`/`on-remove`; wire `:on-action` in `pick!`.
- Modify `test/wtr/dashboard_test.lg` — replace intent tests with on-action wiring tests.
- Modify `README.md` — dashboard footer + notes (`enter` opens a shell; remove refreshes live).

---

### Task 1: Silent `switch!` / `remove!` helpers in commands

**Files:**
- Modify: `src/wtr/commands.lg`
- Test: `test/wtr/commands_test.lg` (existing — must stay green)

- [ ] **Step 1: Add the silent helpers**
  Add public `switch!` `[name]` and `remove!` `[name force?]` per the "Silent helper shapes" above — resolve the target, do the `git/*` side effect, build the same message strings the current commands print, and return result maps. Never `print`, never `os/exit`; catch exceptions into `{:ok? false … :message (first-nonblank-line …)}`.

- [ ] **Step 2: Rewrite the CLI wrappers**
  Replace the bodies of `switch` and `remove` with thin wrappers: call the `!` helper (passing `(:force opts)` for remove), then `(println (:message res))` on `:ok?` else `(error-exit (:message res))`. Keep the command specs in `main.lg` untouched.

- [ ] **Step 3: Verify existing tests + build**
  Run: `lgx test` — Expected: PASS (44 tests; `resolve-*` and `run-*` helpers unchanged).
  Run: `lgx build` — Expected: builds `bin/wtr`.

- [ ] **Step 4: Smoke-check the CLI in a sandbox**
  In a throwaway git repo with an extra worktree, confirm `./bin/wtr switch <name>` and `./bin/wtr remove <name>` still print the same success messages and that a not-found name still errors with exit 1.

- [ ] **Step 5: Commit**
  `refactor: add silent switch!/remove! helpers behind the CLI commands`

---

### Task 2: On-action rewiring in the dashboard

**Files:**
- Modify: `src/wtr/dashboard.lg`
- Test: `test/wtr/dashboard_test.lg`

- [ ] **Step 1: Rewrite the tests**
  In `dashboard_test.lg`: delete the `result->intent-maps-results` deftest, and replace `pick-acts-on-selection` with the four on-action wiring cases from the Testing section (enter→run-fn; s→switch-fn then quit; d+y→remove-fn; d+n→nothing). Injected `:switch-fn`/`:remove-fn` take the action event and return a `{:status …}` (or `{:items … :status …}`) map.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — `result->intent` still exists / `pick!` has no `:on-action`, so `s`/`d` don't invoke the injected fns (they still return through `select`).

- [ ] **Step 3: Implement the on-action rewiring**
  In `src/wtr/dashboard.lg`: delete `run-action` and `result->intent`; add `on-switch`/`on-remove`; rewrite `pick!` to read `:run-fn`/`:switch-fn`/`:remove-fn`, build the `:on-action` handler, register `:actions [switch-action remove-action]`, `dissoc` the three fns, and run `run-fn` only on a `:select` result. Leave `show!`, `interactive?`, `run-name!`, `switch-action`, `remove-action` in place.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS.

- [ ] **Step 5: Full check + codex review**
  Run: `lgx check` — Expected: fmt clean, lint 0/0, tests PASS.
  Then run the `review-with-codex` skill on the uncommitted changes and address any must-fix findings.

- [ ] **Step 6: Commit**
  `feat: make the dashboard a live manager via tiny-tui :on-action`

---

### Task 3: Docs and sandbox verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the dashboard section**
  Footer becomes `↑/↓ navigate   enter select   s switch   d remove   q quit` (no `r run`). Note that `enter` opens a shell in the highlighted worktree, `s`/`d` act in place and keep you in the dashboard, and `d` refreshes the list after removing.

- [ ] **Step 2: Rebuild and verify in an isolated sandbox**
  Run: `lgx build`, then set up a throwaway git repo with 2+ worktrees and drive `./bin/wtr` under a pty (reuse the scratchpad driver). Confirm: `enter` execs a shell; `s` shows a status and stays; `[:down "d" "y"]` removes the worktree+branch and the row disappears live with a status; `[:down "d" "n" "q"]` removes nothing; `d` on the main row shows the graceful refusal and stays; `q` quits. Never run against the wtr checkout itself.

- [ ] **Step 3: Commit**
  `docs: document the live-manager dashboard`
