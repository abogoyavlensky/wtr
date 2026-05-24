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
