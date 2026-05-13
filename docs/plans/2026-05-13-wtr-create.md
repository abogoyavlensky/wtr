# wtr create — implementation plan

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
  "Returns ~/.config/wtr/config.toml path")

(defn read-config []
  "Reads config file, returns {:base-dir \"/path\"} or nil if missing")

(defn write-config! [config]
  "Writes config map to file, creates parent dirs if needed")

(defn validate-base-dir! [path]
  "Validates path is absolute, throws ex-info if not")

(defn ensure-config! [override-base-dir]
  "Returns base-dir from override, config, or creates default config.
   Creates config on first run if missing.")
```

TOML parsing: Use simple string manipulation (read line, split on `=`, trim).
TOML writing: Simple string formatting.

### `src/wtr/git.lg` (enhance existing)

Add worktree creation operations to existing git module.

```clojure
(defn main-worktree-path []
  "Returns absolute path to main worktree (first entry from worktrees)")

(defn branch-exists? [name]
  "Returns true if branch exists (checks git branch --list)")

(defn create-worktree! [path branch from-ref]
  "Calls git worktree add. Throws ex-info on failure.")
```

### `src/wtr/commands.lg` (add create function)

Command handler that orchestrates config, validation, and git operations.

```clojure
(defn create [{:keys [global args opts]}]
  "Create a new worktree"
  (let [name (:name args)
        from-ref (:from opts)
        base-dir (config/ensure-config! (:base-dir global))
        main-path (git/main-worktree-path)
        project (basename main-path)
        wt-path (str base-dir "/" project "/" name)]
    
    ;; Validate
    (when (git/branch-exists? name)
      (error-exit "Branch '" name "' already exists"))
    (when (dir-exists? wt-path)
      (error-exit "Directory already exists: " wt-path))
    
    ;; Create
    (git/create-worktree! wt-path name from-ref)
    
    ;; Report
    (println "Created worktree at" wt-path)
    (println "Branch:" name (if from-ref (str "(from " from-ref ")") ""))))
```

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

### Step 2: Enhance git module

1. Edit `src/wtr/git.lg`
2. Implement `main-worktree-path` (use existing `worktrees` function)
3. Implement `branch-exists?` (call `git branch --list {name}`)
4. Implement `create-worktree!` (call `git worktree add`)
5. Write tests in `test/wtr/git_test.lg`:
   - `main-worktree-path` returns first worktree path
   - `branch-exists?` detects existing branches

### Step 3: Create command

1. Edit `src/wtr/commands.lg`
2. Implement `create` function with validation and orchestration
3. Add helper for directory existence check
4. Add helper for error-exit with message
5. Write tests in `test/wtr/commands_test.lg`:
   - Path construction logic
   - Validation logic (branch exists, dir exists)

### Step 4: Update main

1. Edit `main.lg`
2. Add `:opts` with `--base-dir` to app spec
3. Add `create` command to `:commands`
4. Verify help output shows new command and global option

### Step 5: Add tests for list command

1. Edit `test/wtr/format_test.lg`
2. Test column alignment with various path lengths
3. Test current worktree marker detection
4. Test ANSI color stripping for width calculation

### Step 6: Update README

1. Edit `README.md`
2. Add tool description and purpose
3. Document `list` command with example output
4. Document `create` command with examples
5. Document configuration file location and format
6. Add installation/build instructions

### Step 7: Verification

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

# Cleanup
git worktree remove {paths}
git branch -D {branches}
```

Run automated tests:
```bash
# Run test suite
lgx test
```

### Step 8: Commit

```bash
git add src/wtr/config.lg src/wtr/git.lg src/wtr/commands.lg main.lg
git add test/wtr/config_test.lg test/wtr/git_test.lg test/wtr/commands_test.lg test/wtr/format_test.lg
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
