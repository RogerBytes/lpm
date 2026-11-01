#!/bin/bash

# --- Shared utilities for detecting the Lutris installation (Flatpak vs native package) ---
#
# check_flatpak_lutris_installed() is used by the 9 lib/ files that need to know whether Lutris is
# installed (zgc-dependency-checker.sh, zgp-game-installer.sh, zgp-game-lister.sh,
# zgp-game-uninstaller.sh, zgr-runner-installer.sh, zgr-runner-lister.sh, zgr-runner-packer.sh,
# zgr-runner-remote-lister.sh, zgr-runner-uninstaller.sh). A single sourced definition keeps the
# detection consistent everywhere. Detection based on leftover files (pga.db, games/ folder) rather
# than the installed application could read the wrong database if an old Flatpak or native profile
# lingers after switching install method.
#
# This file prints nothing (no zenity, no echo): it is a pure detection function; each caller stays
# responsible for resolving the paths that depend on it.

# Returns 0 (true) if Lutris is installed via Flatpak, 1 (false) otherwise (native package or absent).
check_flatpak_lutris_installed() {
  flatpak list 2>/dev/null | grep -q lutris
}

# Returns 0 (true) if Lutris appears installed as a native package (as opposed to Flatpak), 1 (false)
# otherwise.
#
# Detection is based only on the real EXECUTABLE being on disk -- in the PATH (normal case), or at one
# of the standard Lutris package locations (Debian/RPM/Arch) even if the PATH does not contain it
# (non-standard install). Never on data files: uninstalling the native package (apt/dnf/pacman) never
# touches "~/.local/share/lutris/" (USER data, not managed by any package manager), so pga.db and
# runners/wine stay orphaned there forever and would keep reporting a removed native Lutris as
# installed.
check_native_lutris_installed() {
  command -v lutris >/dev/null 2>&1 && return 0

  local candidate
  for candidate in /usr/bin/lutris /usr/local/bin/lutris /usr/games/lutris /opt/lutris/bin/lutris; do
    [[ -x "${candidate}" ]] && return 0
  done

  return 1
}

# Sets ALL the paths of a Lutris install (arg: flatpak | native), so no command repeats this
# list. Sets:
#   lutris_version     flatpak | native
#   version            flatpak | package (word written in the Exec= of shortcuts, kept as is)
#   lutris_db          pga.db
#   lutris_config_dir  games/*.yml
#   lutris_system_file system.yml
#   lutris_data_dir    Lutris data folder (banners/, coverart/, runners/, runtime/)
#   runner_dir         runners/wine
#   runtime_dir        runtime
#   lutris_umu         runtime/umu/umu-run
#   games_dir          game_path of system.yml, else ~/Games
# Creates nothing. zgu_load_lutris_env (below) detects the install first.
# shellcheck disable=SC2034  # the variables are read by the commands that call these functions
zgu_set_lutris_paths() {
  lutris_version="$1"
  case "${lutris_version}" in
    flatpak)
      version="flatpak"
      lutris_data_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris"
      lutris_config_dir="${lutris_data_dir}/games"
      lutris_system_file="${lutris_data_dir}/system.yml"
      ;;
    native)
      version="package"
      lutris_data_dir="${HOME}/.local/share/lutris"
      lutris_config_dir="${HOME}/.config/lutris/games"
      lutris_system_file="${HOME}/.config/lutris/system.yml"
      ;;
    *)
      return 1
      ;;
  esac
  lutris_db="${lutris_data_dir}/pga.db"
  runner_dir="${lutris_data_dir}/runners/wine"
  runtime_dir="${lutris_data_dir}/runtime"
  lutris_umu="${runtime_dir}/umu/umu-run"

  games_dir="${HOME}/Games"
  if [[ -f "${lutris_system_file}" ]]; then
    local extracted_path
    extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
    [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
  fi
  return 0
}

# Same, but detects which Lutris is in use first (asks once if both are installed, see
# zgu_resolve_lutris_version). Returns 1 if no Lutris is installed.
zgu_load_lutris_env() {
  local detected
  detected=$(zgu_resolve_lutris_version "cli" "${HOME}/.local/share/lutris/pga.db" "${HOME}/.local/share/lutris/runners/wine")
  [[ -n "${detected}" ]] || return 1
  zgu_set_lutris_paths "${detected}"
}

