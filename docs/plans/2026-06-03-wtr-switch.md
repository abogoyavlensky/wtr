# wtr switch — Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add `wtr switch <name>` — flip the **main** worktree to a detached HEAD at a target worktree's branch tip so you can read/build/run that branch's code from your fully-set-up main project dir; `wtr switch master` (or `main`) re-attaches the main worktree to its branch as usual.

**Tech Stack:** let-go (Clojure-flavored, bundled to a native binary via lgx), tiny-cli (CLI arg framework, already supports the simple `:args` spec this command needs), lgx (build/run), Bash for smoke tests.

Single-repo change: only `wtr` is touched. Unlike `wtr run`, this command uses `os/sh` (not the unreleased `os/exec*`), so there is **no cross-repo dependency and no release blocker** — it builds on the current released toolchain.

---

## Background: why detached HEAD

A branch that is checked out in a worktree cannot be checked out again in another worktree — `git switch <branch>` from the main worktree would be refused with *"already used by worktree …"*. Detaching HEAD at that branch's tip (`git switch --detach <branch>`) sidesteps the restriction: the main worktree's working tree is populated with the branch's committed state, but no branch ref is moved or claimed. This is exactly what you want for "let me look at / build / run this branch from the dir where my env and tooling already live," without disturbing the feature worktree.

The round trip back is an ordinary, attached switch: `wtr switch master` runs `git switch master` in the main worktree, re-attaching it to its branch.

## Design

### 1. Command shape & UX

```
wtr switch <name>
```

- One required positional `<name>`, no command-specific options. The global `--base-dir` opt stays available (unused here — resolution is config-free — but consistent with the other commands).
- `wtr switch feat-x` → main worktree detaches at `feat-x`'s branch tip.
- `wtr switch master` / `wtr switch main` → main worktree re-attaches to that branch (ordinary switch).
- `wtr switch nope` (no matching worktree) → `Error: Worktree not found: nope` (exit 1).

Always operates on the **main** worktree (`git/main-worktree-path`, the first `git worktree list` entry), regardless of the current directory — so you can run it from anywhere, including from inside a feature worktree, and it flips the main project dir.

### 2. Name resolution (pure, config-free)

Resolve against the live `git worktree list`, reusing the suffix-match rule already proven in `resolve-worktree-path`. A new **pure** function returns an *intent* rather than a path, because `switch` needs the target's branch/sha and the reattach-vs-detach decision:

```clojure
;; src/wtr/commands.lg
(defn resolve-switch-target
  "Map (worktrees, name) to a switch intent, or nil when no worktree matches.
     master|main           -> {:mode :reattach :ref name}
     a matching worktree   -> {:mode :detach :ref <branch|head> :label name :sha <head>}
     otherwise             -> nil
   master/main are reserved tokens (re-attach the main worktree), shadowing any
   worktree literally named that — consistent with `run`. For detach, :ref is the
   worktree's branch (refs/heads/ stripped) so we land on the branch tip; if the
   worktree is itself detached (no :branch), :ref falls back to its :head sha."
  [wts name]
  ...)
```

- Worktree match: the worktree whose `:path` ends with `/<name>` (handles namespaced names like `feature/bar`, whose path is `…/<project>/feature/bar`).
- `:ref` (detach): `(:branch w)` with a leading `refs/heads/` stripped, else `(:head w)`.
- `:sha` (detach): `(:head w)` — used only for the confirmation message; after `git switch --detach <branch>`, HEAD equals the branch tip equals the worktree's head, so this is accurate without a second git call.
- `master`/`main` are matched **before** any worktree lookup.

Unit-testable with no git spawned, exactly like `resolve-worktree-path`.

### 3. Git side-effect (in `wtr.git`)

```clojure
(defn switch-ref!
  "git -C <main-path> switch [--detach] <ref>. Throws ex-info {:stderr ...} on
   non-zero exit (same shape as create-worktree!)."
  [main-path ref detach?]
  ...)
```

