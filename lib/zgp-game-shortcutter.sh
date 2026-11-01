#!/bin/bash

# --- Shortcut generation (applications menu / desktop) for already installed games ---
#
# Unlike zgp-game-installer.sh (which offers shortcut creation only when installing a .zgp),
# this command (re)generates shortcuts afterwards for any game already in Lutris -- e.g. to
# regenerate a shortcut after the default icon was fixed (see zgu_write_game_shortcut in
# zgu-desktop-utils.sh), or for a game added to Lutris by other means than lpm.
#
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-games-cli.sh
source "${script_dir}/zgu-games-cli.sh"
# shellcheck source=./zgu-lpm-paths.sh
source "${script_dir}/zgu-lpm-paths.sh"
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"

# --- Argument parsing (from bin/lpm) ---
# $1, $2... = target game slugs, or "--all" for all installed Wine games, plus these
# options accepted anywhere among them (short AND long forms, as elsewhere in the project):
#   -s, --shortcut=<menu|desktop|both|none>   where to (re)generate shortcut(s)
#                                              (default "both")
#   -n, --no-loadingscreen                    disable the lpm loading screen for these
#                                              game(s) (default: enabled, see
#                                              zgl-launcher-orchestrator.sh)
#   -k, --allow-hooks                         allow the Lutris launch hooks
#                                              (prelaunch_command/prelaunch_wait/
#                                              postexit_command) already configured for
#                                              these game(s); default: disabled for safety
#                                              (commented out in their YAML, never deleted;
#                                              see zgu_apply_hook_policy)
#   --desktop-dir=<path>                      folder for the desktop shortcut, instead of the
#                                              one detected by zgu_get_desktop_dir();
#                                              no effect if no desktop shortcut is requested
#                                              (shortcut_mode "menu" or "none")
# No confirmation flag: this command only writes .desktop files and disables/restores
# existing config lines, nothing destructive.
shortcut_mode="both"
loadingscreen_enabled=true
allow_hooks=false
desktop_dir_override=""
cli_targets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--shortcut)
      shortcut_mode="${2:-both}"
      shift $(( $# >= 2 ? 2 : 1 ))
      ;;
    --shortcut=*)
      shortcut_mode="${1#--shortcut=}"
      shift
      ;;
    -n|--no-loadingscreen)
      loadingscreen_enabled=false
      shift
      ;;
    -k|--allow-hooks)
      allow_hooks=true
      shift
      ;;
    --desktop-dir=*)
      desktop_dir_override="${1#--desktop-dir=}"
      shift
      ;;
    *)
      cli_targets+=("$1")
      shift
      ;;
  esac
done

case "${shortcut_mode}" in
  menu | desktop | both | none) ;;
  *)
    zgu_cli_error "$(t shortcut.invalid_shortcut_mode_cli "${shortcut_mode}")"
    exit 1
    ;;
esac

# Lutris path configuration



# Installed Wine/Proton builds folder: see the detailed note in zgp-game-installer.sh
# (needed by zgu_write_game_shortcut to tell a Proton runner from classic Wine).


# 1. sqlite3 check
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t shortcut.sqlite_missing)"
  exit 1
fi

# 2. Flatpak vs native package detection (function from zgu-lutris-utils.sh; also handles
# both being installed)
zgu_load_lutris_env || {
  zgu_cli_error "$(t shortcut.lutris_missing)"
  exit 1
}

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t shortcut.db_missing "${lutris_db}")"
  exit 1
fi

# 3. Fetch Wine games from the Lutris DB (id is needed to build "lutris:rungameid/<id>" in
# the shortcut; configpath to find the game's YAML config -- see zgu_write_game_shortcut)
#
# COALESCE(...,'') on EVERY column is required: in SQLite, NULL || anything is NULL for the
# whole concatenation, so a game with an empty "executable" (prefix just (re)created in
# Lutris, .exe not yet configured) would drop the entire row (sqlite3 prints an empty line,
# skipped by the "[[ -z "${game_name}" ]] && continue" below) and become unfindable for "lpm
# shortcut" ("Game not found") although it exists in the DB.
zgp_games_load shortcut zgu_cli_error blacklist sanitize

