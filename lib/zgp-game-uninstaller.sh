#!/bin/bash

# --- Récupération des arguments du routeur lpm ---
# $1 = Flag de confirmation ("yes" si -y)
# $2, $3, ... = Liste des slugs de jeux cibles en CLI
confirm_flag="${1:-}"
shift || true
cli_games=("$@")

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

# Configuration des chemins Lutris
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

games_dir="${HOME}/Games"

# 1. Vérifications de base (sqlite3 requis)
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t uninstall_game.sqlite_missing)"
  exit 1
fi

# 2. Fermeture préalable de Lutris pour libérer la BDD
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps)
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
    # Ne devrait jamais arriver : $version n'est affecté qu'à "flatpak" ou "package"
    # ci-dessus (sinon exit 1). Garde-fou si cette invariant venait à changer.
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

# Chemin Games personnalisé (si défini dans Lutris) : préférence globale stockée dans
# system.yml ("system: game_path:"), pas dans runners/wine.yml (options propres au runner
# Wine uniquement). Voir la même remarque détaillée dans zgp-game-installer.sh.
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

# 4. Récupération des jeux Wine depuis la BDD Lutris
games_list=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || slug || char(31) || directory FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgu_cli_error "$(t uninstall_game.none_found)"
  exit 0
fi

declare -A slug_by_name
declare -A dir_by_name
declare -A name_by_slug

# Jeux vivant dans un préfixe de store partagé (Epic Games Store, EA App, Ubisoft
# Connect...) : hors du principe un-jeu-un-préfixe de lpm, jamais désinstallables via lpm
# -- les supprimer casserait le préfixe partagé pour les autres jeux qui y vivent encore
# (voir zgu_get_blacklisted_slugs dans zgu-lutris-utils.sh).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

while IFS=$'\x1f' read -r game_name game_slug game_dir; do
  [[ -z "${game_name}" ]] && continue
  [[ -n "${blacklisted_slugs[${game_slug}]:-}" ]] && continue

  # game_name (colonne "name" de la table Lutris) peut provenir de N'IMPORTE QUEL jeu wine
  # de la base, pas uniquement de ceux installés par lpm (jeu ajouté manuellement dans
  # Lutris, base éditée à la main...) : zgp-game-installer.sh neutralise déjà tout "/" dans
  # game_real_name avant de l'écrire en base ("${game_real_name//\//-}"), mais un jeu ajouté
  # hors lpm peut contourner ce filtre. game_name sert plus bas à construire des chemins de
  # suppression ("${desktop_dir}/${game_name} ...") : sans ce même filtre ici, un "/" dans
  # le nom ferait cibler un chemin incorrect au lieu du raccourci voulu.
  game_name="${game_name//\//-}"

  [[ -z "${game_dir}" ]] && game_dir="${games_dir}/${game_slug}"

  slug_by_name["${game_name}"]="${game_slug}"
  dir_by_name["${game_name}"]="${game_dir}"
  name_by_slug["${game_slug}"]="${game_name}"
done <<< "${games_list}"

games_to_delete=()

# Supprime physiquement un préfixe de jeu, mais SEULEMENT s'il se résout bien en un
# sous-dossier direct de games_dir. "directory" en base Lutris peut provenir de N'IMPORTE
# QUEL jeu runner='wine' de la base, pas uniquement de ceux installés par lpm (jeu ajouté
# manuellement dans Lutris, base éditée à la main, entrée résiduelle après changement de
# dossier de jeux...) : sans cette vérification, un rm -rf aveugle sur cette valeur pouvait
# supprimer un dossier arbitraire du système si "directory" pointait hors de games_dir.
# Retourne 0 si supprimé (ou déjà absent), 1 si le chemin a été jugé dangereux (rien n'est
# supprimé dans ce cas, à l'appelant d'avertir l'utilisateur).
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

# --- Sélection des jeux ciblés (CLI uniquement : bin/lpm n'a plus aucun point d'entrée
# interactif, la sélection graphique via Zenity a été entièrement retirée) ---
for target_slug in "${cli_games[@]}"; do
  found_name="${name_by_slug[${target_slug}]}"
  if [[ -n "${found_name}" ]]; then
    games_to_delete+=("${found_name}")
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

