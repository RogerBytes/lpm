#!/bin/bash

# --- Lister les jeux isolables (vivant dans un giga-préfixe de store partagé) ---
# Sortie : <slug>  <nom du jeu>  <store à viser pour "lpm isolate">
#
# Jusqu'ici, cette liste n'existait qu'en mode interactif (Zenity, via "lpm isolate" sans
# argument) : cette commande CLI dédiée permet de l'inspecter/scripter sans ouvrir de
# fenêtre. Ne liste QUE les jeux pour lesquels le store est effectivement reconnu par
# zgu_detect_isolation_store (donc réellement isolables via "lpm isolate <slug>") : un jeu
# blacklisté par la détection générique (préfixe partagé mais store non reconnu, ex. Steam)
# n'apparaît pas ici, pour ne jamais lister un slug que "lpm isolate" refuserait ensuite
# avec "store inconnu".

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

# 1. Vérification de sqlite3
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t list_isolable.sqlite_missing)"
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps)
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

# 3. Pour chaque slug blacklisté (préfixe partagé), résolution nom + store réellement ciblé
printed_any=0
while IFS= read -r bl_slug; do
  [[ -z "${bl_slug}" ]] && continue
  safe_bl="${bl_slug//\'/\'\'}"
  row=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || directory FROM games WHERE runner='wine' AND slug='${safe_bl}' LIMIT 1;" 2>/dev/null)
  IFS=$'\x1f' read -r bl_name bl_dir <<< "${row}"
  [[ -z "${bl_name}" ]] && continue

  # "directory" vient de la base Lutris comme partout ailleurs dans lpm : résolution en
  # chemin réel avant toute utilisation (même prudence que zgp-game-isolator.sh), même si
  # ici on ne fait que lire/afficher, jamais écrire ni supprimer.
  real_dir=$(realpath -e "${bl_dir}" 2>/dev/null)
  [[ -z "${real_dir}" ]] && continue

  store=$(zgu_detect_isolation_store "${lutris_db}" "${real_dir}")
  [[ -z "${store}" ]] && continue

  # Le launcher lui-même (Battle.net, Epic Games Store, ...) n'est jamais un jeu isolable --
  # voir zgu_is_store_launcher_name dans zgu-lutris-utils.sh -- donc jamais listé ici, pour
  # rester cohérent avec "lpm isolate" qui ne tente plus non plus de l'isoler.
  zgu_is_store_launcher_name "${store}" "${bl_name}" && continue

  store_label=$(zgu_store_display_name "${store}")
  echo "${bl_slug}  ${bl_name}  ${store_label}"
  printed_any=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

[[ "${printed_any}" -eq 0 ]] && t list_isolable.none_found

exit 0
