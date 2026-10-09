#!/bin/bash

# --- Arguments from the lpm router ---
# $1 = confirmation flag ("yes" if -y)
# $2, $3, ... = target game slugs in CLI
confirm_flag="${1:-}"
shift || true
cli_games=("$@")

# Option "--desktop-dir=<path>": custom desktop shortcuts folder used at install time (see
# zgp-game-installer.sh) -- removed from the slug list, and cleaned IN ADDITION to the
# default desktop folder. Used by the GUI to delete a cancelled batch.
desktop_dir_override=""
_filtered_games=()
for _arg in "${cli_games[@]}"; do
  case "${_arg}" in
    --desktop-dir=*) desktop_dir_override="${_arg#--desktop-dir=}" ;;
    *) _filtered_games+=("${_arg}") ;;
  esac
done
cli_games=("${_filtered_games[@]}")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# No target: explicit error (like install, pack...) rather than an empty "success".
if [[ ${#cli_games[@]} -eq 0 ]]; then
  zgu_cli_error "$(t common.missing_target_cli "lpm uninstall")"
  exit 1
fi

# Lutris path configuration
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

games_dir="${HOME}/Games"

# 1. Basic checks (sqlite3 required)
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t uninstall_game.sqlite_missing)"
  exit 1
fi

# 2. Close Lutris first to release the DB
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Flatpak vs native package detection (function from zgu-lutris-utils.sh; also handles
# both being installed)
version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgu_cli_error "$(t uninstall_game.lutris_missing)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_system_file="${lutris_flatpak_system_file}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_db="${lutris_flatpak_db}"
    ;;
  package)
    lutris_system_file="${lutris_package_system_file}"
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_db="${lutris_package_db}"
    ;;
  *)
    # Should never happen: $version is only set to "flatpak" or "package" above (else exit
    # 1). Safeguard in case that invariant changes.
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

# Custom Games path (if set in Lutris): a global preference stored in system.yml ("system:
# game_path:"), not in runners/wine.yml (Wine-runner-only options). See the detailed note in
# zgp-game-installer.sh.
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  if [[ -n "${extracted_path}" ]]; then
    games_dir="${extracted_path}"
  fi
fi

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t uninstall_game.db_missing "${lutris_db}")"
  exit 1
fi

# 4. Fetch Wine games from the Lutris DB
games_list=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || slug || char(31) || directory FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgu_cli_error "$(t uninstall_game.none_found)"
  exit 0
fi

declare -A name_by_slug
declare -A dir_by_slug

# Games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) are
# outside lpm's one-game-one-prefix model and can never be uninstalled via lpm: deleting
# them would break the shared prefix for the other games still living in it (see
# zgu_get_blacklisted_slugs in zgu-lutris-utils.sh).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

while IFS=$'\x1f' read -r game_name game_slug game_dir; do
  [[ -z "${game_name}" ]] && continue
  [[ -n "${blacklisted_slugs[${game_slug}]:-}" ]] && continue

  # game_name (Lutris "name" column) can come from ANY wine game in the DB, not only those
  # installed by lpm (game added manually in Lutris, hand-edited DB...).
  # zgp-game-installer.sh already neutralises any "/" in game_real_name before writing it to
  # the DB ("${game_real_name//\//-}"), but a game added outside lpm can bypass that.
  # game_name is used below to build deletion paths ("${desktop_dir}/${game_name} ..."):
  # without the same filter here, a "/" in the name would target a wrong path instead of the
  # intended shortcut.
  game_name="${game_name//\//-}"

  [[ -z "${game_dir}" ]] && game_dir="${games_dir}/${game_slug}"

  name_by_slug["${game_slug}"]="${game_name}"
  dir_by_slug["${game_slug}"]="${game_dir}"
done <<< "${games_list}"

games_to_delete=()

# Physically deletes a game prefix, but ONLY if it resolves to a direct subfolder of
# games_dir. "directory" in the Lutris DB can come from ANY runner='wine' game, not only
# those installed by lpm (game added manually, hand-edited DB, leftover entry after a
# games-folder change...): without this check, a blind rm -rf on that value could delete an
# arbitrary system folder if "directory" pointed outside games_dir.
# Returns 0 if deleted (or already absent), 1 if the path was judged dangerous (nothing is
# deleted; the caller must warn the user).
safe_delete_prefix_dir() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 0

  local real_dir real_games_dir
  real_dir=$(realpath -e "${dir}" 2>/dev/null)
  real_games_dir=$(realpath -e "${games_dir}" 2>/dev/null)

  if [[ -z "${real_dir}" ]] || [[ -z "${real_games_dir}" ]] || [[ "${real_dir}" != "${real_games_dir}/"* ]]; then
    return 1
  fi

  rm -rf "${real_dir}"
  return 0
}

# --- Target game selection (CLI only; the former Zenity selection was removed) ---
for target_slug in "${cli_games[@]}"; do
  found_name="${name_by_slug[${target_slug}]}"
  if [[ -n "${found_name}" ]]; then
    games_to_delete+=("${target_slug}")
  else
    if [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t uninstall_game.slug_blacklisted "${target_slug}")"
      exit 1
    else
      zgu_cli_error "$(t uninstall_game.slug_not_found "${target_slug}")"
      exit 1
    fi
  fi
done

