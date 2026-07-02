# Dashboard `create` Action Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `create` action (key `c`) to the bare-`wtr` live-manager dashboard: prompt for a name, create the worktree, then return to the list with the cursor on the new worktree so `enter` opens a shell in it. Needs two small tiny-tui additions.

**Tech Stack:** let-go (Clojure-like), tiny-tui (local `../tiny-tui`), tiny-cli (local `../tiny-cli`), lgx build tool. Cross-repo, local-only (no pushes).

---

## Design

### Why create is different from switch/remove

`create` needs two things `tui/select` was not built for:
1. **Free-text name input.** `tui/input` runs its own screen loop, so it cannot nest inside the select loop where `:on-action` runs. So `create` must *leave* select, take the name outside, create, and *re-enter* — it can't be an in-loop `:on-action` like `s`/`d`.
2. **Landing the cursor on the new row.** `tlist/create` always starts at `:cursor 0`, and `set-items` only *clamps* the old cursor (`list.lg:64`). There is no way to focus a chosen row.

Both are met with two small, general tiny-tui additions.

### tiny-tui additions (`../tiny-tui`)

- **`:cursor-item`** on `tui/select` — start the cursor on the row equal to that item (else the top). Implemented in `tlist/create`: `:cursor` becomes the index of `:cursor-item` in `items` (via `keep-indexed`), defaulting to `0`. `window` already auto-scrolls to the cursor, so a deep target renders correctly; `set-items` is unchanged.
- **`:returns?` on an action** — with `:on-action` set, an action carrying `:returns? true` still *returns its event* (exits select) instead of running in-loop. In `select-update`, add a branch before the on-action dispatch: `(and action (:returns? action)) [state event]`. (Destructive + returns is not needed and not supported.)

### Interaction model

```
dashboard → tui/select (actions: create[returns?], switch, remove[destructive]; :on-action for s/d)
   ├─ enter   → {:type :select} → run-name! (exec shell)                 ← leaves the manager
   ├─ c       → {:type :action :create} RETURNS → tui/input(name) → create! → re-enter with :cursor-item = new name
   ├─ s / d   → :on-action, in place (unchanged)
   └─ q / esc → exit
```

`pick!` gains a thin **outer loop**: it re-enters `tui/select` only after a `create` (or never, for a normal session). `s`/`d` stay flicker-free in-loop; the only screen transition is the deliberate create.

### wtr changes

- **Silent `cmds/create!`** `[name from-ref base-dir-override]` → `{:ok? true :name :path :from}` on success, `{:ok? false :message}` on failure. Mirrors `switch!`/`remove!`: resolve base-dir (`config/ensure-config!`), build `{base}/{project}/{name}`, guard existing branch/dir, `git/create-worktree!`. Never prints or exits (it *does* own `ensure-config!`, whose rare first-run notice is acceptable). Returns **structured** success data (not a prebuilt message) so the CLI keeps its exact two-line output.
- **CLI `create`** becomes a thin wrapper: call `create!` with `(:from opts)`/`(:base-dir global)`; on failure `error-exit`; on success print the existing two lines (`Created worktree at <path>` / `Branch: <name> [(from <ref>)]`) then the existing `--sh` shell. Byte-identical CLI behavior; the README `create` example stays valid.
- **Dashboard**:
  - `create-action` `{:id :create :key "c" :label "create" :returns? true}`.
  - `create-input` → `tui/input {:title "New worktree name" :placeholder "name" :validate <blank + git/branch-exists?>}` (submit-time validation; no `ensure-config!` there). Returns the name or nil.
  - `create-name!` → run `create-input`; on a name, `cmds/create! name nil nil`; return the created `:name` on success, else nil (a rare post-validation failure just re-enters at the top).
  - `pick!` outer loop: `:actions [create-action switch-action remove-action]`, `:on-action` for `s`/`d`, `:cursor-item` from the loop var; injectable `:run-fn`/`:switch-fn`/`:remove-fn`/`:create-fn`; on `:select` run, on `:action :create` `(recur (create-fn))`, on `:cancel` stop.
- Footer becomes `↑/↓ navigate · enter select · c create · s switch · d remove · q quit`.

### Cross-repo dependency

wtr must consume the local tiny-tui with the new features, so its `lgx.edn` tiny-tui dep switches from `:git/sha "53ea484…"` to `:local/root "../tiny-tui"` (same dev arrangement already used for tiny-cli). Reconciling/pushing tiny-tui is deferred to the user.

### Testing

