#!/bin/bash

# --- List the runners available on the remote GitHub release ---
# Output: one <runner name> per line, sorted alphabetically.
# A runner already present locally is flagged "(déjà installé)".

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

# GITHUB_RELEASE_URL is defined in zgu-github-release-utils.sh; change the repo/release there.

# 1. Required dependencies check
if ! command -v python3 >/dev/null 2>&1; then
  zgu_cli_error "$(t list_remote.python_missing)"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  zgu_cli_error "$(t list_remote.network_tool_missing)"
  exit 1
fi

# 2. Flatpak vs native Lutris detection (to flag already installed runners; from zgu-lutris-utils.sh,
# also handles both being installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
  *) runner_dir="${HOME}/.local/share/lutris/runners/wine" ;;
esac

# 3. Fetch the list of .zgr assets of the GitHub release
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
  # On stderr, not stdout: gui/backend.py::list_remote_runners() treats EVERY non-empty stdout line
  # of "lpm list-remote-runners" as a remote runner name (same fix as zgp-game-lister.sh).
  t list_remote.none_available >&2
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
