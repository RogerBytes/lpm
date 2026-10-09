#!/bin/bash

# --- lpm vsync: disable VSync for ONE game via environment variables ---
#
#   lpm vsync status                     slugs of games with at least one active setting
#   lpm vsync <slug> [status]            state of the game's 5 settings (one "id=on|off" line)
#   lpm vsync <slug> on  [setting...]    enable the given settings (no argument: all 5)
#   lpm vsync <slug> off [setting...]    remove the given settings (no argument: all 5)
#
# Settings: d3d9, d3d11 (Direct3D 10 and 11), d3d12, gl-nvidia, gl-mesa. Each maps to a
# variable read by ONE graphics layer only (DXVK, VKD3D-Proton, NVIDIA driver, Mesa): a game
# uses one API at a time and the other variables have no effect on it, so setting them all
# together is harmless (see lib/zgu-vsync-edit.py for details and sources). The variables
# are written to system.env in the game's Lutris YAML, like "lpm tools <slug> env" (same
# file, same editor: YAML comments are preserved).
#
# Unlike "lpm tools", no Wine runner or prefix is needed: only the game's YAML is read/written.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

vsync_settings=(d3d9 d3d11 d3d12 gl-nvidia gl-mesa)

cli_args=("$@")

if [[ ${#cli_args[@]} -eq 0 ]]; then
  zgu_cli_error "$(t vsync.cli_usage)"
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t game_tools.sqlite3_missing)"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t game_tools.env_yaml_missing_cli)"
  exit 1
fi

# --- Flatpak vs native package detection (same paths as the rest of the project) ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

lutris_version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  zgu_cli_error "$(t game_tools.lutris_missing_cli)"
  exit 1
fi

case "${lutris_version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    ;;
  native)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t game_tools.no_games_found_cli "${HOME}/Games")"
  exit 1
fi

# --- "lpm vsync status": games with at least one active setting ---
if [[ ${#cli_args[@]} -eq 1 ]] && [[ "${cli_args[0]}" = "status" ]]; then
  while IFS=$'\x1f' read -r row_slug row_config; do
    [[ -z "${row_slug}" ]] || [[ -z "${row_config}" ]] && continue
    yml_file="${lutris_config_dir}/${row_config}.yml"
    [[ -f "${yml_file}" ]] && printf '%s\t%s\n' "${row_slug}" "${yml_file}"
  done < <(sqlite3 -separator $'\x1f' "${lutris_db}" "SELECT slug, configpath FROM games WHERE runner='wine';" 2>/dev/null) \
    | python3 "${script_dir}/zgu-vsync-edit.py" any
  exit 0
fi

# --- One game: "lpm vsync <slug> [status|on|off] [setting...]" ---
target_slug=$(basename -- "${cli_args[0]}")
action="${cli_args[1]:-status}"
setting_args=("${cli_args[@]:2}")

case "${action}" in
  status|on|off) ;;
  *)
    zgu_cli_error "$(t vsync.invalid_action_cli "${action}")"
    exit 1
    ;;
esac

if [[ "${action}" = "status" ]] && [[ ${#setting_args[@]} -gt 0 ]]; then
  zgu_cli_error "$(t vsync.cli_usage)"
  exit 1
fi

for setting in "${setting_args[@]}"; do
  valid=false
  for known in "${vsync_settings[@]}"; do
    [[ "${setting}" = "${known}" ]] && valid=true
  done
  if [[ "${valid}" = false ]]; then
    zgu_cli_error "$(t vsync.invalid_setting_cli "${setting}")"
    exit 1
  fi
done

row=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || configpath FROM games WHERE slug='${target_slug//\'/\'\'}' AND runner='wine' LIMIT 1;" 2>/dev/null)
if [[ -z "${row}" ]]; then
  zgu_cli_error "$(t game_tools.slug_not_found_cli "${target_slug}")"
  exit 1
fi
IFS=$'\x1f' read -r target_name target_configpath <<< "${row}"

yml_file="${lutris_config_dir}/${target_configpath}.yml"
if [[ -z "${target_configpath}" ]] || [[ ! -f "${yml_file}" ]]; then
  zgu_cli_error "$(t game_tools.env_config_missing_cli "${target_name}")"
  exit 1
fi

if [[ "${action}" = "status" ]]; then
  python3 "${script_dir}/zgu-vsync-edit.py" "${yml_file}" status
  exit $?
fi

if ! python3 "${script_dir}/zgu-vsync-edit.py" "${yml_file}" "${action}" "${setting_args[@]}"; then
  zgu_cli_error "$(t game_tools.env_write_failed_cli "${target_name}")"
  exit 1
fi
zgu_cli_ok "$(t "vsync.saved_${action}_cli" "${target_name}")"