Builds `["git" "-C" main-path "switch"]`, conditionally inserts `"--detach"`, appends `ref`, runs via `os/sh`, and throws `ex-info` with `:stderr`/`:stdout` on failure. Not unit-tested against live git — consistent with `create-worktree!`, which the suite also leaves to smoke tests.

### 4. Command flow (`cmds/switch`)

```clojure
(defn switch
  [{:keys [args]}]
  (try
    (let [name   (:name args)
          wts    (git/worktrees)
          main   (:path (first wts))
          target (resolve-switch-target wts name)]
      (when-not target
        (error-exit (str "Worktree not found: " name)))
      (git/switch-ref! main (:ref target) (= :detach (:mode target)))
      (if (= :detach (:mode target))
        (println (str "Switched main worktree to '" (:label target)
                      "' (detached at " (subs (:sha target) 0 7)
                      "). Run 'wtr switch master' to return."))
        (println "Switched main worktree to" (:ref target))))
    (catch e :default
      ;; identical to create/run: print git stderr when present, else Error: msg
      ...)))
```

- Short sha is `(subs sha 0 7)` inline (mirrors `fmt/short-sha`, which is private to that ns).
- The `catch` block is the same shape used by `create` and `run`.

### 5. Error handling

- Not a git repo / `git worktree list` fails → `git/worktrees` throws `ex-info` with `:stderr`; the catch prints it and exits 1 (same as `list`/`create`/`run`).
- No matching worktree → `error-exit "Worktree not found: <name>"` (helper prepends `Error:`, exit 1).
- Missing `<name>` → tiny-cli "Missing argument" (exit 2), no code needed.
- `git switch` refuses (conflicting local changes in the main worktree, or `wtr switch main` in a master-only repo, etc.) → `switch-ref!` throws with git's stderr; the catch surfaces it verbatim, exit 1. No special dirty-state guard — thin wrapper, defer to git's own behavior (it carries cleanly-mergeable changes, refuses conflicting ones).

### 6. Caveat (documented, not coded)

Detaching at the branch **tip** reflects the branch's *committed* state. Uncommitted/working-tree changes living in the feature worktree do **not** appear in the main worktree — git cannot share a working tree across worktrees. The README will note this.

## File Structure

**wtr** (`/Users/andrew/Projects/wtr`)
- Modify: `src/wtr/commands.lg` — add `resolve-switch-target` (pure) and `switch` (command handler).
- Modify: `test/wtr/commands_test.lg` — unit tests for `resolve-switch-target` (extend the `sample-wts` fixture with `:branch`/`:head`).
- Modify: `src/wtr/git.lg` — add `switch-ref!`.
- Modify: `main.lg` — register the `switch` command (`:name`, `:doc`, one `:name` arg, `:run cmds/switch`).
- Modify: `README.md` — add a `wtr switch` section.

No new files: the command is small and every piece has a natural home in an existing namespace, matching how `create`/`list` are organized.

## Tasks

Local toolchain invocation (per project memory — use local lg + lgx, not system installs):
`LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx …`
For brevity below, `LGX` = `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx`.

### Task 1: wtr — resolve-switch-target (pure resolver)

**Files:**
- Modify: `src/wtr/commands.lg`
- Test: `test/wtr/commands_test.lg`

- [x] **Step 1: Write failing tests** in `commands_test.lg`. Extend `sample-wts` so non-main records carry `:branch` and `:head`, plus one detached record (`:head` present, no `:branch`):
  - `master` → `{:mode :reattach :ref "master"}`; `main` → `{:mode :reattach :ref "main"}`.
  - `feat-x` (branch `refs/heads/feat-x`, head `"8a1b2c3…"`) → `{:mode :detach :ref "feat-x" :label "feat-x" :sha "8a1b2c3…"}` (verifies `refs/heads/` stripping).
  - `feature/bar` (path `…/wtr/feature/bar`, branch `refs/heads/feature/bar`) → `:mode :detach`, `:ref "feature/bar"`, `:label "feature/bar"` (namespaced suffix match).
  - a detached worktree (no `:branch`) → `:ref` equals its `:head` sha.
  - `nope` → `nil`.
