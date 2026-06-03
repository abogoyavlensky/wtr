# wtr config — Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `wtr config` — a read-only command that prints the config file path and its content, or (when the file doesn't exist yet) the path plus the would-be default `base_dir`.

**Tech Stack:** let-go (Clojure-flavored, bundled to a native binary via lgx), tiny-cli (CLI arg framework), lgx (build/run).

Single-repo change, no release blocker — uses `slurp`/`file-exists?`/`os/sh` like the existing config and git code.

---

## Design

### Behavior

- Resolve `path` via the existing `config/config-path` (`~/.config/wtr/config.toml`).
- **File exists** → print the path and its raw content verbatim (`slurp`). No TOML parsing, so a hand-edited or malformed file is shown as-is — the right behavior for a read-only inspector. No git needed on this path.
- **File missing** → print the path with a `(not created yet)` note, the would-be default `base_dir` (`config/default-base-dir` applied to `git/main-worktree-path`), and a hint to run `wtr create`. Git is only touched here.
- Ignores the global `--base-dir` override entirely: `config` reports the on-disk file, not the effective per-invocation value.

### Output

```
# exists
Config: /Users/andrew/.config/wtr/config.toml

base_dir = "/Users/andrew/Projects/worktrees"

# missing
Config: /Users/andrew/.config/wtr/config.toml (not created yet)

Default base_dir: /Users/andrew/Projects/worktrees
Run 'wtr create <name>' to initialize it.
```

### Components

Mirrors the existing `list` → `render-list` split — IO in the command, a pure renderer that is unit-tested:

- **`config/render-config`** (pure, in `wtr.config`) — `[path content default]` → output string. `content` non-nil selects the exists branch (content shown, trailing whitespace trimmed); `content` nil selects the missing branch (uses `default`). No filesystem or git access, so it is unit-testable directly. Lives in `wtr.config` for cohesion with the other config helpers and is tested in `config_test.lg`.
- **`cmds/config`** (command handler, in `wtr.commands`) — resolves the path, branches on `file-exists?`, does the IO (`slurp` on exists; `git/main-worktree-path` + `config/default-base-dir` on missing), calls `config/render-config`, and `println`s the result. Wrapped in the same `try`/`catch` shape as `list`/`create`/`switch`.
- **`main.lg`** — register a `config` command entry (no args, no opts) after `switch`.

### Error handling

All errors flow through the shared `catch` → exit 1 (print git's `:stderr` when present, else `Error: <message>`):

- `$HOME` unset → `config/config-path` throws `HOME environment variable is not set`.
- Missing file *and* not in a git repo → `git/main-worktree-path` → `git/worktrees` throws `ex-info` carrying git's stderr (consistent with the other commands).

### Testing

Unit-test `config/render-config` for both branches. The command's IO (`slurp`, git) is not unit-tested — consistent with the project leaving filesystem/git paths to manual/smoke verification.

## File Structure

**wtr** (`/Users/andrew/Projects/wtr`)
- Modify: `src/wtr/config.lg` — add the pure `render-config`.
- Modify: `test/wtr/config_test.lg` — unit tests for `render-config` (both branches).
- Modify: `src/wtr/commands.lg` — add the `config` command handler.
- Modify: `main.lg` — register the `config` command.
- Modify: `README.md` — document `wtr config`.

No new files: every piece has a natural home in an existing namespace.

## Implementation Steps

Local toolchain invocation (per project memory — use local lg + lgx, not system installs):
`LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx …`
For brevity below, `LGX` = `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx`.

### Task 1: config/render-config (pure renderer)

**Files:**
- Modify: `src/wtr/config.lg`
- Test: `test/wtr/config_test.lg`

- [ ] **Step 1: Write failing tests** in `config_test.lg`:
  - exists: `(config/render-config "/h/.config/wtr/config.toml" "base_dir = \"/x\"\n" nil)` → `"Config: /h/.config/wtr/config.toml\n\nbase_dir = \"/x\""` (trailing newline of the content trimmed; no parsing).
  - missing: `(config/render-config "/h/.config/wtr/config.toml" nil "/x/worktrees")` → a string that contains the path, the `(not created yet)` note, `Default base_dir: /x/worktrees`, and the `Run 'wtr create` hint.
- [ ] **Step 2: Run tests, verify they fail**
  Run: `LGX test`
  Expected: FAIL (`render-config` undefined).
- [ ] **Step 3: Implement `render-config`** in `config.lg` per Design. Exists branch: `Config: <path>` + blank line + `(str/trimr content)`. Missing branch: `Config: <path> (not created yet)` + blank line + `Default base_dir: <default>` + newline + `Run 'wtr create <name>' to initialize it.`. The returned string has no trailing newline (the command `println`s it).
- [ ] **Step 4: Run tests, verify they pass**
  Run: `LGX test`
  Expected: PASS.
- [ ] **Step 5: Commit**
  `git commit -m "Add config/render-config"`

### Task 2: config command + wiring

**Files:**
- Modify: `src/wtr/commands.lg`, `main.lg`

- [ ] **Step 1: Implement `cmds/config`** in `commands.lg` per Design — `[context]` arg (unused, like `list`); resolve `(config/config-path)`; if `(file-exists? path)` print `(config/render-config path (slurp path) nil)`, else print `(config/render-config path nil (config/default-base-dir (git/main-worktree-path)))`; wrap in the shared `create`/`switch` `try`/`catch` (print `:stderr` when present, else `Error: <msg>`, then `os/exit 1`).
- [ ] **Step 2: Wire into `main.lg`** — add a `config` entry to `:commands` after `switch`: `:name "config"`, `:doc "Show the config file path and its content."`, no `:args`, `:run cmds/config`.
- [ ] **Step 3: Run tests + build**
  Run: `LGX test && LGX build`
  Expected: suite still green; `./bin/wtr help config` shows the command.
- [ ] **Step 4: Smoke-check both branches** against `./bin/wtr`:
  - With a config present (e.g. point `$HOME` at a temp dir holding `.config/wtr/config.toml`, or use your real one): `./bin/wtr config` prints `Config: <path>` then the file content.
  - With no config (temp `$HOME` with no config file, run from inside the repo): prints the `(not created yet)` note and `Default base_dir: …`.
- [ ] **Step 5: Commit**
  `git commit -m "Add wtr config command"`

### Task 3: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document `config`** — add a `### wtr config` section (after `wtr switch`): read-only inspector that prints the config file path and content, the missing-file behavior (path + would-be default + create hint), and that it reports the on-disk file (ignores `--base-dir`).
- [ ] **Step 2: Commit**
  `git commit -m "Document wtr config"`

## Out of scope (YAGNI)

- Editing/initializing config (`config set`, `--init`) — `config` is read-only; `create` already initializes.
- Surfacing the `--base-dir` override in the output — decided against; pure file inspector.
- Validating/parsing the TOML for display — raw content is shown verbatim.
