#!/bin/bash

# --- Lister les runners disponibles sur la release GitHub distante ---
# Sortie : <nom du runner> par ligne, triés alphabétiquement.
# Un runner déjà présent localement est signalé par "(déjà installé)".

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-github-release-utils.sh
source "${script_dir}/zgu-github-release-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# GITHUB_RELEASE_URL est définie dans zgu-github-release-utils.sh (sourcé plus haut),
# seul endroit à modifier pour changer le dépôt/la release des runners.

# 1. Vérification des dépendances nécessaires
if ! command -v python3 >/dev/null 2>&1; then
  zgu_cli_error "$(t list_remote.python_missing)"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  zgu_cli_error "$(t list_remote.network_tool_missing)"
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif (pour marquer les runners déjà installés ; fonction
# fournie par zgu-lutris-utils.sh -- résout aussi le cas des deux installées en même temps)
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
  *) runner_dir="${HOME}/.local/share/lutris/runners/wine" ;;
esac

# 3. Récupération de la liste des assets .zgr de la release GitHub
api_url=$(zgu_github_api_url "${GITHUB_RELEASE_URL}")
release_json=$(zgu_fetch_url "${api_url}")

if [[ -z "${release_json}" ]]; then
  zgu_cli_error "$(t list_remote.fetch_failed)"
  exit 1
fi

remote_runners=$(python3 -c '
import sys, json
try:
    data = json.loads(sys.argv[1])
    names = []
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        if name.endswith(".zgr"):
            names.append(name[:-4])
    names.sort(key=str.lower)
    for n in names:
        print(n)
except Exception:
    pass
' "${release_json}")

if [[ -z "${remote_runners}" ]]; then
  t list_remote.none_available
  exit 0
fi

installed_suffix="$(t list_remote.already_installed_suffix)"

while IFS= read -r runner_name; do
  [[ -z "${runner_name}" ]] && continue
  if [[ -d "${runner_dir}/${runner_name}" ]]; then
    echo "${runner_name}${installed_suffix}"
  else
    echo "${runner_name}"
  fi
done <<< "${remote_runners}"

exit 0