# Returns (on stdout) the default Wine/Proton runner configured globally in Lutris (key "version:" of
# runners/wine.yml, whether Flatpak or native package), or "proton-cachyos-x86_64" if no file is
# found or readable.
#
# Used by zgp-game-installer.sh and zgp-game-packer.sh: a single definition keeps the default
# fallback runner identical everywhere.
zgu_get_default_runner() {
  local runners_path found=""
  for runners_path in \
    "${HOME}/.local/share/lutris/runners/wine.yml" \
    "${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine.yml" \
    "${HOME}/.config/lutris/runners/wine.yml"; do
    if [[ -f "${runners_path}" ]]; then
      found=$(awk -F': ' '/^[[:space:]]*version:/ {print $2; exit}' "${runners_path}" | tr -d '"'\''[:space:]')
      [[ -n "${found}" ]] && break
    fi
  done
  [[ -z "${found}" ]] && found="proton-cachyos-x86_64"
  echo "${found}"
}

# --- Detection of games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) ---
#
# lpm applies the one-game-one-prefix principle, but Lutris does not always create a wineprefix per
# game: some third-party launchers (client installed + games inside) create ONE wineprefix shared by
# several games (identical "directory" on several rows of the games table). Those games must appear
# nowhere in lpm (not listed, packable or uninstallable), or the shared prefix would break for the
# other games living in it.
#
# GOG, itch.io and ZOOM Platform were verified to already follow one-game-one-prefix (each game has
# its own "directory" in the database, even if in a subfolder like gog/<game>/): they are NOT in this
# list.
ZGU_STORE_KEYWORDS=("Epic Games Store" "EA App" "EA Desktop" "Ubisoft Connect" "Battle.net" "Steam")

# Returns (on stdout, one slug per line) the slugs of runner='wine' games to exclude from lpm: those
# whose "directory" is shared by at least one other entry of the games table (main signal, detects any
# shared-prefix store automatically without knowing its name), plus a keyword safety net
# (ZGU_STORE_KEYWORDS) to also block a freshly installed but still empty store (no duplicated
# "directory" detectable yet).
#
# Prints nothing and modifies nothing: a pure read function, called by each script
# (lister/packer/uninstaller) to filter its own game list.
zgu_get_blacklisted_slugs() {
  local lutris_db="$1"
  [[ -f "${lutris_db}" ]] || return 0

  local rows
  rows=$(sqlite3 "${lutris_db}" "SELECT slug || char(31) || name || char(31) || directory FROM games WHERE runner='wine';" 2>/dev/null)
  [[ -z "${rows}" ]] && return 0

  local -A dir_count
  local slug name dir
  while IFS=$'\x1f' read -r slug name dir; do
    [[ -z "${dir}" ]] && continue
    dir_count["${dir}"]=$(( ${dir_count["${dir}"]:-0} + 1 ))
  done <<< "${rows}"

  local kw is_blacklisted
  while IFS=$'\x1f' read -r slug name dir; do
    [[ -z "${slug}" ]] && continue
    is_blacklisted=0

    if [[ -n "${dir}" ]] && [[ "${dir_count[${dir}]:-0}" -gt 1 ]]; then
      is_blacklisted=1
    fi

    if [[ "${is_blacklisted}" -eq 0 ]]; then
      for kw in "${ZGU_STORE_KEYWORDS[@]}"; do
        # Whole word only: "Steam" must not hide "SteamWorld Dig".
        if [[ " ${name} " == *[^[:alnum:]]"${kw}"[^[:alnum:]]* ]]; then
          is_blacklisted=1
          break
        fi
      done
    fi

    [[ "${is_blacklisted}" -eq 1 ]] && echo "${slug}"
  done <<< "${rows}"
}

# --- Store detection (Epic/EA/Ubisoft/Battle.net) for a given giga-prefix ---
#
# Shared by zgp-game-isolator.sh ("lpm isolate") and zgp-isolable-lister.sh ("lpm list-isolable"):
# a single definition keeps the list shown by list-isolable and the store actually targeted by
# isolate consistent.
#
# Distinct from ZGU_STORE_KEYWORDS above, which also includes "Steam" for the general blacklist safety
# net: Steam is out of scope here (lpm does not manage Steam games). Only the 4 documented stores are
# recognized; a shared prefix that is not one of them (unknown store, or blacklisted only by generic
# duplicated-"directory" detection) returns 1 and prints nothing: neither isolate nor list-isolable
# must guess a store they cannot handle.
zgu_detect_isolation_store() {
  local lutris_db="$1" giga_dir="$2" safe_dir rows name
  safe_dir="${giga_dir//\'/\'\'}"
  rows=$(sqlite3 "${lutris_db}" "SELECT name FROM games WHERE runner='wine' AND directory='${safe_dir}';" 2>/dev/null)
  while IFS= read -r name; do
    case "${name}" in
      *"Epic Games Store"*) echo "egs"; return 0 ;;
      *"EA App"*|*"EA Desktop"*) echo "ea"; return 0 ;;
      *"Ubisoft Connect"*) echo "ubisoft"; return 0 ;;
      *"Battle.net"*) echo "battlenet"; return 0 ;;
    esac
  done <<< "${rows}"
  return 1
}

