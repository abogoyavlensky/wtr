# wtr create — implementation plan (completed 2026-05-13)

Implement the `create` subcommand of `wtr` in let-go. Creates new git worktrees
with automatic configuration management. See `docs/INITIAL_DESIGN.md` for the
broader tool vision.

## Goals

- Create worktrees in a configurable base directory with pattern `{base-dir}/{project}/{name}`
- Auto-create config file on first run with sensible defaults
- Support `--base-dir` global flag to override config
- Support `--from` option to create from specific branch/commit
- Validate inputs before calling git (fail on existing branch or directory)
- Clear error messages for all failure cases

Out of scope: other subcommands (`switch`, `cd`, `run`), shell completion,
branch prefix configuration. Those follow in later plans.

## Usage

```bash
# First run - creates config and worktree
$ wtr create feature-x
Created config at ~/.config/wtr/config.toml with base_dir = /Users/andrew/Projects/worktrees
Created worktree at /Users/andrew/Projects/worktrees/wtr/feature-x
Branch: feature-x

# Subsequent runs use config
$ wtr create bugfix-y
Created worktree at /Users/andrew/Projects/worktrees/wtr/bugfix-y
Branch: bugfix-y

# Override base directory
$ wtr --base-dir /tmp/test-worktrees create temp-feature
Created worktree at /tmp/test-worktrees/wtr/temp-feature
Branch: temp-feature

# Create from specific ref
$ wtr create hotfix --from main
Created worktree at /Users/andrew/Projects/worktrees/wtr/hotfix
Branch: hotfix (from main)
```

## Configuration

Config file: `~/.config/wtr/config.toml`

Format:
```toml
base_dir = "/absolute/path/to/worktrees"
```

**First-run behavior:**
- If config doesn't exist, resolve `../worktrees` relative to main worktree root
- Convert to absolute path
- Create `~/.config/wtr/` directory if needed
- Write config file
- Print message about config creation
- Continue with worktree creation

**Validation:**
- `base_dir` must be an absolute path
- Reject relative paths with clear error: `"Error: base_dir must be an absolute path, got: {path}"`

## Worktree Path Structure

Pattern: `{base-dir}/{project-name}/{worktree-name}`

Example:
- Main worktree: `/Users/andrew/Projects/wtr`
- Project name: `wtr` (basename of main worktree)
- Worktree name: `feature-x`
- Full path: `/Users/andrew/Projects/worktrees/wtr/feature-x`

## Branch Naming

No automatic prefix - use the name as-is. Users can include their own prefixes:
- `wtr create foo` → branch `foo`
- `wtr create agent/foo` → branch `agent/foo`
- `wtr create feature/bar` → branch `feature/bar`

## Error Handling

Fail fast with clear messages:

1. **Relative path in config:**
   ```
   Error: base_dir must be an absolute path, got: ../worktrees
   Edit ~/.config/wtr/config.toml to use an absolute path.
   ```

2. **Branch already exists:**
   ```
   Error: Branch 'feature-x' already exists
   ```

3. **Directory already exists:**
   ```
   Error: Directory already exists: /path/to/worktrees/wtr/feature-x
   ```

4. **Git command fails:**
   Pass through git's stderr and exit with code 1

5. **Invalid from-ref:**
   Git will report this naturally (e.g., "fatal: invalid reference: bad-ref")

All errors exit with code 1.

## Code Layout

Four components:

### `src/wtr/config.lg` (new)

Config file management and validation.

```clojure
(defn config-path []
  "Returns absolute path to ~/.config/wtr/config.toml.
   Implementation: resolve HOME via (os/getenv \"HOME\"); since let-go
   returns \"\" for unset vars (gotchas), guard with str/blank? and
   throw ex-info if HOME is unset. Concatenate with \"/.config/wtr/config.toml\".")

(defn read-config []
  "Reads config file, returns {:base-dir \"/path\"} or nil if missing.
   Use (file-exists? path) for existence check; (slurp path) to read.")

(defn write-config! [config]
  "Writes config map to file, creates parent dirs if needed.
   Use (mkdir parent-dir) — let-go's mkdir is recursive (wraps os.MkdirAll).
   Use (spit path content) to write.")

(defn validate-base-dir! [path]
  "Validates path is absolute (starts with \"/\"), throws ex-info if not.
   Error message: \"base_dir must be an absolute path, got: {path}\".")

(defn ensure-config! [override-base-dir main-worktree-path]
  "Returns base-dir from override, config, or creates default config.
   Creates config on first run if missing. Uses main-worktree-path to
   resolve default ../worktrees relative path.
   Prints \"Created config at <path> with base_dir = <dir>\" on first-run create.")
```

TOML parsing: Use simple string manipulation (read line, split on `=`, trim).
Match `key = "value"` lines only; ignore blanks and `#` comments.
TOML writing: Simple string formatting: `base_dir = "<absolute-path>"\n`.

