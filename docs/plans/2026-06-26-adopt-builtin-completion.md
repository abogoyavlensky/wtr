# Adopt tiny-cli Built-in Completion Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace wtr's hand-rolled shell completion with tiny-cli's built-in completion, keeping only wtr's app-specific worktree-name logic as a `:complete` fn. User-facing behavior is unchanged. All existing completion tests are kept — rewired to exercise tiny-cli's engine against wtr's app shape, re-confirming the built-in.

**Tech Stack:** let-go (`.lg`), tiny-cli (consumed via `:local/root` to the `auto-completion` branch), `lgx test` / `lgx check` / `lgx build`. This plan spans two repos:
- **tiny-cli** — `/Users/andrew/Projects/worktrees/tiny-cli/auto-completion` (branch `auto-completion`).
- **wtr** — `/Users/andrew/Projects/wtr` (branch `auto-completion-from-tiny-cli`).

---

## Design

### Background

tiny-cli now ships built-in shell completion: a hidden `completion <shell>`
command, a hidden `__complete` endpoint intercepted in `run!`, generated
bash/zsh/fish scripts, command/flag/help completion from the app spec, and a
`:complete` hook (a vector or `(fn [ctx])`) on any arg/option spec for dynamic
values. wtr's `lgx.edn` already points `tiny-cli` at the `auto-completion`
branch via `:local/root`.

wtr currently re-implements all of this by hand: a `completion` command, a
`__complete` interception in `main.lg`, a pure `candidates` engine, three
bundled resource scripts, and a `complete!` I/O entry point. Everything except
the worktree-name derivation is now redundant.

### tiny-cli fix (prerequisite)

