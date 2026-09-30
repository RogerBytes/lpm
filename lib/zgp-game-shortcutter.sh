#!/bin/bash

# --- Génération de raccourcis (menu applications / bureau) pour des jeux déjà installés ---
#
# Contrairement à zgp-game-installer.sh (qui propose déjà la création de raccourcis, mais
# uniquement au moment de l'installation d'un .zgp), cette commande permet de (re)générer
# les raccourcis a posteriori pour n'importe quel jeu déjà présent dans Lutris -- utile en
# particulier pour régénérer un raccourci existant après avoir corrigé l'icône par défaut
# (voir zgu_write_game_shortcut dans zgu-desktop-utils.sh), ou pour créer les raccourcis d'un
# jeu ajouté à Lutris par un autre moyen que lpm.
#
# $1, $2... = slugs de jeux cibles en CLI, ou "--all" pour tous les jeux Wine installés.
# Pas de flag de confirmation : cette commande n'écrit que des fichiers .desktop (raccourcis),
# rien de destructif.
cli_targets=("$@")

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

# Configuration des chemins Lutris
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

# Dossier des builds Wine/Proton installés : voir la même remarque détaillée dans
# zgp-game-installer.sh (nécessaire à zgu_write_game_shortcut pour distinguer un runner
# Proton d'un Wine classique).
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

games_dir="${HOME}/Games"