# 6. Confirmation handling (without the 'yes' flag, ask for a text confirmation in the terminal)
if [[ "${confirm_flag}" != "yes" ]]; then
  t uninstall_game.confirm_cli_header
  for game_slug in "${games_to_delete[@]}"; do
    t uninstall_game.confirm_cli_item "${name_by_slug[${game_slug}]}" "${dir_by_slug[${game_slug}]}"
  done
  read -r -p "$(t uninstall_game.confirm_cli_prompt)" response || response="n"  # EOF (no terminal) = cancel, never an implicit confirmation
  case "${response}" in
    [nN])
      t uninstall_game.confirm_cli_cancelled
      exit 0
      ;;
    *)
      ;;
  esac
fi

# 7. Deletion processing (text output in CLI)
total_games=${#games_to_delete[@]}

# --- EXECUTION (CLI only) ---
# Cancellation (SIGTERM/SIGINT sent by the GUI to the script
# process ONLY, not its children): the game currently being deleted is finished normally
# (never a half-deleted game), then the script stops before the next one. Exit code 130.
cancel_requested=0
trap 'cancel_requested=1' TERM INT

current=0
for game_slug in "${games_to_delete[@]}"; do
  # Everything is indexed by the (unique) SLUG, so games with the same name are not confused.
  game_name="${name_by_slug[${game_slug}]}"
  if [[ "${cancel_requested}" -eq 1 ]]; then
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
    echo "[CANCELLED]"
    t uninstall_game.cancelled_run_cli
    exit 130
  fi
  current=$((current + 1))
  t uninstall_game.progress_cli "${current}" "${total_games}" "${game_name}"

  # game_slug comes from the "slug" column of the Lutris DB, which can come from ANY wine
  # game in the DB, not only those installed by lpm (game added manually, hand-edited DB...)
  # -- same remark as for game_name above. game_slug is used below to build deletion paths
  # (rm -f "${lutris_config_dir}/${game_slug}-"*.yml, "${desktop_dir}/${game_slug}.desktop",
  # etc.): without this filter, a "/" or "../" in the slug could target a path outside its
  # expected folder. Same rejection filter as applied to "slug" in zgp-game-installer.sh.
  case "${game_slug}" in
    */*|.|..|*[$'\n\r\t']*)
      zgu_cli_error "$(t uninstall_game.unsafe_prefix_skip "${game_name}" "${game_slug}")"
      zgu_log "uninstall" "ERREUR" "slug=${game_slug} nom=${game_name} raison=slug_non_sur"
      continue
      ;;
  esac

  # Escaping for consistency with zgp-game-installer.sh: these slugs come from the Lutris DB
  # itself (so are reliable in practice), but any value interpolated into an SQL query must
  # be handled uniformly across the project.
  safe_game_slug="${game_slug//\'/\'\'}"
  prefix_dir=$(sqlite3 "${lutris_db}" "SELECT directory FROM games WHERE slug='${safe_game_slug}' AND runner='wine' LIMIT 1;")
  [[ -z "${prefix_dir}" ]] && prefix_dir="${dir_by_slug[${game_slug}]}"

  # A. Delete the physical prefix on disk
  if ! safe_delete_prefix_dir "${prefix_dir}"; then
    zgu_cli_error "$(t uninstall_game.unsafe_prefix_skip "${game_name}" "${prefix_dir}")"
    zgu_log "uninstall" "ERREUR" "slug=${game_slug} nom=${game_name} raison=prefixe_dangereux dir=${prefix_dir}"
  fi

  # B. Delete the Lutris YML config
  # Lutris names this file "<slug>-<timestamp>.yml" (configpath column in the DB). Delete exactly
  # that one; without a usable configpath, fall back to "<slug>-<digits>.yml" files only -- never
  # "<slug>-*.yml", which would also hit another game whose slug starts with "<slug>-"
  # (e.g. "mario" and "mario-kart").
  config_path=$(sqlite3 "${lutris_db}" "SELECT configpath FROM games WHERE slug='${safe_game_slug}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  case "${config_path}" in
    ""|*/*|.|..) config_path="" ;;
  esac
  if [[ -n "${config_path}" ]]; then
    rm -f "${lutris_config_dir}/${config_path}.yml"
  else
    for cfg_file in "${lutris_config_dir}/${game_slug}-"*.yml; do
      [[ -e "${cfg_file}" ]] || continue
      cfg_base="${cfg_file##*/}"
      [[ "${cfg_base}" =~ ^"${game_slug}"-[0-9]+\.yml$ ]] && rm -f "${cfg_file}"
    done
  fi

  # C. Delete the entry in the SQLite DB
  sqlite3 "${lutris_db}" "DELETE FROM games WHERE slug='${safe_game_slug}';"

  # D. Delete the .desktop shortcuts
  desktop_dir=$(zgu_get_desktop_dir)

  rm -f "${desktop_dir}/${game_slug}.desktop"
  rm -f "${desktop_dir}/${game_name} $(t install_game.bonus_folder_suffix)"
  if [[ -n "${desktop_dir_override}" ]] && [[ "${desktop_dir_override}" != "${desktop_dir}" ]]; then
    rm -f "${desktop_dir_override}/${game_slug}.desktop"
    rm -f "${desktop_dir_override}/${game_name} $(t install_game.bonus_folder_suffix)"
  fi
  rm -f "${HOME}/.local/share/applications/net.lutris.${game_slug}.desktop"

  zgu_log "uninstall" "OK" "slug=${game_slug} nom=${game_name}"
  printf '[REMOVED] %s\n' "${game_slug}"
done

update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
zgu_cli_ok "$(t uninstall_game.done_cli)"

exit 0