Rewiring wtr's kept tests surfaced one genuine tiny-cli bug: `help <command>
<TAB>` re-offers command names, but `help` takes exactly one positional, so a
second argument is invalid (`help list extra` → "Too many arguments for
help."). The correct behavior — wtr's original — is to offer nothing once
help's one arg is filled, exactly as a normal command stops offering candidates
past its fixed args.

Fix tiny-cli's `candidates` `:help` branch to return `[]` when a positional is
already present:

```clojure
(= :help command)
(if (empty? positionals)
  (vec (remove #(= "help" %) (command-name-candidates app)))
  [])
```

This lands on the `auto-completion` branch that wtr consumes, with a matching
tiny-cli test. It is the only behavioral change; every other completion case is
already identical between the two engines (verified).

### wtr changes

**`src/wtr/completion.lg` — slim to its worktree-name core.** Keep `basename`
and the pure `worktree-names` verbatim. Replace everything else (`candidates`,
`split-context`, `value-taking-longs`, `find-command`, `long-flags`,
`command-names`, `completion-script`, `completion`, `complete!`, `shells`,
`worktree-arg-commands`) with one I/O function that *is* the `:complete` hook —
the old `complete!` names-fn body plus the `main`/`master` aliases that
`candidates` used to prepend:

```clojure
(defn worktree-name-candidates
  "Completion candidates for a worktree-name positional (run/switch/remove):
   main/master plus existing non-main worktree names, from git + config.
   Used as a tiny-cli :complete fn — tiny-cli wraps __complete in try/catch, so
   a non-repo or bad-config state simply yields no candidates."
  [_ctx]
  (let [wts (git/worktrees)
        base (:base-dir (config/read-config))
        prefix (when-not (str/blank? (or base ""))
                 (str base "/" (basename (:path (first wts))) "/"))]
    (into ["main" "master"] (worktree-names wts prefix))))
```

The namespace then requires only `clojure.string`, `wtr.config`, and `wtr.git`.

**`main.lg` — three edits:**
- Add `:complete completion/worktree-name-candidates` to the `:name` arg of the
  `run`, `switch`, and `remove` commands.
- Remove the entire `completion` command from `:commands` (tiny-cli injects its
  own hidden one).
- Simplify `main` to `(defn- main [] (cli/run! app (cli-argv os/args)))` —
  delete the `__complete` `if` and its comment; tiny-cli's `run!` intercepts
  `__complete`. `cli-argv` stripping is unchanged, so the binary still feeds
  `wtr __complete …` straight through. The `[wtr.completion :as completion]`
  require stays (now used for `:complete`).

**Delete** `resources/completions/wtr.bash`, `wtr.zsh`, `wtr.fish`. Keep
`:resource-paths ["resources"]` in `lgx.edn` — still needed for
`resources/VERSION`.

**`lgx.edn`** already has the `:local/root` dep (done by the user). No README
change: `wtr completion <shell>` and the "dynamic worktree names" behavior are
identical, so every install snippet stays accurate.

### Tests — keep all, rewired to tiny-cli

`test/wtr/completion_test.lg` keeps every case; the `candidates-*` and
`completion-scripts` blocks now drive tiny-cli's engine against a wtr-mirror
app, re-confirming the built-in through wtr's real shape:

- Require `[tiny-cli.completion :as tc]` alongside `[wtr.completion :as
  completion]`.
- The mirror `app` drops its own `completion` command and gives the `run` /
  `switch` / `remove` `:name` args `:complete (fn [_ctx] ["main" "master"
  "feat-x" "feature/bar"])` — the fixture that the worktree-name assertions
  expect. (Subcommand/flag tests never invoke these fns.)
- Derive `iapp` once: `(def iapp (tc/install-command app))` so the injected
  hidden `completion` command is present, and assert against `(tc/candidates
  iapp words cur)` — the 3-arg signature (no names-fn param; the `:complete`
  fns supply the names).
- `candidates`-style assertions carry over verbatim, including
  `(tc/candidates iapp ["help" "list"] "")` → `[]` (the case the tiny-cli fix
  enables).
- `completion-scripts` block asserts `(tc/script {:name "wtr"} shell)` is
  non-blank and contains `__complete` for each shell, and `nil` for an unknown
  shell.
- `worktree-names-derivation` stays on `wtr.completion/worktree-names`,
  unchanged.

No unit test is added for `worktree-name-candidates` (a thin git+config I/O
wrapper, like the old `complete!` — covered by the smoke check).

### Behavioral parity

Every case wtr's old engine handled is reproduced by tiny-cli's engine plus the
one `:complete` fn: worktree names + `main`/`master` for run/switch/remove,
shells after `completion`, command names after `help` (now correctly empty once
help's arg is filled), flags, empty after `run <name>` (variadic → file
fallback), nothing for `create`. No user-visible change.

## File Structure

**tiny-cli repo** (`/Users/andrew/Projects/worktrees/tiny-cli/auto-completion`):
- Modify: `src/tiny_cli/completion.cljc` — the `:help` branch of `candidates`.
- Modify: `test/tiny_cli/completion_test.cljc` — add the filled-help-arg case.

**wtr repo** (`/Users/andrew/Projects/wtr`):
- Modify: `src/wtr/completion.lg` — slim to `basename`, `worktree-names`,
  `worktree-name-candidates`.
- Modify: `main.lg` — wire `:complete`, drop the `completion` command, simplify
  `main`.
- Delete: `resources/completions/wtr.bash`, `wtr.zsh`, `wtr.fish`.
- Modify: `test/wtr/completion_test.lg` — rewire to tiny-cli, keep all cases.

## Implementation Steps

### Task 1: Fix the tiny-cli help-arg edge case (tiny-cli repo)

All commands run in `/Users/andrew/Projects/worktrees/tiny-cli/auto-completion`.

**Files:**
- Modify: `src/tiny_cli/completion.cljc`
- Test: `test/tiny_cli/completion_test.cljc`

- [x] **Step 1: Add the failing test**
  In the `candidates-commands` deftest, add a case:
  `(is (= [] (completion/candidates app ["help" "list"] "")))` with a
  `testing` label like "help offers nothing once its command arg is filled".

- [x] **Step 2: Run it and watch it fail**
  Run: `lgx test`
  Expected: FAIL — current `:help` branch returns command names, not `[]`.

- [x] **Step 3: Fix the `:help` branch**
  In `candidates`, change the `(= :help command)` branch to return the
  command-name candidates only when `(empty? positionals)`, else `[]` (see
  Design).

- [x] **Step 4: Verify**
  Run: `lgx test` then `lgx test-all`
  Expected: PASS on let-go, Clojure, and Babashka.

- [x] **Step 5: Commit (tiny-cli repo)**
  `git commit -m "fix: stop completing help's second positional"`

### Task 2: Slim wtr.completion and rewire main.lg (wtr repo)

All commands run in `/Users/andrew/Projects/wtr`.

**Files:**
- Modify: `src/wtr/completion.lg`
- Modify: `main.lg`
- Delete: `resources/completions/wtr.bash`, `wtr.zsh`, `wtr.fish`

- [x] **Step 1: Slim `src/wtr/completion.lg`**
  Reduce the namespace to `basename`, the pure `worktree-names` (verbatim), and
  the new `worktree-name-candidates` (see Design). Drop the `io`/`os` requires
  and everything tiny-cli now provides. Keep `clojure.string`, `wtr.config`,
  `wtr.git`.

- [x] **Step 2: Rewire `main.lg`**
  Add `:complete completion/worktree-name-candidates` to the `:name` arg of
  `run`, `switch`, and `remove`. Remove the `completion` command from
  `:commands`. Simplify `main` to `(cli/run! app (cli-argv os/args))`, deleting
  the `__complete` branch and its comment. Keep the `wtr.completion` require.

- [x] **Step 3: Delete the bundled scripts**
  Run: `git rm resources/completions/wtr.bash resources/completions/wtr.zsh resources/completions/wtr.fish`

- [x] **Step 4: Verify compilation and the kept derivation tests**
  Run: `lgx test`
  Expected: the suite loads (no missing-var errors from the slimmed namespace);
  `worktree-names-derivation` passes. The rewired candidate tests come in
  Task 3 — if they reference removed vars at this point, proceed to Task 3
  before judging the full suite.

- [x] **Step 5: Commit (wtr repo)**
  `git commit -m "refactor: adopt tiny-cli built-in completion"`

### Task 3: Rewire the completion tests, keeping every case (wtr repo)

All commands run in `/Users/andrew/Projects/wtr`.

**Files:**
- Modify: `test/wtr/completion_test.lg`

- [x] **Step 1: Rewrite the test to drive tiny-cli**
  Per the Design "Tests" section: require `[tiny-cli.completion :as tc]`; give
  the mirror `app` `:complete` fns on run/switch/remove `:name` and drop its
  `completion` command; derive `(def iapp (tc/install-command app))`; replace
  every `completion/candidates app … names-fn` call with
  `(tc/candidates iapp words cur)` (3 args); replace the `completion-scripts`
  block with `(tc/script {:name "wtr"} shell)` assertions; assert
  `(tc/candidates iapp ["help" "list"] "")` → `[]`. Keep
  `worktree-names-derivation` on `wtr.completion/worktree-names`. Keep every
  existing case.

- [x] **Step 2: Run the full wtr suite**
  Run: `lgx test`
  Expected: PASS — all kept completion cases plus the rest of wtr's tests.

- [x] **Step 3: Commit (wtr repo)**
  `git commit -m "test: re-confirm tiny-cli completion through wtr"`

### Task 4: Full checks and binary smoke test (wtr repo)

All commands run in `/Users/andrew/Projects/wtr`.

- [ ] **Step 1: Run the full gate**
  Run: `lgx check`
  Expected: fmt clean, lint clean, `lgx test` green.

- [ ] **Step 2: Build and smoke-test the binary**
  Run: `lgx build`, then from inside a git repo:
  - `bin/wtr completion bash` prints a script containing `__complete`.
  - `bin/wtr __complete ""` lists `list create run switch remove config
    completion help`.
  - `bin/wtr __complete sw` → `switch`.
  - `bin/wtr __complete remove ""` → `main` `master` plus this repo's worktree
    names.
  - `bin/wtr __complete create ""` and `bin/wtr __complete run feat-x ""` →
    empty.
  - `bin/wtr __complete help list ""` → empty (the fixed help-arg case).
  - `bin/wtr completion powershell` → error on stderr, exit 2.
  - `__complete` run outside a git repo → empty, exit 0.
  - Optionally `source <(bin/wtr completion bash)` and drive `_wtr_complete`
    with a mock `COMP_WORDS` to confirm the real bash path (binary path as
    `COMP_WORDS[0]`).

- [ ] **Step 3: No commit needed**
  `lgx fmt` (inside `lgx check`) may reformat; if so, commit any formatting with
  `git commit -m "style: format"`. Otherwise nothing to commit.

## Follow-up (out of scope)

Once tiny-cli is released and tagged, switch wtr's `lgx.edn` dep from
`:local/root` back to `:git/tag` (the commented lines already in the file).

## Implementation Summary

_(Filled in after implementation.)_
