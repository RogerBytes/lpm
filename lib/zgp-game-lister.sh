#!/bin/bash

# --- List the Wine games installed via Lutris ---
# Output: <slug>  <game name>

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

# Lutris path configuration
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

# 1. sqlite3 check
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t list_games.sqlite_missing)"
  exit 1
fi

# 2. Flatpak vs native package detection (function from zgu-lutris-utils.sh; also handles
# both being installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
case "${lutris_version}" in
  flatpak) lutris_db="${lutris_flatpak_db}" ;;
  native) lutris_db="${lutris_package_db}" ;;
  *)
    zgu_cli_error "$(t list_games.lutris_missing)"
    exit 1
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t list_games.db_missing "${lutris_db}")"
  exit 1
fi

# 3. Fetch Wine games (slug then name), sorted by name
games_list=$(sqlite3 "${lutris_db}" "SELECT slug || char(31) || name FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  # On stderr, not stdout: gui/backend.py::list_games() parses all of "lpm list" stdout line
  # by line as "<slug>  <name>" (regex "^(\S+)\s+(.*)$"), so this purely informational
  # message would show up as a fake selectable game.
  t list_games.none_installed >&2
  exit 0
fi

# Games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) are
# outside lpm's one-game-one-prefix model and never listed (see zgu_get_blacklisted_slugs in
# zgu-lutris-utils.sh).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

printed_any=0
while IFS=$'\x1f' read -r slug name; do
  [[ -z "${slug}" ]] && continue
  [[ -n "${blacklisted_slugs[${slug}]:-}" ]] && continue
  echo "${slug}  ${name}"
  printed_any=1
done <<< "${games_list}"

[[ "${printed_any}" -eq 0 ]] && t list_games.none_installed >&2

exit 0
