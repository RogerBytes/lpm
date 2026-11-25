#!/bin/bash
# --- ludis lutris-defaults: Lutris-wide Wine defaults (not tied to one game) ---
#   ludis lutris-defaults status
#   ludis lutris-defaults runner [name]            show / set the default Wine or Proton runner
#   ludis lutris-defaults apply [runner=<name>] [winetricks=system|runner]   (used by the GUI)
#   ludis lutris-defaults winetricks [system|runner]  show / set which winetricks games use by default
# They are the "wine" section of Lutris's runners/wine.yml (runner level): a game that has its own
# value keeps it. Keys "version" and "system_winetricks" are the ones Lutris itself reads
# (lutris/runners/wine.py). Only that file is edited, through zgu-yaml-edit.py.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

# $1 = mode (always "cli"), $2 = subcommand, $3 = value
sub="${2:-status}"
value="${3:-}"

zgu_load_lutris_env || { zgu_cli_error "$(t lutris_defaults.lutris_missing_cli)"; exit 1; }
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t game_tools.env_yaml_missing_cli)"
  exit 1
fi

# Same folder as the games/ folder of this Lutris: <config>/runners/wine.yml
conf_file="$(dirname "${lutris_config_dir}")/runners/wine.yml"

read_key() {
  [[ -f "${conf_file}" ]] || { echo ""; return 0; }
  KEY="$1" YML_PATH="${conf_file}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    wine = data.get("wine")
    v = wine.get(os.environ["KEY"]) if isinstance(wine, dict) else None
    print("" if v is None else str(v))
except Exception:
    print("")
' 2>/dev/null
}

ensure_file() {
  mkdir -p "$(dirname "${conf_file}")" 2>/dev/null || return 1
  [[ -f "${conf_file}" ]] || printf 'wine:\n' > "${conf_file}" 2>/dev/null
  [[ -f "${conf_file}" ]]
}

show_runner() {
  local current
  current="$(read_key version)"
  echo "${current:-default}"
}

show_winetricks() {
  case "$(read_key system_winetricks | tr '[:upper:]' '[:lower:]')" in
    true) echo "system" ;;
    *)    echo "runner" ;;
  esac
}

set_runner() {
  local name="$1"
  if [[ -z "${name}" ]] || [[ "${name}" = */* ]] || [[ "${name}" = .* ]]; then
    zgu_cli_error "$(t game_tools.runner_name_missing_cli)"
    return 1
  fi
  if [[ -z "$(zgu_get_wine_binary "${runner_dir}" "${name}")" ]]; then
    zgu_cli_error "$(t game_tools.runner_not_installed_cli "${name}")"
    return 1
  fi
  if ! ensure_file || ! python3 "${script_dir}/zgu-yaml-edit.py" "${conf_file}" set wine version "${name}" >/dev/null 2>&1; then
    zgu_cli_error "$(t lutris_defaults.write_failed_cli "${conf_file}")"
    return 1
  fi
  zgu_cli_ok "$(t lutris_defaults.runner_set_cli "${name}")"
}

set_winetricks() {
  local choice="$1" flag
  case "${choice}" in
    system) flag=true ;;
    runner) flag=false ;;
    *)
      zgu_cli_error "$(t lutris_defaults.invalid_winetricks_cli "${choice}")"
      return 1
      ;;
  esac
  if ! ensure_file || ! python3 "${script_dir}/zgu-yaml-edit.py" "${conf_file}" set wine system_winetricks "${flag}" --bool >/dev/null 2>&1; then
    zgu_cli_error "$(t lutris_defaults.write_failed_cli "${conf_file}")"
    return 1
  fi
  zgu_cli_ok "$(t lutris_defaults.winetricks_set_cli "${choice}")"
}

case "${sub}" in
  status)
    printf 'runner=%s\nwinetricks=%s\n' "$(show_runner)" "$(show_winetricks)"
    ;;
  runner)
    if [[ -z "${value}" ]]; then show_runner; exit 0; fi
    set_runner "${value}"
    exit $?
    ;;
  winetricks)
    if [[ -z "${value}" ]]; then show_winetricks; exit 0; fi
    set_winetricks "${value}"
    exit $?
    ;;
  apply)
    # ludis lutris-defaults apply [runner=<name>] [winetricks=system|runner]   (used by the GUI)
    shift 2
    rc=0
    for arg in "$@"; do
      case "${arg}" in
        runner=*)     set_runner "${arg#runner=}" || rc=1 ;;
        winetricks=*) set_winetricks "${arg#winetricks=}" || rc=1 ;;
        *) zgu_cli_error "$(t lutris_defaults.invalid_action_cli "${arg}")"; rc=1 ;;
      esac
    done
    exit "${rc}"
    ;;
  *)
    zgu_cli_error "$(t lutris_defaults.invalid_action_cli "${sub}")"
    exit 1
    ;;
esac
