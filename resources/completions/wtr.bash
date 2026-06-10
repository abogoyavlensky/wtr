# bash completion for wtr.
# Load with: source <(wtr completion bash)
_wtr_complete() {
    local cur candidates
    cur="${COMP_WORDS[COMP_CWORD]}"
    candidates="$("${COMP_WORDS[0]}" __complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)"
    local IFS=$'\n'
    COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
}

# -o default: fall back to filename completion when wtr offers nothing
# (e.g. the command tail of `wtr run <name> ...`).
complete -o default -F _wtr_complete wtr
