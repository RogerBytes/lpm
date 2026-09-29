#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-checklist-utils.sh
source "${script_dir}/zgu-checklist-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"

# --- Récupération des arguments du routeur lpm ---
# $1 = Flag de confirmation ("yes" si -y)
# $2, $3, ... = Liste des runners cibles à supprimer en CLI
confirm_flag="${1:-}"
shift || true
cli_runners=("$@")

# Configuration des chemins des runners Lutris
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# 1. Détection du type de Lutris (Flatpak vs Paquet natif ; fonction fournie par
# zgu-lutris-utils.sh -- résout aussi le cas des deux installées en même temps)
uninstall_runner_display_mode="gui"
[[ ${#cli_runners[@]} -gt 0 ]] && uninstall_runner_display_mode="cli"
lutris_version=$(zgu_resolve_lutris_version "${uninstall_runner_display_mode}" "" "${lutris_package_runner_dir}")
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
  *) runner_dir="${HOME}/.local/share/lutris/runners/wine" ;;
esac

if [[ ! -d "${runner_dir}" ]]; then
  if [[ ${#cli_runners[@]} -gt 0 ]]; then
    zgu_cli_error "$(t uninstall_runner.dir_missing_cli "${runner_dir}")"
  else
    zenity --error --text="$(t uninstall_runner.dir_missing_gui "${runner_dir}")" 2>/dev/null
  fi
  exit 1
fi

cd "${runner_dir}" || exit 1

declare -A path_by_runner
runners_to_delete=()

# 2. Gestion Mode CLI (Multi-runners) vs Mode Interactif
if [[ ${#cli_runners[@]} -gt 0 ]]; then
  # --- MODE CLI (Terminal, aucun Zenity) ---
  missing=()

  for target_runner_raw in "${cli_runners[@]}"; do
    # basename() neutralise toute tentative de traversée de chemin ("../", chemin absolu...)
    # dans un nom de runner fourni en CLI : sans cela, "lpm uninstall-runner ../../Games/x"
    # pouvait faire pointer r_path en dehors de runner_dir et déclencher un rm -rf sur un
    # dossier arbitraire du système accessible par traversée relative depuis runner_dir.
    target_runner_arg=$(basename -- "${target_runner_raw}")
    r_path="${runner_dir}/${target_runner_arg}"
    if [[ ! -d "${r_path}" ]]; then
      missing+=("${target_runner_raw}")
      continue
    fi
    runners_to_delete+=("${target_runner_arg}")
    path_by_runner["${target_runner_arg}"]="${r_path}"
  done

  # Vérification stricte : le moindre runner introuvable annule tout, rien n'est supprimé
  if [[ ${#missing[@]} -gt 0 ]]; then
    zgu_cli_error "$(t uninstall_runner.missing_cli_header "${runner_dir}")"
    for name in "${missing[@]}"; do
      zgu_cli_error "$(t uninstall_runner.missing_cli_item "${name}")"
    done
    zgu_cli_error "$(t uninstall_runner.missing_cli_footer)"
    exit 1
  fi

  # Confirmation interactive si le flag -y n'est pas présent
  if [[ "${confirm_flag}" != "yes" ]]; then
    t uninstall_runner.confirm_cli_header
    for name in "${runners_to_delete[@]}"; do
      t uninstall_runner.confirm_cli_item "${name}" "${path_by_runner[${name}]}"
    done
    read -r -p "$(t uninstall_runner.confirm_cli_prompt)" response
    case "${response}" in
      [nN])
        t uninstall_runner.confirm_cli_cancelled
        exit 0
        ;;
      *)
        ;;
    esac
  fi
else
  # --- MODE INTERACTIF (Avec Zenity) ---
  if ! command -v zenity >/dev/null 2>&1; then
    zgu_cli_error "$(t uninstall_runner.zenity_missing)"
    exit 1
  fi

  zgu_start_focus_watcher

  shopt -s nullglob
  runners_list=( */ )

  if [[ ${#runners_list[@]} -eq 0 ]]; then
    zenity --info --text="$(t uninstall_runner.none_found_gui "${runner_dir}")" 2>/dev/null
    exit 0
  fi

  # Tri alphabétique propre
  mapfile -t sorted_runners < <(printf '%s\n' "${runners_list[@]}" | sort)

  checklist_values=()

  for runner in "${sorted_runners[@]}"; do
    runner="${runner%/}"
    [[ -d "${runner}" ]] || continue
    path_by_runner["${runner}"]="${runner_dir}/${runner}"
    checklist_values+=( "${runner}" )
  done

  # Fenêtre de sélection (checklist) pour choisir les runners à supprimer, avec bouton
  # "Tout cocher/décocher" (voir zgu-checklist-utils.sh) -- décoché par défaut (FALSE) pour
  # éviter les erreurs d'étourderie.
  selected_runners=$(zgu_gui_checklist_toggle_all FALSE 1 \
    "$(t uninstall_runner.list_title)" \
    "$(t uninstall_runner.list_text)" \
    650 400 \
    "$(t uninstall_runner.list_column_delete)" "$(t uninstall_runner.list_column_name)" \
    -- \
    "${checklist_values[@]}")

  if [[ -z "${selected_runners}" ]]; then
    exit 0
  fi

  IFS=$'\x1f' read -r -a runners_to_delete <<< "${selected_runners}"

  # Construction du résumé pour la fenêtre de confirmation
  summary_text="$(t uninstall_runner.confirm_gui_header)"
  for runner in "${runners_to_delete[@]}"; do
    r_path="${path_by_runner[${runner}]}"
    summary_text+="$(t uninstall_runner.confirm_gui_item "${runner}" "${r_path}")"
  done

  summary_text+="$(t uninstall_runner.confirm_gui_footer)"

  # zenity --text-info (plutôt que --question) : voir le commentaire détaillé équivalent
  # dans zgp-game-uninstaller.sh -- même correctif de hauteur/défilement, même sémantique de
  # boutons/codes de retour, pas de balise Pango dans le texte pour la même raison.
  summary_file=$(mktemp)
  printf '%s' "${summary_text}" > "${summary_file}"

  # Demande de confirmation finale
  if ! zenity --text-info --title="$(t uninstall_runner.confirm_title)" \
    --filename="${summary_file}" \
    --width=550 --height=350 2>/dev/null; then
    rm -f "${summary_file}"
    zenity --info --title="$(t uninstall_runner.cancel_title)" --text="$(t uninstall_runner.cancel_text)" 2>/dev/null
    exit 0
  fi
  rm -f "${summary_file}"
fi

# 3. Traitement de la suppression
total_runners=${#runners_to_delete[@]}

if [[ ${#cli_runners[@]} -gt 0 ]]; then
  # --- MODE CLI (Affichage textuel épuré) ---
  current=0
  for runner in "${runners_to_delete[@]}"; do
    current=$((current + 1))
    t uninstall_runner.progress_cli "${current}" "${total_runners}" "${runner}"

    r_path="${path_by_runner[${runner}]}"
    if [[ -d "${r_path}" ]]; then
      rm -rf "${r_path}"
    fi
  done

  zgu_cli_ok "$(t uninstall_runner.done_cli)"
else
  # --- MODE INTERACTIF (Barre de progression Zenity) ---

  # Compteur de réussites réelles, même principe que install_success_file dans
  # zgp-game-installer.sh : fichier plutôt que variable, le bloc ci-dessous tournant dans un
  # sous-shell (celui du pipe vers "zenity --progress").
  uninstall_success_file=$(mktemp)

  (
    current=0
    for runner in "${runners_to_delete[@]}"; do
      current=$((current + 1))
      # Plafonné a 99, jamais 100, tant qu'on est dans la boucle -- voir le commentaire pres du
      # "zenity --progress" plus bas : le vrai "100" n'est ecrit qu'une seule fois, tout a la
      # fin, apres que CHAQUE runner a ete reellement supprime.
      percent=$(( (current * 99) / total_runners ))

      echo "${percent}"
      t uninstall_runner.progress_gui "${runner}" "${current}" "${total_runners}"

      r_path="${path_by_runner[${runner}]}"

      # Suppression physique du dossier du runner
      if [[ -d "${r_path}" ]]; then
        rm -rf "${r_path}"
        echo 1 >> "${uninstall_success_file}"
      fi

      sleep 0.2
    done

    echo "100"
    t uninstall_runner.cleanup_gui
    sleep 0.3

  # "--auto-close" est conserve (meme comportement Zenity confirme que dans
  # zgp-game-uninstaller.sh : certaines versions referment la fenetre des qu'elles lisent un
  # "100") -- le plafond a 99 ci-dessus garantit que ce "100" n'arrive qu'une fois tout
  # reellement termine.
  ) | zenity --progress \
    --title="$(t uninstall_runner.progress_gui_title)" \
    --text="$(t uninstall_runner.progress_gui_text)" \
    --percentage=0 \
    --auto-close \
    --width=450 2>/dev/null

  zenity_status=$?

  if [[ "${zenity_status}" -ne 0 ]]; then
    rm -f "${uninstall_success_file}"
    zenity --info --title="$(t uninstall_runner.interrupted_title)" --text="$(t uninstall_runner.interrupted_text)" 2>/dev/null
    exit 0
  fi

  uninstall_success_count=$(wc -l < "${uninstall_success_file}" 2>/dev/null)
  rm -f "${uninstall_success_file}"
  [[ -z "${uninstall_success_count}" ]] && uninstall_success_count=0

  if [[ "${uninstall_success_count}" -eq "${total_runners}" ]] && [[ "${total_runners}" -gt 0 ]]; then
    notify-send "$(t uninstall_runner.notify_title)" "$(t uninstall_runner.notify_body)" 2>/dev/null
  elif [[ "${uninstall_success_count}" -eq 0 ]]; then
    notify-send "$(t uninstall_runner.notify_title_none)" "$(t uninstall_runner.notify_body_none)" 2>/dev/null
  else
    notify-send "$(t uninstall_runner.notify_title_partial)" "$(t uninstall_runner.notify_body_partial "${uninstall_success_count}" "${total_runners}")" 2>/dev/null
  fi
fi

exit 0
