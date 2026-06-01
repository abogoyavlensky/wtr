# wtr - a thin wrapper around `git worktree`

Simplifies managinig multiple git worktrees, navigation between them and 
testing different worktrees in the upstream directory.

## Raw implementation in bash script

```shell
### Worktree management
wt-create() {
  local name="$1"

  if [ -z "$name" ]; then
    echo "Usage: wt-create <feature-name>"
    return 1
  fi

  local project
  project="$(basename "$(git rev-parse --show-toplevel)")" || return 1

  git worktree add "../worktrees/${project}/${name}" -b "agent/${name}"
}


wt-list() {
  git worktree list
}

wt-run() {
  local name="$1"
  shift || true

  if [ -z "$name" ]; then
    echo "Usage: wt-run <worktree-name> [agent-command...]"
    return 1
  fi

  local root project wt
  root="$(git rev-parse --show-toplevel)" || return 1
  project="$(basename "$root")"
  wt="$(dirname "$root")/worktrees/${project}/${name}"

  if [ ! -d "$wt" ]; then
    echo "Worktree not found: $wt"
    return 1
  fi

  echo "Running in: $wt"
  (
    cd "$wt" || exit 1
    exec "$@"
  )
}

_wt_main_root() {
  git worktree list --porcelain | awk '
    /^worktree / {
      print substr($0, 10)
      exit
    }
  '
}

_wt_base() {
  local main_root project

  main_root="$(_wt_main_root)" || return 1
  project="$(basename "$main_root")"

  echo "$(dirname "$main_root")/worktrees/${project}"
}

_wt_dir() {
  local name="$1"
  local base_dir

  base_dir="$(_wt_base)" || return 1
  echo "${base_dir}/${name}"
}

_wt_branch() {
  local name="$1"
  local wt_dir

  wt_dir="$(_wt_dir "$name")" || return 1

  if [ ! -d "$wt_dir" ]; then
    echo "Worktree not found: $wt_dir" >&2
    return 1
  fi

  git -C "$wt_dir" branch --show-current
}

wt-switch() {
  local name="$1"
  local main_root branch wt_dir

  if [ -z "$name" ]; then
    echo "Usage: wt-switch <worktree-name|branch-name|master>"
    return 1
  fi

  main_root="$(_wt_main_root)" || return 1

  case "$name" in
    master|main)
      git -C "$main_root" switch "$name"
      return $?
      ;;
  esac

  wt_dir="$(_wt_dir "$name" 2>/dev/null)"

  if [ -d "$wt_dir" ]; then
    branch="$(_wt_branch "$name")" || return 1
  else
    branch="$name"

    if [[ "$branch" != */* ]]; then
      branch="agent/${branch}"
    fi
  fi

  if [ -z "$branch" ]; then
    echo "Could not detect branch for: $name"
    return 1
  fi

  git -C "$main_root" switch --detach "$branch"
}

wt-cd() {
  local name="$1"
  local main_root wt_dir

  if [ -z "$name" ]; then
    echo "Usage: wt-cd <worktree-name|master|main>"
    return 1
  fi

  main_root="$(_wt_main_root)" || return 1

  case "$name" in
    master|main)
      cd "$main_root" || return 1
      return 0
      ;;
  esac

  wt_dir="$(_wt_dir "$name")" || return 1

  if [ ! -d "$wt_dir" ]; then
    echo "Worktree not found: $wt_dir"
    return 1
  fi

  cd "$wt_dir" || return 1
}
```

The idea is to capture this target behaviour and implement in `let-go` (https://github.com/nooga/let-go).
To be bale to build a sinlge lightweight binary.

## UX design

Eventually, we would need few commands:

```bash
wtr list  # lists all worktrees
wtr create <name>  # creates a new worktree with the given name
wtr run <name> <command...>  # runs the given command in the given existing worktree
wtr cd <name>  # changes directory to the given worktree
wtr switch <name>  # switches to the given worktree in detached mode (!)
wtr remove <name>  # removes the given worktree
wtr config  # read-only show current config file path and its content
```

### Example usage

Minminal, how it works now, output of `wtr list`:

```bash
$ wtr list
/Users/andrew/Projects/unison                     463de25 [master]
/Users/andrew/Projects/worktrees/unison/chat-dot  463de25 [agent/chat-dot]
```

## Open questions

1. How to configure defualt `worktree` directory?
  - My thinking is that it should be outside the current upstream repo. For example, relative to current repo: `../worktrees/${project}/${name}`.
  - Maybe we can configure absolute path to the worktrees directory in `~/.config/wtr/config.toml`? For example: `worktrees_dir = "/home/user/Projects/worktrees"`.
2. Maybe we could provide also setup for auto-completion config for zsh/bash? 
  - For example, `wtr completion zsh` would output the config for zsh auto-completion.
