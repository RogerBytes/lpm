#!/bin/bash

# --- List isolable games (living in a shared-store "giga prefix") ---
# Output: <slug>  <game name>  <store to target for "lpm isolate">
#
# Dedicated CLI command to inspect/script this list without opening a window. Lists ONLY
# games whose store is actually recognised by zgu_detect_isolation_store (i.e. really
# isolable via "lpm isolate <slug>"): a game blacklisted by the generic detection (shared
# prefix but unrecognised store, e.g. Steam) does not appear, so that no slug is listed
# that "lpm isolate" would then refuse with "unknown store".

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

# 1. sqlite3 check
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t list_isolable.sqlite_missing)"
  exit 1
fi

# 2. Flatpak vs native package detection (function from zgu-lutris-utils.sh; also handles
# both being installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
case "${lutris_version}" in
  flatpak) lutris_db="${lutris_flatpak_db}" ;;
  native) lutris_db="${lutris_package_db}" ;;
  *)
    zgu_cli_error "$(t list_isolable.lutris_missing)"
    exit 1
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t list_isolable.db_missing "${lutris_db}")"
  exit 1
fi

# 3. For each blacklisted slug (shared prefix), resolve the name + the store actually targeted
printed_any=0
while IFS= read -r bl_slug; do
  [[ -z "${bl_slug}" ]] && continue
  safe_bl="${bl_slug//\'/\'\'}"
  row=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || directory FROM games WHERE runner='wine' AND slug='${safe_bl}' LIMIT 1;" 2>/dev/null)
  IFS=$'\x1f' read -r bl_name bl_dir <<< "${row}"
  [[ -z "${bl_name}" ]] && continue

  # "directory" comes from the Lutris DB as everywhere else in lpm: resolved to a real path
  # before any use (same caution as zgp-game-isolator.sh), even though here it is only
  # read/displayed.
  real_dir=$(realpath -e "${bl_dir}" 2>/dev/null)
  [[ -z "${real_dir}" ]] && continue

  store=$(zgu_detect_isolation_store "${lutris_db}" "${real_dir}")
  [[ -z "${store}" ]] && continue

  # The store launcher itself (Battle.net, Epic Games Store, ...) is never an isolable game
  # -- see zgu_is_store_launcher_name in zgu-lutris-utils.sh -- so it is never listed here,
  # consistent with "lpm isolate" not trying to isolate it either.
  zgu_is_store_launcher_name "${store}" "${bl_name}" && continue

  store_label=$(zgu_store_display_name "${store}")
  echo "${bl_slug}  ${bl_name}  ${store_label}"
  printed_any=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

[[ "${printed_any}" -eq 0 ]] && t list_isolable.none_found >&2

exit 0
