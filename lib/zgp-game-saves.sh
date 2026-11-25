#!/bin/bash

# --- ludis saves: back up / restore / share the SAVES of ONE game (never the whole prefix) ---
#
#   ludis saves dir [path]                  show or set the sync folder (one subfolder per game)
#   ludis saves <slug> status               what is saved where (local / sync folder)
#   ludis saves <slug> backup               copy the game's saves to <sync>/<slug>/current/
#   ludis saves <slug> restore              copy <sync>/<slug>/current/ back into the prefix
#   ludis saves <slug> export [file.zgs]    make a shareable archive of the saves
#   ludis saves <slug> import <file.zgs>    put the saves of an archive into the prefix
#   ludis saves <slug> pull | push          what the automatic mode does at launch / during and
#                                           at the end of the game (quiet; usable by hand too)
#   ludis saves <slug> auto [follow|on|off] automatic mode for this game (follows the global one)
#   ludis saves <slug> folders [list|add <path>|remove <path>|reset]
#                                           choose the folders (relative to the Windows user folder)
#                                           instead of the default ones; stored in the prefix
#   ludis saves auto [on|off]               global automatic mode (default: on once a sync folder is set)
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
# restore or import overwrites them; "previous/" keeps the 5 latest snapshots.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-ludis-paths.sh
source "${script_dir}/zgu-ludis-paths.sh"

saves_conf="${XDG_CONFIG_HOME:-${HOME}/.config}/ludis/saves.conf"
saves_dirs=(AppData Documents "Saved Games")
saves_keep=5
saves_excludes=(
  "AppData/Local/Temp" "AppData/Local/Temp/*" "AppData/LocalLow/Temp"
  "*/CrashDumps" "*/CrashDumps/*" "*/D3DSCache" "*/D3DSCache/*" "*/GPUCache" "*/GPUCache/*"
  "*/ShaderCache" "*/ShaderCache/*" "*/NVIDIA/DXCache" "*/NVIDIA/GLCache"
  "*/NVIDIA/DXCache/*" "*/NVIDIA/GLCache/*" "*/Code Cache" "*/Code Cache/*"
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

# saves_rotate <previous_dir>: keeps the newest ${saves_keep} snapshots.
saves_rotate() {
  local d n=0
  while IFS= read -r d; do
    n=$((n + 1))
    if (( n > saves_keep )); then rm -rf -- "${d}"; fi
  done < <(find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
  return 0
}

# saves_snapshot_local <label>: copies the CURRENT local saves to <previous>/<date>-<label>/.
saves_snapshot_local() {
  local snap="${game_sync}/previous/$(date +%Y%m%d-%H%M%S)-$1"
  [[ -n "$(saves_items)" ]] || return 0
  mkdir -p -- "${game_sync}/previous" && saves_pack "${snap}" || return 1
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

# saves_do_restore <label>: local saves kept in previous/<date>-<label>, then <sync>/current restored.
saves_do_restore() {
  if [[ ! -d "${game_sync}/current" ]]; then
    zgu_cli_error "$(t saves.no_backup_cli "${target_name}")"
    return 1
  fi
  saves_snapshot_local "$1" || { zgu_cli_error "$(t saves.write_failed_cli "${game_sync}")"; return 1; }
  cp -a -- "${game_sync}/current" "${work}/src" || return 1
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
  if [[ -z "${cli_action}" ]]; then saves_conf_get "" auto | grep -qi '^off' && echo off || echo on; exit 0; fi
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
  status|backup|restore|export|import|pull|push|auto|folders) ;;
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
user_dir="$(saves_user_dir)" || { zgu_cli_error "$(t saves.no_user_dir_cli "${target_name}")"; exit 1; }

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
      echo "backup=$(date -d "@$(cut -d' ' -f1 "${game_sync}/stamp" 2>/dev/null || echo 0)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) previous=$(find "${game_sync}/previous" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    else
      echo "backup=none"
    fi
    ;;

  backup)
    saves_need_sync_dir || exit 1
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
      mkdir -p -- "${game_sync}/previous"
      mv -- "${game_sync}/current" "${game_sync}/previous/$(date +%Y%m%d-%H%M%S)-backup"
      saves_rotate "${game_sync}/previous"
    fi
    mv -- "${game_sync}/.current.tmp" "${game_sync}/current"
    printf '%s %s\n' "$(date +%s)" "$(hostname 2>/dev/null | tr -d ' ')" > "${game_sync}/stamp" 2>/dev/null
    saves_mark_synced "${target_slug}"
    zgu_log "saves" "OK" "slug=${target_slug} action=backup"
    zgu_cli_ok "$(t saves.backup_ok_cli "${target_name}" "${game_sync}/current")"
    ;;

  restore)
    saves_need_sync_dir || exit 1
    saves_do_restore "before-restore" || exit 1
    zgu_cli_ok "$(t saves.restore_ok_cli "${target_name}")"
    ;;

  pull)
    # Launch of the game (automatic mode): bring the saves of ANOTHER machine/session if the
    # sync folder holds a newer backup than the last one this machine made or took. The local
    # saves are always kept in previous/ first. Prints one status line.
    [[ -n "${game_sync}" && -d "${game_sync}/current" ]] || { echo "pull=no-backup"; exit 0; }
    remote="$(cut -d' ' -f1 "${game_sync}/stamp" 2>/dev/null)"
    [[ "${remote}" =~ ^[0-9]+$ ]] || remote="$(stat -c %Y "${game_sync}/current" 2>/dev/null || echo 0)"
    last="$(saves_last_sync "${target_slug}")"
    local_new="$(saves_local_newest)"
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
        glob="$(saves_conf_get "" auto)"; [[ "${glob,,}" = off ]] || glob=on
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

  folders)
    ff="$(zgu_ludis_path "${prefix_dir}" saves_folders)"
    sub="${cli_arg:-list}"; path_arg="${4:-}"
    case "${sub}" in
      list) saves_folder_lines ;;
      reset)
        zgu_ludis_remove "${prefix_dir}" saves_folders; zgu_ludis_prune "${prefix_dir}"
        zgu_cli_ok "$(t saves.folders_reset_cli "${target_name}")"
        ;;
      add|remove)
        path_arg="${path_arg%/}"
        if [[ -z "${path_arg}" || "${path_arg}" = /* || "${path_arg}" = *..* || "${path_arg}" = *$'\n'* ]]; then
          zgu_cli_error "$(t saves.folder_invalid_cli "${path_arg}")"; exit 1
        fi
        mkdir -p -- "$(dirname "${ff}")" || exit 1
        if [[ ! -f "${ff}" ]]; then printf '%s\n' "${saves_dirs[@]}" > "${ff}"; fi
        if [[ "${sub}" = add ]]; then
          grep -qxF -- "${path_arg}" "${ff}" || printf '%s\n' "${path_arg}" >> "${ff}"
        else
          grep -vxF -- "${path_arg}" "${ff}" > "${ff}.tmp" ; mv -f -- "${ff}.tmp" "${ff}"
        fi
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
