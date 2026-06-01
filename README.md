# WTR - Git [w]ork[t]ree [r]outer

WTR is a small tool to manage multiple git worktrees. It removes the need to
remember absolute paths and standardises a layout so that every worktree of a
project lives under a single base directory.

## Commands

### `wtr list`

Lists every worktree of the current repository with a short commit and the
branch label. The current worktree is marked with `*`.

```
$ wtr list
   PATH                                          COMMIT   BRANCH
*  /Users/andrew/Projects/wtr                    3270c3d  master
   /Users/andrew/Projects/worktrees/wtr/feat-x   8a1b2c3  feat-x
```

### `wtr create <name>`

Creates a new worktree at `<base-dir>/<project>/<name>` on a new branch named
`<name>`. The base directory is read from `~/.config/wtr/config.toml`. On the
first run, the config is created with a sensible default.

```
# First run also writes ~/.config/wtr/config.toml
$ wtr create feature-x
Created config at ~/.config/wtr/config.toml with base_dir = /Users/andrew/Projects/worktrees
Created worktree at /Users/andrew/Projects/worktrees/wtr/feature-x
Branch: feature-x

# Create from a specific ref
$ wtr create hotfix --from main
Created worktree at /Users/andrew/Projects/worktrees/wtr/hotfix
Branch: hotfix (from main)

# Override base directory for one invocation
$ wtr --base-dir /tmp/scratch create throwaway
Created worktree at /tmp/scratch/wtr/throwaway
Branch: throwaway
```

The branch name is taken from `<name>` as-is — no prefix is added. To use a
namespaced branch, pass it explicitly: `wtr create feature/bar`.

### `wtr run <name> [command...]`

Runs a command in the named worktree, with stdio streamed and the command's
exit code propagated. With no command, it opens an interactive shell (`$SHELL`,
falling back to `/bin/sh`) in the worktree — the binary-native way to "be in"
a worktree without changing your parent shell. `master` or `main` target the
main worktree.

```bash
# Run a one-off command in a worktree
$ wtr run feature-x npm test

# Flags after <name> flow to the command — no `--` needed
$ wtr run feature-x git status -s

# A literal `--` inside the command is passed through untouched
$ wtr run feature-x git checkout -- file.txt

# Open a shell in the worktree; `exit` returns you
$ wtr run feature-x

# Operate on the main worktree
$ wtr run master git pull
```

The name is resolved against `git worktree list`, so only existing worktrees
match (no config needed). Namespaced names work too: `wtr run feature/bar`.
A worktree literally named `master` or `main` is shadowed by the main-worktree
alias.

Note: an interactive shell needs the built binary (`./bin/wtr run …`). Under
`lgx run` the dev runner buffers stdio, so a nested shell won't be interactive.

## Configuration

Config file: `~/.config/wtr/config.toml`

```toml
base_dir = "/Users/andrew/Projects/worktrees"
```

- `base_dir` must be an absolute path.
- On the first run, `wtr` writes a config that points at a `worktrees`
  directory sibling to the main worktree.

## Build

`wtr` is a [let-go](https://github.com/nooga/let-go) script bundled to a
native binary via [lgx](https://github.com/abogoyavlensky/lgx).

```bash
# Run from source (development)
lgx run -- list

# Bundle to a binary
lgx build
./bin/wtr list
```

## Tests

```bash
lgx test
```
