#!/bin/bash

# --- lpm sgdb-key get|set <key> ---
#
# Manages the SteamGridDB API key used by "lpm icon"/"splash"/"logo" (lib/zgp-game-icon.sh,
# zgp-game-splash.sh, zgp-game-logo.sh: same storage file and validation). Added for
# gui/*.py (page_images): the key is entered directly on the page, masked but editable, and
# revalidated by a REAL API call on every change.
#
# "get": prints on stdout a JSON object {"key": "<stored key, or "" if none>"}. Never retested
# here (simple read to prefill the GUI field): the API is only called when a key is
# edited/added ("set"), not each time the page opens or resets. "lpm icon"/"splash"/"logo"
# revalidate the key on each real use anyway (see their zgp_sgdb_key_valid).
#
# "set" <key>: tests the key with a real SteamGridDB API call before saving it (never saved
# unvalidated). An empty key CLEARS the stored key (not an error: the GUI field was emptied).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"

# Same file as lib/zgp-game-icon.sh/zgp-game-splash.sh/zgp-game-logo.sh (sgdb_key_file):
# single source of truth, read/written identically on both sides.
sgdb_key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/steamgriddb.key"
sgdb_api="https://www.steamgriddb.com/api/v2"

zgp_sgdb_read_key() {
  [[ -f "${sgdb_key_file}" ]] || return 1
  head -n1 "${sgdb_key_file}" 2>/dev/null | tr -d '[:space:]'
}

zgp_sgdb_key_valid() {
  local key="$1" code
  [[ -z "${key}" ]] && return 1
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${key}" "${sgdb_api}/search/autocomplete/a" 2>/dev/null)
  [[ "${code}" = "200" ]]
}

action="${1:-}"

case "${action}" in
  get)
    key=$(zgp_sgdb_read_key || true)
    SGDB_KEY="${key}" python3 -c '
import json, os
print(json.dumps({"key": os.environ.get("SGDB_KEY", "")}))
' 2>/dev/null
    exit 0
    ;;
  set)
    candidate="${2:-}"
    candidate="${candidate//[$'\n\r\t ']/}"

    if [[ -z "${candidate}" ]]; then
      rm -f "${sgdb_key_file}"
      exit 0
    fi

    if ! zgp_sgdb_key_valid "${candidate}"; then
      zgu_cli_error "$(t sgdb_key.invalid)"
      exit 1
    fi

    mkdir -p "$(dirname "${sgdb_key_file}")"
    printf '%s\n' "${candidate}" > "${sgdb_key_file}"
    chmod 600 "${sgdb_key_file}"
    exit 0
    ;;
  *)
    zgu_cli_error "$(t sgdb_key.cli_usage)"
    exit 1
    ;;
esac
