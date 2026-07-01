# Protect Default Branches from Removal Implementation Plan

> **Status: ✅ Completed (2026-07-01).** See the Implementation Summary at the end.

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Protect the `main`/`master` default branch from `wtr remove` — hide it from `remove` completion — and fix the completion bug where both `main` and `master` are suggested even when the repo only has one.

**Tech Stack:** let-go (`.lg`), tiny-cli (`:complete` hooks), `lgx test` / `lgx check`.

---

## Design

### Background

`wtr` refers to the main worktree by two reserved tokens, `master` and `main`.
Both are hardcoded aliases for the first (main) worktree in
`resolve-worktree-path` / `resolve-switch-target` / `resolve-remove-target`,
regardless of the worktree's actual branch. `run`, `switch`, and `remove` share
one completion fn, `completion/worktree-name-candidates`, which always emits
`["main" "master"]` plus the non-main worktree names.

Two problems follow:

1. **Completion bug (run/switch):** both `main` and `master` are always
   suggested, even in a repo whose default branch is only one of them.
2. **Removal protection (remove):** `main`/`master` should never be offered as
   `remove` candidates, since removing the main worktree is disallowed.

### Already implemented — rejection

Rejecting `wtr remove master` / `wtr remove main` is **already done** and needs
no change:

- `commands/resolve-remove-target` maps `master`/`main` (and any name resolving
  to the main worktree path) to `{:main? true}`.
- `commands/remove` errors on `{:main? true}` with *"Refusing to remove the main
  worktree: <name>"* via `error-exit` (exit 1).
- Covered by `resolve-remove-target-main-guard` in `commands_test.lg` and
  documented in `README.md` (remove section).

This plan keeps that guard as-is and only changes completion.

### Change A — run/switch completion shows the real default branch

Replace the hardcoded `["main" "master"]` with a single canonical token derived
from the main worktree (`first wts`):

- **`completion/default-branch-token`** — given the main worktree record,
  returns exactly one of `"main"` / `"master"`:
  - if its branch (with `refs/heads/` stripped) is `main` or `master`, return
    that;
  - otherwise (detached, or on a custom branch) fall back to whichever of
    `main` / `master` exists as a local branch, preferring `main` — mirroring
    the existing `commands/main-return-branch` fallback.

  It returns only `main`/`master` (never a custom branch name) because those are
  the only reserved aliases that actually resolve to the main worktree.

`worktree-name-candidates` becomes `[default-token] ++ non-main-names`.

### Change B — remove completion hides main/master

Add **`completion/removable-worktree-name-candidates`**, returning only the
non-main worktree names (no default-branch token). Point `remove`'s `:complete`
at it in `main.lg`; `run` and `switch` keep `worktree-name-candidates`.

### Shared refactor

Both candidate fns compute the same base-prefix from config and derive non-main
names. Extract a private **`completion/names-with-prefix`** for that shared
logic so the two public fns stay thin.

### Key decisions

1. **Runtime resolution is unchanged** — both `main` and `master` still resolve
   to the main worktree everywhere. Only what completion *suggests* changes.
2. **`default-branch-token` returns only `main`/`master`.** Custom-branch or
   detached main worktrees fall back to whichever of the two exists (main
   preferred).
3. **Token logic lives in `completion`, not shared with `main-return-branch`.**
   They diverge on custom-branch main worktrees: switch-back advice wants the
   real branch, completion needs a token that resolves.
4. **No code change for rejection** — already guarded, tested, documented.

### Testing strategy

`completion_test.lg` drives tiny-cli's engine against a wtr-shaped mirror app
using `constantly` fixtures for the `:complete` fns, plus pure unit tests for
`completion`'s own derivations. This plan:

- splits the single `wt-names` fixture into a run/switch fixture (one default
  token + names) and a remove fixture (names only), and updates the affected
  engine expectations;
- adds unit tests for `default-branch-token` (attached-main cases, which are
  pure — the git-fallback branches hit a real repo and are left uncovered, as
  `main-return-branch` tests already do).

## File Structure

- **Modify** `src/wtr/completion.lg` — add `default-branch-token`, private
  `names-with-prefix`; rewrite `worktree-name-candidates`; add
  `removable-worktree-name-candidates`.
- **Modify** `main.lg` — `remove`'s arg `:complete` →
  `completion/removable-worktree-name-candidates`.
- **Modify** `test/wtr/completion_test.lg` — split fixtures, update
  expectations, add `default-branch-token` tests.
- **Modify** `README.md` — one line in the remove section noting `main`/`master`
  are excluded from `remove` completion.

---

### Task 1: `default-branch-token` + single-token run/switch completion

**Files:**
- Modify: `src/wtr/completion.lg`
- Test: `test/wtr/completion_test.lg`

- [x] **Step 1: Write the failing tests**
  In `completion_test.lg`, add a `default-branch-token-derivation` deftest:
  - `{:branch "refs/heads/master"}` → `"master"`
  - `{:branch "refs/heads/main"}` → `"main"`
  These are the pure, repo-free cases (attached main worktree).

- [x] **Step 2: Run tests to verify they fail**
  Run: `lgx test`
  Expected: FAIL — `wtr.completion/default-branch-token` is unresolved.

