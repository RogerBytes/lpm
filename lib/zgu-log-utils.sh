#!/bin/bash

# --- ludis action log ---
#
# Append-only text file, one line per event, tab-separated columns:
# TIMESTAMP <TAB> COMMAND <TAB> STATUS <TAB> DETAIL
#   - STATUS is OK / ERROR / WARN / INFO
#   - DETAIL is a free string "key=value key2=value2 ..."
#
# Purpose: debugging a failed install/isolate/pack/uninstall after the fact (see ludis log,
# lib/zgp-log-viewer.sh) -- not an exhaustive log of all stdout/stderr, only key decisions (command
# start, success/failure per processed item, with the reason).
#
# Location: ALWAYS ~/.local/share/ludis/ludis.log, HARDCODED on $HOME -- never via $XDG_DATA_HOME. Some
# ludis scripts (zgl-launcher-runtime.sh, among others) are invoked by Lutris as
# "system.prelaunch_command" and inherit ITS environment -- a Flatpak Lutris redefines
# $XDG_DATA_HOME to its own private data folder ("~/.var/app/net.lutris.Lutris/data"). With a dynamic
# "${XDG_DATA_HOME:-...}" fallback those scripts would write to a different file than the one
# "ludis log" reads in a normal shell.
#
# Rotation: beyond ZGU_LOG_MAX_LINES lines, ludis.log is renamed ludis.log.1 (overwriting any previous
# ludis.log.1 -- a single backup level, not a logrotate-style stack) and a new empty ludis.log is started.
# "ludis log --all"/"--grep" only cover the current ludis.log, never ludis.log.1 -- intentional, matching
# the "debug a failure after the fact" scope above.
#
# Best-effort: a log write error (disk full, read-only folder, permissions...) must NEVER make the
# ludis command itself fail, hence the systematic "|| true"/"|| return 0" below.

# Folders of the project's former name ("lpm"): moved to "ludis" once, before anything reads them.
for _zgu_base in "${XDG_CONFIG_HOME:-${HOME}/.config}" "${HOME}/.local/share" "${XDG_CACHE_HOME:-${HOME}/.cache}"; do
  if [[ -d "${_zgu_base}/lpm" && ! -L "${_zgu_base}/lpm" && ! -e "${_zgu_base}/ludis" && ! -L "${_zgu_base}/ludis" ]]; then
    mv -- "${_zgu_base}/lpm" "${_zgu_base}/ludis" 2>/dev/null || true
  fi
done
unset _zgu_base
[[ -f "${HOME}/.local/share/ludis/lpm.log" && ! -e "${HOME}/.local/share/ludis/ludis.log" ]] \
  && mv -- "${HOME}/.local/share/ludis/lpm.log" "${HOME}/.local/share/ludis/ludis.log" 2>/dev/null
ZGU_LOG_DIR="${HOME}/.local/share/ludis"
ZGU_LOG_FILE="${ZGU_LOG_DIR}/ludis.log"
ZGU_LOG_MAX_LINES=10000

# Best-effort rotation: called before each write (zgu_log), never from reading (zgp-log-viewer.sh) --
# rotation is a side effect of writing. "wc -l" on a file capped at ZGU_LOG_MAX_LINES lines stays
# negligible, no need to optimize further.
zgu_log_rotate_if_needed() {
  [[ -f "${ZGU_LOG_FILE}" ]] || return 0
  local current_lines
  current_lines=$(wc -l < "${ZGU_LOG_FILE}" 2>/dev/null) || return 0
  [[ "${current_lines}" -gt "${ZGU_LOG_MAX_LINES}" ]] || return 0
  mv -f -- "${ZGU_LOG_FILE}" "${ZGU_LOG_FILE}.1" 2>/dev/null || true
}

# zgu_log <command> <status> <detail>
# Appends a line to the log. Neutralizes tabs/newlines in each field before writing: "command" and
# "status" are always ludis-internal constants, but "detail" may embed a slug/game name possibly forged
# by a third party (shared .zgp package, see zgp-game-installer.sh) -- without this filter, a \t or \n
# in it would break the 4-column tab format for any later read (ludis log --grep, awk, etc.).
zgu_log() {
  local command="$1" status="$2" detail="$3"
  mkdir -p "${ZGU_LOG_DIR}" 2>/dev/null || return 0
  zgu_log_rotate_if_needed
  command="${command//[$'\t\n']/ }"
  status="${status//[$'\t\n']/ }"
  detail="${detail//[$'\t\n']/ }"
  local ts
  ts=$(date +%FT%T%z 2>/dev/null) || ts="?"
  printf '%s\t%s\t%s\t%s\n' "${ts}" "${command}" "${status}" "${detail}" >> "${ZGU_LOG_FILE}" 2>/dev/null || true
}
