#!/bin/bash

# --- Récupération des arguments du routeur lpm ---
# $1 = Niveau de compression optionnel (ex: "5" ou vide)
# $2 = generate_hash_flag ("yes" si --hash)
# $3, $4, ... = Liste des runners cibles en CLI
compression_arg="${1:-}"
shift || true
generate_hash_flag="${1:-}"
shift || true
cli_runners=("$@")

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
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# En mode interactif, "generate_hash_flag" (positionnel, --hash) n'existe pas : la décision
# passe par une question Zenity dédiée plus bas (voir "GENERATE_HASH" juste avant la boucle
# de compression). En CLI, --hash décide seul, sans question.
GENERATE_HASH=false
[[ "${generate_hash_flag}" = "yes" ]] && GENERATE_HASH=true

# Configuration des chemins des runners Lutris
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

OUTPUT_DIR="${HOME}"

# 1. Vérification de zstd (toujours requis)
if ! command -v zstd >/dev/null 2>&1; then
  zgu_cli_error "$(t pack_runner.zstd_missing)"
  exit 1
fi

# 2. Détection du type de Lutris (Flatpak vs Paquet natif ; fonction fournie par
# zgu-lutris-utils.sh -- résout aussi le cas des deux installées en même temps)
pack_runner_display_mode="gui"
[[ ${#cli_runners[@]} -gt 0 ]] && pack_runner_display_mode="cli"
lutris_version=$(zgu_resolve_lutris_version "${pack_runner_display_mode}" "" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  # Détection explicite (alignée sur les autres scripts de lib/) : un repli silencieux
  # vers le chemin natif par défaut donnerait un message "dossier introuvable" plus loin
  # dans le script, bien moins clair que la vraie cause (Lutris non installé).
  if [[ ${#cli_runners[@]} -gt 0 ]]; then
    zgu_cli_error "$(t pack_runner.lutris_missing_cli)"
  else
    zenity --error --text="$(t pack_runner.lutris_missing_gui)" 2>/dev/null
  fi
  exit 1
fi
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
esac

if [[ ! -d "${runner_dir}" ]]; then
  if [[ ${#cli_runners[@]} -gt 0 ]]; then
    zgu_cli_error "$(t pack_runner.dir_missing_cli "${runner_dir}")"
  else
    zenity --error --text="$(t pack_runner.dir_missing_gui "${runner_dir}")" 2>/dev/null
  fi
  exit 1
fi

cd "${runner_dir}" || exit 1

# --all (CLI uniquement) : remplace le seul argument "--all" par la liste triée de tous
# les dossiers de runners présents sur le disque -- même source (nullglob + tri) que la
# liste proposée en mode interactif juste en dessous. La boucle CLI n'a ensuite besoin
# d'aucun changement : chaque nom existe forcément (on vient de le lister), donc la
# vérification [[ -d ... ]] passera toujours ; seule la vérification anti-conflit
# (archive .zgr déjà existante) s'applique encore normalement.
if [[ ${#cli_runners[@]} -eq 1 ]] && [[ "${cli_runners[0]}" = "--all" ]]; then
  shopt -s nullglob
  all_runner_dirs=( */ )
  shopt -u nullglob
  mapfile -t all_sorted_runners < <(printf '%s\n' "${all_runner_dirs[@]}" | sed 's#/$##' | sort)
  if [[ ${#all_sorted_runners[@]} -eq 0 ]]; then
    zgu_cli_error "$(t pack_runner.no_runner_found "${runner_dir}")"
    exit 1
  fi
  cli_runners=("${all_sorted_runners[@]}")
fi

declare -A path_by_runner
runners_to_export=()

# 3. Gestion Mode CLI (Multi-runners) vs Mode Interactif
if [[ ${#cli_runners[@]} -gt 0 ]]; then
  # --- MODE CLI (Terminal, aucun Zenity) ---
  LEVEL="${compression_arg:-3}"
  missing=()
  conflicts=()

  for target_runner_raw in "${cli_runners[@]}"; do
    # basename() neutralise toute tentative de traversée de chemin ("../", chemin absolu...)
    # dans un nom de runner fourni en CLI : sans cela, un nom comme "../../home/user/.ssh"
    # aurait pu faire lire/archiver un dossier arbitraire du système en dehors de runner_dir.
    target_runner_arg=$(basename -- "${target_runner_raw}")
    if [[ ! -d "${runner_dir}/${target_runner_arg}" ]]; then
      missing+=("${target_runner_raw}")
      continue
    fi

    archive_path="${OUTPUT_DIR}/${target_runner_arg}.zgr"
    if [[ -f "${archive_path}" ]]; then
      conflicts+=("${target_runner_arg}")
    fi

    runners_to_export+=("${target_runner_arg}")
    path_by_runner["${target_runner_arg}"]="${runner_dir}/${target_runner_arg}"
  done

  # Vérification stricte : le moindre runner manquant ou paquet déjà existant annule tout, rien n'est exporté
  if [[ ${#missing[@]} -gt 0 ]] || [[ ${#conflicts[@]} -gt 0 ]]; then
    if [[ ${#missing[@]} -gt 0 ]]; then
      zgu_cli_error "$(t pack_runner.missing_header_cli "${runner_dir}")"
      for name in "${missing[@]}"; do
        zgu_cli_error "$(t pack_runner.missing_item_cli "${name}")"
      done
    fi
    if [[ ${#conflicts[@]} -gt 0 ]]; then
      zgu_cli_error "$(t pack_runner.conflict_header_cli "${OUTPUT_DIR}")"
      for name in "${conflicts[@]}"; do
        zgu_cli_error "$(t pack_runner.conflict_item_cli "${name}")"
      done
      zgu_cli_error "$(t pack_runner.conflict_hint)"
    fi
    zgu_cli_error "$(t pack_runner.nothing_exported)"
    exit 1
  fi
else
  # --- MODE INTERACTIF (Avec Zenity) ---
  if ! command -v zenity >/dev/null 2>&1; then
    zgu_cli_error "$(t pack_runner.zenity_missing)"
    exit 1
  fi

  zgu_start_focus_watcher

  shopt -s nullglob
  runners_list=( */ )

  if [[ ${#runners_list[@]} -eq 0 ]]; then
    zenity --info --text="$(t pack_runner.no_runner_found "${runner_dir}")" 2>/dev/null
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

  # Bouton "Tout cocher/décocher" en plus de la liste (voir zgu-checklist-utils.sh).
  selected_runners=$(zgu_gui_checklist_toggle_all FALSE 1 \
    "$(t pack_runner.select_title)" \
    "$(t pack_runner.select_text)" \
    650 350 \
    "$(t pack_runner.select_col_export)" "$(t pack_runner.select_col_name)" \
    -- \
    "${checklist_values[@]}")

  if [[ -z "${selected_runners}" ]]; then
    exit 0
  fi

  # Demande facultative pour personnaliser le taux de compression
  LEVEL=3
  if zenity --question \
    --title="$(t pack_runner.compression_question_title)" \
    --text="$(t pack_runner.compression_question_text)" \
    --width=400 2>/dev/null; then
    if level_choice=$(zenity --scale \
      --title="$(t pack_runner.compression_scale_title)" \
      --text="$(t pack_runner.compression_scale_text)" \
      --min-value=1 \
      --max-value=22 \
      --value=3 \
      --step=1 \
      --width=400 2>/dev/null) && [[ -n "${level_choice}" ]]; then
      LEVEL="${level_choice}"
    fi
  fi

  if zenity --question \
    --title="$(t pack_runner.hash_question_title)" \
    --text="$(t pack_runner.hash_question_text)" \
    --width=400 2>/dev/null; then
    GENERATE_HASH=true
  fi

  IFS=$'\x1f' read -r -a runners_to_export <<< "${selected_runners}"
fi

# 4. Traitement de la compression
cd "${runner_dir}" || exit 1

total_runners=${#runners_to_export[@]}
current=0

# Fenêtre de progression PARTAGÉE (voir zgu_batch_progress_open dans zgu-progress-utils.sh),
# même principe que zgp-game-installer.sh/zgp-game-packer.sh : sans ça, plusieurs runners
# sélectionnés ici ouvraient et refermaient une fenêtre par runner.
pack_using_batch=false
if [[ ${#cli_runners[@]} -eq 0 ]] && [[ "${total_runners}" -gt 1 ]]; then
  pack_using_batch=true
  zgu_batch_progress_open "$(t pack_runner.batch_progress_title "${total_runners}")"
fi

for runner in "${runners_to_export[@]}"; do
  current=$((current + 1))
  r_path="${path_by_runner[${runner}]}"

  ARCHIVE_NAME="${runner}"
  archive_path="${OUTPUT_DIR}/${ARCHIVE_NAME}.zgr"

  # Commande de compression sécurisée avec support du mode ultra (20 à 22)
  if [[ "${LEVEL}" -gt 19 ]]; then
    zstd_opt="--ultra -${LEVEL}"
  else
    zstd_opt="-${LEVEL}"
  fi

  if [[ ${#cli_runners[@]} -gt 0 ]]; then
    # --- MODE CLI : pv + zstd, barre de progression texte ---
    t pack_runner.compressing_cli "${current}" "${total_runners}" "${ARCHIVE_NAME}" "${LEVEL}"

    source_size=$(du -sb "${r_path}" 2>/dev/null | cut -f1)
    [[ -z "${source_size}" ]] && source_size=0

    if command -v pv >/dev/null 2>&1; then
      tar -C "${runner_dir}" -cf - "${runner}" | pv -s "${source_size}" | zstd "${zstd_opt}" > "${archive_path}"
      tar_exit="${PIPESTATUS[0]}"
    else
      tar -C "${runner_dir}" -cf - "${runner}" | zstd "${zstd_opt}" > "${archive_path}"
      tar_exit="${PIPESTATUS[0]}"
    fi

    if [[ "${tar_exit}" -ne 0 ]] || [[ ! -s "${archive_path}" ]]; then
      zgu_cli_error "$(t pack_runner.compression_failed_cli "${ARCHIVE_NAME}")"
      rm -f "${archive_path}"
      exit 1
    fi

    # Restreint aux seuls droits du propriétaire, par cohérence avec zgp-game-packer.sh.
    chmod 600 "${archive_path}"

    if [[ "${GENERATE_HASH}" = true ]]; then
      zgu_write_hash_sidecar "${archive_path}" "${OUTPUT_DIR}"
    fi

    zgu_cli_ok "$(t pack_runner.done_cli "${archive_path}")"
  else
    # --- MODE INTERACTIF : délégué à zgu_gui_compress_zstd (voir zgu-progress-utils.sh) :
    # pourcentage réel piloté par pv sur le flux tar d'entrée, exactement le même mécanisme
    # que le mode CLI ci-dessus. ---
    pack_zen_text="$(t pack_runner.export_text "${LEVEL}")"
    if [[ "${pack_using_batch}" = true ]]; then
      pack_zen_text="$(t pack_runner.batch_progress_item "${current}" "${total_runners}" "${ARCHIVE_NAME}" "${pack_zen_text}")"
    fi
    zgu_gui_compress_zstd "${runner_dir}" "${runner}" "${archive_path}" "${LEVEL}" \
      "$(t pack_runner.export_title "${ARCHIVE_NAME}")" \
      "${pack_zen_text}"
    compress_status=$?

    if [[ "${compress_status}" -eq 2 ]]; then
      [[ "${pack_using_batch}" = true ]] && zgu_batch_progress_close
      zenity --info --title="$(t pack_runner.cancel_title)" --text="$(t pack_runner.cancel_text "${ARCHIVE_NAME}")" 2>/dev/null
      exit 0
    elif [[ "${compress_status}" -ne 0 ]]; then
      [[ "${pack_using_batch}" = true ]] && zgu_batch_progress_close
      zenity --error --text="$(t pack_runner.compression_error "${ARCHIVE_NAME}")" 2>/dev/null
      exit 1
    fi

    if [[ "${GENERATE_HASH}" = true ]]; then
      zgu_write_hash_sidecar "${archive_path}" "${OUTPUT_DIR}"
    fi
  fi

done

[[ "${pack_using_batch}" = true ]] && zgu_batch_progress_close

if [[ ${#cli_runners[@]} -eq 0 ]]; then
  notify-send "$(t pack_runner.notify_title)" "$(t pack_runner.notify_body "${OUTPUT_DIR}")" 2>/dev/null
else
  zgu_cli_ok "$(t pack_runner.cli_done)"
fi
exit 0
