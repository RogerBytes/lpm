#!/bin/bash

# --- Lister les jeux Wine installés via Lutris ---
# Sortie : <slug>  <nom du jeu>

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

# Configuration des chemins Lutris
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

# 1. Vérification de sqlite3
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t list_games.sqlite_missing)"
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps)
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

# 3. Récupération des jeux Wine (slug puis nom), triés par nom
games_list=$(sqlite3 "${lutris_db}" "SELECT slug || char(31) || name FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  t list_games.none_installed
  exit 0
fi

# Jeux vivant dans un préfixe de store partagé (Epic Games Store, EA App, Ubisoft
# Connect...) : hors du principe un-jeu-un-préfixe de lpm, jamais listés (voir
# zgu_get_blacklisted_slugs dans zgu-lutris-utils.sh).
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

[[ "${printed_any}" -eq 0 ]] && t list_games.none_installed

exit 0