- [x] **Step 2: Run tests, verify they fail**
  Run: `LGX test`
  Expected: FAIL (`resolve-switch-target` undefined).
- [x] **Step 3: Implement `resolve-switch-target`** in `commands.lg` per Design §2. Reuse the existing suffix-match shape from `resolve-worktree-path`; strip a leading `refs/heads/` from `:branch` (e.g. `(str/replace branch #"^refs/heads/" "")`); fall back to `:head` when `:branch` is absent.
- [x] **Step 4: Run tests, verify they pass**
  Run: `LGX test`
  Expected: PASS.
- [x] **Step 5: Commit**
  `git commit -m "Add resolve-switch-target resolver"`

### Task 2: wtr — git/switch-ref!

**Files:**
- Modify: `src/wtr/git.lg`

- [x] **Step 1: Implement `switch-ref!`** per Design §3 — assemble the arg vector with a conditional `"--detach"`, run via `os/sh`, throw `ex-info` with `{:stderr (:err result) :stdout (:out result)}` on non-zero exit (mirror `create-worktree!`).
- [x] **Step 2: Sanity-check it compiles / loads**
  Run: `LGX test`
  Expected: PASS (existing suite still green; no new test — live-git side-effects are smoke-tested in Task 4, consistent with `create-worktree!`).
- [x] **Step 3: Commit**
  `git commit -m "Add git/switch-ref!"`

### Task 3: wtr — switch command + wiring

**Files:**
- Modify: `src/wtr/commands.lg`, `main.lg`

- [x] **Step 1: Implement `cmds/switch`** per Design §4 — resolve, `error-exit` on `nil`, call `git/switch-ref!`, print the mode-specific one-liner, with the shared `create`/`run` catch block.
- [x] **Step 2: Wire into `main.lg`** — add a `switch` entry to `:commands` with `:doc "Switch the main worktree to a worktree's branch (detached)."`, one arg `{:key :name :doc "Worktree name, or master/main to re-attach the main worktree."}`, and `:run cmds/switch`.
- [x] **Step 3: Build the binary**
  Run: `LGX build`
  Expected: builds `bin/wtr`; `./bin/wtr help switch` shows the command and its arg.
- [x] **Step 4: Commit**
  `git commit -m "Add wtr switch command"`

### Task 4: wtr — end-to-end smoke tests (built binary)

> **Caution:** `switch <name>` detaches the **main worktree it is run from** — i.e. your live wtr checkout. Run this matrix from a scratch clone (`git clone . /tmp/wtr-smoke-repo`), not the dir you are developing in, to avoid a confusing detached-HEAD surprise mid-development. Step 3's cleanup re-attaches regardless.

- [x] **Step 1: Setup** — from the wtr repo, create a couple of worktrees under a temp base, e.g.
  `./bin/wtr --base-dir /tmp/wtr-smoke create smoke-switch` and
  `./bin/wtr --base-dir /tmp/wtr-smoke create feature/bar`.
- [x] **Step 2: Run the matrix** against `./bin/wtr` from the main repo dir:
  - `switch smoke-switch` → prints `Switched main worktree to 'smoke-switch' (detached at …). Run 'wtr switch master' to return.`; `git -C . status` shows detached HEAD at the branch tip; `git worktree list` shows the main worktree detached.
  - `switch master` → prints `Switched main worktree to master`; main worktree re-attached to `master`.
  - `switch feature/bar` → namespaced name resolves and detaches; then `switch master` to return.
  - `switch nope` → `Error: Worktree not found: nope`, rc 1.
  - (Optional) dirty-state: make an uncommitted edit in the main worktree, `switch smoke-switch`, confirm git's own refuse/carry message surfaces and rc reflects it.