# 1. Vérification de sqlite3 (zenity uniquement requis en mode interactif)
if ! command -v sqlite3 >/dev/null 2>&1; then
  if [[ ${#cli_targets[@]} -gt 0 ]]; then
    zgu_cli_error "$(t shortcut.sqlite_missing)"
  else
    zgu_gui_error "$(t shortcut.sqlite_missing)"
  fi
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps)
shortcut_display_mode="gui"
[[ ${#cli_targets[@]} -gt 0 ]] && shortcut_display_mode="cli"
version=$(zgu_resolve_lutris_version "${shortcut_display_mode}" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  if [[ ${#cli_targets[@]} -gt 0 ]]; then
    zgu_cli_error "$(t shortcut.lutris_missing)"
  else
    zgu_gui_error "$(t shortcut.lutris_missing)"
  fi
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_system_file="${lutris_flatpak_system_file}"
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  package)
    lutris_system_file="${lutris_package_system_file}"
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    runner_dir="${lutris_package_runner_dir}"
    ;;
  *)
    # Ne devrait jamais arriver : $version n'est affecté qu'à "flatpak" ou "package"
    # ci-dessus (sinon exit 1). Garde-fou si cette invariant venait à changer.
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

# Chemin Games personnalisé (si défini dans Lutris) : voir la même remarque détaillée dans
# zgp-game-installer.sh.
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  if [[ -n "${extracted_path}" ]]; then
    games_dir="${extracted_path}"
  fi
fi

if [[ ! -f "${lutris_db}" ]]; then
  if [[ ${#cli_targets[@]} -gt 0 ]]; then
    zgu_cli_error "$(t shortcut.db_missing "${lutris_db}")"
  else
    zgu_gui_error "$(t shortcut.db_missing "${lutris_db}")"
  fi
  exit 1
fi

# 3. Récupération des jeux Wine depuis la BDD Lutris (id inclus : nécessaire pour construire
# "lutris:rungameid/<id>" dans le raccourci ; configpath inclus : nécessaire pour retrouver le
# YAML de config du jeu -- voir zgu_write_game_shortcut)
#
# COALESCE(...,'') sur CHAQUE colonne, indispensable : en SQLite, NULL || quoi que ce soit
# renvoie NULL pour toute la concaténation -- un jeu dont "executable" est encore vide (préfixe
# tout juste (re)créé dans Lutris, .exe pas encore configuré) faisait donc disparaître TOUTE la
# ligne (sqlite3 l'affiche comme une ligne vide, ensuite sautée par "[[ -z "${game_name}" ]] &&
# continue" ci-dessous) -- le jeu restait bien visible dans "lpm list" (qui ne lit pas
# "executable"), mais devenait introuvable pour "lpm shortcut", avec l'erreur "Jeu introuvable"
# alors qu'il existe bien en base. Même motif déjà correctement traité dans zgp-game-icon.sh
# pour cette même liste de colonnes -- oubli isolé à ce script-ci.
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  if [[ ${#cli_targets[@]} -gt 0 ]]; then
    zgu_cli_error "$(t shortcut.none_found)"
  else
    zenity --info --text="$(t shortcut.none_found)" 2>/dev/null
  fi
  exit 0
fi

declare -A slug_by_name
declare -A dir_by_name
declare -A name_by_slug
declare -A id_by_slug
declare -A exe_by_slug
declare -A configpath_by_slug

# Jeux vivant dans un préfixe de store partagé (Epic Games Store, EA App, Ubisoft
# Connect...) : hors du principe un-jeu-un-préfixe de lpm, jamais proposés ici (même filtre
# que zgp-game-uninstaller.sh et zgp-game-lister.sh -- voir zgu_get_blacklisted_slugs).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

# Conserve l'ordre trié de la requête SQL (ORDER BY name COLLATE NOCASE ASC) dans un tableau
# indexé séparé : voir la même remarque détaillée dans zgp-game-uninstaller.sh.
sorted_game_names=()

while IFS=$'\x1f' read -r game_id game_name game_slug game_dir game_exe game_configpath; do
  [[ -z "${game_name}" ]] && continue
  [[ -n "${blacklisted_slugs[${game_slug}]:-}" ]] && continue

  # game_name (colonne "name" de la table Lutris) peut provenir de n'importe quel jeu wine
  # de la base, pas uniquement ceux installés par lpm -- même filtre que dans
  # zgp-game-uninstaller.sh, pour la même raison (game_name sert de clé de tableau associatif
  # ci-dessous, un "/" ne poserait pas de souci ici en soi, mais on reste cohérent avec le
  # filtre appliqué partout ailleurs sur cette colonne avant de l'afficher/l'utiliser).
  game_name="${game_name//\//-}"

  [[ -z "${game_dir}" ]] && game_dir="${games_dir}/${game_slug}"

  slug_by_name["${game_name}"]="${game_slug}"
  dir_by_name["${game_name}"]="${game_dir}"
  name_by_slug["${game_slug}"]="${game_name}"
  id_by_slug["${game_slug}"]="${game_id}"
  exe_by_slug["${game_slug}"]="${game_exe}"
  configpath_by_slug["${game_slug}"]="${game_configpath}"
  sorted_game_names+=("${game_name}")
done <<< "${games_list}"

if [[ ${#sorted_game_names[@]} -eq 0 ]]; then
  if [[ ${#cli_targets[@]} -gt 0 ]]; then
    zgu_cli_error "$(t shortcut.none_found)"
  else
    zenity --info --text="$(t shortcut.none_found)" 2>/dev/null
  fi
  exit 0
fi

games_to_process=()
create_menu=false
create_desktop=false
# Écran de chargement (voir lib/zgl-launcher-orchestrator.sh) : actif par défaut pour tout
# raccourci créé/régénéré par lpm, quel que soit le mode (CLI ou interactif) -- aucun flag
# CLI dédié pour l'instant (cohérent avec create_menu/create_desktop en mode CLI, toujours
# "true" également, sans équivalent --no-menu/--no-desktop). Désactivable ensuite au cas par
# cas en décochant la case ci-dessous en mode interactif, ou en supprimant à la main le
# marqueur "${game_dir}/.lpm-no-loadingscreen" en mode CLI.
loadingscreen_enabled=true

# --- Mode CLI vs Mode Interactif ---
if [[ ${#cli_targets[@]} -gt 0 ]]; then
  # --- MODE CLI (100% Terminal, zéro Zenity) ---
  if [[ "${cli_targets[0]}" = "--all" ]]; then
    games_to_process=("${sorted_game_names[@]}")
  else
    for target_slug in "${cli_targets[@]}"; do
      found_name="${name_by_slug[${target_slug}]}"
      if [[ -n "${found_name}" ]]; then
        games_to_process+=("${found_name}")
      elif [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
        zgu_cli_error "$(t shortcut.slug_blacklisted "${target_slug}")"
        exit 1
      else
        zgu_cli_error "$(t shortcut.slug_not_found "${target_slug}")"
        exit 1
      fi
    done
  fi

  create_menu=true
  create_desktop=true
else
  # --- MODE INTERACTIF (Avec Zenity) ---
  if ! command -v zenity >/dev/null 2>&1; then
    zgu_cli_error "$(t shortcut.zenity_missing)"
    exit 1
  fi

  zgu_start_focus_watcher

  checklist_values=()
  for g_name in "${sorted_game_names[@]}"; do
    checklist_values+=( "${g_name}" "${slug_by_name[${g_name}]}" )
  done

  # zgu_gui_checklist_toggle_all (voir zgu-checklist-utils.sh) : liste --checklist avec un
  # bouton "Tout cocher/décocher" en plus. Tout coché par défaut (TRUE) : à la différence de
  # la désinstallation, régénérer un raccourci n'a rien de destructif, donc partir de "tout
  # sélectionné" est le comportement le plus pratique ici.
  selected_games=$(zgu_gui_checklist_toggle_all TRUE 2 \
    "$(t shortcut.select_title)" \
    "$(t shortcut.select_text)" \
    650 450 \
    "$(t shortcut.select_col_create)" "$(t shortcut.select_col_game)" "$(t shortcut.select_col_slug)" \
    -- \
    "${checklist_values[@]}")

  if [[ -z "${selected_games}" ]]; then
    exit 0
  fi

  IFS=$'\x1f' read -r -a games_to_process <<< "${selected_games}"

  # Écran menu/bureau : réutilise volontairement les mêmes libellés que l'écran équivalent de
  # zgp-game-installer.sh (install_game.shortcuts_opt_menu/_opt_desktop/_col_create/
  # _col_location) plutôt que d'en dupliquer une traduction séparée -- même case à cocher,
  # même sens, les deux pré-cochées par défaut.
  opt_menu_label="$(t install_game.shortcuts_opt_menu)"
  opt_desktop_label="$(t install_game.shortcuts_opt_desktop)"
  # Même case, mêmes libellés réutilisés qu'entre zgp-game-shortcutter.sh et
  # zgp-game-installer.sh pour opt_menu_label/opt_desktop_label ci-dessus -- voir
  # zgp-game-installer.sh pour l'écran équivalent à la création.
  opt_loadingscreen_label="$(t install_game.shortcuts_opt_loadingscreen)"

  shortcut_locations=$(zenity --list --checklist --title="$(t shortcut.locations_title)" --text="$(t shortcut.locations_text)" --column="$(t install_game.shortcuts_col_create)" --column="$(t install_game.shortcuts_col_location)" --separator=$'\x1f' TRUE "${opt_menu_label}" TRUE "${opt_desktop_label}" TRUE "${opt_loadingscreen_label}" --width=500 --height=250 2>/dev/null)

  if [[ "${shortcut_locations}" == *"${opt_menu_label}"* ]]; then
    create_menu=true
  fi
  if [[ "${shortcut_locations}" == *"${opt_desktop_label}"* ]]; then
    create_desktop=true
  fi
  loadingscreen_enabled=false
  if [[ "${shortcut_locations}" == *"${opt_loadingscreen_label}"* ]]; then
    loadingscreen_enabled=true
  fi

  if [[ "${create_menu}" = false ]] && [[ "${create_desktop}" = false ]]; then
    exit 0
  fi
fi

# 4. Génération effective des raccourcis (fonction partagée avec zgp-game-installer.sh --
# voir zgu_write_game_shortcut dans zgu-desktop-utils.sh)
for game_name in "${games_to_process[@]}"; do
  game_slug="${slug_by_name[${game_name}]}"
  game_id="${id_by_slug[${game_slug}]}"
  game_prefix_dir="${dir_by_name[${game_name}]}"
  game_exe="${exe_by_slug[${game_slug}]}"
  game_configpath="${configpath_by_slug[${game_slug}]}"

  zgu_write_game_shortcut "${game_name}" "${game_slug}" "${game_prefix_dir}" "${game_id}" "${version}" "${create_menu}" "${create_desktop}" "${game_exe}" "${game_configpath}" "${lutris_config_dir}" "${runner_dir}"

  # Marqueur d'écran de chargement (voir lib/zgl-launcher-orchestrator.sh) : idempotent,
  # aussi bien pour une toute première création que pour une régénération -- créé si décoché,
  # supprimé si coché, quel que soit l'état précédent.
  if [[ "${loadingscreen_enabled}" = true ]]; then
    rm -f "${game_prefix_dir}/.lpm-no-loadingscreen" 2>/dev/null
  else
    mkdir -p "${game_prefix_dir}" 2>/dev/null
    : > "${game_prefix_dir}/.lpm-no-loadingscreen" 2>/dev/null
  fi

  [[ ${#cli_targets[@]} -gt 0 ]] && t shortcut.created_cli "${game_name}"
done

if [[ ${#cli_targets[@]} -eq 0 ]]; then
  zenity --info --text="$(t shortcut.done_gui "${#games_to_process[@]}")" 2>/dev/null
fi

exit 0
