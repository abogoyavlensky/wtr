# Interactive Worktree Dashboard on Bare `wtr` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a bare `wtr` (no subcommand) launch an inline, arrow-key worktree list with action keybindings (starting with `run`), by adding a native root-command handler to tiny-cli.

**Tech Stack:** let-go (Clojure-like), tiny-cli (CLI framework, `../tiny-cli`), tiny-tui (terminal UI), lgx build tool.

---

## Design

### Problem

Today a bare `wtr` prints static root help. We want it to render an interactive list of the repo's worktrees where keybindings trigger actions — `run` first, more later. tiny-cli currently has no hook for this: when no command is named, its parser returns `{:status :help}` and prints `root-help`.

### Approach

Rather than intercept in `main.lg`, extend tiny-cli natively with an **optional app-level `:run` handler** — "what runs when no subcommand is named." wtr then registers `dashboard/show!` as that handler. No interception, and help/version/completion are untouched for free.

**Why the seam is safe.** In tiny-cli's `parse`, every help/version path (`help`, `--help`, `-h`, `--version`, `-v`) returns from *inside* the token loop. The only way to reach the end of the loop with `command == nil` is when every token was consumed as a global option — a genuinely bare invocation. `__complete` short-circuits even earlier in `run!`. So dispatching a root handler at that fall-through (core.cljc:656-665) cannot affect help, version, or completion.

### Flow

```
main → cli/run! app argv
          │
          ├─ subcommand named ──────────────→ that command's :run   (unchanged)
          ├─ help/version/completion ───────→ help/version/complete (unchanged)
          └─ no command token → app :run → dashboard/show!(context)
                                               ├─ tty  → tui/select (inline, actions) → run-in-dir!
                                               └─ non-tty → cmds/list (static worktree list)
```

### tiny-cli change (`../tiny-cli`)

- **Public API:** an optional top-level `:run` on the app map, a `(fn [context] …)` matching command runners. Deliberately minimal — not `:root {:run … :opts …}`; global `:opts` already cover a bare invocation, and that superset stays open for later without breaking `:run`.
- **Parser:** at the `parse` fall-through, when `command` is nil, dispatch `(:run app)` if present, else keep returning root help:
  ```clojure
  (if (:run app)
    (let [context (finalize-context app {} state)]   ; no args/opts → {:global … :args {} :opts {}}
      (if (= :error (:status context)) context
        {:status :ok :command {:run (:run app)} :context context}))
    {:status :help :command nil :text (root-help app)})
  ```
  `finalize-context` with an empty command map yields `{:global … :args {} :opts {}}` and still enforces required/invalid **global** options for the bare case. `run-result`/`run!` already invoke `(:run command)` for `:ok`, so no change is needed there.
- **Validation:** one guard in `app-spec-error` — if `:run` is present it must be a fn.
- `completion/install-command` uses `(update app :commands conj …)`, so it preserves the top-level `:run`; no change needed there.

### wtr change

