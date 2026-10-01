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
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# --hash décide seul si un sidecar sha256 est généré -- bin/lpm n'a plus aucun point d'entrée
# interactif pour proposer la question équivalente à la place.
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
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  # Détection explicite (alignée sur les autres scripts de lib/) : un repli silencieux
  # vers le chemin natif par défaut donnerait un message "dossier introuvable" plus loin
  # dans le script, bien moins clair que la vraie cause (Lutris non installé).
  zgu_cli_error "$(t pack_runner.lutris_missing_cli)"
  exit 1
fi
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
esac

if [[ ! -d "${runner_dir}" ]]; then
  zgu_cli_error "$(t pack_runner.dir_missing_cli "${runner_dir}")"
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

# 3. Sélection des runners à exporter : bin/lpm n'a plus aucun point d'entrée interactif,
# donc "lpm pack-runner" exige toujours des noms (ou "--all") en ligne de commande --
# l'ancien mode interactif (checklist Zenity + questions taux de compression/sidecar sha256)
# a été retiré.
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

# 4. Traitement de la compression
cd "${runner_dir}" || exit 1

total_runners=${#runners_to_export[@]}
current=0

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

  # pv + zstd, barre de progression texte
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
done

zgu_cli_ok "$(t pack_runner.cli_done)"
exit 0
