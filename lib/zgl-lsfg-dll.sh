#!/bin/bash

# --- lpm lsfg-dll get|set <path> ---
#
# Non-interactive counterpart of zgp_lsfg_ensure_dll (see zgl-lsfg-manager.sh, item 3 of its
# header). It ONLY reads/writes the reference DLL lsfg-vk.dll stored at
# "~/.config/lpm/lsfg-vk/lsfg-vk.dll", never the activation itself ("lpm lsfg <slug...> on|off").
# Added for gui/*.py (page_lsfg): the terminal prompt ("read -p") of zgp_lsfg_ensure_dll
# cannot work when the GUI runs the command (no TTY attached).
#
# "get": prints on stdout a JSON object {"path": "<stored DLL path if still present, else "">"}.
#
# "set" <local_path>: checks that the file exists and is named "lsfg-vk.dll" (never the
# "Lossless.dll" of the public branch: a wrongly named DLL breaks game launch, see the
# comment in zgp_lsfg_ensure_dll), then copies it to the storage location. Errors go to
# stderr, with the same "lsfg.dll_*" messages as zgp_lsfg_ensure_dll.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"

action="${1:-}"
lsfg_dll_master="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/lsfg-vk/lsfg-vk.dll"

case "${action}" in
  get)
    LSFG_DLL_MASTER="${lsfg_dll_master}" python3 -c '
import json, os
path = os.environ.get("LSFG_DLL_MASTER", "")
print(json.dumps({"path": path if os.path.isfile(path) else ""}))
' 2>/dev/null
    exit 0
    ;;
  set)
    candidate="${2:-}"
    if [[ -z "${candidate}" ]] || [[ ! -f "${candidate}" ]]; then
      zgu_cli_error "$(t lsfg.dll_not_found "${candidate}")"
      exit 1
    fi

    # Same check as zgp_lsfg_ensure_dll (the file name is authoritative): a renamed
    # Lossless.dll would otherwise pass without the "mipmaps" shader required by lsfg-vk 2.0.
    candidate_basename="$(basename -- "${candidate}")"
    if [[ "${candidate_basename,,}" != "lsfg-vk.dll" ]]; then
      zgu_cli_error "$(t lsfg.dll_wrong_name "${candidate_basename}")"
      exit 1
    fi

    mkdir -p "$(dirname "${lsfg_dll_master}")"
    if ! cp -f -- "${candidate}" "${lsfg_dll_master}"; then
      zgu_cli_error "$(t lsfg.dll_copy_failed)"
      exit 1
    fi
    exit 0
    ;;
  *)
    zgu_cli_error "$(t lsfg.dll_cli_usage)"
    exit 1
    ;;
esac