- [x] **Step 3: Cleanup** — `wtr switch master` to leave the repo attached; remove the temp worktrees + branches and `/tmp/wtr-smoke` (`git worktree remove` + `git branch -D`, or a future `wtr remove`).

### Task 5: wtr — README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Document `switch`** — add a `### wtr switch <name>` section after `wtr run`: what detached-switch is for (inspect/build a branch from your set-up main dir), an example showing the detach + `wtr switch master` round trip, the master/main shadowing note (consistent with `run`), and the caveat that it reflects the branch's **committed** state (uncommitted changes in the feature worktree won't show).
- [x] **Step 2: Commit**
  `git commit -m "Document wtr switch"`

## Risks and Notes

- **No release blocker.** `switch` uses `os/sh` only (like `worktrees`/`create-worktree!`), so it does not depend on let-go's unreleased `os/exec*`. It builds and ships on the current pinned toolchain (`lg 1.9.0`, `lgx 0.1.0-alpha12`, tiny-cli `v0.1.0-alpha7`).
- **`wtr switch main` in a master-only repo** (or vice-versa) fails with git's "invalid reference" — surfaced verbatim. Acceptable: the user knows their default branch (matches the bash `wt-switch` inspiration, which also switches to the literal token).
- **Re-attach can't be inferred from state.** After a detach, the main worktree has no current branch, so the reattach target must be the literal token the user types (`master`/`main`) — we don't try to recover the "original" branch. This is by design and matches the bash reference.
- **Reflects committed state only** — see Design §6; documented in the README.
- **POSIX/`/`-path assumptions** — same as the rest of wtr; Windows is already unsupported.

## Out of scope (YAGNI)

- Arbitrary-branch / ref switching for names that don't match a worktree (the bash `else` branch with `agent/` prefixing) — decided against; resolution is worktree-only, consistent with `run`, and the project dropped the `agent/` prefix.
- A dirty-worktree guard / auto-stash — defer to git's native behavior.
- Honoring `--base-dir` for resolution (config-free by design).
- Disambiguating two worktrees that share a name suffix (first match wins; same documented edge as `run`).

## Outcome (2026-06-03)

`wtr switch <name>` implemented and verified end-to-end. Single-repo change, no
release blocker. Commits on `master`:

- `32e8be5` — `resolve-switch-target` pure resolver + unit tests.
- `14e1d4f` — `git/switch-ref!` (mirrors `create-worktree!`).
- `37eea56` — `switch` command + `main.lg` wiring.
- `ee44b32` — codex review fix (see below).
- `374b3bf` — README section.

Final suite: **29 tests, 54 assertions, 0 failures.**

**Codex second-opinion review** (`review-with-codex`, scope `--base 278555d`)
returned four findings; three were false positives on unchanged pre-existing
code (`lgx.edn` is already a published `:git/tag`, not `:local/root`;
`resolve-worktree-path` already suffix-matches namespaced names;
`strip-runner-args` already requires both `LGX_RUN` and a `--` marker). One was
valid and in-scope and was fixed:

- The detach hint hardcoded *"Run 'wtr switch master' to return"*, which is wrong
  on a `main`-default repo. Now derived via `main-return-branch` from the main
  worktree's actual branch (captured before detaching); when the main worktree is
  already detached, it probes for a `main` branch, else falls back to `master`.
  Covered by a unit test (attached case) and verified live below.

**Smoke matrix** (built binary, throwaway scratch repos — never the live
checkout):
- master-default clone: detach shows `HEAD (no branch)` with main HEAD == the
  worktree's branch tip; `switch master` re-attaches (`## master...`); namespaced
  `feature/bar` detaches and returns; `switch nope` → `Error: Worktree not found:
  nope`, rc 1; hint reads `master`.
- main-default repo: `switch wt1` hint reads **`Run 'wtr switch main' to
  return.`**; `switch main` re-attaches to `main`. Confirms the hint fix.
