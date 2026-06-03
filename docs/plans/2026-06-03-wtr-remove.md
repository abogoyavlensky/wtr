# wtr remove — Implementation Plan

Status: Completed

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `wtr remove <name> [--force]` — remove a worktree and clean up its branch, safe by default (refuses on dirty worktree / unmerged branch) with `--force` to escalate.

**Tech Stack:** let-go (Clojure-flavored, bundled to a native binary via lgx), tiny-cli (CLI arg framework), lgx (build/run), Bash for smoke tests.

Single-repo change, no release blocker — uses `os/sh` like the existing git code.

---

## Design

### Safety posture

`wtr remove` is the most destructive command, so it is **safe by default** and
mirrors the symmetry with `create` (which makes the worktree *and* its branch):

- **Default:** `git worktree remove <dir>` (git refuses if the worktree is dirty)
  then `git branch -d <branch>` (git refuses if the branch isn't fully merged).
  If the branch is unmerged, the worktree is still removed and the branch is
  **kept** with a clear note — no work is silently lost.
- **`--force`:** `git worktree remove --force <dir>` then `git branch -D <branch>`
  — force both, for throwaway feature/agent branches.

Two guards baked in:
- **Refuse to remove the main worktree** (`master`/`main`, or any name that
  resolves to the first worktree entry) with a clean error, rather than letting
  git's own refusal leak.
- **No interactive confirmation prompt** — consistent with `run`/`switch`/`config`
  and the script/agent use case; `--force` is the only gate.

### Command shape & UX

```
wtr remove <name> [--force]
```

- `wtr remove feat-x` → removes the `feat-x` worktree; deletes branch `feat-x`
  if it is merged, otherwise keeps it with a note.
- `wtr remove feat-x --force` → removes the worktree even if dirty and
  force-deletes the branch.
- `wtr remove master` / `wtr remove main` → refused (main worktree).
- `wtr remove nope` → `Error: Worktree not found: nope` (exit 1).

### Resolution (pure, config-free)

A pure function returns a remove *intent*, mirroring `resolve-switch-target`:

```clojure
;; src/wtr/commands.lg
(defn resolve-remove-target
  "Map (worktrees `wts`, `name`) to a remove intent, or nil when nothing matches.
     master|main, or a name resolving to the main (first) worktree -> {:main? true}
     a matching non-main worktree -> {:path <abs> :branch <branch|nil>}
     otherwise                    -> nil
   Suffix match (path ends with `/<name>`) reuses the resolve-worktree-path rule
   so namespaced names like `feature/bar` work. :branch is the worktree's branch
   with a leading `refs/heads/` stripped, or nil when the worktree is detached
   (no branch to delete). The {:main? true} guard catches both the master/main
   aliases and the edge where a name suffix-matches the main worktree itself."
  [wts name]
  ...)
```

- `main-path` = `(:path (first wts))`.
- `master`/`main` → matched record is `(first wts)` → `{:main? true}`.
- else find the record whose `:path` ends with `/<name>`; nil when none; when its
  path equals `main-path` → `{:main? true}`; otherwise
  `{:path (:path rec) :branch <stripped :branch or nil>}`.

Unit-testable with no git spawned.

### Git side-effects (in `wtr.git`)

```clojure
(defn remove-worktree!
  "git -C <main> worktree remove [--force] <wt-path>. Throws ex-info {:stderr ...}
   on non-zero exit (fatal — caller aborts before touching the branch)."
  [main-path wt-path force?] ...)

(defn delete-branch!
  "git -C <main> branch (-d|-D) <branch>. Returns the os/sh result map (does NOT
   throw), so a safe-delete `not fully merged` refusal is a non-fatal outcome the
   caller can report and keep the branch."
  [main-path branch force?] ...)
```

- `remove-worktree!` builds `["git" "-C" main-path "worktree" "remove"]` + `(when force? ["--force"])` + `[wt-path]`; throws `ex-info` with `:stderr`/`:stdout` on non-zero (mirrors `create-worktree!`/`switch-ref!`).
- `delete-branch!` builds `["git" "-C" main-path "branch" (if force? "-D" "-d") branch]`; returns the `os/sh` result so the command inspects `:exit`/`:err`.

### Command flow (`cmds/remove`)

```clojure
(defn remove
  [{:keys [args opts]}]
  (try
    (let [name   (:name args)
          force? (:force opts)
          wts    (git/worktrees)
          main   (:path (first wts))
          target (resolve-remove-target wts name)]
      (cond
        (nil? target)      (error-exit (str "Worktree not found: " name))
        (:main? target)    (error-exit (str "Refusing to remove the main worktree: " name))
        :else
        (do
          (git/remove-worktree! main (:path target) force?)  ; throws -> caught
          (let [branch (:branch target)]
            (if branch
              (let [res (git/delete-branch! main branch force?)]
                (if (zero? (:exit res))
                  (println (str "Removed worktree " (:path target) " and branch " branch "."))
                  (println (str "Removed worktree " (:path target) ". Kept branch '" branch "': "
                                <git's primary reason from (:err res)>
                                " Re-run with --force to delete it."))))
              (println (str "Removed worktree " (:path target) ".")))))))
    (catch e :default
      ;; same shape as create/switch: print git stderr when present, else Error: msg
      ...)))
```

- The kept-branch path is **exit 0** — the worktree (the primary target) was removed; the branch is retained for safety with an actionable note.
- `<git's primary reason from (:err res)>` = the first non-blank line of `(:err res)`, trimmed (typically `the branch 'x' is not fully merged.`). Keep it compact; don't dump git's multi-line hint block. Guard the blank case: if `(:err res)` is empty, fall back to a generic reason (e.g. `could not delete branch`) so the note never renders with a dangling colon.

### Error handling

- Not a git repo / `git worktree list` fails → `git/worktrees` throws `ex-info` with `:stderr`; caught, printed, exit 1 (same as the other commands).
- No matching worktree → `error-exit "Worktree not found: <name>"` (exit 1).
- Main worktree target → `error-exit "Refusing to remove the main worktree: <name>"` (exit 1).
- Dirty worktree without `--force` → `remove-worktree!` throws git's stderr (e.g. `... contains modified or untracked files, use --force to delete it`) → caught, printed, exit 1. Git's own message already references `--force`.
- Missing `<name>` → tiny-cli "Missing argument" (exit 2), no code needed.

## File Structure

**wtr** (`/Users/andrew/Projects/wtr`)
- Modify: `src/wtr/git.lg` — add `remove-worktree!` and `delete-branch!`.
- Modify: `src/wtr/commands.lg` — add `resolve-remove-target` (pure) and `remove` (command).
- Modify: `test/wtr/commands_test.lg` — unit tests for `resolve-remove-target`.
- Modify: `main.lg` — register the `remove` command with the `--force` opt.
- Modify: `README.md` — add a `wtr remove` section.

No new files: every piece has a natural home in an existing namespace.

## Tasks

Local toolchain invocation (per project memory — use local lg + lgx, not system installs):
`LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx …`
For brevity below, `LGX` = `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx`.

### Task 1: wtr — git helpers (remove-worktree!, delete-branch!)

**Files:**
- Modify: `src/wtr/git.lg`

- [x] **Step 1: Implement `remove-worktree!`** per Design — conditional `--force`, `os/sh`, throw `ex-info {:stderr (:err result) :stdout (:out result)}` on non-zero (mirror `switch-ref!`).
- [x] **Step 2: Implement `delete-branch!`** per Design — `(if force? "-D" "-d")`, `os/sh`, **return** the result map (no throw).
- [x] **Step 3: Sanity-check it compiles**
  Run: `LGX test`
  Expected: PASS (existing suite still green; no new unit test — git side-effects are smoke-tested in Task 4, consistent with `create-worktree!`/`switch-ref!`).
- [x] **Step 4: Commit**
  `git commit -m "Add git/remove-worktree! and git/delete-branch!"`

### Task 2: wtr — resolve-remove-target (pure resolver)

**Files:**
- Modify: `src/wtr/commands.lg`
- Test: `test/wtr/commands_test.lg`

- [x] **Step 1: Write failing tests** in `commands_test.lg`. Add a fixture of worktree records (main + non-main with `:branch`, a namespaced one, a detached one with no `:branch`):
  - `master` / `main` → `{:main? true}`.
  - a name suffix-matching the **main** worktree (e.g. its dir basename) → `{:main? true}`.
  - `feat-x` (branch `refs/heads/feat-x`) → `{:path … :branch "feat-x"}` (verifies `refs/heads/` stripping).
  - `feature/bar` → `{:path … :branch "feature/bar"}` (namespaced suffix match).
  - a detached worktree (no `:branch`) → `{:path … :branch nil}`.
  - `nope` → `nil`.
- [x] **Step 2: Run tests, verify they fail**
  Run: `LGX test`
  Expected: FAIL (`resolve-remove-target` undefined).
- [x] **Step 3: Implement `resolve-remove-target`** per Design — reuse the suffix-match shape; compare the matched path to `main-path` for the `{:main? true}` guard; strip a leading `refs/heads/` from `:branch`, nil when absent.
- [x] **Step 4: Run tests, verify they pass**
  Run: `LGX test`
  Expected: PASS.
- [x] **Step 5: Commit**
  `git commit -m "Add resolve-remove-target resolver"`

### Task 3: wtr — remove command + wiring

**Files:**
- Modify: `src/wtr/commands.lg`, `main.lg`

- [x] **Step 1: Implement `cmds/remove`** per Design — `[{:keys [args opts]}]`; resolve; `cond` for not-found / main-worktree / else; `git/remove-worktree!` then (if branch) `git/delete-branch!` with the zero/non-zero message split (kept-branch is exit 0); shared try/catch.
- [x] **Step 2: Wire into `main.lg`** — add a `remove` entry to `:commands` after `config`: `:doc "Remove a worktree and clean up its branch."`, one arg `{:key :name :doc "Worktree name to remove."}`, one opt `{:key :force :long "force" :doc "Force removal of a dirty worktree and force-delete the branch."}` (boolean — no `:value?`), `:run cmds/remove`.
- [x] **Step 3: Build the binary**
  Run: `LGX build`
  Expected: builds `bin/wtr`; `./bin/wtr help remove` shows the command, its arg, and `--force`.
- [x] **Step 4: Commit**
  `git commit -m "Add wtr remove command"`

### Task 4: wtr — end-to-end smoke tests (built binary)

> **Caution:** run the matrix against a throwaway scratch repo, never the live wtr checkout — `remove` deletes worktrees and branches.

- [x] **Step 1: Setup** — `git clone <repo> /tmp/wtr-rm-repo`; from it, create worktrees under a temp base with `./bin/wtr --base-dir /tmp/wtr-rm-base create <name>`. Prepare: one branch with no unique commits (deletes cleanly with `-d`), one with an unmerged commit, and one with a dirty/uncommitted file.
- [x] **Step 2: Run the matrix** against `./bin/wtr` from the scratch repo dir:
  - `remove <merged>` → `Removed worktree … and branch <merged>.`; `git worktree list` and `git branch` confirm both gone.
  - `remove <unmerged>` (no `--force`) → worktree removed, branch **kept** with the note, exit 0; `git branch` shows it survives.
  - `remove <unmerged> --force` → branch now deleted.
  - dirty worktree, no `--force` → git's "contains modified or untracked files" error, exit 1; then `--force` removes it.
  - `remove master` / `remove main` → `Error: Refusing to remove the main worktree`, exit 1; main worktree intact.
  - `remove nope` → `Error: Worktree not found: nope`, exit 1.
- [x] **Step 3: Cleanup** — remove the scratch repo, temp base, and any leftover worktrees/branches; `rm -rf /tmp/wtr-rm-repo /tmp/wtr-rm-base`.

### Task 5: wtr — README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Document `remove`** — add a `### wtr remove <name>` section after `wtr config`: removes a worktree and cleans up its branch, the safe-by-default behavior (refuses dirty worktree / unmerged branch; branch kept with a note), `--force` to escalate, the main-worktree refusal, and that names resolve against `git worktree list` like the other commands.
- [x] **Step 2: Commit**
  `git commit -m "Document wtr remove"`

## Risks and Notes

- **No release blocker.** Uses `os/sh` only (like the rest of `wtr.git`); builds on the current pinned toolchain.
- **Kept-branch is exit 0.** Removing the worktree is the primary goal; an unmerged branch retained for safety is communicated via a note, not a failure. (Documented; revisit if scripts need to detect it.)
- **`delete-branch!` non-zero is assumed unmerged.** The kept-branch note surfaces git's first stderr line, so an unexpected reason is still visible to the user.
- **POSIX/`/`-path assumptions** — same as the rest of wtr; Windows is already unsupported.

## Out of scope (YAGNI)

- Interactive confirmation prompt — `--force` is the only gate; tool is non-interactive.
- Removing multiple worktrees in one call / globbing.
- A separate flag to keep the branch (`--keep-branch`) — default already keeps an unmerged branch; a merged branch is cheap to recreate.
- Pruning stale worktree metadata (`git worktree prune`).

## Implementation Summary

Completed on 2026-06-03.

- Added git helpers for removing worktrees and deleting branches.
- Added the pure `resolve-remove-target` resolver with unit coverage for main-worktree guards, namespaced names, detached worktrees, and missing targets.
- Added `wtr remove <name> [--force]` and wired it into CLI help.
- Verified with `LGX test`, `LGX build`, `./bin/wtr help remove`, and an end-to-end smoke matrix in a throwaway `/tmp` clone.
- Documented `wtr remove` in the README.

One smoke-test adjustment was needed: after a safe unmerged removal, the worktree no longer exists, so the force-unmerged path was verified with a separate unmerged worktree.
