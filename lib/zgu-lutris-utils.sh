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

# Resolves the version to use for THIS lpm run, in this order:
#   1. Environment variable LPM_LUTRIS_VERSION ("flatpak" or "native") -- one-off override, never
#      written to disk.
#   2. Saved config file (ZGU_LUTRIS_VERSION_CONFIG), ONLY if it designates a version still installed
#      -- otherwise it is deleted here (silently) so a "zombie" choice cannot resurface later if the
#      other version is reinstalled in a different context.
#   3. Only one version installed -> used directly, nothing displayed, nothing saved.
#   4. Both installed, nothing saved -> warning + immediate interactive choice, then saved so it is
#      not asked again while both remain installed. A cancelled choice (Zenity closed, or empty CLI
#      answer other than the "2" shortcut) falls back to Flatpak for THIS run only, without saving,
#      so it is asked again next time rather than freezing an unconfirmed choice.
#
# $1 = display mode ("cli" or "gui", same convention as the callers).
# $2 = path of the native package's pga.db (empty string if the caller does not have it).
# $3 = native Wine runners folder, or empty string (see check_native_lutris_installed).
#
# Writes "flatpak" or "native" on stdout. Returns 1 if neither is installed -- displaying the "Lutris
# not found" error is not this function's job; each caller keeps its own message.
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

  if [[ -f "${ZGU_LUTRIS_VERSION_CONFIG}" ]]; then
    local saved
    saved=$(<"${ZGU_LUTRIS_VERSION_CONFIG}")
    saved="${saved//[$'\t\r\n ']/}"
    if [[ "${saved}" = "flatpak" ]] && [[ "${has_flatpak}" = true ]]; then
      echo "flatpak"; return 0
    elif [[ "${saved}" = "native" ]] && [[ "${has_native}" = true ]]; then
      echo "native"; return 0
    else
      rm -f "${ZGU_LUTRIS_VERSION_CONFIG}"
    fi
  fi

  if [[ "${has_flatpak}" = true ]] && [[ "${has_native}" = false ]]; then
    echo "flatpak"; return 0
  fi
  if [[ "${has_native}" = true ]] && [[ "${has_flatpak}" = false ]]; then
    echo "native"; return 0
  fi

  # Both are installed and nothing is saved: warning + immediate choice. "display_mode" is always
  # "cli" now (bin/lpm has no interactive entry point; the GUI always calls this script with explicit
  # targets): no zenity branch here.
  local choice="" confirmed=true
  t common.dual_lutris_warning_cli >&2
  local response
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
  return 0
}

# zgu_get_wine_binary <runner_dir> <version>
# Resolves the path of the wine binary for the given runner version. TWO possible folder layouts,
# checked in the Lutris source (lutris/runners/wine.py: get_executable() calls
# proton.get_proton_wine_path(version) for a Proton version, vs get_path_for_version() -- i.e.
# "bin/wine" -- for a real Wine build; also confirmed by a Proton-GE maintainer on
# github.com/lutris/lutris/issues/6673, describing the "files/bin/wine" layout of Proton runners):
#   - A real Wine build (e.g. "lutris-ge-8.7-x86_64", "wine-11.14-amd64"):
#     <runner_dir>/<version>/bin/wine
#   - A Proton runner (e.g. "GE-Proton11-3", "proton-cachyos-..."), which carries a layout inherited
#     from Steam Play (compatibilitytools.d):
#     <runner_dir>/<version>/files/bin/wine
# Rather than guess from the version NAME (fragile: nothing guarantees a Proton runner name contains
# "proton", or the reverse), the disk is probed directly: both locations are tested in order and the
# first really executable binary is used -- same result as Lutris without a naming convention.
# Output: path on stdout, nothing if not found/not executable (return code 1).
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
