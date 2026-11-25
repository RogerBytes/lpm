#!/bin/bash
# --- Launch options of a game kept in its Lutris YAML (tools <slug> gamemode|gamescope|...) ---
# Sourced by zgp-game-tools.sh; uses its variables (target_name, target_configpath,
# lutris_config_dir, lutris_version, script_dir) and its tools_check_env().
#
# Every option is a key of the game's YAML, written only through zgu-yaml-edit.py (targeted edit,
# comments kept). Key names and defaults come from Lutris itself (lutris/sysoptions.py and
# lutris/runners/wine.py):
#   section system: gamemode, gamescope, gamescope_output_res, gamescope_game_res,
#                   gamescope_fps_limiter, resolution ("off" = keep the current one)
#   section wine:   esync, fsync, dxvk, system_winetricks
# Three states for a yes/no option: "on" (true), "off" (false), "default" (key removed, Lutris
# decides: gamemode, fsync and dxvk/esync default to on when available). "off" is written as an
# explicit false, never by removing the key, because the Lutris default may be on.

declare -A GO_SECTION=([gamemode]=system [gamescope]=system [gamescope-output]=system
  [gamescope-game]=system [gamescope-fps]=system [resolution]=system
  [esync]=wine [fsync]=wine [dxvk]=wine [system-winetricks]=wine)
declare -A GO_KEY=([gamemode]=gamemode [gamescope]=gamescope [gamescope-output]=gamescope_output_res
  [gamescope-game]=gamescope_game_res [gamescope-fps]=gamescope_fps_limiter [resolution]=resolution
  [esync]=esync [fsync]=fsync [dxvk]=dxvk [system-winetricks]=system_winetricks)
declare -A GO_TYPE=([gamemode]=bool [gamescope]=bool [esync]=bool [fsync]=bool [dxvk]=bool
  [system-winetricks]=bool [gamescope-output]=res [gamescope-game]=res [gamescope-fps]=fps [resolution]=resoff)
GO_ORDER=(gamemode gamescope gamescope-output gamescope-game gamescope-fps resolution esync fsync dxvk system-winetricks)

go_is_option() { [[ -n "${GO_TYPE[$1]:-}" ]]; }

# Prints on | off | default (yes/no options) or the value / default (others).
go_read() {
  local id="$1" yml_file="$2"
  SECTION="${GO_SECTION[$id]}" KEY="${GO_KEY[$id]}" TYPE="${GO_TYPE[$id]}" YML_PATH="${yml_file}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    sec = data.get(os.environ["SECTION"])
    key = os.environ["KEY"]
    if not isinstance(sec, dict) or key not in sec or sec[key] is None:
        print("default")
    else:
        v = sec[key]
        if os.environ["TYPE"] == "bool":
            print("on" if v is True or str(v).lower() in ("true", "1", "yes", "on") else "off")
        elif v is False:
            print("off")          # YAML 1.1 reads an unquoted "off" as false
        else:
            print(str(v))
except Exception:
    print("default")
' 2>/dev/null || echo default
}

# go_valid <id> <value>: 0 if the value is acceptable for this option.
go_valid() {
  local id="$1" value="$2"
  case "${GO_TYPE[$id]}" in
    bool)   [[ "${value}" =~ ^(on|off|default)$ ]] ;;
    res)    [[ "${value}" = default ]] || [[ "${value}" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] ;;
    fps)    [[ "${value}" = default ]] || [[ "${value}" =~ ^[1-9][0-9]{0,2}$ ]] ;;
    resoff) [[ "${value}" =~ ^(default|off)$ ]] || [[ "${value}" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] ;;
  esac
}