- **tiny-tui** (`core_test.lg`, headless): `:cursor-item "c"` → `enter` selects index 2; unknown `:cursor-item` → top; a `:returns?` action fires its event through `select` even with `:on-action` set (not swallowed).
- **wtr** (`dashboard_test.lg`): existing `enter`/`s`/`d` cases stay green under the outer loop; new `create` case — `(scripted ["c" :enter])` with `:items ["main" "feat-x" "new-wt"]` and `:create-fn` returning `"new-wt"` → `:run-fn` gets `"new-wt"` (proves `:returns?` fired create-fn *and* `:cursor-item` focused the new row); a create-cancel case — `:create-fn` returns nil → cursor at top → `:run-fn` gets `"main"`. `commands_test.lg` stays green.
- **Integration** (isolated sandbox, pty): `c` → type a name → new worktree created; the dashboard returns with the cursor on it; `enter` opens a shell there; blank and duplicate names are rejected inline; `wtr create`/`wtr create --sh` unchanged on the CLI.

## File Structure

- `../tiny-tui`: modify `src/tiny_tui/list.lg` (`:cursor-item`), `src/tiny_tui/core.lg` (`:returns?` + select docstring), `test/tiny_tui/core_test.lg`, `README.md`.
- `wtr`: modify `lgx.edn` (tiny-tui → local root), `src/wtr/commands.lg` (`create!` + wrapper), `src/wtr/dashboard.lg` (create wiring + outer loop), `test/wtr/dashboard_test.lg`, `README.md`.

---

### Task 1: tiny-tui — `:cursor-item` and `:returns?`

**Files:**
- Modify: `../tiny-tui/src/tiny_tui/list.lg`, `../tiny-tui/src/tiny_tui/core.lg`
- Test: `../tiny-tui/test/tiny_tui/core_test.lg`
- Docs: `../tiny-tui/README.md`

- [x] **Step 1: Write the failing tests**
  In `core_test.lg`, add: (a) `tui/select` with `:cursor-item` over `["a" "b" "c"]` + scripted `[:enter]` returns `{:type :select :item "c" :index 2}`; an unknown `:cursor-item` returns index 0; (b) a `:returns? true` action with `:on-action` set — scripted `["c"]` returns `{:type :action :action :new …}` rather than looping. Use the existing `scripted`/`select-opts` patterns.

- [x] **Step 2: Run tests to verify they fail**
  Run: `cd ../tiny-tui && lgx test` — Expected: FAIL (no `:cursor-item`, `:returns?` swallowed by on-action).

- [x] **Step 3: Implement**
  `list.lg` `create`: set `:cursor` to the index of `:cursor-item` in `items` (`keep-indexed`, `or … 0`). `core.lg` `select-update`: add `(and action (:returns? action)) [state event]` before the `(= :action …) (apply-on-action …)` branch; update the `select` docstring to mention `:cursor-item` and `:returns?`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `cd ../tiny-tui && lgx test` — Expected: PASS.

- [x] **Step 5: Docs + full check + commit**
  Document `:cursor-item` and `:returns?` in the tiny-tui README select/App-spec section. Run `cd ../tiny-tui && lgx check` (lg + clj + bb, lint, fmt) — Expected: all green. Commit in `../tiny-tui`: `feat: add :cursor-item and :returns? to select`.

---

### Task 2: Point wtr at local tiny-tui

**Files:**
- Modify: `lgx.edn`

- [x] **Step 1: Switch the dep**
  In `lgx.edn`, change the `tiny-tui` dep to `{:local/root "../tiny-tui"}` (comment out the `:git/url`/`:git/sha` for later restoration).

- [x] **Step 2: Verify resolution**
  Run: `lgx test` — Expected: existing 44 tests PASS against the local tiny-tui.

- [x] **Step 3: Commit**
  `chore: dev-pin tiny-tui to local root for create action`

---

### Task 3: Silent `cmds/create!`

**Files:**
- Modify: `src/wtr/commands.lg`
- Test: `test/wtr/commands_test.lg` (existing — must stay green)

- [x] **Step 1: Add `create!`**
  Add public `create!` `[name from-ref base-dir-override]` returning `{:ok? true :name :path :from}` / `{:ok? false :message}` per the design — `ensure-config!`, path build, branch/dir guards, `git/create-worktree!`, try/catch → `{:ok? false :message (first-nonblank-line …)}`. No print, no exit.

- [x] **Step 2: Rewrite the CLI wrapper**
  `create` calls `create!` with `(:from opts)`/`(:base-dir global)`; on failure `error-exit`; on success print the existing two lines from the result then the existing `--sh` block. Keep `main.lg`'s create spec untouched.

- [x] **Step 3: Verify + smoke**
  Run: `lgx test` — Expected: PASS. Run: `lgx build`. In a sandbox repo, confirm `./bin/wtr create x` prints the same two lines and `./bin/wtr create --sh x2` drops into a shell; a duplicate name still errors with exit 1.

- [x] **Step 4: Commit**
  `refactor: add silent create! helper behind the CLI command`

---

### Task 4: Dashboard create wiring