# Converts an internal store code (returned by zgu_detect_isolation_store) to its full display name,
# for humans (list-isolable, isolate messages).
zgu_store_display_name() {
  case "$1" in
    egs) echo "Epic Games Store" ;;
    ea) echo "EA App / EA Desktop" ;;
    ubisoft) echo "Ubisoft Connect" ;;
    battlenet) echo "Battle.net" ;;
    *) echo "$1" ;;
  esac
}

# The launcher itself (Epic Games Launcher, EA App/Desktop, Ubisoft Connect, Battle.net) lives in the
# same shared giga-prefix as the games, so it also shows up as a "runner=wine" entry in pga.db with a
# shared "directory" -- the same signal as a real game (see zgu_get_blacklisted_slugs above). It is
# never a game to isolate individually: it is already duplicated entirely (the "base") into the new
# prefix of EACH isolated game (see "1. Copie du socle" in zgp-game-isolator.sh), so isolating the
# launcher on its own makes no sense and always fails (no game folder of its own).
#
# Exact names under which Lutris/lpm knows these entries (a subset of ZGU_STORE_KEYWORDS above) --
# shared by "lpm isolate" (must never try to isolate it) and "lpm list-isolable" (must never list
# it), so both commands always agree.
zgu_is_store_launcher_name() {
  local store="$1" name="$2"
  case "${store}" in
    egs) [[ "${name}" = "Epic Games Store" ]] ;;
    ea) [[ "${name}" = "EA App" ]] || [[ "${name}" = "EA Desktop" ]] ;;
    ubisoft) [[ "${name}" = "Ubisoft Connect" ]] ;;
    battlenet) [[ "${name}" = "Battle.net" ]] ;;
    *) return 1 ;;
  esac
}

# --- Resolution of the Lutris version to use (Flatpak vs native package) when both are installed ---
#
# Callers used to do "if check_flatpak_lutris_installed; then ... elif check_native_lutris_installed;
# then ...": with both present, Flatpak silently won, with no message telling the user their native
# library (games/runners) was ignored.
#
# Persistent config file for the choice forced by the user, in the same folder as the SteamGridDB key
# (~/.config/lpm/): same persistence conventions across the project.
ZGU_LUTRIS_VERSION_CONFIG="${HOME}/.config/lpm/lutris-version"

# Resolves the Lutris version to use for THIS lpm run, in this order:
#   1. LPM_LUTRIS_VERSION ("flatpak" or "native"): one-off override, never written to disk.
#   2. The saved choice (ZGU_LUTRIS_VERSION_CONFIG), ONLY if that version is still installed;
#      otherwise it is silently deleted so a stale choice cannot come back later.
#   3. Only one version installed: used directly, nothing displayed or saved.
#   4. Both installed, nothing saved: warning + interactive choice, then saved. A cancelled choice
#      (Zenity closed, empty CLI answer other than "2") means Flatpak for THIS run only, unsaved.
#
# $1 = display mode ("cli" or "gui"). $2 = path of the native package's pga.db (empty if unknown).
# $3 = native Wine runners folder, or empty (see check_native_lutris_installed).
#
# Writes "flatpak" or "native" on stdout. Returns 1 if neither is installed (the "Lutris not
# found" message is each caller's job).
# Saved choice (ZGU_LUTRIS_VERSION_CONFIG): prints it if that version is still installed (has_*
# args), otherwise deletes the stale file. Args: has_flatpak has_native. Returns 0 if printed.
_zgu_saved_lutris_version() {
  local has_flatpak="$1" has_native="$2" saved
  [[ -f "${ZGU_LUTRIS_VERSION_CONFIG}" ]] || return 1
  saved=$(<"${ZGU_LUTRIS_VERSION_CONFIG}")
  saved="${saved//[$'\t\r\n ']/}"
  if [[ "${saved}" = "flatpak" ]] && [[ "${has_flatpak}" = true ]]; then
    echo "flatpak"; return 0
  elif [[ "${saved}" = "native" ]] && [[ "${has_native}" = true ]]; then
    echo "native"; return 0
  fi
  rm -f "${ZGU_LUTRIS_VERSION_CONFIG}"
  return 1
}