- [x] **Step 3: Implement `default-branch-token` and rewrite `worktree-name-candidates`**
  In `completion.lg`:
  - Add `default-branch-token` taking the main worktree record: strip
    `refs/heads/` from `:branch`; if the result is `"main"`/`"master"` return
    it; else return `"main"` when `git/branch-exists?` `"main"`, otherwise
    `"master"`. Add a docstring stating it only ever returns `main`/`master`.
  - Extract private `names-with-prefix` (the current config/base-prefix +
    `worktree-names` logic from `worktree-name-candidates`).
  - Rewrite `worktree-name-candidates` as
    `(into [(default-branch-token (first wts))] (names-with-prefix wts))`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lgx test`
  Expected: PASS for the new deftest. (Engine tests asserting `["main" "master" …]`
  still use the `constantly` fixture, so they are unaffected until Task 3.)

- [x] **Step 5: Commit**
  `git commit -am "Show only the real default branch in run/switch completion"`

### Task 2: Remove completion hides main/master

**Files:**
- Modify: `src/wtr/completion.lg`
- Modify: `main.lg`

- [x] **Step 1: Add `removable-worktree-name-candidates`**
  In `completion.lg`, add `removable-worktree-name-candidates` returning
  `(names-with-prefix (git/worktrees))` — non-main names only, no default token.
  Docstring: main/master are protected and never offered for `remove`.

- [x] **Step 2: Wire it into `main.lg`**
  In the `remove` command's `:args`, change the name arg's `:complete` from
  `completion/worktree-name-candidates` to
  `completion/removable-worktree-name-candidates`. Leave `run`/`switch` on
  `worktree-name-candidates`.

- [x] **Step 3: Verify build and checks**
  Run: `lgx check`
  Expected: PASS (fmt, lint, test all green).

- [x] **Step 4: Commit**
  `git commit -am "Hide main/master from wtr remove completion"`

### Task 3: Update engine-wiring tests for the split fixtures

**Files:**
- Modify: `test/wtr/completion_test.lg`

- [x] **Step 1: Split the fixture**
  Replace the single `wt-names` fixture with two:
  - `run-switch-names` → `(constantly ["master" "feat-x" "feature/bar"])`
    (one default token + names, matching the new `worktree-name-candidates`);
  - `remove-names` → `(constantly ["feat-x" "feature/bar"])` (names only).
  Update the mirror `app`: `run`/`switch` use `run-switch-names`, `remove` uses
  `remove-names`. Update the fixture comment to describe both fns.

- [x] **Step 2: Update affected expectations**
  In `candidates-worktree-names`:
  - `switch ""` → `["master" "feat-x" "feature/bar"]`.
  - `remove --force ""` ("a flag does not consume the name slot") →
    `["feat-x" "feature/bar"]`.
  Leave prefix-filtered assertions (`remove "feat"`, `run "feature"`) and the
  "completes nothing" cases unchanged — they already exclude main/master.

- [x] **Step 3: Run the full suite**
  Run: `lgx test`
  Expected: PASS.

- [x] **Step 4: Commit**
  `git commit -am "Split completion test fixtures for run/switch vs remove"`

### Task 4: Document the completion behavior

**Files:**
- Modify: `README.md`

- [x] **Step 1: Add a note to the remove section**
  After the existing "`wtr remove master` and `wtr remove main` are always
  refused …" paragraph, add one sentence: `main`/`master` are also excluded from
  `wtr remove` shell completion. Use /writing-clearly.

- [x] **Step 2: Verify checks still pass**
  Run: `lgx check`
  Expected: PASS.

- [x] **Step 3: Commit**
  `git commit -am "Document main/master exclusion from remove completion"`

---

## Implementation Summary

All four tasks landed, plus one review-driven fix. Delivered across five commits
on `master` (`524cc67`, `147d4fa`, `0effa70`, `7652925`, `2bb68d5`), following
the plan doc commit `66309e7`.

**What shipped:**

- **`completion/default-branch-token`** — derives the single canonical
  completion token for the main worktree (`main`/`master`), so run/switch
  completion now suggests the repo's *actual* default branch instead of always
  offering both. Fixes the reported bug.
- **`completion/removable-worktree-name-candidates`** — remove completion now
  offers only non-main worktree names; `main`/`master` are excluded.
- **`main.lg`** — `remove`'s `:complete` rewired to the new fn; run/switch keep
  `worktree-name-candidates`.
- Private **`names-with-prefix`** extracted to share the config/base-prefix
  derivation between both candidate fns.
- **README** remove section notes the completion exclusion.

**Rejection was already implemented** — `resolve-remove-target` +
`commands/remove` already refuse `wtr remove main`/`master`; no code change
needed, as the design anticipated.

**Codex second-opinion review (P2, fixed):** a secondary worktree literally
named `main`/`master` (shadowed by the reserved alias, hence un-removable) could
still leak into remove completion. Added the pure, tested helper
**`completion/removable-names`** to drop exact `main`/`master` (keeping
namespaced names like `feature/main`), wired into
`removable-worktree-name-candidates`.

**Verification:** `lgx check` green throughout — final run **42 tests, 110
assertions, 0 failures**, lint 0 errors/0 warnings, fmt clean. No blockers.
