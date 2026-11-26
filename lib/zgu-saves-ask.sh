#!/bin/bash
# Shared by the installer (replacing an installed game) and the uninstaller: ONE question for the
# whole batch, "back up the saves first?", then the backup of each game. Sourced, never run alone.
# Needs zgl-lang-loader.sh, zgu-cli-utils.sh and zgu-ludis-paths.sh already sourced.

# zgu_saves_default_dir: the folder chosen when none was set yet (Documents/Ludis-saves).
zgu_saves_default_dir() {
  local docs
  docs="$(xdg-user-dir DOCUMENTS 2>/dev/null)"
  [[ -n "${docs}" && "${docs}" != "${HOME}" && -d "${docs}" ]] || docs="${HOME}/Documents"
  printf '%s/Ludis-saves\n' "${docs}"
}

# zgu_saves_decide <yes|no|""> <count>: sets saves_decision to yes or no.
# A flag (--save / --no-save) decides without asking. Otherwise, with a terminal, the question is
# asked ONCE for the batch (not skipped by -y); the default answer is no. Without a terminal: no.
zgu_saves_decide() {
  local flag="$1" count="$2" dest reply
  saves_decision="no"
  case "${flag}" in
    yes) saves_decision="yes"; return 0 ;;
    no) return 0 ;;
  esac
  [[ -t 0 ]] || return 0
  dest="$(zgu_saves_conf_get sync_dir)"
  [[ -n "${dest}" ]] || dest="$(zgu_saves_default_dir)"
  t common.saves_dest_cli "${dest}"
  read -r -p "$(t common.saves_prompt_cli "${count}")" reply || reply="n"
  case "${reply}" in
    [oOyY]) saves_decision="yes" ;;
  esac
}

# zgu_saves_ensure_dir <script_dir>: when no sync folder is set yet, sets the default one.
zgu_saves_ensure_dir() {
  [[ -n "$(zgu_saves_conf_get sync_dir)" ]] && return 0
  bash "$1/zgp-game-saves.sh" dir default
}

# zgu_saves_backup_one <script_dir> <lutris slug>: backs up the saves of one game.
# Returns 0 when it worked or when the game simply has no saves; 1 on a real failure.
zgu_saves_backup_one() {
  local out
  if out=$(bash "$1/zgp-game-saves.sh" "$2" backup 2>&1); then
    printf '%s\n' "${out}"
    return 0
  fi
  # "no saves found" (the message names AppData in every language) is not a failure.
  printf '%s' "${out}" | grep -q 'AppData' && return 0
  printf '%s\n' "${out}" >&2
  return 1
}
