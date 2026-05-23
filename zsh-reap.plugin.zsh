# zsh-reap — track long-running foreground jobs; expose a CLI for external
# tools to list, kill, and restart them. See spec/SPEC.md for the design.

# Zsh Plugin Standard $0 handling (robust to FUNCTION_ARGZERO / POSIX_ARGZERO /
# eval-sourcing).
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"

typeset -gA REAP
REAP[DIR]="${0:h}"
REAP[STATE_DIR]="${ZSH_REAP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zsh-reap}"
REAP[THRESHOLD]="${ZSH_REAP_THRESHOLD:-5}"

# Defensively add functions/ and bin/ if missing. We don't rely on
# $PMSPEC's f/b bits because a stale value from a previous plugin manager
# in the user's env can lie about what's been done for us.
[[ -z ${fpath[(r)${0:h}/functions]} ]] && fpath+=( "${0:h}/functions" )
[[ -z ${path[(r)${0:h}/bin]} ]]       && path+=( "${0:h}/bin" )

zmodload zsh/datetime  # $EPOCHSECONDS

autoload -Uz add-zsh-hook
autoload -Uz _reap_preexec _reap_precmd _reap_zshexit _reap_watcher

[[ -o interactive ]] || return 0
(( ZSH_SUBSHELL == 0 )) || return 0

mkdir -p "${REAP[STATE_DIR]}/jobs" "${REAP[STATE_DIR]}/pending"
chmod 0700 "${REAP[STATE_DIR]}"

# A stale pending file for this PID (PID reuse across reboots) would
# trigger an unwanted restart on the next prompt — drop it on load.
rm -f "${REAP[STATE_DIR]}/pending/$$"

add-zsh-hook preexec _reap_preexec
add-zsh-hook precmd  _reap_precmd
add-zsh-hook zshexit _reap_zshexit
