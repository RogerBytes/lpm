#!/bin/bash

# --- Récupération des arguments du routeur lpm ---
# $1 = Niveau de compression optionnel (ex: "5" ou vide)
# $2 = generate_hash_flag ("yes" si --hash)
# $3, $4, ... = Liste des dossiers de jeux cibles
compression_arg="${1:-}"
shift || true
generate_hash_flag="${1:-}"
shift || true
cli_games=("$@")

# Configuration des chemins et variables de base
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-progress-utils.sh
source "${script_dir}/zgu-progress-utils.sh"
# shellcheck source=./zgu-checklist-utils.sh
source "${script_dir}/zgu-checklist-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# En mode interactif, "generate_hash_flag" (positionnel, --hash) n'existe pas : la décision
# passe par une question Zenity dédiée plus bas (voir "GENERATE_HASH" juste avant la boucle
# de compression). En CLI, --hash décide seul, sans question.
GENERATE_HASH=false
[[ "${generate_hash_flag}" = "yes" ]] && GENERATE_HASH=true

OUTPUT_DIR="${HOME}"

# Configuration des chemins Lutris (Flatpak vs paquet natif), avec la même détection que
# tous les autres scripts de lib/ (via zgu-lutris-utils.sh). Un test d'existence de fichiers
# résiduels pourrait lire la mauvaise base de données si un ancien profil Flatpak ou natif
# traîne encore sur le disque, d'où l'usage de la détection centralisée.
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

GAMES_DIR="${HOME}/Games"

# Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout aussi
# le cas des deux installées en même temps)
pack_game_display_mode="gui"
[[ ${#cli_games[@]} -gt 0 ]] && pack_game_display_mode="cli"
lutris_version=$(zgu_resolve_lutris_version "${pack_game_display_mode}" "${lutris_package_db}" "")
if [[ -z "${lutris_version}" ]]; then
  # Détection explicite (alignée sur les autres scripts de lib/) : un repli silencieux
  # vers les chemins natifs donnerait un message "dossier introuvable" plus tard dans le
  # script, bien moins clair que la vraie cause (Lutris non installé).
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    zgu_cli_error "$(t pack_game.lutris_missing_cli)"
  else
    zgu_gui_error "$(t pack_game.lutris_missing_gui)"
  fi
  exit 1
fi
case "${lutris_version}" in
  flatpak)
    lutris_db_path="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_system_file="${lutris_flatpak_system_file}"
    ;;
  native)
    lutris_db_path="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_system_file="${lutris_package_system_file}"
    ;;
esac

# Chemin Games personnalisé (si défini dans Lutris) : même lecture dynamique que dans
# zgp-game-installer.sh et zgp-game-uninstaller.sh. Cette préférence globale vit dans
# system.yml ("system: game_path:"), PAS dans runners/wine.yml (qui ne contient que des
# options propres au runner Wine, comme system_winetricks/version).
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && GAMES_DIR="${extracted_path}"
fi

# Anonymise tout chemin utilisateur (Windows "Users\\<nom>\\" / "Users\<nom>\" et
# POSIX "/home/<nom>/") vers "anonuser", quel que soit le nom d'utilisateur rencontré :
# une liste figée de noms connus laisserait passer silencieusement tout autre nom
# d'utilisateur (ancien testeur, autre machine, .reg hérité...). Le YAML embarqué est
# nettoyé dynamiquement de la même façon (voir plus bas dans ce fichier) ; les .reg /
# goglog.ini / lutris.json passent par cette fonction commune.
anonymize_user_paths() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  # Chemins Windows échappés dans les .reg ("Users\\\\<nom>\\\\") et non échappés
  sed -i -E 's#([Uu]sers\\\\)[^\\"'"'"']+(\\\\)#\1anonuser\2#g' "${f}"
  sed -i -E 's#([Uu]sers\\)[^\\"'"'"']+(\\)#\1anonuser\2#g' "${f}"
  # Chemins POSIX ("/home/<nom>/")
  sed -i -E 's#(/home/)[^/"'"'"']+(/)#\1anonuser\2#g' "${f}"
  # Filet de sécurité : le $USER courant, même hors contexte de chemin
  sed -i "s|${USER}|anonuser|g" "${f}"
}