**Files:**
- Modify: `src/wtr/dashboard.lg`
- Test: `test/wtr/dashboard_test.lg`

- [x] **Step 1: Write the failing tests**
  In `dashboard_test.lg`, add: a create-focus case — `(scripted ["c" :enter])` with `:items ["main" "feat-x" "new-wt"]`, `:create-fn (fn [] "new-wt")`, `:run-fn` recording → `:run-fn` gets `"new-wt"`; a create-cancel case — `:create-fn (fn [] nil)` → `:run-fn` gets `"main"`. Keep the existing enter/s/d cases.

- [x] **Step 2: Run tests to verify they fail**
  Run: `lgx test` — Expected: FAIL (no `create-action`, no outer loop / `:cursor-item`).

- [x] **Step 3: Implement**
  Add `create-action`, `create-input`, `create-name!`; rewrite `pick!` with the outer loop, `:create-fn`, `:actions [create-action switch-action remove-action]`, and `:cursor-item` from the loop var (dissoc `:create-fn` too). Keep `on-switch`/`on-remove`/`run-name!`/`show!`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lgx test` — Expected: PASS.

- [x] **Step 5: Full check + codex review**
  Run: `lgx check` — Expected: green. Then run `review-with-codex` on the uncommitted wtr changes and address must-fix findings.

- [x] **Step 6: Commit**
  `feat: add create action to the worktree dashboard`

---

### Task 5: Docs and sandbox verification

**Files:**
- Modify: `README.md`

- [x] **Step 1: Update the dashboard section**
  Footer becomes `↑/↓ navigate   enter select   c create   s switch   d remove   q quit`. Note `c` prompts for a name, creates the worktree, and returns with the cursor on it (press `enter` to open a shell there); blank/duplicate names are rejected.

- [x] **Step 2: Rebuild and verify in an isolated sandbox**
  Run: `lgx build`, then drive `./bin/wtr` under a pty (extend the scratchpad driver to type a name): `c` → type `new-x` → `enter` (submit) → worktree `new-x` created and present in `git worktree list`; the dashboard returns with the cursor on `new-x`; a following `enter` opens a shell there (send `exit`). Also confirm a duplicate name shows the inline validator error. Never run against the wtr checkout itself.

- [x] **Step 3: Commit**
  `docs: document the dashboard create action`

---

## Implementation Summary

**Status: COMPLETE.**

### tiny-tui (`../tiny-tui` master, local only)
- `b559e4b` — `:cursor-item` (start the cursor on a given row) and `:returns?` (an action that exits `select` even under `:on-action`).
- `e520ef6` — `:status` (seed `select`'s status line from opts), added while resolving a codex finding so create failures surface as a status line.
- Only my files staged; the maintainer's uncommitted `select_project.lg`/screenshot WIP was left untouched.

### wtr (`tui-branch-select`)
- `8f3c209` — dev-pinned tiny-tui to `:local/root "../tiny-tui"`.
- `3b480c1` (+ `2e0c3c3` fmt) — silent `cmds/create!` returning `{:ok? :name :path :from}`; CLI `create` wraps it (two-line output + `--sh` preserved, verified byte-identical).
- `565de2e` — `create` action (`c`): a `:returns?` action leaves select → `tui/input` (blank/existing-branch rejected inline) → `cmds/create!` → re-enter focused on the new worktree via `:cursor-item`. Failures surface as a status line; honors a global `--base-dir`.
- `b32235a` — README dashboard footer + create note.

### Codex review (Task 4)
Three rounds. Round 1 [P2]: create errors silently dropped → fixed with the tiny-tui `:status` seed + threading a `{:name/:status}` result. Round 2 [P2]: `--base-dir` override ignored on dashboard create → fixed by threading `(:base-dir (:global context))` through `pick!`. Round 3: clean.

### Verification
- `lgx check` (wtr): 45 tests / 119 assertions / 0 failures; lint 0/0; fmt clean.
- tiny-tui `lgx test`: 165 tests / 301 assertions / 0 failures. (`lgx check` lint has a **pre-existing** clj-kondo gap on `screen.lg`'s bare `(catch e …)` — present on untouched `HEAD`, no `.clj-kondo` config; my files lint clean. Not my regression.)
- Manual (built binary, isolated sandbox, pty): footer shows `c create`; `c` → type `new-x` → submit → worktree created under `--base-dir` (`wts/repo/new-x`), dashboard re-enters with the cursor on `› new-x`, `enter` opens a shell there (`pwd` = the new worktree); a duplicate name shows `Branch 'existing' already exists` inline and creates nothing; `wtr create`/`--sh` unchanged on the CLI.

### Follow-ups / notes
- Both tiny-cli and tiny-tui are now dev-pinned to local roots; publishing them and repinning wtr to released refs remains the user-driven release step (deferred, no pushes).
