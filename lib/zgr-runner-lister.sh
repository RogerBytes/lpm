#!/bin/bash

# --- List the Wine/Proton runners installed for Lutris ---
# Output: <runner name> (one per line, sorted alphabetically)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# Flatpak vs native Lutris detection (from zgu-lutris-utils.sh; also handles both being installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
  *)
    # Explicit detection: avoids a silent fallback to a default native path that would hide a missing Lutris.
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
  # On stderr, not stdout: gui/backend.py::list_runners() treats EVERY non-empty stdout line of
  # "lpm list-runner" as a runner name (same fix as "lpm list" in zgp-game-lister.sh).
  t list_runner.none_installed >&2
  exit 0
fi

# Clean alphabetical sort
mapfile -t sorted_runners < <(printf '%s\n' "${runners_list[@]}" | sort)

for runner in "${sorted_runners[@]}"; do
  runner="${runner%/}"
  [[ -d "${runner}" ]] || continue
  echo "${runner}"
done

exit 0
