#!/bin/bash

# --- ludis saves: back up / restore / share the SAVES of ONE game (never the whole prefix) ---
#
#   ludis saves dir [path]                  show or set the sync folder (one subfolder per game)
#   ludis saves <slug> status               what is saved where (local / sync folder)
#   ludis saves <slug> backup               copy the game's saves to <sync>/<slug>/current/
#   ludis saves <slug> restore [snapshot]   copy <sync>/<slug>/current/ (or an older snapshot of
#                                           "history") back into the prefix
#   ludis saves <slug> history              the older snapshot kept in previous/ (compressed)
#   ludis saves <slug> initial              keep the initial state of the saves (once; the launcher does it
#                                           the first time the game is launched through Ludis)
#   ludis saves <slug> reset [--yes]        put the saves back to that initial state (the current ones are kept once)
#   ludis saves <slug> path                 the Windows user folder of the prefix
#   ludis saves <slug> export [file.zgs]    make a shareable archive of the saves
#   ludis saves <slug> import <file.zgs>    put the saves of an archive into the prefix
#   ludis saves <slug> pull | push          what the automatic mode does at launch / during and
#                                           at the end of the game (quiet; usable by hand too)
#   ludis saves <slug> auto [follow|on|off] automatic mode for this game (follows the global one)
#   ludis saves <slug> folders [list|add <path>|remove <path>|reset]
#                                           choose the folders (relative to the Windows user folder)
#                                           instead of the default ones; stored in the prefix
#   ludis saves <slug> exclude [list|add <pattern>|remove <pattern>|reset]
#                                           more files/folders NOT to take, on top of the built-in
#                                           exclusions (caches, logs, Windows profile leftovers...)
#   ludis saves auto [on|off]               global automatic mode (default: off)
#   ludis saves interval [minutes]          copy every N minutes while playing (0 = off, 1-60, default 10)
#
# What counts as "saves": the folders AppData, Documents and "Saved Games" of the Windows user
# of the prefix (whatever its name: "steamuser" under Proton, the Linux user name under Wine),
# minus caches that can be rebuilt (Temp, shader caches, crash dumps). The folder choice is per game
# and lives in the prefix: <prefix>/ludis/settings/saves-folders.txt (one path per line, relative to
# the Windows user folder, REPLACES the defaults) and saves-extra.txt (one extra folder per line,
# relative to drive_c, e.g. "Games/Foo/save", added to whatever is chosen).
# Files are stored with paths RELATIVE to the Windows user folder, so a backup or an archive
# made under one user name restores under any other.
#
# Safety: nothing outside the prefix's user folder is ever written; links found in a backup or
# an archive are deleted (never followed); the local saves are copied to "previous/" before any
# restore or import overwrites them; "previous/" keeps 2 compressed snapshots at most: the previous backup and
# the last safety copy (see saves_rotate). The initial state is kept in the prefix: <prefix>/ludis/saves-initial.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-ludis-paths.sh
source "${script_dir}/zgu-ludis-paths.sh"
# shellcheck source=./zgu-saves-ask.sh
source "${script_dir}/zgu-saves-ask.sh"

saves_conf="${XDG_CONFIG_HOME:-${HOME}/.config}/ludis/saves.conf"
saves_dirs=(AppData Documents "Saved Games")
saves_keep=5
# A backup becomes the "previous" one only when the last "previous" is at least this old (seconds).
saves_prev_min_age=900
saves_excludes=(
  # temporary files and caches that are rebuilt by themselves
  "AppData/Local/Temp" "AppData/LocalLow/Temp"
  "*/CrashDumps" "*/Crashes" "*/D3DSCache" "*/GPUCache" "*/ShaderCache" "*/Code Cache"
  "*/NVIDIA/DXCache" "*/NVIDIA/GLCache" "*/Cache" "*/cache" "*/INetCache" "*/INetCookies"
  "AppData/Local/dxvk" "AppData/Local/vkd3d*" "AppData/Local/mesa_shader_cache*"
  "*.dxvk-cache" "*.dxvk.bin" "*.dxvk.lut"
  # what Windows itself puts in every profile (shortcuts, history, thumbnails): not game data
  "AppData/Local/Microsoft" "AppData/Roaming/Microsoft"
  # logs and engine telemetry
  "*.log" "*.log.*" "*/Logs" "*/logs" "*/Unity" "*/Analytics"
  # empty folders Wine creates inside Documents
  "Documents/Downloads" "Documents/Music" "Documents/Pictures" "Documents/Videos" "Documents/Templates"
)

saves_conf_get() {
  sed -n "s/^[[:space:]]*${2:-sync_dir}[[:space:]]*=[[:space:]]*//p" "${saves_conf}" 2>/dev/null | tail -n 1
}

# saves_conf_set <value> [key]
saves_conf_set() {
  local tmp key="${2:-sync_dir}"
  mkdir -p "$(dirname "${saves_conf}")" || return 1
  tmp="$(mktemp "${saves_conf}.XXXXXX")" || return 1
  { grep -v -E "^[[:space:]]*${key}[[:space:]]*=" "${saves_conf}" 2>/dev/null; printf '%s=%s\n' "${key}" "$1"; } > "${tmp}" \
    && mv -f -- "${tmp}" "${saves_conf}"
}