# Récupération dynamique du runner par défaut global de Lutris (fonction partagée,
# voir zgu-lutris-utils.sh)
default_runner=$(zgu_get_default_runner)

# Vérification de zstd (toujours requis)
if ! command -v zstd >/dev/null 2>&1; then
  zgu_cli_error "$(t pack_game.zstd_missing)"
  exit 1
fi

# python3 lui-même est requis, distinctement de PyYAML ci-dessous : sans cette vérification
# séparée, une machine sans python3 du tout recevait le même message "PyYAML manquant" qu'une
# machine avec python3 mais sans le module, ce qui égarait l'utilisateur sur la vraie cause.
# Même style que la vérification zstd juste au-dessus (stderr uniquement, pas de dialogue
# Zenity dédié) : ce script n'a jamais distingué cli/gui pour ses erreurs de dépendances.
if ! command -v python3 >/dev/null 2>&1; then
  zgu_cli_error "$(t pack_game.python3_missing)"
  exit 1
fi

# Le module PyYAML est requis pour nettoyer/réécrire le YAML Lutris embarqué dans le .zgp.
# Sans lui, le paquet pouvait être créé avec un zgp-game-config.yml non nettoyé (chemins
# absolus, version de runner manquante) sans qu'aucune erreur ne soit visible.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    zgu_cli_error "$(t pack_game.pyyaml_missing_cli)"
  else
    zgu_gui_error "$(t pack_game.pyyaml_missing_gui)"
  fi
  exit 1
fi

if [[ ! -d "${GAMES_DIR}" ]]; then
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    zgu_cli_error "$(t pack_game.games_dir_missing "${GAMES_DIR}")"
    exit 1
  else
    zgu_gui_error "$(t pack_game.games_dir_missing "${GAMES_DIR}")"
    exit 1
  fi
fi

declare -A folder_by_name  # game_real_name -> chemin réel absolu du préfixe (depuis pga.db)
declare -A slug_by_name    # game_real_name -> slug (pour la relecture de configpath plus bas)
games_to_export=()

