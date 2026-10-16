# Source this file in interactive Bash. No command produced by Pi is evaluated here.
[[ $- == *i* ]] || return 0
[[ ${_TT_LOADED:-} == 1 ]] && return 0
_TT_LOADED=1
_TT_BIN="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/tt"

# Only translate at the main prompt, never inside a multiline shell command.
# Preserve both the user's prompt hooks and the previous command's exit status.
_tt_prompt() {
  local status=$?
  _TT_PRIMARY=1
  return "$status"
}
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
  PROMPT_COMMAND=(_tt_prompt "${PROMPT_COMMAND[@]}")
else
  PROMPT_COMMAND="_tt_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
_TT_PRIMARY=1

_tt_enter() {
  local map command
  # The second key in the Enter macro normally accepts the line. For tt, it is
  # an empty macro, so replacement and execution require separate key presses.
  for map in emacs-standard vi-insert vi-command; do
    bind -m "$map" '"\C-x\C-]": accept-line'
  done
  if [[ ${_TT_PRIMARY:-0} == 1 ]] \
      && [[ $READLINE_LINE =~ ^[[:space:]]*tt([[:space:]]|$) ]] \
      && [[ ! $READLINE_LINE =~ ^[[:space:]]*tt[[:space:]]+- ]]; then
    for map in emacs-standard vi-insert vi-command; do
      bind -m "$map" '"\C-x\C-]": ""'
    done
    if command=$(printf '%s' "$READLINE_LINE" | "$_TT_BIN" --readline); then
      READLINE_LINE=$command
      READLINE_POINT=${#READLINE_LINE}
      READLINE_MARK=$READLINE_POINT
    fi
  else
    _TT_PRIMARY=0
  fi
}

# Handle both normal (Emacs) and Vim readline editing modes.
for _tt_map in emacs-standard vi-insert vi-command; do
  bind -m "$_tt_map" -x '"\C-x\C-t": _tt_enter'
  bind -m "$_tt_map" '"\C-x\C-]": accept-line'
  bind -m "$_tt_map" '"\C-m": "\C-x\C-t\C-x\C-]"'
  bind -m "$_tt_map" '"\C-j": "\C-x\C-t\C-x\C-]"'
done
unset _tt_map
