# fish completion for wtr.
# Load with: wtr completion fish | source
# or save it: wtr completion fish > ~/.config/fish/completions/wtr.fish
function __wtr_complete
    set -l words (commandline -opc)
    set -l cur (commandline -ct)
    # "$cur" stays quoted: at an argument boundary it is empty and must still
    # reach __complete as the word under the cursor.
    set -g __wtr_candidates ($words[1] __complete $words[2..-1] "$cur" 2>/dev/null)
    test (count $__wtr_candidates) -gt 0
end

# Dynamic candidates when wtr offers any...
complete -c wtr -f -n '__wtr_complete' -a '$__wtr_candidates'
# ...otherwise fall back to file completion (e.g. the command tail of
# `wtr run <name> ...`).
complete -c wtr -n 'not __wtr_complete' -F
