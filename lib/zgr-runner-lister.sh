#!/bin/bash

# --- Lister les runners Wine/Proton installés pour Lutris ---
# Sortie : <nom du runner> (un par ligne, triés alphabétiquement)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps)
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
  *)
    # Détection explicite (alignée sur les autres scripts de lib/) : évite le repli
    # silencieux vers un chemin natif par défaut qui masquerait l'absence de Lutris.
    zgu_cli_error "$(t list_runner.lutris_missing)"
    exit 1
    ;;
esac

if [[ ! -d "${runner_dir}" ]]; then
  zgu_cli_error "$(t list_runner.dir_missing "${runner_dir}")"
  exit 1
fi

cd "${runner_dir}" || exit 1

shopt -s nullglob
runners_list=( */ )

if [[ ${#runners_list[@]} -eq 0 ]]; then
  t list_runner.none_installed
  exit 0
fi

# Tri alphabétique propre
mapfile -t sorted_runners < <(printf '%s\n' "${runners_list[@]}" | sort)

for runner in "${sorted_runners[@]}"; do
  runner="${runner%/}"
  [[ -d "${runner}" ]] || continue
  echo "${runner}"
done

exit 0
