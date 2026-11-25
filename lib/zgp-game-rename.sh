#!/bin/bash

# --- ludis rename <slug> "<new display name>": changes the name Lutris shows for a game ---
# Only the display name (Lutris database) changes: the slug, the game folder and the prefix stay
# as they are. The next export uses the name Lutris shows, so exporting again keeps the new name.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

slug="${1:-}"
new_name="${2:-}"

if [[ -z "${slug}" || -z "${new_name}" ]]; then
  zgu_cli_error "$(t common.missing_target_cli "ludis rename <slug> <name>")"
  exit 1
fi
# Trim, refuse control characters and absurd lengths.
new_name="$(printf '%s' "${new_name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "${new_name}" || "${#new_name}" -gt 100 || "${new_name}" =~ [[:cntrl:]] ]]; then
  zgu_cli_error "$(t rename_game.invalid_name_cli)"
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t list_games.sqlite_missing)"
  exit 1
fi
zgu_load_lutris_env || {
  zgu_cli_error "$(t list_games.lutris_missing)"
  exit 1
}
[[ -f "${lutris_db}" ]] || { zgu_cli_error "$(t list_games.db_missing "${lutris_db}")"; exit 1; }

safe_slug="${slug//\'/\'\'}"
old_name=$(sqlite3 "${lutris_db}" "SELECT name FROM games WHERE slug='${safe_slug}' AND runner='wine' LIMIT 1;" 2>/dev/null)
if [[ -z "${old_name}" ]]; then
  zgu_cli_error "$(t rename_game.not_found_cli "${slug}")"
  exit 1
fi

safe_name="${new_name//\'/\'\'}"
if ! sqlite3 "${lutris_db}" "UPDATE games SET name='${safe_name}' WHERE slug='${safe_slug}';" 2>/dev/null; then
  zgu_cli_error "$(t rename_game.failed_cli)"
  exit 1
fi
zgu_log "rename" "OK" "slug=${slug} old=${old_name} new=${new_name}"
t rename_game.done_cli "${old_name}" "${new_name}"
