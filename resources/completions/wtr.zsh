#compdef wtr
# zsh completion for wtr.
# Load with: source <(wtr completion zsh)
# or save on your fpath: wtr completion zsh > ~/.zfunc/_wtr

_wtr() {
    local -a candidates
    candidates=("${(@f)$("${words[1]}" __complete "${(@)words[2,CURRENT]}" 2>/dev/null)}")
    if (( ${#candidates[@]} )) && [[ -n "${candidates[1]}" ]]; then
        compadd -Q -a candidates
    else
        # Nothing to offer (e.g. the command tail of `wtr run <name> ...`):
        # fall back to default (filename) completion.
        _default
    fi
}

# On fpath, #compdef invokes _wtr for us; when sourced, register it manually.
if [[ "${funcstack[1]}" == "_wtr" ]]; then
    _wtr "$@"
else
    compdef _wtr wtr
fi
