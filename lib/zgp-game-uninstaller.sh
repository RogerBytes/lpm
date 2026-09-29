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
# shellcheck source=./zgu-checklist-utils.sh
source "${script_dir}/zgu-checklist-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"
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

# 1. Vérifications de base (sqlite3 requis, zenity uniquement si mode interactif)
if ! command -v sqlite3 >/dev/null 2>&1; then
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    zgu_cli_error "$(t uninstall_game.sqlite_missing)"
  else
    zenity --error --text="$(t uninstall_game.sqlite_missing)" 2>/dev/null
  fi
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
uninstall_game_display_mode="gui"
[[ ${#cli_games[@]} -gt 0 ]] && uninstall_game_display_mode="cli"
version=$(zgu_resolve_lutris_version "${uninstall_game_display_mode}" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    zgu_cli_error "$(t uninstall_game.lutris_missing)"
  else
    zenity --error --text="$(t uninstall_game.lutris_missing)" 2>/dev/null
  fi
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
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    zgu_cli_error "$(t uninstall_game.db_missing "${lutris_db}")"
  else
    zenity --error --text="$(t uninstall_game.db_missing "${lutris_db}")" 2>/dev/null
  fi
  exit 1
fi

# 4. Récupération des jeux Wine depuis la BDD Lutris
games_list=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || slug || char(31) || directory FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    zgu_cli_error "$(t uninstall_game.none_found)"
  else
    zenity --info --text="$(t uninstall_game.none_found)" 2>/dev/null
  fi
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

# Conserve l'ordre trié de la requête SQL (ORDER BY name COLLATE NOCASE ASC) dans un tableau
# indexé séparé : l'ordre d'itération des clés d'un tableau associatif Bash ("${!array[@]}")
# n'est PAS garanti alphabétique, contrairement à ce que suppose la construction de
# zenity_args plus bas. Sans ce tableau, la liste de jeux présentée dans la fenêtre Zenity
# apparaissait dans un ordre arbitraire au lieu de l'ordre alphabétique attendu.
sorted_game_names=()

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
  sorted_game_names+=("${game_name}")
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

# --- Mode CLI vs Mode Interactif ---
if [[ ${#cli_games[@]} -gt 0 ]]; then
  # --- MODE CLI (100% Terminal, zéro Zenity) ---
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
else
  # --- MODE INTERACTIF (Avec Zenity) ---
  if ! command -v zenity >/dev/null 2>&1; then
    zgu_cli_error "$(t uninstall_game.zenity_missing)"
    exit 1
  fi

  zgu_start_focus_watcher

  checklist_values=()
  for g_name in "${sorted_game_names[@]}"; do
    checklist_values+=( "${g_name}" "${slug_by_name[${g_name}]}" )
  done

  # zgu_gui_checklist_toggle_all (voir zgu-checklist-utils.sh) : même fenêtre --list
  # --checklist qu'avant, avec en plus un bouton "Tout cocher/décocher" qui bascule toutes
  # les lignes sans toucher aux cases individuelles.
  selected_games=$(zgu_gui_checklist_toggle_all FALSE 2 \
    "$(t uninstall_game.select_title)" \
    "$(t uninstall_game.select_text)" \
    650 450 \
    "$(t uninstall_game.select_col_delete)" "$(t uninstall_game.select_col_game)" "$(t uninstall_game.select_col_slug)" \
    -- \
    "${checklist_values[@]}")

  if [[ -z "${selected_games}" ]]; then
    exit 0
  fi

  IFS=$'\x1f' read -r -a games_to_delete <<< "${selected_games}"
fi

# 6. Gestion de la confirmation
if [[ ${#cli_games[@]} -gt 0 ]]; then
  # En mode CLI, si le flag 'yes' n'est pas passé, on demande une confirmation textuelle dans le terminal
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
else
  # En mode interactif graphique
  #
  # zenity --text-info (plutôt que --question) : avec beaucoup de jeux sélectionnés, un
  # --question ordinaire s'étire pour tenir tout le texte (--height y est ignoré dès que le
  # contenu dépasse), donnant une fenêtre démesurée. --text-info est un vrai widget de texte
  # défilant : au-delà de --height, une barre de défilement apparaît au lieu d'agrandir la
  # fenêtre. Boutons OK/Annuler par défaut, mêmes codes de retour qu'un --question (0 =
  # confirmé, autre = annulé) -- le reste de la logique ci-dessous ne change pas.
  #
  # Pas de balise Pango (<b>/<i>) dans le texte : --text-info (sans --html) est un GtkTextView
  # brut, ces balises s'afficheraient telles quelles au lieu d'être interprétées comme du gras/
  # italique.
  summary_text="$(t uninstall_game.confirm_gui_header)"
  for game_name in "${games_to_delete[@]}"; do
    p_dir="${dir_by_name[${game_name}]}"
    summary_text+="$(t uninstall_game.confirm_gui_item "${game_name}" "${p_dir}")"
  done

  summary_text+="$(t uninstall_game.confirm_gui_footer)"

  summary_file=$(mktemp)
  printf '%s' "${summary_text}" > "${summary_file}"

  if ! zenity --text-info --title="$(t uninstall_game.confirm_title)" \
    --filename="${summary_file}" \
    --width=550 --height=350 2>/dev/null; then
    rm -f "${summary_file}"
    zenity --info --title="$(t uninstall_game.cancel_title)" --text="$(t uninstall_game.cancel_text)" 2>/dev/null
    exit 0
  fi
  rm -f "${summary_file}"
fi

# 7. Traitement de la suppression (avec affichage CLI textuel ou barre Zenity)
total_games=${#games_to_delete[@]}

if [[ ${#cli_games[@]} -gt 0 ]]; then
  # --- EXÉCUTION EN MODE CLI (Affichage textuel épuré) ---
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
else
  # --- EXÉCUTION EN MODE INTERACTIF (Barre de progression Zenity) ---

  # Compteur de réussites réelles, même logique et même raison que pour install_success_file
  # dans zgp-game-installer.sh (voir ce fichier) : un fichier plutôt qu'une variable, car le
  # bloc ci-dessous tourne dans un sous-shell (celui du pipe vers "zenity --progress") --
  # toute variable qu'il modifierait resterait invisible une fois ce sous-shell terminé. Permet
  # au notify-send final de refléter le vrai résultat plutôt que d'annoncer un succès total
  # systématique, même quand un jeu a été ignoré (slug non sûr, préfixe dangereux).
  uninstall_success_file=$(mktemp)

  (
    current=0
    for game_name in "${games_to_delete[@]}"; do
      current=$((current + 1))
      # Plafonné a 99, jamais 100, tant qu'on est dans la boucle (voir le commentaire sur
      # "--auto-close" plus bas, pres du "zenity --progress" de ce bloc) : le vrai "100" n'est
      # ecrit qu'une seule fois, tout a la fin, une fois CHAQUE jeu reellement supprime ET le
      # nettoyage (update-desktop-database) deja effectue -- jamais avant.
      percent=$(( (current * 99) / total_games ))

      echo "${percent}"
      t uninstall_game.progress_gui "${game_name}" "${current}" "${total_games}"

      game_slug="${slug_by_name[${game_name}]}"

      # Voir le commentaire détaillé équivalent dans le bloc CLI plus haut dans ce fichier :
      # game_slug peut provenir de n'importe quelle entrée de la base Lutris, pas
      # uniquement de celles installées par lpm.
      case "${game_slug}" in
        */*|.|..|*[$'\n\r\t']*)
          zgu_cli_error "$(t uninstall_game.unsafe_prefix_skip "${game_name}" "${game_slug}")"
          zgu_log "uninstall" "ERREUR" "slug=${game_slug} nom=${game_name} raison=slug_non_sur"
          continue
          ;;
      esac

      safe_game_slug="${game_slug//\'/\'\'}"
      prefix_dir=$(sqlite3 "${lutris_db}" "SELECT directory FROM games WHERE slug='${safe_game_slug}' AND runner='wine' LIMIT 1;")
      [[ -z "${prefix_dir}" ]] && prefix_dir="${dir_by_name[${game_name}]}"

      if ! safe_delete_prefix_dir "${prefix_dir}"; then
        zgu_cli_error "$(t uninstall_game.unsafe_prefix_skip "${game_name}" "${prefix_dir}")"
        zgu_log "uninstall" "ERREUR" "slug=${game_slug} nom=${game_name} raison=prefixe_dangereux dir=${prefix_dir}"
      fi
      rm -f "${lutris_config_dir}/${game_slug}-"*.yml
      sqlite3 "${lutris_db}" "DELETE FROM games WHERE slug='${safe_game_slug}';"

      desktop_dir=$(zgu_get_desktop_dir)

      rm -f "${desktop_dir}/${game_slug}.desktop"
      rm -f "${desktop_dir}/${game_name} $(t install_game.bonus_folder_suffix)"
      rm -f "${HOME}/.local/share/applications/net.lutris.${game_slug}.desktop"

      zgu_log "uninstall" "OK" "slug=${game_slug} nom=${game_name}"
      echo 1 >> "${uninstall_success_file}"

      sleep 0.3
    done

    echo "100"
    t uninstall_game.cleanup_gui
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
    sleep 0.4

  # "--auto-close" est conserve ici (contrairement a la fenetre de lot partagee de
  # zgp-game-installer.sh) : confirme reel que sur certaines versions de Zenity, la fenetre se
  # referme des qu'elle lit un "100" -- y compris envoye PAR ERREUR trop tot. Le plafond a 99
  # ci-dessus dans la boucle garantit que le seul "100" jamais envoye est celui d'apres la
  # boucle, une fois TOUT (suppressions + update-desktop-database) deja termine -- rien ne peut
  # donc plus etre coupe net par une fermeture anticipee.
  ) | zenity --progress \
    --title="$(t uninstall_game.progress_gui_title)" \
    --text="$(t uninstall_game.progress_gui_text)" \
    --percentage=0 \
    --auto-close \
    --no-cancel 2>/dev/null

  # Notification finale reflétant le résultat RÉEL (même principe que zgp-game-installer.sh) :
  # succès total, aucun, ou partiel plutôt qu'un succès annoncé sans condition.
  uninstall_success_count=$(wc -l < "${uninstall_success_file}" 2>/dev/null)
  rm -f "${uninstall_success_file}"
  [[ -z "${uninstall_success_count}" ]] && uninstall_success_count=0

  if [[ "${uninstall_success_count}" -eq "${total_games}" ]] && [[ "${total_games}" -gt 0 ]]; then
    notify-send "$(t uninstall_game.notify_title)" "$(t uninstall_game.notify_body)" 2>/dev/null
  elif [[ "${uninstall_success_count}" -eq 0 ]]; then
    notify-send "$(t uninstall_game.notify_title_none)" "$(t uninstall_game.notify_body_none)" 2>/dev/null
  else
    notify-send "$(t uninstall_game.notify_title_partial)" "$(t uninstall_game.notify_body_partial "${uninstall_success_count}" "${total_games}")" 2>/dev/null
  fi
fi

exit 0