# Jeux vivant dans un préfixe de store partagé (Epic Games Store, EA App, Ubisoft
# Connect...) : jamais empaquetables via lpm. Un .zgp mélangerait plusieurs jeux dans une
# seule archive, et le nettoyage/anonymisation appliqué plus bas (fait pour être rejoué
# à l'installation sur une autre machine) abîmerait le préfixe partagé pour les autres
# jeux qui y vivent encore (voir zgu_get_blacklisted_slugs dans zgu-lutris-utils.sh).
declare -A blacklisted_slugs
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
  while IFS= read -r bl_slug; do
    [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
  done < <(zgu_get_blacklisted_slugs "${lutris_db_path}")
fi

# Résout un slug Lutris (jeu runner='wine') vers le chemin réel et sûr de son préfixe.
# Découverte via pga.db (colonne "directory") plutôt que par scan de GAMES_DIR/*/ à un seul
# niveau : un scan à un seul niveau raterait tout jeu imbriqué plus profondément (ex:
# gog/<jeu>/, comme les jeux GOG de Lutris) et, pire, empaquetterait un dossier
# intermédiaire (ex: "gog/") en bloc si plusieurs jeux y vivaient, mélangeant leurs
# préfixes dans une seule archive.
# "directory" peut provenir de N'IMPORTE QUEL jeu wine de la base pga.db, pas uniquement
# ceux gérés par lpm : même garde anti-évasion que zgp-game-uninstaller.sh (le chemin
# résolu doit rester un sous-dossier réel de GAMES_DIR).
# Sortie : chemin réel sur stdout, rien si introuvable/dangereux (code de retour 1).
resolve_prefix_dir_by_slug() {
  local slug="$1" safe_slug raw_dir real_dir real_games_dir
  safe_slug="${slug//\'/\'\'}"
  raw_dir=$(sqlite3 "${lutris_db_path}" "SELECT directory FROM games WHERE slug='${safe_slug}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  [[ -z "${raw_dir}" ]] && return 1

  real_dir=$(realpath -e "${raw_dir}" 2>/dev/null)
  real_games_dir=$(realpath -e "${GAMES_DIR}" 2>/dev/null)
  if [[ -z "${real_dir}" ]] || [[ -z "${real_games_dir}" ]] || [[ "${real_dir}" != "${real_games_dir}/"* ]]; then
    return 1
  fi
  echo "${real_dir}"
}

# --all (CLI uniquement) : remplace le seul argument "--all" par la liste triée de tous
# les slugs de jeux wine non blacklistés, connue via pga.db -- exactement la même source
# que la liste proposée en mode interactif. La boucle CLI ci-dessous n'a ensuite besoin
# d'aucun changement : elle retraite chaque slug comme si l'utilisateur l'avait tapé.
if [[ ${#cli_games[@]} -eq 1 ]] && [[ "${cli_games[0]}" = "--all" ]]; then
  all_wine_slugs=()
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
    while IFS= read -r all_slug; do
      [[ -z "${all_slug}" ]] && continue
      [[ -n "${blacklisted_slugs[${all_slug}]:-}" ]] && continue
      all_wine_slugs+=("${all_slug}")
    done < <(sqlite3 "${lutris_db_path}" "SELECT slug FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)
  fi
  if [[ ${#all_wine_slugs[@]} -eq 0 ]]; then
    zgu_cli_error "$(t pack_game.no_prefix_found "${GAMES_DIR}")"
    exit 1
  fi
  cli_games=("${all_wine_slugs[@]}")
fi

# --- Mode CLI vs Mode Interactif ---
if [[ ${#cli_games[@]} -gt 0 ]]; then
  # --- MODE CLI (Pas de Zenity, 100% Terminal) ---
  LEVEL="${compression_arg:-3}"

  for target_slug_raw in "${cli_games[@]}"; do
    # basename() neutralise toute tentative de traversée de chemin ("../", chemin absolu...)
    # dans le slug fourni en CLI, par cohérence avec le reste du projet.
    target_slug=$(basename -- "${target_slug_raw}")

    if [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t pack_game.slug_blacklisted_cli "${target_slug}")"
      exit 1
    fi

    resolved_dir=$(resolve_prefix_dir_by_slug "${target_slug}")
    if [[ -z "${resolved_dir}" ]]; then
      zgu_cli_error "$(t pack_game.folder_not_found_cli "${target_slug_raw}" "${GAMES_DIR}")"
      exit 1
    fi

    game_real_name=""
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
      safe_target_slug="${target_slug//\'/\'\'}"
      game_real_name=$(sqlite3 "${lutris_db_path}" "SELECT name FROM games WHERE slug='${safe_target_slug}' LIMIT 1;" 2>/dev/null)
    fi
    [[ -z "${game_real_name}" ]] && game_real_name="${target_slug}"

    # Vérification anti-écrasement en CLI
    archive_path="${OUTPUT_DIR}/${game_real_name}.zgp"
    if [[ -f "${archive_path}" ]]; then
      zgu_cli_error "$(t pack_game.archive_exists_cli "${game_real_name}" "${OUTPUT_DIR}")"
      zgu_cli_error "$(t pack_game.archive_exists_hint)"
      exit 1
    fi

    games_to_export+=("${game_real_name}")
    folder_by_name["${game_real_name}"]="${resolved_dir}"
    slug_by_name["${game_real_name}"]="${target_slug}"
  done
else
  # --- MODE INTERACTIF (Avec Zenity) ---
  if ! command -v zenity >/dev/null 2>&1; then
    zgu_cli_error "$(t pack_game.zenity_missing)"
    exit 1
  fi

  zgu_start_focus_watcher

  if ! command -v sqlite3 >/dev/null 2>&1 || [[ ! -f "${lutris_db_path}" ]]; then
    zenity --info --text="$(t pack_game.no_prefix_found "${GAMES_DIR}")" 2>/dev/null
    exit 0
  fi

  games_rows=$(sqlite3 "${lutris_db_path}" "SELECT slug || char(31) || name FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)
  if [[ -z "${games_rows}" ]]; then
    zenity --info --text="$(t pack_game.no_prefix_found "${GAMES_DIR}")" 2>/dev/null
    exit 0
  fi

  checklist_values=()
  while IFS=$'\x1f' read -r row_slug row_name; do
    [[ -z "${row_slug}" ]] && continue
    [[ -n "${blacklisted_slugs[${row_slug}]:-}" ]] && continue

    resolved_dir=$(resolve_prefix_dir_by_slug "${row_slug}")
    [[ -z "${resolved_dir}" ]] && continue

    game_real_name="${row_name}"
    [[ -z "${game_real_name}" ]] && game_real_name="${row_slug}"

    folder_by_name["${game_real_name}"]="${resolved_dir}"
    slug_by_name["${game_real_name}"]="${row_slug}"
    checklist_values+=( "${game_real_name}" )
  done <<< "${games_rows}"

  if [[ ${#checklist_values[@]} -eq 0 ]]; then
    zenity --info --text="$(t pack_game.no_prefix_found "${GAMES_DIR}")" 2>/dev/null
    exit 0
  fi

  # Bouton "Tout cocher/décocher" en plus de la liste (voir zgu-checklist-utils.sh).
  selected_games=$(zgu_gui_checklist_toggle_all FALSE 1 \
    "$(t pack_game.select_title)" \
    "$(t pack_game.select_text)" \
    500 400 \
    "$(t pack_game.select_col_export)" "$(t pack_game.select_col_name)" \
    -- \
    "${checklist_values[@]}")

  [[ -z "${selected_games}" ]] && exit 0

  IFS=$'\x1f' read -r -a games_to_export <<< "${selected_games}"

  # --- Vérification anti-écrasement en Mode Interactif ---
  for game_real_name in "${games_to_export[@]}"; do
    archive_path="${OUTPUT_DIR}/${game_real_name}.zgp"
    if [[ -f "${archive_path}" ]]; then
      # Appel Zenity avec --width=450, hors du gabarit standard de zgu_gui_error : on logue
      # explicitement ici plutôt que de passer par elle, même effet, sans perdre --width.
      zgu_log "zgp-game-packer" "ERREUR" "$(t pack_game.archive_exists_gui "${game_real_name}")"
      zenity --error \
        --title="$(t pack_game.archive_exists_title)" \
        --text="$(t pack_game.archive_exists_gui "${game_real_name}")" \
        --width=450 2>/dev/null
      exit 1
    fi
  done

  LEVEL=3
  if zenity --question \
    --title="$(t pack_game.compression_question_title)" \
    --text="$(t pack_game.compression_question_text)" \
    --width=400 2>/dev/null; then
    if level_choice=$(zenity --scale \
      --title="$(t pack_game.compression_scale_title)" \
      --text="$(t pack_game.compression_scale_text)" \
      --min-value=1 --max-value=22 --value=3 --step=1 --width=400 2>/dev/null); then
      [[ -n "${level_choice}" ]] && LEVEL="${level_choice}"
    fi
  fi

  if zenity --question \
    --title="$(t pack_game.hash_question_title)" \
    --text="$(t pack_game.hash_question_text)" \
    --width=400 2>/dev/null; then
    GENERATE_HASH=true
  fi
fi

# Fenêtre de progression PARTAGÉE (voir zgu_batch_progress_open dans zgu-progress-utils.sh),
# même principe que zgp-game-installer.sh : sans ça, plusieurs jeux sélectionnés ici ouvraient
# et refermaient une fenêtre par jeu, avec le focus qui revenait sans arrêt au premier plan et
# aucun compteur "N/Total" affiché.
pack_using_batch=false
if [[ ${#cli_games[@]} -eq 0 ]] && [[ ${#games_to_export[@]} -gt 1 ]]; then
  pack_using_batch=true
  zgu_batch_progress_open "$(t pack_game.batch_progress_title "${#games_to_export[@]}")"
fi
pack_idx=0

# Traitement de chaque jeu sélectionné
for game_real_name in "${games_to_export[@]}"; do
  pack_idx=$((pack_idx + 1))
  WINEPREFIX_DIR="${folder_by_name[${game_real_name}]}"
  game_slug="${slug_by_name[${game_real_name}]}"

  [[ -z "${WINEPREFIX_DIR}" ]] && continue
  [[ ! -d "${WINEPREFIX_DIR}" ]] && continue

  # Racine plate de l'archive nommée d'après le dossier réel du préfixe (dirname/basename
  # du chemin résolu depuis pga.db) plutôt que GAMES_DIR + nom : fonctionne quelle que soit
  # la profondeur du préfixe (ex: gog/<jeu>/), l'archive garde toujours une racine plate
  # nommée d'après le dossier du jeu -- zéro changement côté installeur (zgp-game-installer.sh
  # ne connaît que cette racine plate, jamais la profondeur d'origine).
  PARENT_DIR=$(dirname -- "${WINEPREFIX_DIR}")
  WINEPREFIX_NAME=$(basename -- "${WINEPREFIX_DIR}")

  configpath=""

  if [[ -n "${game_slug}" ]] && command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
    safe_game_slug="${game_slug//\'/\'\'}"
    configpath=$(sqlite3 "${lutris_db_path}" "SELECT configpath FROM games WHERE slug='${safe_game_slug}' LIMIT 1;" 2>/dev/null)
  fi

  ARCHIVE_NAME="${game_real_name}"
  archive_path="${OUTPUT_DIR}/${ARCHIVE_NAME}.zgp"

  # Recherche robuste du sous-dossier de jeu interne (2>/dev/null : si "drive_c/Games"
  # n'existe pas pour ce préfixe, on veut basculer silencieusement sur le fallback
  # ci-dessous plutôt qu'afficher une erreur "find: No such file or directory" inutile)
  GAME_DIR=$(basename "$(find "${WINEPREFIX_DIR}/drive_c/Games" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1)")
  [[ -z "${GAME_DIR}" ]] && GAME_DIR="${WINEPREFIX_NAME}"

  ini_parent_dir="${WINEPREFIX_DIR}/drive_c/Games/${GAME_DIR}"
  goglog="${ini_parent_dir}/goglog.ini"
  lutris_json="${WINEPREFIX_DIR}/lutris.json"

  if [[ -f "${goglog}" ]]; then
    anonymize_user_paths "${goglog}"
  fi

  if [[ -f "${lutris_json}" ]]; then
    anonymize_user_paths "${lutris_json}"
  fi

  # Nettoyage des liens symboliques et dossiers temporaires inutiles
  [[ -d "${WINEPREFIX_DIR}/dosdevices" ]] && rm -rf "${WINEPREFIX_DIR}/dosdevices"
  [[ -L "${WINEPREFIX_DIR}/drive_c/users/steamuser" ]] && unlink "${WINEPREFIX_DIR}/drive_c/users/steamuser"
  [[ -L "${WINEPREFIX_DIR}/drive_c/users/${USER}" ]] && unlink "${WINEPREFIX_DIR}/drive_c/users/${USER}"
  [[ -d "${WINEPREFIX_DIR}/drive_c/users/${USER}" ]] && mv -n "${WINEPREFIX_DIR}/drive_c/users/${USER}" "${WINEPREFIX_DIR}/drive_c/users/steamuser"
  [[ -L "${WINEPREFIX_DIR}/pfx" ]] && unlink "${WINEPREFIX_DIR}/pfx"

  for link_name in "Application Data" "Desktop" "Music" "Pictures" "Videos" "Documents" "My Documents" "Downloads"; do
    [[ -L "${WINEPREFIX_DIR}/drive_c/users/steamuser/${link_name}" ]] && unlink "${WINEPREFIX_DIR}/drive_c/users/steamuser/${link_name}"
  done

  # "Local Settings" (ancien chemin XP : Local Settings/Application Data, Temp, History...)
  # est entièrement reconstruit par Proton/Wine à la prochaine initialisation du préfixe.
  # S'il survit à l'empaquetage, il peut contenir à la fois "Application Data" (vrai dossier,
  # pas encore migré) ET "Application Data BACKUP" (résidu d'une migration Proton déjà faite
  # avant le pack) : à la réinstallation, Proton retente sa migration automatique et échoue
  # avec "Directory not empty" car la destination existe déjà et n'est pas vide. Supprimé sans
  # condition (comme les liens ci-dessus) pour repartir sur une migration propre à chaque
  # install, plutôt que de traquer un par un tous les sous-dossiers/BACKUP qu'il peut contenir.
  [[ -e "${WINEPREFIX_DIR}/drive_c/users/steamuser/Local Settings" || -L "${WINEPREFIX_DIR}/drive_c/users/steamuser/Local Settings" ]] \
    && rm -rf -- "${WINEPREFIX_DIR}/drive_c/users/steamuser/Local Settings"

  [[ -d "${WINEPREFIX_DIR}/drive_c/ProgramData/Package Cache/" ]] && rm -rf -- "${WINEPREFIX_DIR}/drive_c/ProgramData/Package Cache/"*
  [[ -d "${WINEPREFIX_DIR}/drive_c/users/steamuser/Temp" ]] && rm -rf -- "${WINEPREFIX_DIR}/drive_c/users/steamuser/Temp/"*
  [[ -d "${WINEPREFIX_DIR}/drive_c" ]] && mkdir -p "${WINEPREFIX_DIR}/drive_c/users/steamuser/Temp"

  find "${WINEPREFIX_DIR}/drive_c" -type l ! -exec test -e {} \; -delete
  # "{}" est passé en argument positionnel plutôt qu'interpolé dans le texte du script :
  # un nom de fichier contenant des caractères spéciaux (`, $, guillemets...) ne peut plus
  # être interprété comme du code par bash.
  #
  # Copie-puis-remplace (et non supprime-puis-copie) : "cp -L" résout lui-même la cible du
  # lien, qu'elle soit relative ou absolue -- contrairement à un "readlink" manuel suivi
  # d'un "cp" sur ce chemin brut, qui échouait silencieusement pour tout lien RELATIF (la
  # cible lue par readlink est relative au dossier du lien, pas au répertoire courant du
  # script). Le lien était alors déjà supprimé avant l'échec de la copie : le fichier
  # disparaissait purement et simplement de l'archive .zgp, sans erreur bloquante visible.
  # En copiant d'abord vers un fichier temporaire avant de supprimer le lien, un échec de
  # copie laisse le lien original intact au lieu de perdre le fichier.
  find "${WINEPREFIX_DIR}/drive_c" -type l -exec bash -c '
    for link; do
      tmp="${link}.zgp-tmp"
      if cp -rL -- "${link}" "${tmp}" 2>/dev/null; then
        rm -f -- "${link}"
        mv -- "${tmp}" "${link}"
      else
        rm -f -- "${tmp}"
      fi
    done
  ' _ {} +
  find "${WINEPREFIX_DIR}/drive_c/windows/system32" -type f -name '*.orig' -delete
  find "${WINEPREFIX_DIR}/drive_c/windows/syswow64" -type f -name '*.orig' -delete

  for reg_file in "system.reg" "user.reg" "userdef.reg"; do
    if [[ -f "${WINEPREFIX_DIR}/${reg_file}" ]]; then
      anonymize_user_paths "${WINEPREFIX_DIR}/${reg_file}"
    fi
  done

  # --- PLUS DE FICHIER MÊTA SÉPARÉ POUR LE VRAI NOM DU JEU ---
  # zgp-meta.json existait uniquement pour transporter le nom réel du jeu jusqu'à
  # l'installation. Inutile : le YAML Lutris embarqué juste en dessous (zgp-game-config.yml)
  # contient déjà nativement une clé racine "name" avec cette même valeur (confirmé sur un
  # vrai export Lutris), et ce YAML n'est de toute façon jamais retiré de cette clé par le
  # nettoyage ci-dessous (seuls "script", "version" et "slug" y sont retirés). L'installeur
  # lit donc directement "name" depuis ce YAML plutôt que depuis un second fichier redondant.

  # --- EMBARQUEMENT PROPRE DU YAML LUTRIS (si disponible) ---
  if [[ -n "${configpath}" ]] && [[ -f "${lutris_config_dir}/${configpath}.yml" ]]; then
    cp "${lutris_config_dir}/${configpath}.yml" "${WINEPREFIX_DIR}/zgp-game-config.yml"

    # Le préfixe absolu du wineprefix (ex: /home/harry/Games/mariovania) est remplacé par
    # le placeholder natif de Lutris "$GAMEDIR" dans tous les chemins du YAML embarqué,
    # résolu dynamiquement à l'installation d'après le dossier de jeux réellement configuré
    # chez l'utilisateur qui installe (voir zgp-game-installer.sh). Le remplacement doit
    # couvrir tout le chemin (pas seulement le segment "/home/<nom>/") : sinon, un dossier
    # de jeux personnalisé ou différent de celui de la machine ayant créé le paquet reste
    # figé dans le YAML et casse l'installation.
    YML_PATH="${WINEPREFIX_DIR}/zgp-game-config.yml" WINEPREFIX_DIR_ENV="${WINEPREFIX_DIR}" DEFAULT_RUNNER="${default_runner}" ERR_YAML_LABEL="$(t pack_game.yaml_cleanup_error)" python3 -c '
import yaml, re, os

yml_path = os.environ["YML_PATH"]
prefix_dir = os.environ.get("WINEPREFIX_DIR_ENV", "")
default_runner = os.environ.get("DEFAULT_RUNNER", "")
prefix_pattern = re.escape(prefix_dir) if prefix_dir else None

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        data.pop("script", None)
        data.pop("version", None)
        data.pop("slug", None)

        # GAMEID (system.env.GAMEID) est generee par lpm a l installation (voir
        # zgu_write_game_shortcut dans zgu-desktop-utils.sh) a partir de l id Lutris du jeu
        # dans LA BASE DE CETTE MACHINE -- un simple compteur auto-incremente, jamais le
        # meme d une machine a l autre. La conserver dans le .zgp exporte referencerait un
        # id perime des la reinstallation ailleurs (ou meme ici apres une reinstallation),
        # avec un risque reel de collision entre deux jeux differents portant par coincidence
        # le meme vieil id -- exactement le bug de fusion dans le panel qu on vient de
        # corriger. Retiree specifiquement (pas tout "env", qui peut contenir des reglages
        # legitimes et voulus comme WINEDLLOVERRIDES/MANGOHUD) : chaque installation la
        # recalcule de toute facon automatiquement, aucune fonctionnalite perdue.
        system_cfg = data.get("system")
        if isinstance(system_cfg, dict):
            env_cfg = system_cfg.get("env")
            if isinstance(env_cfg, dict):
                env_cfg.pop("GAMEID", None)

        def clean_paths(obj):
            if isinstance(obj, dict):
                return {k: clean_paths(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [clean_paths(v) for v in obj]
            elif isinstance(obj, str):
                s = obj
                if prefix_pattern:
                    s = re.sub(prefix_pattern + r"(?=/|$)", "$GAMEDIR", s)
                # Filet de sécurité : anonymise tout chemin utilisateur qui référencerait
                # encore /home/<nom> en dehors du prefix, pour tout chemin non couvert par
                # le placeholder ci-dessus
                s = re.sub(r"/home/[^/]+/", "/home/anonuser/", s)
                return s
            return obj

        data = clean_paths(data)

        if not isinstance(data.get("wine"), dict):
            data["wine"] = {}
        if not data["wine"].get("version"):
            data["wine"]["version"] = default_runner

        with open(yml_path, "w") as f:
            yaml.dump(data, f, sort_keys=False)
except Exception as e:
    err_label = os.environ.get("ERR_YAML_LABEL", "YAML cleanup error")
    print(f"{err_label}: {e}")
' 2>/dev/null
  fi
  # ---------------------------------------------------------

  if [[ "${LEVEL}" -gt 19 ]]; then
    zstd_opt="--ultra -${LEVEL}"
  else
    zstd_opt="-${LEVEL}"
  fi

  # --- EXÉCUTION DE LA COMPRESSION SELON LE MODE ---
  if [[ ${#cli_games[@]} -gt 0 ]]; then
    # MODE CLI : Utilisation de pv pour une barre textuelle propre si dispo, sinon simple message
    t pack_game.compressing_cli "${ARCHIVE_NAME}" "${LEVEL}"
    if command -v pv >/dev/null 2>&1; then
      source_size=$(du -sb "${WINEPREFIX_DIR}" 2>/dev/null | cut -f1)
      [[ -z "${source_size}" ]] && source_size=0
      
      tar -C "${PARENT_DIR}" -cf - "${WINEPREFIX_NAME}" | pv -s "${source_size}" | zstd "${zstd_opt}" > "${archive_path}"
      tar_exit="${PIPESTATUS[0]}"
    else
      tar -C "${PARENT_DIR}" -cf - "${WINEPREFIX_NAME}" | zstd "${zstd_opt}" > "${archive_path}"
      tar_exit="${PIPESTATUS[0]}"
    fi

    if [[ "${tar_exit}" -ne 0 ]] || [[ ! -s "${archive_path}" ]]; then
      zgu_cli_error "$(t pack_game.compression_failed_cli "${ARCHIVE_NAME}")"
      zgu_log "pack" "ERREUR" "slug=${game_slug} nom=${game_real_name} raison=compression_echouee code=${tar_exit}"
      rm -f "${archive_path}"
      exit 1
    fi

    # Le .zgp peut embarquer des données sensibles (registre Wine : clés de licence,
    # chemins...) : restreint aux seuls droits du propriétaire pour éviter qu'un autre
    # utilisateur local de la même machine puisse le lire avant un partage volontaire.
    chmod 600 "${archive_path}"

    if [[ "${GENERATE_HASH}" = true ]]; then
      zgu_write_hash_sidecar "${archive_path}" "${OUTPUT_DIR}"
    fi

    zgu_log "pack" "OK" "slug=${game_slug} nom=${game_real_name} archive=${archive_path}"

    zgu_cli_ok "$(t pack_game.done_cli "${archive_path}")"
  else
    # MODE INTERACTIF : délégué à zgu_gui_compress_zstd (voir zgu-progress-utils.sh) :
    # pourcentage réel piloté par pv sur le flux tar d'entrée, exactement le même mécanisme
    # que le mode CLI ci-dessus.
    pack_zen_text="$(t pack_game.export_text "${LEVEL}")"
    if [[ "${pack_using_batch}" = true ]]; then
      pack_zen_text="$(t pack_game.batch_progress_item "${pack_idx}" "${#games_to_export[@]}" "${ARCHIVE_NAME}" "${pack_zen_text}")"
    fi
    zgu_gui_compress_zstd "${PARENT_DIR}" "${WINEPREFIX_NAME}" "${archive_path}" "${LEVEL}" \
      "$(t pack_game.export_title "${ARCHIVE_NAME}")" \
      "${pack_zen_text}"
    compress_status=$?

    if [[ "${compress_status}" -eq 2 ]]; then
      [[ "${pack_using_batch}" = true ]] && zgu_batch_progress_close
      zgu_log "pack" "INFO" "slug=${game_slug} nom=${game_real_name} raison=annule_par_utilisateur"
      zenity --info --title="$(t pack_game.cancel_title)" --text="$(t pack_game.cancel_text "${ARCHIVE_NAME}")" 2>/dev/null
      exit 0
    elif [[ "${compress_status}" -ne 0 ]]; then
      [[ "${pack_using_batch}" = true ]] && zgu_batch_progress_close
      zgu_log "pack" "ERREUR" "slug=${game_slug} nom=${game_real_name} raison=compression_echouee code=${compress_status}"
      zgu_gui_error "$(t pack_game.compression_error "${ARCHIVE_NAME}")"
      exit 1
    fi

    if [[ "${GENERATE_HASH}" = true ]]; then
      zgu_write_hash_sidecar "${archive_path}" "${OUTPUT_DIR}"
    fi

    zgu_log "pack" "OK" "slug=${game_slug} nom=${game_real_name} archive=${archive_path}"
  fi

  # Nettoyage des fichiers temporaires embarqués avant la fin
  rm -f "${WINEPREFIX_DIR}/zgp-game-config.yml"

done

[[ "${pack_using_batch}" = true ]] && zgu_batch_progress_close

if [[ ${#cli_games[@]} -eq 0 ]]; then
  notify-send "$(t pack_game.notify_title)" "$(t pack_game.notify_body)" 2>/dev/null
else
  zgu_cli_ok "$(t pack_game.cli_done)"
fi
exit 0