# The shortcuts are chosen by game name: index the slug and folder by name too.
declare -A slug_by_name dir_by_name
sorted_game_names=()
for game_slug in "${sorted_slugs[@]}"; do
  slug_by_name["${name_by_slug[${game_slug}]}"]="${game_slug}"
  dir_by_name["${name_by_slug[${game_slug}]}"]="${dir_by_slug[${game_slug}]}"
  sorted_game_names+=("${name_by_slug[${game_slug}]}")
done

games_to_process=()
create_menu=false
create_desktop=false
# "loadingscreen_enabled" and "allow_hooks": see -n/--no-loadingscreen and -k/--allow-hooks
# above (available in both CLI and GUI, see gui/*.py).

# --- Target selection ---
# "lpm shortcut" always requires slugs (or "--all") on the command line; the former
# interactive Zenity mode was removed.
if [[ ${#cli_targets[@]} -eq 0 ]]; then
  zgu_cli_error "$(t common.missing_target_cli "lpm shortcut")"
  exit 1
elif [[ "${cli_targets[0]}" = "--all" ]]; then
  games_to_process=("${sorted_game_names[@]}")
else
  for target_slug in "${cli_targets[@]}"; do
    found_name="${name_by_slug[${target_slug}]}"
    if [[ -n "${found_name}" ]]; then
      games_to_process+=("${found_name}")
    elif [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t shortcut.slug_blacklisted "${target_slug}")"
      exit 1
    else
      zgu_cli_error "$(t shortcut.slug_not_found "${target_slug}")"
      exit 1
    fi
  done
fi

# Resolve "shortcut_mode" (see -s/--shortcut above) into the two booleans expected by
# zgu_write_game_shortcut; its validity was already checked above, so there is no "*)" case.
case "${shortcut_mode}" in
  both) create_menu=true; create_desktop=true ;;
  menu) create_menu=true; create_desktop=false ;;
  desktop) create_menu=false; create_desktop=true ;;
  none) create_menu=false; create_desktop=false ;;
esac

# 4. Generate the shortcuts (function shared with zgp-game-installer.sh -- see
# zgu_write_game_shortcut in zgu-desktop-utils.sh)
for game_name in "${games_to_process[@]}"; do
  game_slug="${slug_by_name[${game_name}]}"
  game_id="${id_by_slug[${game_slug}]}"
  game_prefix_dir="${dir_by_name[${game_name}]}"
  game_exe="${exe_by_slug[${game_slug}]}"
  game_configpath="${configpath_by_slug[${game_slug}]}"

  zgu_write_game_shortcut "${game_name}" "${game_slug}" "${game_prefix_dir}" "${game_id}" "${version}" "${create_menu}" "${create_desktop}" "${game_exe}" "${game_configpath}" "${lutris_config_dir}" "${runner_dir}" "${desktop_dir_override}"

  # Loading-screen marker (see lib/zgl-launcher-orchestrator.sh): idempotent for both first
  # creation and regeneration -- created when the loading screen is unchecked, removed when
  # checked, whatever the previous state.
  if [[ "${loadingscreen_enabled}" = true ]]; then
    zgu_lpm_remove "${game_prefix_dir}" no_loadingscreen
    zgu_lpm_prune "${game_prefix_dir}"
  else
    zgu_lpm_remove "${game_prefix_dir}" no_loadingscreen
    mkdir -p "$(dirname "$(zgu_lpm_path "${game_prefix_dir}" no_loadingscreen)")" 2>/dev/null
    : > "$(zgu_lpm_path "${game_prefix_dir}" no_loadingscreen)" 2>/dev/null
  fi

  # Disable/restore the Lutris launch hooks (see zgu_apply_hook_policy in
  # zgu-desktop-utils.sh) -- no-op if "game_configpath" is empty (no resolved YAML config)
  # or the file does not exist.
  if [[ -n "${game_configpath}" ]]; then
    zgu_apply_hook_policy "${lutris_config_dir}/${game_configpath}.yml" "${allow_hooks}"
  fi

  t shortcut.created_cli "${game_name}"
done

exit 0