- **`main.lg`:** add `:run dashboard/show!` to `app`. `(cli/run! app *command-line-args*)` stays as-is. `show!` needs no reference to `app` (the non-tty fallback is `cmds/list`, not root help), so there is no self-referential `def`.
- **`wtr.dashboard`:** the root handler and TUI.
  - `interactive?` → `(some? (term/size))` (tiny-tui throws off a tty).
  - `result->intent` (pure): map a `tui/select` result to `[:run name]` or `:cancel`.
  - `pick!` — build items from `completion/worktree-name-candidates`, run `tui/select` inline with `:actions [{:id :run :key "r" :label "run"}]` (enter also runs), then dispatch the intent. Accepts injectable opts (`:items`, `:run-fn`, plus tiny-tui's `:screen`/`:read-key-fn`/`:render-fn`) for headless tests.
  - `show!` (the handler): `(if (interactive?) (try (pick!) (catch … (cmds/list context))) (cmds/list context))`.
- **`wtr.commands`:** extract the exec tail of `run` into a public `run-in-dir! [dir cmd]` (clears `LGX_RUN`, classifies the command, mise-trust preflight for shell-backed modes, `os/exec*`). `run` calls it; the dashboard calls it with `[]` (interactive shell). Pure DRY refactor — `run-command-mode`/`run-exec-argv` tests stay green.

### Key decisions

- **List contents = tab-completion candidates** (`completion/worktree-name-candidates`: the `main`/`master` token plus worktree names). Each resolves to a real worktree path via `cmds/resolve-worktree-path`, so `run` always has a directory to cd into. Plain names for v1; branch/current markers are an easy later enrichment.
- **Bare `wtr` non-tty → static worktree list** (reuse `cmds/list`), not help. Bare `wtr` means "show my worktrees, interactively when possible" — one mental model across tty and pipe. This changes `wtr | cat` from help→list; `wtr --help` / `wtr help` still print help. Not-in-a-repo behaves exactly like `wtr list` (git error to stderr, exit 1).
- **Start with run + enter only.** switch/remove don't `exec` and would need a refresh loop around the TUI; deferred as a deliberate follow-up.

### Cross-repo workflow

tiny-cli and wtr are separate repos. Build and validate everything locally with wtr pinned to `:local/root "../tiny-cli"` (the commented pattern already in `lgx.edn`). The final task pins wtr back to a published tiny-cli ref — an outward-facing release step the user drives.

### Testing

- **tiny-cli** (`core_test.cljc`, portable across lg/clj/bb — keep tests at the pure `parse`/`run-result` level): bare + `:run` → handler dispatched with `:global`; bare, no `:run` → still `:help`; `--help`/`help`/`--version` with a `:run` present → still help/version.
- **wtr** (`dashboard_test.lg`): `result->intent` cases; a headless `pick!` wiring test via tiny-tui hooks (scripted `[:down :enter]` → `run-fn` gets the highlighted name; `[:esc]` → no run). `commands_test.lg` stays green through the refactor.
- **Manual:** `./bin/wtr` in a repo with a few worktrees — arrows navigate, enter/`r` opens a shell in the selected worktree, `q`/esc exits cleanly, `wtr --help` still prints help, `wtr | cat` prints the static list.

## File Structure

**`../tiny-cli` (land and commit first):**
- Modify `src/tiny_cli/core.cljc` — root handler at the `parse` fall-through; `:run` fn guard in `app-spec-error`.
- Modify `test/tiny_cli/core_test.cljc` — root-handler dispatch tests.
- Modify `README.md` — document app-level `:run` in the App Spec Reference.

**`wtr`:**
- Modify `lgx.edn` — tiny-cli dep: `:local/root "../tiny-cli"` for dev; a published ref to finish.
- Modify `src/wtr/commands.lg` — extract public `run-in-dir!`; `run` delegates to it.
- Create `src/wtr/dashboard.lg` — `interactive?`, `result->intent`, `pick!`, `show!`.
- Create `test/wtr/dashboard_test.lg` — `result->intent` + `pick!` wiring tests.
- Modify `main.lg` — register `:run dashboard/show!` on `app`.
- Modify `README.md` — document bare `wtr` dashboard and the non-tty fallback.

> Work on a branch in `../tiny-cli` too (not `master`). wtr is already on `tui-branch-select`.

---

### Task 1: Root-command handler in tiny-cli

**Files:**
- Modify: `../tiny-cli/src/tiny_cli/core.cljc`
- Test: `../tiny-cli/test/tiny_cli/core_test.cljc`

- [ ] **Step 1: Write the failing tests**
  In `core_test.cljc`, add a small app with a top-level `:run` handler (an `(fn [ctx] …)` that records `ctx` to an atom and returns a sentinel) and a global option plus `:version`. Assert via `core/parse` and `core/run-result`:
  - `core/parse app-with-run []` → `{:status :ok}` and `(:run (:command …))` is the handler; `run-result` invokes it and its `:context` carries a `:global` map.
  - a global option before the bare invocation (e.g. `["--flag" "x"]`) flows into the handler's `:global`.
  - `core/parse app-without-run []` → `{:status :help}` (unchanged).
  - with the `:run` handler present, `["--help"]`, `["help"]`, `["-h"]` → `{:status :help}`; `["--version"]` → `{:status :version}`.
  - `app-spec-error` rejects a non-fn `:run` (e.g. `:run 42`).

- [ ] **Step 2: Run tests to verify they fail**
  Run: `cd ../tiny-cli && lgx test`
  Expected: FAIL — bare invocation still returns `:help`; the non-fn `:run` guard does not exist yet.

- [ ] **Step 3: Implement the root handler**
  In `core.cljc`: at the `parse` fall-through (`command` nil branch, ~line 663), dispatch `(:run app)` when set — build `context` via `(finalize-context app {} state)`, return `{:status :ok :command {:run (:run app)} :context context}` (propagating a `:error` context), else keep the existing root-help result. In `app-spec-error`, add a branch: when `(contains? app :run)` and `(not (fn? (:run app)))`, return `(error-result "App :run must be a function.")`.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `cd ../tiny-cli && lgx test`
  Expected: PASS (new tests green, existing tests unaffected).

- [ ] **Step 5: Document the API**
  In `../tiny-cli/README.md` App Spec Reference, document the optional top-level `:run` — the handler run when no subcommand is named; receives the same `{:global :args :opts}` context (args/opts empty); help/version still win.

- [ ] **Step 6: Full check and commit**
  Run: `cd ../tiny-cli && lgx check`
  Expected: fmt clean, lint clean, `test-all` (lg + clj + bb) PASS.
  Then commit in `../tiny-cli`: `feat: add optional app-level :run root-command handler`

---

### Task 2: Point wtr at the local tiny-cli for development

**Files:**
- Modify: `lgx.edn`

- [ ] **Step 1: Switch the tiny-cli dep to a local root**
  In `lgx.edn`, change the `tiny-cli` dep to `{:local/root "../tiny-cli"}` (comment out the `:git/url`/`:git/tag` lines to restore later).

- [ ] **Step 2: Verify the dependency resolves**
  Run: `lgx test`
  Expected: the project still compiles and all existing tests PASS against the local tiny-cli.

- [ ] **Step 3: Commit**
  `chore: dev-pin tiny-cli to local root for dashboard work`

---

### Task 3: Extract `run-in-dir!` in commands

**Files:**
- Modify: `src/wtr/commands.lg`
- Test: `test/wtr/commands_test.lg` (existing — must stay green)

- [ ] **Step 1: Extract the exec tail**
  Add a public `run-in-dir! [dir cmd]` directly before `run`: `(os/setenv "LGX_RUN" "")`, then classify with `run-command-mode`, build argv with `run-exec-argv`, run `trust-mise-worktree!` for shell-backed modes, and `(os/exit (apply os/exec* argv))`. Give it a docstring: execs `cmd` (empty = interactive shell) in `dir`, replacing the process.

- [ ] **Step 2: Delegate from `run`**
  Rewrite `run`'s body to resolve `dir`, `error-exit` when not found, then call `(run-in-dir! dir cmd)`. Keep the surrounding `try`/`catch`.

- [ ] **Step 3: Run tests to verify no regression**
  Run: `lgx test`
  Expected: PASS — `run-command-mode` and `run-exec-argv` tests unchanged.

- [ ] **Step 4: Commit**
  `refactor: extract run-in-dir! from run command`

---

### Task 4: Dashboard namespace

**Files:**
- Create: `src/wtr/dashboard.lg`
- Test: `test/wtr/dashboard_test.lg`

- [ ] **Step 1: Write the failing tests**
  In `dashboard_test.lg`, add a `scripted` helper (returns queued messages then nil, as in tiny-tui's `core_test`). Test:
  - `result->intent` — `{:type :select :item "feat-x"}` → `[:run "feat-x"]`; `{:type :action :action :run :item "feat-x"}` → `[:run "feat-x"]`; `{:type :cancel}` → `:cancel`.
  - `pick!` wiring — call with `{:items ["main" "feat-x"] :run-fn <records to atom> :screen false :read-key-fn (scripted [:down :enter]) :render-fn (fn [_] nil)}`; assert the atom holds `"feat-x"`. A second case with `(scripted [:esc])` leaves the atom untouched (cancel runs nothing).

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — `wtr.dashboard` does not exist.

- [ ] **Step 3: Implement the namespace**
  Create `src/wtr/dashboard.lg` requiring `[term]`, `[tiny-tui.core :as tui]`, `[wtr.commands :as cmds]`, `[wtr.completion :as completion]`, `[wtr.git :as git]`. Implement:
  - `interactive?` → `(some? (term/size))`.
  - `result->intent` (pure) per the tests.
  - `run-name!` (private) → `(cmds/run-in-dir! (cmds/resolve-worktree-path (git/worktrees) name) [])`.
  - `pick!` — merge a base `{:title "Worktrees" :item->text identity :inline? true :actions [{:id :run :key "r" :label "run"}]}` with `(dissoc opts :run-fn)`; only add `:items (completion/worktree-name-candidates nil)` to the base when `opts` does not supply `:items` (so tests skip the git call). Call `tui/select`, then `(let [intent (result->intent result)] (when-not (= :cancel intent) ((:run-fn opts run-name!) (second intent))))`.
  - `show!` `[context]` — `(if (interactive?) (try (pick!) (catch Exception _ (cmds/list context))) (cmds/list context))`.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS.

- [ ] **Step 5: Commit**
  `feat: add interactive worktree dashboard namespace`

---

### Task 5: Register the root handler

**Files:**
- Modify: `main.lg`

- [ ] **Step 1: Wire the handler**
  Require `[wtr.dashboard :as dashboard]` in `main.lg` and add `:run dashboard/show!` to the `app` map (alongside `:name`/`:version`/`:doc`). Optionally tweak the `run` command's name-arg `:doc` to note it can also be reached from the bare-`wtr` dashboard.

- [ ] **Step 2: Build the binary**
  Run: `lgx build` (or the project's bundle command) to produce `bin/wtr`.
  Expected: builds without error.

- [ ] **Step 3: Manual verification**
  Use /run or drive `./bin/wtr` directly in a repo with a couple of worktrees. Confirm:
  - `./bin/wtr` shows the inline list; arrows navigate; enter and `r` open a shell in the selected worktree; `q`/esc exit cleanly with nothing run.
  - `./bin/wtr --help` and `./bin/wtr help` still print static help.
  - `./bin/wtr | cat` prints the static worktree list (non-tty fallback).

- [ ] **Step 4: Commit**
  `feat: launch worktree dashboard on bare wtr`

---

### Task 6: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document bare `wtr`**
  Add a short section (and a Commands-table/Quickstart mention) covering: bare `wtr` opens the interactive worktree dashboard on a terminal; `↑/↓` navigate, `enter`/`r` run (open a shell in the selected worktree), `q`/esc quit; help is at `wtr --help` / `wtr help`; piped/redirected, `wtr` prints the static worktree list. Note the interactive shell needs the built binary (same caveat as `wtr run`).

- [ ] **Step 2: Commit**
  `docs: document the bare wtr dashboard`

---

### Task 7: Publish tiny-cli and pin wtr (user-driven release)

**Files:**
- Modify: `lgx.edn`

- [ ] **Step 1: Push tiny-cli**
  With the user's go-ahead, push the `../tiny-cli` branch/change to GitHub and merge as they prefer. Optionally cut a release tag (`cd ../tiny-cli && lgx release <version>`), or note the merged commit sha.

- [ ] **Step 2: Pin wtr to the published ref**
  In `lgx.edn`, replace `:local/root "../tiny-cli"` with the published ref — `:git/url` + `:git/tag "v<version>"` (mirroring the current pin) or `:git/sha "<sha>"` (mirroring the tiny-tui pin).

- [ ] **Step 3: Full check against the pinned dependency**
  Run: `lgx check`
  Expected: fmt clean, lint clean, tests PASS against the published tiny-cli.

- [ ] **Step 4: Commit**
  `chore: pin tiny-cli to <ref> with root-command handler`
