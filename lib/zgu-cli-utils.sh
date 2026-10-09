#!/bin/bash

# --- Shared utility: ANSI coloring of CLI messages (success in green, error in red) ---
#
# Also sources zgu-log-utils.sh: "zgu_cli_error" needs it (see below) to automatically log EVERY
# CLI error displayed, without the calling script having to source it itself -- any script that
# already sources zgu-cli-utils.sh gets logging for free, including future error messages.
_zgu_cli_utils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgu-log-utils.sh
source "${_zgu_cli_utils_dir}/zgu-log-utils.sh"
#
# Only concerns messages actually printed on the terminal in CLI mode: text captured via "$(t ...)"
# for a Zenity --text=... never goes through these functions, so no raw ANSI codes in a dialog.
#
# Automatically disabled if stdout/stderr is not a real terminal (redirect to a file, pipe to another
# command...) via "[[ -t N ]]": otherwise "lpm list > games.txt" or "lpm log --grep foo | less" would
# get literal escape sequences (\033[32m...) polluting the file or breaking the pager.
#
# zgu_cli_ok <text>: prints <text> in green on stdout (success/final confirmation of a CLI operation
# -- not intermediate progress messages, which stay neutral).
zgu_cli_ok() {
  if [[ -t 1 ]]; then
    printf '\033[32m%s\033[0m\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# zgu_cli_error <text>: prints <text> in red on stderr (all CLI error messages, already redirected to
# stderr throughout the project -- this existing signal allows coloring errors mechanically).
#
# ALSO logs every call to lpm.log (STATUS=ERROR), before printing the message -- this covers all
# pre-check errors (zenity/python3/pyyaml/zstd missing, Lutris database not found, invalid argument...),
# not only errors inside a processing loop (explicit "zgu_log" calls). "command" is deduced from the
# calling script (BASH_SOURCE[1], one level above this function) rather than requiring an extra
# parameter at every existing call site.
zgu_cli_error() {
  local caller
  caller=$(basename -- "${BASH_SOURCE[1]:-inconnu}" .sh)
  zgu_log "${caller}" "ERROR" "$1"
  if [[ -t 2 ]]; then
    printf '\033[31m%s\033[0m\n' "$1" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}
