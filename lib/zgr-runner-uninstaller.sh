#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

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
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  # Détection explicite (alignée sur les autres scripts de lib/, ex. zgr-runner-packer.sh) :
  # un repli silencieux vers le chemin natif par défaut donnerait un message "dossier
  # introuvable" plus loin dans le script, bien moins clair que la vraie cause (Lutris non
  # installé). Réutilise les clés pack_runner.lutris_missing_* (même message, cohérence
  # avec le reste du projet plutôt que dupliquer une clé identique).
  zgu_cli_error "$(t pack_runner.lutris_missing_cli)"
  exit 1
fi
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
  *) runner_dir="${HOME}/.local/share/lutris/runners/wine" ;;
esac

if [[ ! -d "${runner_dir}" ]]; then
  zgu_cli_error "$(t uninstall_runner.dir_missing_cli "${runner_dir}")"
  exit 1
fi

cd "${runner_dir}" || exit 1

declare -A path_by_runner
runners_to_delete=()

# 2. Sélection des runners à supprimer : bin/lpm n'a plus aucun point d'entrée interactif,
# donc "lpm uninstall-runner" exige toujours des noms en ligne de commande -- l'ancien mode
# interactif (checklist Zenity listant tous les runners installés) a été retiré.
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

# 3. Traitement de la suppression (affichage textuel épuré -- la barre de progression Zenity
# de l'ancien mode interactif a été retirée avec lui).
total_runners=${#runners_to_delete[@]}

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

exit 0
