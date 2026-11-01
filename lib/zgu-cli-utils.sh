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

# zgu_archive_config <archive.zgp>: prints the game's YAML, stored by "lpm pack" as the FIRST
# member of the archive (".lpm-config.yml": the cleaned Lutris YAML plus the "lpm_archive" key
# with the exact extracted size). Returns 1, printing nothing, for an archive without it (made
# by an older version) or if it cannot be read.
# Only the very beginning of the archive is read, whatever its size: the first tar header is
# checked through "zstd -dc | head -c" (stops at once, SIGPIPE) BEFORE asking bsdtar for the
# member -- asking bsdtar for a member that does not exist makes it scan the WHOLE archive. "-q"
# stops at the first match, so a second ".lpm-config.yml" planted later in the archive is never
# read: the first one is the only one that counts.
zgu_archive_config() {
  command -v zstd >/dev/null 2>&1 || return 1
  local first cfg
  first=$(zstd -dc -- "$1" 2>/dev/null | head -c 100 | tr -d '\0')
  [[ "${first}" = ".lpm-config.yml" ]] || return 1
  cfg=$(bsdtar -xOqf "$1" .lpm-config.yml 2>/dev/null | head -c 1048576)
  [[ -n "${cfg}" ]] || return 1
  printf '%s\n' "${cfg}"
}

# zgu_archive_exact_size <archive.zgp>: prints the exact extracted size (bytes) recorded by
# "lpm pack"; prints nothing (return 1) for an archive without it or if it cannot be read. Reads
# the "lpm_archive: size" of the first-member YAML (see zgu_archive_config); archives of the
# previous format carry it in a tiny ".lpm-size" first member instead, still understood.
zgu_archive_exact_size() {
  command -v zstd >/dev/null 2>&1 || return 1
  local first meta size
  first=$(zstd -dc -- "$1" 2>/dev/null | head -c 100 | tr -d '\0')
  if [[ "${first}" = ".lpm-config.yml" ]]; then
    size=$(zgu_archive_config "$1" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin.read()) or {}
    print(int(d["lpm_archive"]["size"]))
except Exception:
    pass
' 2>/dev/null)
    [[ "${size}" =~ ^[0-9]+$ ]] || return 1
    echo "${size}"
    return 0
  fi
  [[ "${first}" = ".lpm-size" ]] || return 1
  meta=$(bsdtar -xOqf "$1" .lpm-size 2>/dev/null | head -c 64)
  [[ "${meta}" =~ ^size=([0-9]+)$ ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# zgu_yaml_hooks: reads a game YAML on STDIN and prints, one per line, the automatic launch/close
# hooks it contains ("<key path>\x1f<value>"): the keys Lutris runs by itself at every launch or
# exit (..._command, ..._script and the like). Nothing printed when there is none.
zgu_yaml_hooks() {
  python3 -c '
import sys, yaml

def find_hooks(obj, path=""):
    found = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            kl = k.lower() if isinstance(k, str) else ""
            cur_path = f"{path}.{k}" if path else str(k)
            if kl.endswith("_command") or kl.endswith("_script") or kl.endswith("_wait") or "exec" in kl:
                found.append((cur_path, v))
                continue
            found.extend(find_hooks(v, cur_path))
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            found.extend(find_hooks(item, f"{path}[{i}]"))
    return found

try:
    data = yaml.safe_load(sys.stdin.read())
    for hook_path, hook_value in find_hooks(data):
        print(f"{hook_path}\x1f{hook_value}")
except Exception:
    pass
' 2>/dev/null
}