# go_write <id> <value> <yml>: writes (or, for "default", removes) the key. Prints nothing.
go_write() {
  local id="$1" value="$2" yml_file="$3" section key
  section="${GO_SECTION[$id]}" key="${GO_KEY[$id]}"
  if [[ "${value}" = default ]]; then
    grep -Eq "^[[:space:]]+${key}:" "${yml_file}" 2>/dev/null || return 0   # nothing to remove
    python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" unset "${section}" "${key}" >/dev/null 2>&1
  elif [[ "${GO_TYPE[$id]}" = bool ]]; then
    python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" set "${section}" "${key}" "$([[ "${value}" = on ]] && echo true || echo false)" --bool >/dev/null 2>&1
  else
    python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" set "${section}" "${key}" "${value}" >/dev/null 2>&1
  fi
}

# Warnings after a successful write (never an error: the setting itself is saved).
go_warn() {
  local id="$1" value="$2"
  [[ "${value}" = default || "${value}" = off ]] && [[ "${GO_TYPE[$id]}" != resoff ]] && return 0
  case "${id}" in
    gamescope)
      if [[ "${lutris_version}" = "flatpak" ]]; then
        flatpak list --runtime --columns=application 2>/dev/null | grep -qi 'gamescope' \
          || echo "$(t game_options.warn_gamescope_missing_flatpak)" >&2
      elif ! command -v gamescope >/dev/null 2>&1; then
        echo "$(t game_options.warn_gamescope_missing)" >&2
      fi
      ;;
    gamemode)
      if [[ "${lutris_version}" != "flatpak" ]] && ! command -v gamemoderun >/dev/null 2>&1; then
        echo "$(t game_options.warn_gamemode_missing)" >&2
      fi
      ;;
    resolution)
      [[ "${value}" = default || "${value}" = off ]] && return 0
      if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        echo "$(t game_options.warn_resolution_wayland)" >&2
      fi
      ;;
  esac
  return 0
}

# go_set <id> <value> <yml>: validates, writes, warns, confirms. Returns 1 on error.
go_set() {
  local id="$1" value="$2" yml_file="$3"
  if ! go_valid "${id}" "${value}"; then
    zgu_cli_error "$(t game_options.invalid_value_cli "${id}" "${value}")"
    return 1
  fi
  if ! go_write "${id}" "${value}" "${yml_file}"; then
    zgu_cli_error "$(t game_options.write_failed_cli "${target_name}")"
    return 1
  fi
  if [[ "${value}" = default ]]; then
    zgu_cli_ok "$(t game_options.default_cli "${target_name}" "${id}")"
  else
    zgu_cli_ok "$(t game_options.set_cli "${target_name}" "${id}" "${value}")"
  fi
  go_warn "${id}" "${value}"
  return 0
}

# Entry point: run_game_option <tool> <action-or-value> [more...]
#   tools <slug> <option> status|<value>            (one option)
#   tools <slug> options status                      (all, one "id=value" per line)
#   tools <slug> options apply id=value [id=value..] (several at once, used by the GUI)
run_game_option() {
  local tool="$1" action="${2:-status}" yml_file="${lutris_config_dir}/${target_configpath}.yml" arg id value rc=0
  tools_check_env "${yml_file}" || return 1
  if [[ "${tool}" = "options" ]]; then
    case "${action}" in
      status)
        for id in "${GO_ORDER[@]}"; do printf '%s=%s\n' "${id}" "$(go_read "${id}" "${yml_file}")"; done
        ;;
      apply)
        shift 2
        for arg in "$@"; do
          id="${arg%%=*}" value="${arg#*=}"
          if [[ "${arg}" != *=* ]] || ! go_is_option "${id}"; then
            zgu_cli_error "$(t game_options.invalid_value_cli "${id}" "${value}")"
            rc=1
            continue
          fi
          # Only what changed is written: nothing is touched when the value is already the one asked.
          [[ "$(go_read "${id}" "${yml_file}")" = "${value}" ]] && continue
          go_set "${id}" "${value}" "${yml_file}" || rc=1
        done
        ;;
      *)
        zgu_cli_error "$(t game_options.invalid_action_cli "${action}")"
        return 1
        ;;
    esac
    return "${rc}"
  fi
  if [[ "${action}" = status ]]; then
    go_read "${tool}" "${yml_file}"
    return 0
  fi
  go_set "${tool}" "${action}" "${yml_file}"
}
