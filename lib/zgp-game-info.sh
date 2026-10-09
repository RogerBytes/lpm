#!/bin/bash

# --- lpm info <slug> ---
#
# Shows the known metadata of an installed Wine game, combining the Lutris DB (pga.db) and
# the game's YAML config file (games/<configpath>.yml): name, slug, wineprefix folder,
# executable, Wine/Proton runner version used, install date, and isolation status (dedicated
# prefix, or shared store + the store targeted by "lpm isolate" if any).
#
# One slug at a time (unlike install/uninstall/pack, which accept a list): this is a
# detailed lookup command, not a batch action.

# --- Arguments from the lpm router ---
slug="${1:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

if [[ -z "${slug}" ]]; then
  zgu_cli_error "$(t info.missing_slug)"
  exit 1
fi

lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

# 1. sqlite3 check
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t info.sqlite_missing)"
  exit 1
fi

# 2. Flatpak vs native package detection (function from zgu-lutris-utils.sh; also handles
# both being installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
case "${lutris_version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    ;;
  native)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    ;;
  *)
    zgu_cli_error "$(t info.lutris_missing)"
    exit 1
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t info.db_missing "${lutris_db}")"
  exit 1
fi

# 3. Read the game row -- runner='wine' as everywhere else in lpm: an existing slug with
# another runner (entry added manually to the DB, outside lpm) is not a game lpm knows.
safe_slug="${slug//\'/\'\'}"
row=$(sqlite3 "${lutris_db}" "SELECT COALESCE(name,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') || char(31) || COALESCE(installed_at,'') FROM games WHERE runner='wine' AND slug='${safe_slug}' LIMIT 1;" 2>/dev/null)

if [[ -z "${row}" ]]; then
  zgu_cli_error "$(t info.not_found "${slug}")"
  exit 1
fi

IFS=$'\x1f' read -r game_name game_dir game_exe game_configpath game_installed_at <<< "${row}"

# 4. Resolve to the real wineprefix path (same caution as the rest of lpm: the value comes
# from the Lutris DB, possibly hand-edited) -- for display only, never used to write or
# delete anything.
real_dir=$(realpath -e "${game_dir}" 2>/dev/null)
[[ -z "${real_dir}" ]] && real_dir="${game_dir}"

# 5. Wine/Proton runner version actually used by THIS game (wine.version key of the YAML
# config, read as in zgc-dependency-checker.sh) -- distinct from the global default runner
# (zgu_get_default_runner): a game may have been installed with a specific runner different
# from the current default.
runner_version=""
if [[ -n "${game_configpath}" ]]; then
  # configpath comes from the Lutris DB: same path-traversal filter as zgp-game-isolator.sh
  # (no "/", otherwise refuse to build the path). Read-only here, but same caution as
  # elsewhere in lpm.
  if [[ "${game_configpath}" != *"/"* ]]; then
    yml_path="${lutris_config_dir}/${game_configpath}.yml"
    if [[ -f "${yml_path}" ]] && command -v python3 >/dev/null 2>&1; then
      runner_version=$(YML_PATH="${yml_path}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("wine", {}).get("version", ""))
except Exception:
    pass
' 2>/dev/null)
    fi
  fi
fi
[[ -z "${runner_version}" ]] && runner_version="$(t info.unknown)"

# 6. Install date (installed_at, Unix timestamp in seconds -- see the INSERT in
# zgp-game-installer.sh/zgp-game-isolator.sh) -- falls back to the raw value if "date"
# cannot format it (unexpected locale/format) rather than showing an empty field.
installed_display="${game_installed_at}"
if [[ "${game_installed_at}" =~ ^[0-9]+$ ]]; then
  formatted=$(date -d "@${game_installed_at}" +%F 2>/dev/null)
  [[ -n "${formatted}" ]] && installed_display="${formatted}"
fi
[[ -z "${installed_display}" ]] && installed_display="$(t info.unknown)"

# 7. Isolation status: dedicated prefix (one-game-one-prefix, the normal case), or shared
# prefix -- in which case the targeted store is given if recognised (same detection as "lpm
# isolate"/"lpm list-isolable", see zgu_detect_isolation_store), so the displayed info never
# diverges from what those commands would actually do.
isolation_status="$(t info.isolation_dedicated)"
if [[ -n "${real_dir}" ]]; then
  shared_count=$(sqlite3 "${lutris_db}" "SELECT COUNT(*) FROM games WHERE runner='wine' AND directory='${real_dir//\'/\'\'}';" 2>/dev/null)
  if [[ "${shared_count:-0}" -gt 1 ]]; then
    store=$(zgu_detect_isolation_store "${lutris_db}" "${real_dir}")
    if [[ -n "${store}" ]]; then
      store_label=$(zgu_store_display_name "${store}")
      isolation_status="$(t info.isolation_shared_known "${store_label}" "${slug}")"
    else
      isolation_status="$(t info.isolation_shared_unknown)"
    fi
  fi
fi

# 8. Display
t info.field_name "${game_name}"
t info.field_slug "${slug}"
t info.field_directory "${real_dir}"
t info.field_executable "${game_exe:-$(t info.unknown)}"
t info.field_runner_version "${runner_version}"
t info.field_installed_at "${installed_display}"
t info.field_isolation "${isolation_status}"

exit 0
