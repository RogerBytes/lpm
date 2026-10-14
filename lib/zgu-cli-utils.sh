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

# After a failed write, less than this much free space left on the disk means the disk is full
# (and not, say, a corrupted archive). 1 GiB: a few MiB of slack is not enough, other programs
# and the file system's own reserve keep eating into what is left.
# shellcheck disable=SC2034 # used by zgp-game-installer.sh and zgp-game-packer.sh
ZGU_DISK_FULL_MARGIN=$((1024 * 1024 * 1024))

# zgu_human_size <bytes>: prints a size with a binary unit (e.g. "12.3GiB"), or "<bytes> B" if numfmt
# is unavailable.
zgu_human_size() {
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B --format="%.1f" -- "$1" 2>/dev/null && return 0
  fi
  printf '%s B\n' "$1"
}

# zgu_free_bytes <dir>: prints the free space (bytes) available to the current user on the file
# system holding <dir>; prints nothing (return 1) if it cannot be determined.
zgu_free_bytes() {
  local free_kb
  free_kb=$(df -Pk -- "$1" 2>/dev/null | awk 'NR==2 {print $4}')
  [[ "${free_kb}" =~ ^[0-9]+$ ]] || return 1
  echo $((free_kb * 1024))
}

# zgu_archive_exact_size <archive.zgp>: prints the exact extracted size (bytes) recorded by
# "lpm pack" in the small ".lpm-size" file placed FIRST in the archive; prints nothing (return 1)
# for an archive without it (made by an older version) or if it cannot be read.
# Only the very beginning of the archive is read, whatever its size: the first tar header is
# checked through "zstd -dc | head -c" (stops at once, SIGPIPE) BEFORE asking bsdtar for the
# member -- asking bsdtar for a member that does not exist makes it scan the WHOLE archive.
zgu_archive_exact_size() {
  command -v zstd >/dev/null 2>&1 || return 1
  local first meta
  first=$(zstd -dc -- "$1" 2>/dev/null | head -c 100 | tr -d '\0')
  [[ "${first}" = ".lpm-size" ]] || return 1
  meta=$(bsdtar -xOqf "$1" .lpm-size 2>/dev/null | head -c 64)
  [[ "${meta}" =~ ^size=([0-9]+)$ ]] || return 1
  echo "${BASH_REMATCH[1]}"
}