# 6. Gestion de la confirmation (si le flag 'yes' n'est pas passé, on demande une
# confirmation textuelle dans le terminal)
if [[ "${confirm_flag}" != "yes" ]]; then
  t uninstall_game.confirm_cli_header
  for game_name in "${games_to_delete[@]}"; do
    t uninstall_game.confirm_cli_item "${game_name}" "${dir_by_name[${game_name}]}"
  done
  read -r -p "$(t uninstall_game.confirm_cli_prompt)" response
  case "${response}" in
    [nN])
      t uninstall_game.confirm_cli_cancelled
      exit 0
      ;;
    *)
      ;;
  esac
fi

# 7. Traitement de la suppression (affichage CLI textuel)
total_games=${#games_to_delete[@]}

# --- EXÉCUTION (CLI uniquement) ---
current=0
for game_name in "${games_to_delete[@]}"; do
  current=$((current + 1))
  t uninstall_game.progress_cli "${current}" "${total_games}" "${game_name}"

  game_slug="${slug_by_name[${game_name}]}"

  # game_slug vient de la colonne "slug" de la base Lutris, qui peut provenir de
  # N'IMPORTE QUEL jeu wine de la base, pas uniquement de ceux installés par lpm (jeu
  # ajouté manuellement, base éditée à la main...) -- même remarque que pour game_name
  # plus haut dans ce fichier. game_slug sert plus bas à construire des chemins de
  # suppression (rm -f "${lutris_config_dir}/${game_slug}-"*.yml,
  # "${desktop_dir}/${game_slug}.desktop", etc.) : sans ce filtre, un "/" ou "../" dans
  # ce slug pourrait faire cibler un chemin hors de son dossier attendu. Même filtre de
  # rejet que celui appliqué à "slug" dans zgp-game-installer.sh.
  case "${game_slug}" in
    */*|.|..|*[$'\n\r\t']*)
      zgu_cli_error "$(t uninstall_game.unsafe_prefix_skip "${game_name}" "${game_slug}")"
      zgu_log "uninstall" "ERREUR" "slug=${game_slug} nom=${game_name} raison=slug_non_sur"
      continue
      ;;
  esac

  # Échappement par cohérence avec zgp-game-installer.sh : ces slugs viennent de la base
  # Lutris elle-même (donc fiables en pratique), mais toute valeur interpolée dans une
  # requête SQL doit l'être de façon homogène dans tout le projet.
  safe_game_slug="${game_slug//\'/\'\'}"
  prefix_dir=$(sqlite3 "${lutris_db}" "SELECT directory FROM games WHERE slug='${safe_game_slug}' AND runner='wine' LIMIT 1;")
  [[ -z "${prefix_dir}" ]] && prefix_dir="${dir_by_name[${game_name}]}"

  # A. Suppression du préfixe physique sur le disque
  if ! safe_delete_prefix_dir "${prefix_dir}"; then
    zgu_cli_error "$(t uninstall_game.unsafe_prefix_skip "${game_name}" "${prefix_dir}")"
    zgu_log "uninstall" "ERREUR" "slug=${game_slug} nom=${game_name} raison=prefixe_dangereux dir=${prefix_dir}"
  fi

  # B. Suppression de la configuration YML Lutris
  rm -f "${lutris_config_dir}/${game_slug}-"*.yml

  # C. Suppression de l'entrée dans la base de données SQLite
  sqlite3 "${lutris_db}" "DELETE FROM games WHERE slug='${safe_game_slug}';"

  # D. Suppression des raccourcis .desktop
  desktop_dir=$(zgu_get_desktop_dir)

  rm -f "${desktop_dir}/${game_slug}.desktop"
  rm -f "${desktop_dir}/${game_name} $(t install_game.bonus_folder_suffix)"
  rm -f "${HOME}/.local/share/applications/net.lutris.${game_slug}.desktop"

  zgu_log "uninstall" "OK" "slug=${game_slug} nom=${game_name}"
done

update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
zgu_cli_ok "$(t uninstall_game.done_cli)"

exit 0