# Per-machine state (never in the prefix, so it is not exported with the game): epoch of the last
# time this machine pushed or pulled the saves of a game.
saves_state_file() {
  printf '%s/ludis/saves-state/%s' "${XDG_DATA_HOME:-${HOME}/.local/share}" "$1"
}
saves_last_sync() {
  local v
  v="$(cat "$(saves_state_file "$1")" 2>/dev/null)"
  [[ "${v}" =~ ^[0-9]+$ ]] && printf '%s' "${v}" || printf '0'
}
# saves_mark_synced <slug> [remote_stamp]: now, or the stamp of the backup just taken when it is
# in the future (clock difference between two machines).
saves_mark_synced() {
  local now t="${2:-0}"
  now="$(date +%s)"
  [[ "${t}" =~ ^[0-9]+$ ]] && (( t > now )) && now="${t}"
  mkdir -p "$(dirname "$(saves_state_file "$1")")" 2>/dev/null
  printf '%s\n' "${now}" > "$(saves_state_file "$1")" 2>/dev/null
  return 0
}

# saves_local_newest: epoch of the newest file of the selection (0 = none).
saves_local_newest() {
  local item newest=0 t
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    if [[ "${item}" = _extra/* ]]; then
      t=$(find "${prefix_dir}/drive_c/${item#_extra/}" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
    else
      t=$(find "${user_dir}/${item}" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
    fi
    t="${t%.*}"
    [[ "${t}" =~ ^[0-9]+$ ]] && (( t > newest )) && newest="${t}"
  done < <(saves_items)
  printf '%s' "${newest}"
}

# Valid lines of a per-game list file (relative paths, no "..", no absolute path).
saves_list_file_lines() {
  local f="$1" line
  [[ -f "${f}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" = \#* || "${line}" = /* || "${line}" = *..* ]] && continue
    printf '%s\n' "${line}"
  done < "${f}"
}

# Real Windows user folder of the prefix: first real (non-link) folder of drive_c/users, never Public.
saves_user_dir() {
  local d
  for d in "${prefix_dir}"/drive_c/users/*; do
    [[ -d "${d}" && ! -L "${d}" ]] || continue
    [[ "$(basename -- "${d}")" = "Public" ]] && continue
    printf '%s' "${d}"
    return 0
  done
  return 1
}

# saves_extra_lines: valid extra folders (relative to drive_c) from the per-game settings file.
saves_extra_lines() {
  saves_list_file_lines "$(zgu_ludis_find "${prefix_dir}" saves_extra)"
}

# saves_folder_lines: the chosen folders (relative to the user folder): the per-game list when it
# exists, else the defaults.
saves_folder_lines() {
  local f
  f="$(zgu_ludis_find "${prefix_dir}" saves_folders)"
  if [[ -f "${f}" ]]; then
    saves_list_file_lines "${f}"
  else
    printf '%s\n' "${saves_dirs[@]}"
  fi
}

# saves_items: the folders to take, one per line: relative to the user folder, or "_extra/<line>"
# for the extra folders (existing ones only).
saves_items() {
  local f line
  while IFS= read -r f; do
    [[ -d "${user_dir}/${f}" && ! -L "${user_dir}/${f}" ]] && printf '%s\n' "${f}"
  done < <(saves_folder_lines)
  while IFS= read -r line; do
    [[ -d "${prefix_dir}/drive_c/${line}" && ! -L "${prefix_dir}/drive_c/${line}" ]] && printf '_extra/%s\n' "${line}"
  done < <(saves_extra_lines)
}

# saves_pack <dest_dir>: copies the selection into <dest_dir> (created), links removed.
saves_pack() {
  local dest="$1" item args=() x
  mkdir -p -- "${dest}" || return 1
  for x in "${saves_excludes[@]}"; do args+=(--exclude="${x}"); done
  while IFS= read -r x; do args+=(--exclude="${x}"); done < <(saves_list_file_lines "$(zgu_ludis_find "${prefix_dir}" saves_exclude)")
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    if [[ "${item}" = _extra/* ]]; then
      mkdir -p -- "${dest}/${item}" || return 1
      tar -C "${prefix_dir}/drive_c/${item#_extra/}" -cf - "${args[@]}" . | tar -C "${dest}/${item}" -xf - --no-same-owner || return 1
    else
      tar -C "${user_dir}" -cf - "${args[@]}" "${item}" | tar -C "${dest}" -xf - --no-same-owner || return 1
    fi
  done < <(saves_items)
  find "${dest}" -type l -delete 2>/dev/null
  return 0
}

# saves_unpack <src_dir>: copies the content of <src_dir> into the prefix (existing files overwritten).
# Everything but "_extra" goes to the Windows user folder (paths come from a tar without "..", links
# removed: it cannot land elsewhere); "_extra/<line>" goes to drive_c/<line> ONLY if that line is
# listed in this prefix's saves-extra.txt (an archive can never choose where those files land).
saves_unpack() {
  local src="$1" item line
  find "${src}" -type l -delete 2>/dev/null
  for item in "${src}"/* "${src}"/.[!.]*; do
    [[ -d "${item}" ]] || continue
    [[ "$(basename -- "${item}")" = "_extra" ]] && continue
    mkdir -p -- "${user_dir}/$(basename -- "${item}")" \
      && cp -a -- "${item}/." "${user_dir}/$(basename -- "${item}")/" || return 1
  done
  while IFS= read -r line; do
    item="${src}/_extra/${line}"
    [[ -d "${item}" ]] || continue
    mkdir -p -- "${prefix_dir}/drive_c/${line}" && cp -a -- "${item}/." "${prefix_dir}/drive_c/${line}/" || return 1
  done < <(saves_extra_lines)
  return 0
}

# saves_compress <dir> <dest.tar.zst>: one compressed file from the content of <dir>.
saves_compress() {
  tar -C "$1" -cf - . 2>/dev/null | zstd -q -3 -f -o "$2.tmp" 2>/dev/null && mv -f -- "$2.tmp" "$2" || { rm -f -- "$2.tmp"; return 1; }
}

# saves_name_epoch <snapshot path>: its date (epoch) read from its name YYYYmmdd-HHMMSS-<label>[.tar.zst].
# Prints nothing when the name is not one of ours.
saves_name_epoch() {
  local name stamp epoch
  name="$(basename -- "$1")"; name="${name%.tar.zst}"
  stamp="${name:0:8} ${name:9:2}:${name:11:2}:${name:13:2}"
  epoch="$(date -d "${stamp}" +%s 2>/dev/null)" || return 0
  [[ "${epoch}" =~ ^[0-9]+$ ]] && printf '%s\n' "${epoch}"
}

# saves_rotate <previous_dir>: what previous/ keeps (2 snapshots at most): the newest backup that was
# replaced ("previous backup") and the newest safety copy made before a restore, a pull, a reset or an
# import ("before-*", "conflict"). Everything else is deleted.
# Snapshots are named YYYYmmdd-HHMMSS-<label>.tar.zst (older versions made plain folders: same rule).
saves_rotate() {
  local d name kept_backup=false kept_safe=false
  while IFS= read -r d; do
    name="$(basename -- "${d}")"; name="${name%.tar.zst}"
    [[ -n "$(saves_name_epoch "${d}")" ]] || continue       # not one of ours: never touched
    if [[ "${name}" =~ -(before-|conflict) ]]; then
      [[ "${kept_safe}" = false ]] && { kept_safe=true; continue; }
    else
      [[ "${kept_backup}" = false ]] && { kept_backup=true; continue; }
    fi
    rm -rf -- "${d}"
  done < <(find "$1" -mindepth 1 -maxdepth 1 \( -type f -name '*.tar.zst' -o -type d \) 2>/dev/null | sort -r)
  return 0
}

# saves_snapshot_local <label>: copies the CURRENT local saves to <previous>/<date>-<label>/.
saves_snapshot_local() {
  local snap="${game_sync}/previous/$(date +%Y%m%d-%H%M%S)-$1"
  [[ -n "$(saves_items)" ]] || return 0
  mkdir -p -- "${game_sync}/previous" && saves_pack "${work}/snap" || return 1
  if ! saves_compress "${work}/snap" "${snap}.tar.zst"; then
    mv -- "${work}/snap" "${snap}" || return 1        # no zstd: keep a plain folder
  fi
  rm -rf -- "${work}/snap"
  saves_rotate "${game_sync}/previous"
}

saves_need_sync_dir() {
  sync_dir="$(saves_conf_get)"
  if [[ -z "${sync_dir}" ]]; then
    zgu_cli_error "$(t saves.no_dir_cli)"
    return 1
  fi
  return 0
}

# saves_norm_folder <arg>: a folder given as a path relative to the Windows user folder, as
# "drive_c:<path relative to drive_c>", or as an absolute path inside the prefix (what a folder
# picker returns). Prints "U<tab>relative path" (inside the user folder) or "X<tab>relative path"
# (elsewhere in drive_c); fails for anything else (outside the prefix, "..").
saves_norm_folder() {
  local p="${1%/}" abs u_real d_real
  [[ -n "${p}" && "${p}" != *..* && "${p}" != *$'\n'* ]] || return 1
  case "${p}" in
    drive_c:*)
      p="${p#drive_c:}"
      [[ -n "${p}" && "${p}" != /* ]] || return 1
      printf 'X\t%s' "${p}"
      ;;
    /*)
      abs="$(realpath -m -- "${p}")"
      u_real="$(realpath -- "${user_dir}")"; d_real="$(realpath -- "${prefix_dir}/drive_c")"
      case "${abs}" in
        "${u_real}"/*) printf 'U\t%s' "${abs#"${u_real}"/}" ;;
        "${d_real}"/*) printf 'X\t%s' "${abs#"${d_real}"/}" ;;
        *) return 1 ;;
      esac
      ;;
    *) printf 'U\t%s' "${p}" ;;
  esac
}

# saves_write_config <dest>: the folder choice of this game (what "folders" and "exclude" write in
# the prefix), as "folder=" / "extra=" / "exclude=" lines. Written next to every backup and inside
# every .zgs, so that a prefix made long ago, with no saves settings of its own, learns them.
saves_write_config() {
  {
    echo "ludis-saves-config=1"
    saves_list_file_lines "$(zgu_ludis_find "${prefix_dir}" saves_folders)" | sed 's/^/folder=/'
    saves_list_file_lines "$(zgu_ludis_find "${prefix_dir}" saves_extra)" | sed 's/^/extra=/'
    saves_list_file_lines "$(zgu_ludis_find "${prefix_dir}" saves_exclude)" | sed 's/^/exclude=/'
  } > "$1" 2>/dev/null
}

# saves_refresh_config: after the folder choice or the exclusions changed, the "config" of the backup
# is rewritten at once (only if this game already has a folder in the sync folder).
saves_refresh_config() {
  [[ -n "${game_sync}" && -d "${game_sync}" ]] && saves_write_config "${game_sync}/config"
  return 0
}

# saves_adopt_config <file>: when this prefix has NO saves settings of its own, takes the ones
# recorded in <file> (a backup's "config" or the marker of a .zgs). Settings the prefix already
# has are never replaced. Only plain relative paths are accepted (no "..", no leading "/").
saves_adopt_config() {
  local f="$1" key value dest
  [[ -f "${f}" ]] || return 0
  if [[ -e "$(zgu_ludis_find "${prefix_dir}" saves_folders)" || -e "$(zgu_ludis_find "${prefix_dir}" saves_extra)" \
        || -e "$(zgu_ludis_find "${prefix_dir}" saves_exclude)" ]]; then
    return 0
  fi
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"
    [[ -n "${value}" && "${value}" != /* && "${value}" != *..* ]] || continue
    case "${key}" in
      folder) dest="$(zgu_ludis_path "${prefix_dir}" saves_folders)" ;;
      extra) dest="$(zgu_ludis_path "${prefix_dir}" saves_extra)" ;;
      exclude) dest="$(zgu_ludis_path "${prefix_dir}" saves_exclude)" ;;
      *) continue ;;
    esac
    mkdir -p -- "$(dirname "${dest}")" 2>/dev/null && printf '%s\n' "${value}" >> "${dest}"
  done < "${f}"
  return 0
}

# saves_do_restore <label> [snapshot]: local saves kept in previous/<date>-<label>, then <sync>/current
# (or the named snapshot of previous/) restored.
saves_do_restore() {
  local snap="${2:-}" found
  if [[ -n "${snap}" ]]; then
    found="$(find "${game_sync}/previous" -mindepth 1 -maxdepth 1 -name "*${snap}*" 2>/dev/null | sort -r | head -n 1)"
    if [[ -z "${found}" ]]; then
      zgu_cli_error "$(t saves.no_snapshot_cli "${snap}")"
      return 1
    fi
  elif [[ ! -d "${game_sync}/current" ]]; then
    zgu_cli_error "$(t saves.no_backup_cli "${target_name}")"
    return 1
  fi
  saves_adopt_config "${game_sync}/config"
  # Prepare the saves to bring BEFORE keeping the local ones: that step rotates previous/ and could
  # delete the very snapshot being restored.
  if [[ -z "${snap}" ]]; then
    cp -a -- "${game_sync}/current" "${work}/src" || return 1
  elif [[ -d "${found}" ]]; then
    cp -a -- "${found}" "${work}/src" || return 1
  else
    mkdir -p -- "${work}/src" && zstd -dcq -- "${found}" | tar -C "${work}/src" -xf - --no-same-owner 2>/dev/null \
      || { zgu_cli_error "$(t saves.restore_failed_cli "${target_name}")"; return 1; }
  fi
  saves_snapshot_local "$1" || { zgu_cli_error "$(t saves.write_failed_cli "${game_sync}")"; return 1; }
  if ! saves_unpack "${work}/src"; then
    zgu_cli_error "$(t saves.restore_failed_cli "${target_name}")"
    return 1
  fi
  saves_mark_synced "${target_slug}" "$(cut -d' ' -f1 "${game_sync}/stamp" 2>/dev/null)"
  zgu_log "saves" "OK" "slug=${target_slug} action=restore label=$1"
  return 0
}

# --- arguments ---
cli_slug="${1:-}"
cli_action="${2:-}"
cli_arg="${3:-}"

if [[ -z "${cli_slug}" ]]; then
  zgu_cli_error "$(t saves.cli_usage)"
  exit 1
fi

# "ludis saves auto [on|off]" and "ludis saves interval [minutes]": global automatic mode.
if [[ "${cli_slug}" = "auto" ]]; then
  if [[ -z "${cli_action}" ]]; then saves_conf_get "" auto | grep -qi '^on' && echo on || echo off; exit 0; fi
  [[ "${cli_action}" = on || "${cli_action}" = off ]] || { zgu_cli_error "$(t saves.invalid_action_cli "${cli_action}")"; exit 1; }
  saves_conf_set "${cli_action}" auto || { zgu_cli_error "$(t saves.dir_write_failed_cli)"; exit 1; }
  zgu_cli_ok "$(t saves.auto_global_cli "${cli_action}")"
  exit 0
fi
if [[ "${cli_slug}" = "interval" ]]; then
  if [[ -z "${cli_action}" ]]; then
    v="$(saves_conf_get "" interval)"; [[ "${v}" =~ ^[0-9]+$ ]] || v=10; echo "${v}"; exit 0
  fi
  if ! [[ "${cli_action}" =~ ^[0-9]+$ ]] || (( cli_action > 60 )); then
    zgu_cli_error "$(t saves.interval_invalid_cli "${cli_action}")"; exit 1
  fi
  saves_conf_set "${cli_action}" interval || { zgu_cli_error "$(t saves.dir_write_failed_cli)"; exit 1; }
  zgu_cli_ok "$(t saves.interval_set_cli "${cli_action}")"
  exit 0
fi

# "ludis saves dir [path]": global sync folder.
if [[ "${cli_slug}" = "dir" ]]; then
  if [[ -z "${cli_action}" ]]; then
    sync_dir="$(saves_conf_get)"
    if [[ -z "${sync_dir}" ]]; then echo ""; else echo "${sync_dir}"; fi
    exit 0
  fi
  target="${cli_action}"
  [[ "${target}" = "none" ]] && target=""
  if [[ "${target}" = "default" ]]; then
    target="$(zgu_saves_default_dir)"
  fi
  if [[ -n "${target}" ]]; then
    [[ "${target}" = "~"* ]] && target="${HOME}${target#\~}"
    if [[ "${target}" != /* ]] || ! mkdir -p -- "${target}" 2>/dev/null || [[ ! -w "${target}" ]]; then
      zgu_cli_error "$(t saves.dir_invalid_cli "${cli_action}")"
      exit 1
    fi
    target="$(realpath -- "${target}")"
  fi
  if ! saves_conf_set "${target}"; then
    zgu_cli_error "$(t saves.dir_write_failed_cli)"
    exit 1
  fi
  zgu_cli_ok "$(t saves.dir_set_cli "${target:-none}")"
  exit 0
fi

case "${cli_action}" in
  status|backup|restore|export|import|pull|push|auto|folders|exclude|history|path|initial|reset) ;;
  "") cli_action="status" ;;
  *)
    zgu_cli_error "$(t saves.invalid_action_cli "${cli_action}")"
    exit 1
    ;;
esac

if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t game_tools.sqlite3_missing)"
  exit 1
fi
zgu_load_lutris_env || { zgu_cli_error "$(t game_tools.lutris_missing_cli)"; exit 1; }
if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t game_tools.no_games_found_cli "${games_dir}")"
  exit 1
fi

target_slug=$(basename -- "${cli_slug}")
row=$(sqlite3 "${lutris_db}" "SELECT name FROM games WHERE slug='${target_slug//\'/\'\'}' AND runner='wine' LIMIT 1;" 2>/dev/null)
if [[ -z "${row}" ]]; then
  zgu_cli_error "$(t game_tools.slug_not_found_cli "${target_slug}")"
  exit 1
fi
target_name="${row}"
prefix_dir=$(zgu_resolve_prefix_dir_by_slug "${target_slug}" "${lutris_db}" "${games_dir}")
if [[ -z "${prefix_dir}" ]]; then
  zgu_cli_error "$(t game_tools.prefix_not_found_cli "${target_name}")"
  exit 1
fi
if ! user_dir="$(saves_user_dir)"; then
  # A prefix that was never started has no Windows user folder yet: for "initial" that means "no saves yet".
  if [[ "${cli_action}" = initial ]]; then user_dir=""; else zgu_cli_error "$(t saves.no_user_dir_cli "${target_name}")"; exit 1; fi
fi

sync_dir="$(saves_conf_get)"
game_sync=""
[[ -n "${sync_dir}" ]] && game_sync="${sync_dir%/}/${target_slug}"

work="$(mktemp -d "${TMPDIR:-/tmp}/ludis-saves.XXXXXX")" || exit 1
trap 'rm -rf -- "${work}"' EXIT

case "${cli_action}" in
  status)
    n_local=$(saves_items | wc -l)
    echo "local=${n_local} sync_dir=${sync_dir:-none}"
    if [[ -n "${game_sync}" && -d "${game_sync}/current" ]]; then
      echo "backup=$(date -d "@$(cut -d' ' -f1 "${game_sync}/stamp" 2>/dev/null || echo 0)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) previous=$(find "${game_sync}/previous" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    else
      echo "backup=none"
    fi
    ;;

  backup)
    saves_need_sync_dir || exit 1
    # A prefix with no saves settings of its own (a game just reinstalled, an old prefix) learns the
    # folder choice recorded in this game's backup BEFORE copying anything: otherwise it would copy
    # the default folders and replace the backup (and its config) made with the chosen ones.
    saves_adopt_config "${game_sync}/config"
    if [[ -z "$(saves_items)" ]]; then
      zgu_cli_error "$(t saves.nothing_cli "${target_name}")"
      exit 1
    fi
    mkdir -p -- "${game_sync}" || { zgu_cli_error "$(t saves.write_failed_cli "${game_sync}")"; exit 1; }
    if ! saves_pack "${work}/new"; then
      zgu_cli_error "$(t saves.write_failed_cli "${game_sync}")"
      exit 1
    fi
    if [[ -d "${game_sync}/current" ]] && diff -rq -- "${game_sync}/current" "${work}/new" >/dev/null 2>&1; then
      saves_mark_synced "${target_slug}"
      saves_write_config "${game_sync}/config"
      zgu_cli_ok "$(t saves.unchanged_cli "${target_name}")"
      exit 0
    fi
    # Atomic: build next to the destination, then swap by rename.
    rm -rf -- "${game_sync}/.current.tmp"
    if ! cp -a -- "${work}/new" "${game_sync}/.current.tmp"; then
      rm -rf -- "${game_sync}/.current.tmp"
      zgu_cli_error "$(t saves.write_failed_cli "${game_sync}")"
      exit 1
    fi
    if [[ -d "${game_sync}/current" ]]; then
      # The old backup becomes the "previous" one only when the last "previous" is old enough:
      # otherwise it is simply replaced, so a crash never finds two near-identical copies.
      last_prev="$(find "${game_sync}/previous" -mindepth 1 -maxdepth 1 ! -name '*-before-*' ! -name '*-conflict*' 2>/dev/null | sort -r | head -n 1)"
      prev_epoch=""
      [[ -n "${last_prev}" ]] && prev_epoch="$(saves_name_epoch "${last_prev}")"
      if [[ -z "${prev_epoch}" ]] || (( $(date +%s) - prev_epoch >= saves_prev_min_age )); then
        mkdir -p -- "${game_sync}/previous"
        old="${game_sync}/previous/$(date +%Y%m%d-%H%M%S)-backup"
        if saves_compress "${game_sync}/current" "${old}.tar.zst"; then
          rm -rf -- "${game_sync}/current"
        else
          mv -- "${game_sync}/current" "${old}"
        fi
        saves_rotate "${game_sync}/previous"
      else
        rm -rf -- "${game_sync}/current"
      fi
    fi
    mv -- "${game_sync}/.current.tmp" "${game_sync}/current"
    printf '%s %s\n' "$(date +%s)" "$(hostname 2>/dev/null | tr -d ' ')" > "${game_sync}/stamp" 2>/dev/null
    saves_write_config "${game_sync}/config"
    saves_mark_synced "${target_slug}"
    zgu_log "saves" "OK" "slug=${target_slug} action=backup"
    zgu_cli_ok "$(t saves.backup_ok_cli "${target_name}" "${game_sync}/current")"
    ;;

  restore)
    saves_need_sync_dir || exit 1
    saves_do_restore "before-restore" "${cli_arg}" || exit 1
    zgu_cli_ok "$(t saves.restore_ok_cli "${target_name}")"
    ;;

  history)
    saves_need_sync_dir || exit 1
    find "${game_sync}/previous" -mindepth 1 -maxdepth 1 2>/dev/null | sed 's#.*/##; s#\.tar\.zst$##' | sort -r
    ;;

  initial)
    # The state of the saves before the game was played, kept once in the prefix itself (works without a sync folder).
    initial_dir="$(zgu_ludis_dir "${prefix_dir}")/saves-initial"
    if [[ -d "${initial_dir}" ]]; then
      zgu_cli_ok "$(t saves.initial_exists_cli "${target_name}")"
      exit 0
    fi
    rm -rf -- "${initial_dir}.tmp"
    if [[ -z "${user_dir}" ]]; then initial_ok=true; mkdir -p -- "${initial_dir}.tmp" || initial_ok=false
    else initial_ok=true; saves_pack "${initial_dir}.tmp" || initial_ok=false; fi
    if [[ "${initial_ok}" != true ]] || ! mv -- "${initial_dir}.tmp" "${initial_dir}"; then
      rm -rf -- "${initial_dir}.tmp"
      zgu_cli_error "$(t saves.write_failed_cli "${initial_dir}")"
      exit 1
    fi
    zgu_log "saves" "OK" "slug=${target_slug} action=initial"
    zgu_cli_ok "$(t saves.initial_ok_cli "${target_name}")"
    ;;

  reset)
    initial_dir="$(zgu_ludis_dir "${prefix_dir}")/saves-initial"
    if [[ ! -d "${initial_dir}" ]]; then
      zgu_cli_error "$(t saves.reset_no_initial_cli "${target_name}")"
      exit 1
    fi
    if [[ "${cli_arg}" != "--yes" && "${cli_arg}" != "-y" ]]; then
      if [[ ! -t 0 ]]; then
        zgu_cli_error "$(t saves.reset_need_yes_cli)"
        exit 1
      fi
      read -r -p "$(t saves.reset_confirm_cli "${target_name}")" reply || reply="n"
      case "${reply}" in
        [oOyY]) ;;
        *) echo "$(t saves.reset_cancelled_cli)"; exit 0 ;;
      esac
    fi
    # The current saves are kept once first (sync folder when set, else next to the prefix's own files).
    if [[ -n "${game_sync}" ]]; then
      saves_snapshot_local "before-reset" || { zgu_cli_error "$(t saves.write_failed_cli "${game_sync}")"; exit 1; }
    elif [[ -n "$(saves_items)" ]]; then
      bak="$(zgu_ludis_dir "${prefix_dir}")/saves-before-reset"
      rm -rf -- "${bak}"
      saves_pack "${bak}" || { zgu_cli_error "$(t saves.write_failed_cli "${bak}")"; exit 1; }
    fi
    # Remove exactly the files that count as saves (not the whole folders), then put the initial ones back.
    if saves_pack "${work}/cur"; then
      while IFS= read -r -d '' f; do
        rel="${f#"${work}/cur/"}"
        if [[ "${rel}" = _extra/* ]]; then rm -f -- "${prefix_dir}/drive_c/${rel#_extra/}"; else rm -f -- "${user_dir}/${rel}"; fi
      done < <(find "${work}/cur" -type f -print0)
    fi
    if ! saves_unpack "${initial_dir}"; then
      zgu_cli_error "$(t saves.restore_failed_cli "${target_name}")"
      exit 1
    fi
    zgu_log "saves" "OK" "slug=${target_slug} action=reset"
    zgu_cli_ok "$(t saves.reset_ok_cli "${target_name}")"
    ;;

  path)
    printf '%s\n' "${user_dir}"
    ;;

  pull)
    # Launch of the game (automatic mode): bring the saves of ANOTHER machine/session if the
    # sync folder holds a newer backup than the last one this machine made or took. The local
    # saves are always kept in previous/ first. Prints one status line.
    [[ -n "${game_sync}" && -d "${game_sync}/current" ]] || { echo "pull=no-backup"; exit 0; }
    remote="$(cut -d' ' -f1 "${game_sync}/stamp" 2>/dev/null)"
    [[ "${remote}" =~ ^[0-9]+$ ]] || remote="$(stat -c %Y "${game_sync}/current" 2>/dev/null || echo 0)"
    saves_adopt_config "${game_sync}/config"
    last="$(saves_last_sync "${target_slug}")"
    local_new="$(saves_local_newest)"
    # Nothing to lose locally (game just reinstalled, prefix recreated): always bring the backup, even
    # if this machine "synced" this game before (that memory outlives an uninstall).
    if (( local_new == 0 )); then
      saves_do_restore "before-pull" || { echo "pull=failed"; exit 1; }
      echo "pull=restored label=empty-prefix"
      exit 0
    fi
    if (( remote <= last )); then echo "pull=up-to-date"; exit 0; fi
    if (( last == 0 && local_new > remote )); then echo "pull=local-newer"; exit 0; fi
    label="before-pull"
    (( local_new > last )) && label="conflict"
    saves_do_restore "${label}" || { echo "pull=failed"; exit 1; }
    echo "pull=restored label=${label}"
    ;;

  push)
    # During and at the end of the game (automatic mode): quiet backup once the files stopped changing.
    saves_need_sync_dir >/dev/null 2>&1 || exit 0
    for _ in 1 2 3 4 5 6; do
      (( $(date +%s) - $(saves_local_newest) >= 5 )) && break
      sleep 2
    done
    exec bash "${BASH_SOURCE[0]}" "${cli_slug}" backup >/dev/null 2>&1
    ;;

  auto)
    pg="$(zgu_ludis_path "${prefix_dir}" saves_auto)"
    case "${cli_arg}" in
      "")
        cur="$(tr -d '[:space:]' < "$(zgu_ludis_find "${prefix_dir}" saves_auto)" 2>/dev/null)"
        case "${cur,,}" in on|off) ;; *) cur="follow" ;; esac
        glob="$(saves_conf_get "" auto)"; [[ "${glob,,}" = on ]] || glob=off
        echo "game=${cur} global=${glob}"
        ;;
      follow)
        zgu_ludis_remove "${prefix_dir}" saves_auto; zgu_ludis_prune "${prefix_dir}"
        zgu_cli_ok "$(t saves.auto_game_cli "${target_name}" "${cli_arg}")"
        ;;
      on|off)
        mkdir -p -- "$(dirname "${pg}")" && printf '%s\n' "${cli_arg}" > "${pg}" \
          || { zgu_cli_error "$(t saves.write_failed_cli "${pg}")"; exit 1; }
        zgu_cli_ok "$(t saves.auto_game_cli "${target_name}" "${cli_arg}")"
        ;;
      *) zgu_cli_error "$(t saves.invalid_action_cli "${cli_arg}")"; exit 1 ;;
    esac
    ;;

  exclude)
    xf="$(zgu_ludis_path "${prefix_dir}" saves_exclude)"
    sub="${cli_arg:-list}"; pat_arg="${4:-}"
    case "${sub}" in
      list) saves_list_file_lines "$(zgu_ludis_find "${prefix_dir}" saves_exclude)" ;;
      defaults) printf '%s\n' "${saves_excludes[@]}" ;;
      reset)
        zgu_ludis_remove "${prefix_dir}" saves_exclude; zgu_ludis_prune "${prefix_dir}"
        saves_refresh_config
        zgu_cli_ok "$(t saves.exclude_reset_cli "${target_name}")"
        ;;
      add|remove)
        pat_arg="${pat_arg%/}"
        if [[ -z "${pat_arg}" || "${pat_arg}" = /* || "${pat_arg}" = *..* || "${pat_arg}" = *$'\n'* ]]; then
          zgu_cli_error "$(t saves.folder_invalid_cli "${pat_arg}")"; exit 1
        fi
        mkdir -p -- "$(dirname "${xf}")" || exit 1
        touch "${xf}"
        if [[ "${sub}" = add ]]; then
          grep -qxF -- "${pat_arg}" "${xf}" || printf '%s\n' "${pat_arg}" >> "${xf}"
        else
          grep -vxF -- "${pat_arg}" "${xf}" > "${xf}.tmp"; mv -f -- "${xf}.tmp" "${xf}"
        fi
        saves_refresh_config
        zgu_cli_ok "$(t saves.exclude_updated_cli "${target_name}")"
        ;;
      *) zgu_cli_error "$(t saves.invalid_action_cli "${sub}")"; exit 1 ;;
    esac
    ;;

  folders)
    ff="$(zgu_ludis_path "${prefix_dir}" saves_folders)"
    xf_extra="$(zgu_ludis_path "${prefix_dir}" saves_extra)"
    sub="${cli_arg:-list}"; path_arg="${4:-}"
    case "${sub}" in
      list)
        saves_folder_lines
        saves_extra_lines | sed 's/^/drive_c:/'
        ;;
      reset)
        zgu_ludis_remove "${prefix_dir}" saves_folders; zgu_ludis_remove "${prefix_dir}" saves_extra
        zgu_ludis_prune "${prefix_dir}"
        saves_refresh_config
        zgu_cli_ok "$(t saves.folders_reset_cli "${target_name}")"
        ;;
      add|remove)
        norm="$(saves_norm_folder "${path_arg}")" || { zgu_cli_error "$(t saves.folder_invalid_cli "${path_arg}")"; exit 1; }
        kind="${norm%%$'\t'*}"; rel="${norm#*$'\t'}"
        if [[ "${kind}" = X ]]; then target_file="${xf_extra}"; else target_file="${ff}"; fi
        mkdir -p -- "$(dirname "${target_file}")" || exit 1
        if [[ "${kind}" = U && ! -f "${ff}" ]]; then printf '%s\n' "${saves_dirs[@]}" > "${ff}"; fi
        touch "${target_file}"
        if [[ "${sub}" = add ]]; then
          grep -qxF -- "${rel}" "${target_file}" || printf '%s\n' "${rel}" >> "${target_file}"
        else
          grep -vxF -- "${rel}" "${target_file}" > "${target_file}.tmp"; mv -f -- "${target_file}.tmp" "${target_file}"
        fi
        saves_refresh_config
        zgu_cli_ok "$(t saves.folders_updated_cli "${target_name}")"
        ;;
      *) zgu_cli_error "$(t saves.invalid_action_cli "${sub}")"; exit 1 ;;
    esac
    ;;

  export)
    if [[ -z "$(saves_items)" ]]; then
      zgu_cli_error "$(t saves.nothing_cli "${target_name}")"
      exit 1
    fi
    for tool in zstd tar; do
      command -v "${tool}" >/dev/null 2>&1 || { zgu_cli_error "$(t saves.tool_missing_cli "${tool}")"; exit 1; }
    done
    out="${cli_arg}"
    [[ -z "${out}" ]] && out="${PWD}/${target_slug}-saves.zgs"
    [[ "${out}" = *.zgs ]] || out="${out}.zgs"
    saves_pack "${work}/pack" || { zgu_cli_error "$(t saves.write_failed_cli "${out}")"; exit 1; }
    printf 'ludis-saves=1\nslug=%s\nname=%s\n' "${target_slug}" "${target_name//[$'\n\r']/ }" > "${work}/pack/.ludis-saves"
    saves_write_config "${work}/config.tmp" && grep -E '^(folder|extra|exclude)=' "${work}/config.tmp" >> "${work}/pack/.ludis-saves"
    tmp_out="${out}.tmp-$$"
    if tar -C "${work}/pack" -cf - . | zstd -q -f -o "${tmp_out}" \
       && mv -f -- "${tmp_out}" "${out}"; then
      zgu_log "saves" "OK" "slug=${target_slug} action=export file=${out}"
      zgu_cli_ok "$(t saves.export_ok_cli "${target_name}" "${out}")"
    else
      rm -f -- "${tmp_out}"
      zgu_cli_error "$(t saves.write_failed_cli "${out}")"
      exit 1
    fi
    ;;

  import)
    file="${cli_arg}"
    if [[ -z "${file}" || ! -f "${file}" ]]; then
      zgu_cli_error "$(t saves.import_file_cli "${file}")"
      exit 1
    fi
    for tool in zstd tar; do
      command -v "${tool}" >/dev/null 2>&1 || { zgu_cli_error "$(t saves.tool_missing_cli "${tool}")"; exit 1; }
    done
    # Inspect BEFORE extracting: no absolute path, no "..", no link of any kind.
    listing=$(zstd -dcq -- "${file}" 2>/dev/null | head -c 4294967296 | tar -tvf - 2>/dev/null)
    if [[ -z "${listing}" ]]; then
      zgu_cli_error "$(t saves.import_invalid_cli "${file}")"
      exit 1
    fi
    if printf '%s\n' "${listing}" | awk '{print substr($1,1,1)}' | grep -q '[lh]' \
       || zstd -dcq -- "${file}" 2>/dev/null | head -c 4294967296 | tar -tf - 2>/dev/null | grep -qE '(^|/)\.\.(/|$)|^/'; then
      zgu_cli_error "$(t saves.import_unsafe_cli "${file}")"
      exit 1
    fi
    mkdir -p -- "${work}/src"
    if ! zstd -dcq -- "${file}" | head -c 4294967296 | tar -C "${work}/src" -xf - --no-same-owner --no-same-permissions 2>/dev/null \
       || [[ ! -f "${work}/src/.ludis-saves" ]]; then
      zgu_cli_error "$(t saves.import_invalid_cli "${file}")"
      exit 1
    fi
    saves_adopt_config "${work}/src/.ludis-saves"
    rm -f -- "${work}/src/.ludis-saves"
    # Local saves are kept first: in the sync folder when set, else next to the prefix's own files.
    if [[ -n "${game_sync}" ]]; then
      saves_snapshot_local "before-import" || { zgu_cli_error "$(t saves.write_failed_cli "${game_sync}")"; exit 1; }
    elif [[ -n "$(saves_items)" ]]; then
      bak="$(zgu_ludis_dir "${prefix_dir}")/saves-before-import/$(date +%Y%m%d-%H%M%S)"
      saves_pack "${bak}" || { zgu_cli_error "$(t saves.write_failed_cli "${bak}")"; exit 1; }
    fi
    if ! saves_unpack "${work}/src"; then
      zgu_cli_error "$(t saves.restore_failed_cli "${target_name}")"
      exit 1
    fi
    zgu_log "saves" "OK" "slug=${target_slug} action=import file=${file}"
    zgu_cli_ok "$(t saves.import_ok_cli "${target_name}")"
    ;;
esac