# Both versions installed, nothing saved: warning + immediate CLI choice, saved unless the answer
# was cancelled (then Flatpak for THIS run only). "display_mode" is always "cli" now (bin/lpm has
# no interactive entry point): no zenity branch.
_zgu_ask_lutris_version() {
  local choice="" confirmed=true response
  t common.dual_lutris_warning_cli >&2
  read -r -p "$(t common.dual_lutris_prompt_cli)" response
  case "${response}" in
    2) choice="native" ;;
    1|"") choice="flatpak" ;;
    *) choice="flatpak"; confirmed=false ;;
  esac

  if [[ "${confirmed}" = true ]]; then
    mkdir -p "$(dirname "${ZGU_LUTRIS_VERSION_CONFIG}")"
    echo "${choice}" > "${ZGU_LUTRIS_VERSION_CONFIG}"
  fi
  echo "${choice}"
}

zgu_resolve_lutris_version() {
  # $1 (display mode, "cli" for all callers) is no longer used; kept in first position so callers
  # need no change.
  local package_db="$2" package_runner_dir="$3"

  local has_flatpak=false has_native=false
  check_flatpak_lutris_installed && has_flatpak=true
  check_native_lutris_installed "${package_db}" "${package_runner_dir}" && has_native=true

  if [[ "${has_flatpak}" = false ]] && [[ "${has_native}" = false ]]; then
    return 1
  fi

  case "${LPM_LUTRIS_VERSION:-}" in
    flatpak) [[ "${has_flatpak}" = true ]] && { echo "flatpak"; return 0; } ;;
    native) [[ "${has_native}" = true ]] && { echo "native"; return 0; } ;;
  esac

  _zgu_saved_lutris_version "${has_flatpak}" "${has_native}" && return 0

  if [[ "${has_flatpak}" = true ]] && [[ "${has_native}" = false ]]; then
    echo "flatpak"; return 0
  fi
  if [[ "${has_native}" = true ]] && [[ "${has_flatpak}" = false ]]; then
    echo "native"; return 0
  fi

  _zgu_ask_lutris_version
}

# zgu_get_wine_binary <runner_dir> <version>
# Resolves the wine binary of a runner version. Two folder layouts exist (lutris/runners/wine.py):
#   - a real Wine build (e.g. "wine-11.14-amd64"):  <runner_dir>/<version>/bin/wine
#   - a Proton runner (e.g. "GE-Proton11-3"), Steam Play layout: <runner_dir>/<version>/files/bin/wine
# The name is not a reliable hint (nothing guarantees a Proton runner's name contains "proton"), so
# both locations are probed and the first executable one wins.
# Output: path on stdout, nothing (return 1) if not found/not executable.
zgu_get_wine_binary() {
  local runner_dir="$1" version="$2" candidate
  [[ -z "${version}" ]] && return 1
  for candidate in \
    "${runner_dir}/${version}/bin/wine" \
    "${runner_dir}/${version}/files/bin/wine"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

# zgu_resolve_prefix_dir_by_slug <slug> <pga.db> <games folder>: real path of the prefix of a wine
# game, from its "directory" in pga.db. The slug is SQL-escaped here. "directory" may come from
# ANY wine game in pga.db, not only those managed by lpm: the resolved path must remain a real
# subfolder of the games folder (anti-escape guard, same as zgp-game-uninstaller.sh), otherwise
# an intermediate folder (e.g. "gog/") shared by several games could be packed wholesale or a
# forged entry could point elsewhere.
# Output: real path on stdout, nothing if not found/unsafe (return code 1).
zgu_resolve_prefix_dir_by_slug() {
  local slug="$1" db="$2" games_root="$3" safe_slug raw_dir real_dir real_games_dir
  safe_slug="${slug//\'/\'\'}"
  raw_dir=$(sqlite3 "${db}" "SELECT directory FROM games WHERE slug='${safe_slug}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  [[ -z "${raw_dir}" ]] && return 1

  real_dir=$(realpath -e "${raw_dir}" 2>/dev/null)
  real_games_dir=$(realpath -e "${games_root}" 2>/dev/null)
  if [[ -z "${real_dir}" ]] || [[ -z "${real_games_dir}" ]] || [[ "${real_dir}" != "${real_games_dir}/"* ]]; then
    return 1
  fi
  echo "${real_dir}"
}