Default base-dir derivation (when no override and no config file):
- Take `main-worktree-path` (e.g. `/Users/andrew/Projects/wtr`).
- Parent is `/Users/andrew/Projects`.
- Default base-dir is `/Users/andrew/Projects/worktrees` (sibling `worktrees` dir).
- Derive via `string/last-index-of` + `subs` (no need for an lgx.path dep).

### `src/wtr/git.lg` (enhance existing)

Add worktree creation operations to existing git module.

```clojure
(defn main-worktree-path []
  "Returns absolute path to main worktree.
   Implementation: (-> (worktrees) first :path)")

(defn branch-exists? [name]
  "Returns true if branch exists locally.
   Implementation: git rev-parse --verify refs/heads/<name>
   Check exit code: 0 = exists, non-zero = doesn't exist")

(defn create-worktree! [path branch from-ref]
  "Calls git worktree add. Throws ex-info on failure.
   When from-ref is nil: git worktree add <path> <branch>
   When from-ref is set: git worktree add -b <branch> <path> <from-ref>")
```

### `src/wtr/commands.lg` (add create function)

Command handler that orchestrates config, validation, and git operations.

```clojure
(defn- basename [path]
  "Last non-blank segment of a /-separated path.
   Implementation: (last (filter #(not (str/blank? %)) (str/split path \"/\")))")

(defn- error-exit [& msgs]
  "Prints \"Error: <msgs...>\" to stderr and exits with code 1.
   Implementation: (binding [*out* *err*] (apply println \"Error:\" msgs)) (os/exit 1)
   Callers MUST NOT include the \"Error:\" prefix in their message strings —
   error-exit prepends it.")

(defn create [{:keys [global args opts]}]
  "Create a new worktree"
  (let [name (:name args)
        from-ref (:from opts)
        main-path (git/main-worktree-path)
        base-dir (config/ensure-config! (:base-dir global) main-path)
        project (basename main-path)
        wt-path (str base-dir "/" project "/" name)]

    ;; Validate
    (when (git/branch-exists? name)
      (error-exit "Branch '" name "' already exists"))
    (when (file-exists? wt-path)
      (error-exit "Directory already exists:" wt-path))

    ;; Create
    (git/create-worktree! wt-path name from-ref)

    ;; Report
    (println "Created worktree at" wt-path)
    (if from-ref
      (println "Branch:" name (str "(from " from-ref ")"))
      (println "Branch:" name))))
```

Notes:
- `ensure-config!` takes `main-path` to resolve default `../worktrees` on first run.
- `tiny-cli` passes a context map of shape `{:global {...} :args {...} :opts {...}}`
  (confirmed in `tiny-cli`'s README). Destructuring above matches that contract.
- Use `file-exists?` (core fn) for directory existence — works for both files and
  directories per let-go's `os.Stat` semantics.
- Error message strings must NOT start with `"Error:"` — the helper prepends it.

### `main.lg` (update app spec)

Add global `--base-dir` option and `create` command.

```clojure
(def app
  {:name "wtr"
   :version "0.1.0"
   :doc "Small git worktree helper."
   :opts [{:key :base-dir
           :long "base-dir"
           :value? true
           :doc "Override base directory for worktrees."}]
   :commands [{:name "list"
               :doc "List worktrees."
               :run cmds/list}
              {:name "create"
               :doc "Create a new worktree."
               :args [{:key :name
                       :doc "Worktree name (used for directory and branch)."}]
               :opts [{:key :from
                       :long "from"
                       :value? true
                       :doc "Create from specific branch or commit."}]
               :run cmds/create}]})
```

## Implementation Steps

### Step 1: Config module

1. Create `src/wtr/config.lg`
2. Implement `config-path` (expand `~/.config/wtr/config.toml`)
3. Implement `read-config` (read file, parse TOML, return map or nil)
4. Implement `write-config!` (create dirs, write TOML)
5. Implement `validate-base-dir!` (check absolute path)
6. Implement `ensure-config!` (orchestrate config resolution and creation)
7. Write tests in `test/wtr/config_test.lg`:
   - `validate-base-dir!` rejects relative paths
   - `validate-base-dir!` accepts absolute paths
   - TOML parsing handles basic format
   - `ensure-config!` creates config on first run with correct default path
   - `ensure-config!` returns existing config on subsequent runs

### Step 2: Enhance git module

1. Edit `src/wtr/git.lg`
2. Implement `main-worktree-path` (use existing `worktrees` function)
3. Implement `branch-exists?` (call `git rev-parse --verify refs/heads/{name}`)
4. Implement `create-worktree!` (call `git worktree add`)
5. Write tests in `test/wtr/git_test.lg`:
   - `main-worktree-path` returns first worktree path
   - `branch-exists?` detects existing branches

### Step 3: Create command

1. Edit `src/wtr/commands.lg`
2. Implement `create` function with validation and orchestration
3. Add helper for directory existence check
4. Add helper for error-exit with message
5. Add tests to `test/wtr/commands_test.lg` (file exists but is empty):
   - Path construction logic
   - Validation logic (branch exists, dir exists)
   - Helper functions (dir-exists?, error-exit)

### Step 4: Update main

1. Edit `main.lg`
2. Add `:opts` with `--base-dir` to app spec
3. Add `create` command to `:commands`
4. Verify help output shows new command and global option

### Step 5: Update README

1. Edit `README.md`
2. Add tool description and purpose
3. Document `list` command with example output
4. Document `create` command with examples
5. Document configuration file location and format
6. Add installation/build instructions

### Step 6: Verification

Run smoke tests:

```bash
# Test 1: First run creates config
rm -f ~/.config/wtr/config.toml
wtr create test-first-run
# Verify: config created, worktree created, success message

# Test 2: Subsequent run uses config
wtr create test-second-run
# Verify: no config message, worktree created

# Test 3: Override with flag
wtr --base-dir /tmp/test-wtr create test-override
# Verify: worktree created in /tmp/test-wtr/wtr/test-override

# Test 4: Create from ref
wtr create test-from-main --from main
# Verify: worktree created from main branch

# Test 5: Fail on existing branch
wtr create test-first-run
# Verify: error message about existing branch

# Test 6: Fail on existing directory
mkdir -p {base-dir}/wtr/test-dir-exists
wtr create test-dir-exists
# Verify: error message about existing directory

# Test 7: Fail on relative path in config
echo 'base_dir = "../worktrees"' > ~/.config/wtr/config.toml
wtr create test-relative
# Verify: error message about absolute path requirement

# Cleanup (replace with actual paths/branches from tests above)
git worktree remove /path/to/test-worktree
git branch -D test-branch-name
```

Run automated tests:
```bash
# Local lgx invocation (system lgx may be missing/different)
lgx test
```

### Step 7: Commit

```bash
git add src/wtr/config.lg src/wtr/git.lg src/wtr/commands.lg main.lg
git add test/wtr/config_test.lg test/wtr/git_test.lg test/wtr/commands_test.lg
git add README.md
git commit -m "Implement wtr create command with config management"
```

## Risks and Notes

- **TOML parsing**: Using simple string manipulation instead of a full parser.
  Acceptable for single-setting config. If config grows complex, consider a
  proper TOML library.

- **Path handling**: Using string concatenation for paths. Let-go doesn't have
  a filepath library. Acceptable for Unix-style paths. Windows support would
  need path separator handling.

- **Config location**: Hardcoded to `~/.config/wtr/config.toml`. Standard for
  Unix tools. Could add `WTR_CONFIG` env var for override if needed.

- **First-run race**: If multiple `wtr create` commands run simultaneously on
  first use, both might try to create config. Acceptable - last write wins,
  both use same default path.

- **Directory creation**: `git worktree add` creates the directory. We only
  check if it exists beforehand. If directory is created between check and git
  call, git will fail naturally.

## Future Enhancements

Not in this plan, but noted for later:

- Branch prefix configuration (e.g., `branch_prefix = "agent"`)
- Per-project config (`.wtr.toml` in repo root)
- `wtr init` command for interactive config setup
- Config validation on read (warn about unknown keys)
- Shell completion for worktree names

## Outcome

All steps complete. Implementation matches the plan with two improvements:

- `read-config` now errors when the config file exists but is missing
  `base_dir`, rather than silently overwriting a user-edited but malformed
  config (caught in code review).
- The relative-path validation error includes the two-line message from the
  spec (the hint line was missing in the first pass).

`basename` is `defn` (not `defn-`) so it can be unit-tested.

Test results:
- `test/wtr/config_test.lg` — 7 tests, 11 assertions, 0 failures.
- `test/wtr/git_test.lg` — 3 tests, 4 assertions, 0 failures.
- `test/wtr/commands_test.lg` — 2 tests, 4 assertions, 0 failures.

Smoke tests verified end-to-end:
- First-run config creation under a fake `$HOME`.
- `--base-dir` override creates worktree at the override path.
- `--from <ref>` produces a worktree branched off that ref and reports it.
- Existing branch and existing directory both fail with clear errors and exit 1.
- Invalid `--from` ref: git's `fatal: invalid reference` passes through.
- Relative `base_dir` in config: rejected with the two-line spec error.
- Malformed config (no `base_dir` key): rejected without overwriting the file.

Known low-severity gaps left for a future plan (flagged in review):
- No validation of worktree-name inputs (e.g., names containing `..` or
  starting with `-`). Git rejects most malformed branch names itself; path
  traversal via `name = "../sneaky"` is a robustness gap, not a security one.
- TOML quote-stripping only fires when both ends are quoted; a single
  stray quote is returned verbatim.
