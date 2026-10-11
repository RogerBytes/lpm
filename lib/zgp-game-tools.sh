#!/bin/bash

# --- lpm tools: Wine tools menu for a game (winetricks, registry editor, winecfg, DOS console,
# run an .exe, open the prefix folder, add a favorite folder to the Windows Open/Save dialogs)
# ---
#
# Goal: reproduce EXACTLY what Lutris does for these tools (same wine binary, same environment
# variables), checked against its source (lutris/runners/commands/wine.py and
# lutris/util/wine/wine.py):
#   - No flatpak-spawn/host-spawn: Lutris calls the wine binary directly, whether Lutris (and thus lpm) runs as Flatpak or native package.
#   - The binary used is the one of the runner CONFIGURED FOR THIS GAME (wine.version in its YAML), never a generic "wine" from PATH: winecfg/regedit/winetricks running a different version than the game would behave inconsistently (registry keys, builtin DLLs...).
#   - WINEDLLOVERRIDES is rebuilt with the SAME algorithm as Lutris get_overrides_env() (buckets by normalized value, "winemenubuilder" always disabled).
#   - Winetricks: the binary bundled by Lutris (RUNTIME_DIR/winetricks/winetricks) is preferred, unless the game has "system_winetricks" enabled, exactly the choice Lutris would make for THIS game.
#
# Deliberate simplification: Lutris also adds LD_LIBRARY_PATH for its "Lutris Runtime"
# (compatibility libs it downloads itself). The exact layout of that folder is not
# stable/documented enough to reproduce safely, and it mainly serves to run GAMES
# (DXVK/VKD3D/etc.), not basic Win32 utilities like winecfg/regedit/cmd. It is therefore NOT
# reproduced here; revisit with a concrete case if an issue shows up on an exotic distro.
#
# WINEARCH is not forced either: the prefix already exists (created by Lutris or lpm) and Wine
# detects its architecture from system.reg by itself. Forcing it could break a prefix if the
# value read differs from reality.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

# --- Arguments ---
# $1 = target slug (required)
# $2 = target tool (required):
#      winetricks | regedit | winecfg | console | exe | folder | favorite | env | runner | mangohud | gamepad
# $3 = executable path (only for $2=exe), favorite folder (only for $2=favorite), action (list|set|unset|apply, only for $2=env, with $4/$5 = key/value or KEY=VALUE file), runner name (only for $2=runner), or on|off|status (only for $2=mangohud or gamepad (gamepad also has edit), default status); also required for those tools
cli_slug="${1:-}"
cli_tool="${2:-}"
cli_exe_path="${3:-}"
cli_arg4="${4:-}"
cli_arg5="${5:-}"
cli_argc=$#   # number of arguments received (distinguishes "KEY ''" from a missing value)

if [[ -z "${cli_slug}" ]] || [[ -z "${cli_tool}" ]]; then
  zgu_cli_error "$(t game_tools.cli_usage)"
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t game_tools.sqlite3_missing)"
  exit 1
fi

# --- Flatpak vs native package detection (same paths/conventions as the rest of the project)
# ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# Lutris RUNTIME_DIR: DATA_DIR/runtime (Lutris settings.py); its bundled winetricks lives there
# (RUNTIME_DIR/winetricks/winetricks).
lutris_flatpak_runtime_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runtime"
lutris_package_runtime_dir="${HOME}/.local/share/lutris/runtime"

lutris_version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  zgu_cli_error "$(t game_tools.lutris_missing_cli)"
  exit 1
fi

case "${lutris_version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_system_file="${lutris_flatpak_system_file}"
    runner_dir="${lutris_flatpak_runner_dir}"
    runtime_dir="${lutris_flatpak_runtime_dir}"
    ;;
  native)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_system_file="${lutris_package_system_file}"
    runner_dir="${lutris_package_runner_dir}"
    runtime_dir="${lutris_package_runtime_dir}"
    ;;
esac

games_dir="${HOME}/Games"
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if ! command -v sqlite3 >/dev/null 2>&1 || [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t game_tools.no_games_found_cli "${games_dir}")"
  exit 1
fi

# Resolves the real, safe prefix path of a slug (same anti-escape guard as zgp-game-packer.sh:
# the path must stay a real subfolder of games_dir).
resolve_prefix_dir_by_slug() {
  local slug="$1" safe_slug raw_dir real_dir real_games_dir
  safe_slug="${slug//\'/\'\'}"
  raw_dir=$(sqlite3 "${lutris_db}" "SELECT directory FROM games WHERE slug='${safe_slug}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  [[ -z "${raw_dir}" ]] && return 1

  real_dir=$(realpath -e "${raw_dir}" 2>/dev/null)
  real_games_dir=$(realpath -e "${games_dir}" 2>/dev/null)
  if [[ -z "${real_dir}" ]] || [[ -z "${real_games_dir}" ]] || [[ "${real_dir}" != "${real_games_dir}/"* ]]; then
    return 1
  fi
  echo "${real_dir}"
}

# --- 1. Game selection (CLI slug only) ---
#
# No exclusion of games in shared prefixes (Epic/EA/Ubisoft...) here: unlike pack (export) or
# uninstall, this feature touches/exports nothing, it only launches tools INSIDE the existing
# prefix. This is intended.
target_slug="" target_name="" target_configpath=""

target_slug=$(basename -- "${cli_slug}")
row=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || configpath FROM games WHERE slug='${target_slug//\'/\'\'}' AND runner='wine' LIMIT 1;" 2>/dev/null)
if [[ -z "${row}" ]]; then
  zgu_cli_error "$(t game_tools.slug_not_found_cli "${target_slug}")"
  exit 1
fi
IFS=$'\x1f' read -r target_name target_configpath <<< "${row}"

# --- "runner" tool: handled HERE, before the configured-runner check below. This is precisely
# the case where the runner must be changed: the game's current one is no longer installed (or
# no longer suitable). Only the game's YAML is read/written; neither the prefix nor the old
# runner is needed. The NEW runner must be installed (same on-disk probe as when launching a
# tool). ---
run_runner() {
  local new_runner="$1" yml_file="${lutris_config_dir}/${target_configpath}.yml"
  if [[ -z "${new_runner}" ]] || [[ "${new_runner}" = */* ]] || [[ "${new_runner}" = .* ]]; then
    zgu_cli_error "$(t game_tools.runner_name_missing_cli)"
    return 1
  fi
  if [[ -z "$(zgu_get_wine_binary "${runner_dir}" "${new_runner}")" ]]; then
    zgu_cli_error "$(t game_tools.runner_not_installed_cli "${new_runner}")"
    return 1
  fi
  if [[ -z "${target_configpath}" ]] || [[ ! -f "${yml_file}" ]]; then
    zgu_cli_error "$(t game_tools.env_config_missing_cli "${target_name}")"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
    zgu_cli_error "$(t game_tools.env_yaml_missing_cli)"
    return 1
  fi
  if ! python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" set wine version "${new_runner}"; then
    zgu_cli_error "$(t game_tools.runner_write_failed_cli "${target_name}")"
    return 1
  fi
  zgu_cli_ok "$(t game_tools.runner_set_cli "${target_name}" "${new_runner}")"
}

if [[ "${cli_tool}" = "runner" ]]; then
  run_runner "${cli_exe_path}"
  exit $?
fi

# --- "mangohud" tool: handled HERE too (only the game's Lutris YAML is read/written, neither the
# prefix nor the runner is needed). Lutris option "system.mangohud" ("Enable MangoHud", FPS overlay):
# "on" sets it to true, "off" REMOVES the key (Lutris default = off), "status" (default action)
# prints "on" or "off" on stdout. MangoHud itself is not installed by lpm: when it cannot be found
# for this Lutris, "on" still writes the setting but says it will have no effect until it is
# installed (native: "mangohud" in PATH; Flatpak: the MangoHud Vulkan layer extension). ---
run_mangohud() {
  local action="${1:-status}" yml_file="${lutris_config_dir}/${target_configpath}.yml" state
  case "${action}" in
    on|off|status) ;;
    *)
      zgu_cli_error "$(t game_tools.mangohud_invalid_action_cli "${action}")"
      return 1
      ;;
  esac
  if [[ -z "${target_configpath}" ]] || [[ ! -f "${yml_file}" ]]; then
    zgu_cli_error "$(t game_tools.env_config_missing_cli "${target_name}")"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
    zgu_cli_error "$(t game_tools.env_yaml_missing_cli)"
    return 1
  fi

  if [[ "${action}" = "status" ]]; then
    state=$(YML_PATH="${yml_file}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    system = data.get("system")
    print("on" if isinstance(system, dict) and system.get("mangohud") is True else "off")
except Exception:
    print("off")
' 2>/dev/null)
    echo "${state:-off}"
    return 0
  fi

  if [[ "${action}" = "on" ]]; then
    if ! python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" set system mangohud true --bool >/dev/null 2>&1; then
      zgu_cli_error "$(t game_tools.mangohud_write_failed_cli "${target_name}")"
      return 1
    fi
    zgu_cli_ok "$(t game_tools.mangohud_on_cli "${target_name}")"
    if [[ "${lutris_version}" = "flatpak" ]]; then
      if ! flatpak list --runtime --columns=application 2>/dev/null | grep -qi 'MangoHud'; then
        echo "$(t game_tools.mangohud_missing_flatpak_cli)" >&2
      fi
    elif ! command -v mangohud >/dev/null 2>&1; then
      echo "$(t game_tools.mangohud_missing_native_cli)" >&2
    fi
    return 0
  fi

  # off: removing a key that is already absent is not an error
  if grep -Eq '^[[:space:]]+mangohud:' "${yml_file}" 2>/dev/null; then
    if ! python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" unset system mangohud >/dev/null 2>&1; then
      zgu_cli_error "$(t game_tools.mangohud_write_failed_cli "${target_name}")"
      return 1
    fi
  fi
  zgu_cli_ok "$(t game_tools.mangohud_off_cli "${target_name}")"
}

if [[ "${cli_tool}" = "mangohud" ]]; then
  run_mangohud "${cli_exe_path}"
  exit $?
fi

prefix_dir=$(resolve_prefix_dir_by_slug "${target_slug}")
if [[ -z "${prefix_dir}" ]]; then
  zgu_cli_error "$(t game_tools.prefix_not_found_cli "${target_name}")"
  exit 1
fi

# --- Gamepad: AntiMicroX profile for a game ---
# Lutris itself launches AntiMicroX with a profile for the game when its YAML has
# "system.antimicro_config: <profile file>". lpm creates a blank profile in
# <prefix>/lpm_gamepad/ (never overwritten once it exists, so the user's settings are safe),
# points that option to it, and can open it in AntiMicroX for editing (nothing is watched).
# An antimicro_config that points elsewhere belongs to the user and is never replaced.
# Actions: on | off | edit | status (default status; status prints on, off or other).
run_gamepad() {
  local action="${1:-status}" yml_file="${lutris_config_dir}/${target_configpath}.yml"
  local profile_dir="${prefix_dir}/lpm_gamepad"
  local profile_file="${profile_dir}/lpm-gamepad.gamecontroller.amgp"
  local current
  case "${action}" in
    on|off|edit|status) ;;
    *)
      zgu_cli_error "$(t game_tools.gamepad_invalid_action_cli "${action}")"
      return 1
      ;;
  esac
  if [[ -z "${target_configpath}" ]] || [[ ! -f "${yml_file}" ]]; then
    zgu_cli_error "$(t game_tools.env_config_missing_cli "${target_name}")"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
    zgu_cli_error "$(t game_tools.env_yaml_missing_cli)"
    return 1
  fi

  current=$(YML_PATH="${yml_file}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    system = data.get("system")
    print(str(system.get("antimicro_config") or "") if isinstance(system, dict) else "")
except Exception:
    print("")
' 2>/dev/null)

  case "${action}" in
    status)
      if [[ -z "${current}" ]]; then
        echo "off"
      elif [[ "${current}" = "${profile_file}" ]]; then
        echo "on"
      else
        echo "other"
      fi
      return 0
      ;;
    edit)
      if [[ ! -f "${profile_file}" ]]; then
        zgu_cli_error "$(t game_tools.gamepad_missing_profile_cli "${target_name}")"
        return 1
      fi
      if command -v antimicrox >/dev/null 2>&1; then
        setsid antimicrox --profile "${profile_file}" >/dev/null 2>&1 &
      elif command -v antimicro >/dev/null 2>&1; then
        setsid antimicro --profile "${profile_file}" >/dev/null 2>&1 &
      elif command -v flatpak >/dev/null 2>&1 && flatpak info io.github.antimicrox.antimicrox >/dev/null 2>&1; then
        setsid flatpak run io.github.antimicrox.antimicrox --profile "${profile_file}" >/dev/null 2>&1 &
      else
        zgu_cli_error "$(t game_tools.gamepad_missing_cli)"
        return 1
      fi
      zgu_cli_ok "$(t game_tools.gamepad_edit_cli "${profile_file}")"
      return 0
      ;;
    off)
      if [[ -n "${current}" ]] && [[ "${current}" != "${profile_file}" ]]; then
        zgu_cli_error "$(t game_tools.gamepad_other_cli "${target_name}" "${current}")"
        return 1
      fi
      if [[ -n "${current}" ]]; then
        if ! python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" unset system antimicro_config >/dev/null 2>&1; then
          zgu_cli_error "$(t game_tools.gamepad_write_failed_cli "${target_name}")"
          return 1
        fi
      fi
      zgu_cli_ok "$(t game_tools.gamepad_off_cli "${target_name}")"
      return 0
      ;;
  esac

  # on
  if [[ -n "${current}" ]] && [[ "${current}" != "${profile_file}" ]]; then
    zgu_cli_error "$(t game_tools.gamepad_other_cli "${target_name}" "${current}")"
    return 1
  fi
  if [[ ! -f "${profile_file}" ]]; then
    mkdir -p "${profile_dir}" 2>/dev/null
    if ! cat > "${profile_file}" 2>/dev/null <<'AMGP'
<?xml version="1.0" encoding="UTF-8"?>
<gamecontroller configversion="19" appversion="3.6.1">
    <stickAxisAssociation index="1" xAxis="1" yAxis="2"/>
    <stickAxisAssociation index="2" xAxis="3" yAxis="4"/>
    <vdpadButtonAssociations index="1">
        <vdpadButtonAssociation axis="0" button="12" direction="1"/>
        <vdpadButtonAssociation axis="0" button="13" direction="4"/>
        <vdpadButtonAssociation axis="0" button="14" direction="8"/>
        <vdpadButtonAssociation axis="0" button="15" direction="2"/>
    </vdpadButtonAssociations>
    <names>
        <controlstickname index="1">Stick 1</controlstickname>
        <controlstickname index="2">Stick 2</controlstickname>
    </names>
    <sets/>
</gamecontroller>
AMGP
    then
      zgu_cli_error "$(t game_tools.gamepad_create_failed_cli "${profile_file}")"
      return 1
    fi
  fi
  if [[ "${current}" != "${profile_file}" ]]; then
    if ! python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" set system antimicro_config "${profile_file}" >/dev/null 2>&1; then
      zgu_cli_error "$(t game_tools.gamepad_write_failed_cli "${target_name}")"
      return 1
    fi
  fi
  zgu_cli_ok "$(t game_tools.gamepad_on_cli "${target_name}" "${profile_file}")"
  if ! command -v antimicrox >/dev/null 2>&1 && ! command -v antimicro >/dev/null 2>&1 \
     && ! { command -v flatpak >/dev/null 2>&1 && flatpak info io.github.antimicrox.antimicrox >/dev/null 2>&1; }; then
    echo "$(t game_tools.gamepad_missing_warn_cli)" >&2
  fi
  return 0
}

if [[ "${cli_tool}" = "gamepad" ]]; then
  run_gamepad "${cli_exe_path}"
  exit $?
fi

# --- 2. Read the game Wine config (runner version, system_winetricks, overrides) ---
wine_version=""
system_winetricks="0"
overrides_env="winemenubuilder="

if [[ -n "${target_configpath}" ]]; then
  yml_config_file="${lutris_config_dir}/${target_configpath}.yml"
  if [[ -f "${yml_config_file}" ]] && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    parsed=$(YML_PATH="${yml_config_file}" python3 -c '
import os
import yaml

yml_path = os.environ["YML_PATH"]
version = ""
system_winetricks = "0"
overrides_str = "winemenubuilder="

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f) or {}
    wine_cfg = data.get("wine")
    if isinstance(wine_cfg, dict):
        version = wine_cfg.get("version") or ""
        if wine_cfg.get("system_winetricks"):
            system_winetricks = "1"

        # Faithful reproduction of Lutris get_overrides_env()
        # (lutris/util/wine/wine.py): same buckets, same normalization,
        # "winemenubuilder" always forced to disabled (overrides any user value, as
        # Lutris does).
        overrides = wine_cfg.get("overrides")
        overrides = dict(overrides) if isinstance(overrides, dict) else {}
        overrides["winemenubuilder"] = ""

        buckets = {"n,b": [], "b,n": [], "b": [], "n": [], "d": [], "": []}
        for dll, value in overrides.items():
            v = value or ""
            v = v.replace(" ", "").replace("builtin", "b").replace("native", "n").replace("disabled", "")
            if v in buckets:
                buckets[v].append(dll)

        parts = []
        for value, dlls in buckets.items():
            if dlls:
                parts.append("{}={}".format(",".join(sorted(dlls)), value))
        overrides_str = ";".join(parts)
except Exception:
    pass

print(f"{version}\x1f{system_winetricks}\x1f{overrides_str}")
' 2>/dev/null)
    IFS=$'\x1f' read -r wine_version system_winetricks overrides_env <<< "${parsed}"
  fi
fi

[[ -z "${wine_version}" ]] && wine_version=$(zgu_get_default_runner)

wine_bin=$(zgu_get_wine_binary "${runner_dir}" "${wine_version}")
if [[ -z "${wine_bin}" ]]; then
  zgu_cli_error "$(t game_tools.runner_missing_cli "${wine_version}")"
  exit 1
fi

# --- 3. Resolve the winetricks binary (the one bundled with Lutris, unless the game explicitly
# uses system winetricks; same choice Lutris would make, see find_winetricks() in its source)
# ---
embedded_winetricks="${runtime_dir}/winetricks/winetricks"
winetricks_bin=""
if [[ "${system_winetricks}" = "1" ]] || [[ ! -x "${embedded_winetricks}" ]]; then
  winetricks_bin=$(command -v winetricks 2>/dev/null || true)
else
  winetricks_bin="${embedded_winetricks}"
fi

# --- 4. Launch in the background, detached from this script (setsid), for the 5 tools that open
# a window (winetricks/regedit/winecfg/console/exe): lpm must never block waiting for them to
# close. ---
zgt_launch_detached() {
  setsid "$@" >/dev/null 2>&1 </dev/null &
  disown
}

# zgt_already_running <pgrep_pattern>
# Checks whether a process matching the pattern (e.g. "winecfg\.exe") is ALREADY running for
# THIS exact prefix (${prefix_dir}), not just "a winecfg somewhere on the machine", which could
# belong to ANOTHER game being edited in parallel and must not be blocked. Filtering reads
# /proc/<pid>/environ (exact WINEPREFIX) instead of guessing from the command line (which does
# not contain the prefix for winecfg.exe/regedit.exe; WINEDLLOVERRIDES/WINEPREFIX are passed as
# environment variables).
# Returns 0 if a process is already running for this prefix, 1 otherwise.
zgt_already_running() {
  local pattern="$1" pid environ_file
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    environ_file="/proc/${pid}/environ"
    [[ -r "${environ_file}" ]] || continue
    if tr '\0' '\n' < "${environ_file}" 2>/dev/null | grep -qxF "WINEPREFIX=${prefix_dir}"; then
      return 0
    fi
  done < <(pgrep -f -- "${pattern}" 2>/dev/null)
  return 1
}

run_winetricks() {
  if [[ -z "${winetricks_bin}" ]]; then
    zgu_cli_error "$(t game_tools.winetricks_missing_cli)"
    return 1
  fi
  if zgt_already_running "${winetricks_bin}"; then
    zgu_cli_error "$(t game_tools.already_running_cli "${target_name}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINE="${wine_bin}" WINEDLLOVERRIDES="${overrides_env}" "${winetricks_bin}"
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_regedit() {
  if zgt_already_running 'regedit\.exe'; then
    zgu_cli_error "$(t game_tools.already_running_cli "${target_name}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" regedit.exe
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_winecfg() {
  if zgt_already_running 'winecfg\.exe'; then
    zgu_cli_error "$(t game_tools.already_running_cli "${target_name}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" winecfg.exe
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_console() {
  # Lutris (lutris/runners/wine.py): its "Open Wine console" menu entry calls
  # run_wineconsole(), which runs self._run_executable("wineconsole"), i.e.
  # wineexec("wineconsole", wine_path=self.get_executable(), ...). The result is simply
  # "<resolved wine binary> wineconsole": no cmd.exe argument, no search for a separate
  # "wineconsole" file on disk.
  #
  # "wineconsole" is BUILT INTO Wine itself (like "wine notepad" or "wine cmd") and present in
  # every Wine build, Proton included, even when no separate "bin/wineconsole" file exists
  # (Proton runners do not have it). Lutris never looks for that file either; it always goes
  # through the main wine binary.
  #
  # Running "wine cmd.exe" detached without wineconsole displays nothing: cmd.exe is a console
  # app that tries to attach to an existing terminal, whereas "wine wineconsole" opens its OWN
  # graphical console host built into Wine and needs no host terminal. "cmd" is passed
  # explicitly (rather than relying on an undocumented default) to guarantee the expected
  # shell (a real MS-DOS console).
  #
  # Start directory: Wine maps its Windows current directory to the UNIX current directory of
  # the process at launch time, unrelated to WINEPREFIX. Without intervention, the script
  # inherits lpm's own cwd (typically the filesystem root or wherever lpm was launched), so
  # the console would open outside the prefix. We cd into "<prefix>/drive_c" (the prefix C:
  # drive) first, falling back to the prefix root if "drive_c" does not exist
  # (non-standard/corrupt prefix).
  local console_start_dir="${prefix_dir}/drive_c"
  [[ -d "${console_start_dir}" ]] || console_start_dir="${prefix_dir}"
  (
    # prefix_dir exists (checked by resolve_prefix_dir_by_slug); if both cd still failed,
    # the console would simply open in the current folder, harmlessly.
    # shellcheck disable=SC2164
    cd "${console_start_dir}" 2>/dev/null || cd "${prefix_dir}"
    zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" wineconsole cmd
  )
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_exe() {
  local exe_path="$1"
  # Path required (no interactive file picker fallback).
  if [[ -z "${exe_path}" ]]; then
    zgu_cli_error "$(t game_tools.exe_not_found_cli "${exe_path}")"
    return 1
  fi
  if [[ ! -f "${exe_path}" ]]; then
    zgu_cli_error "$(t game_tools.exe_not_found_cli "${exe_path}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" "${exe_path}"
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_folder() {
  zgt_launch_detached xdg-open "${prefix_dir}"
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

# run_favorite <real_folder>
#
# Adds <real_folder> as the "Place0" shortcut in this game's native Windows Open/Save dialogs
# (comdlg32, NOT the modern IFileOpenDialog windows). Checked in the Wine source
# (dlls/comdlg32/filedlg.c, filedlg_collect_places_pidls()): registry
# HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Comdlg32\Placesbar, values "Place0" to
# "Place4" (5 slots max, places[5] array in the code), read FROM THE GAME'S PREFIX (per-prefix
# registry, not system-wide). Only "Place0" is written, to keep the feature simple instead of
# managing several slots; Place0 is always overwritten if the command is re-run for this game.
#
# A real Linux path cannot be written as-is to this key: Wine expects a Windows-side path
# (resolved later via SHParseDisplayName), so it is converted first with "winepath -w", as
# zgl-launcher-manager.sh already does for the LPM Launcher executable/working-directory paths
# (same winepath choice: the runner CONFIGURED FOR THIS GAME first, falling back to a generic
# winepath from PATH; this gives the same drive-letter resolution as "wine_bin" above).
run_favorite() {
  local target_dir="$1" winepath_bin="" win_path

  # Folder required (no interactive folder picker fallback).
  if [[ -z "${target_dir}" ]]; then
    zgu_cli_error "$(t game_tools.favorite_not_found_cli "${target_dir}")"
    return 1
  fi

  if [[ ! -d "${target_dir}" ]]; then
    zgu_cli_error "$(t game_tools.favorite_not_found_cli "${target_dir}")"
    return 1
  fi

  if [[ -x "$(dirname "${wine_bin}")/winepath" ]]; then
    winepath_bin="$(dirname "${wine_bin}")/winepath"
  elif command -v winepath >/dev/null 2>&1; then
    winepath_bin="winepath"
  fi
  if [[ -z "${winepath_bin}" ]]; then
    zgu_cli_error "$(t game_tools.favorite_winepath_missing_cli)"
    return 1
  fi

  win_path=$(WINEPREFIX="${prefix_dir}" "${winepath_bin}" -w "${target_dir}" 2>/dev/null | tr -d '\r')
  if [[ -z "${win_path}" ]]; then
    zgu_cli_error "$(t game_tools.favorite_winepath_failed_cli "${target_dir}")"
    return 1
  fi

  if WINEPREFIX="${prefix_dir}" "${wine_bin}" reg add \
      "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Comdlg32\Placesbar" \
      /v Place0 /t REG_SZ /d "${win_path}" /f >/dev/null 2>&1; then
    zgu_cli_ok "$(t game_tools.favorite_saved_cli "${target_name}" "${target_dir}")"
  else
    zgu_cli_error "$(t game_tools.favorite_reg_failed_cli)"
    return 1
  fi
}

# --- Game environment variables (system.env in the Lutris YAML), one game at a time. Edited
# line by line (see lib/zgu-env-edit.py) so YAML comments are never destroyed. ---
run_env() {
  local action="${cli_exe_path}"
  local yml_file="${lutris_config_dir}/${target_configpath}.yml"
  if [[ -z "${target_configpath}" ]] || [[ ! -f "${yml_file}" ]]; then
    zgu_cli_error "$(t game_tools.env_config_missing_cli "${target_name}")"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
    zgu_cli_error "$(t game_tools.env_yaml_missing_cli)"
    return 1
  fi
  case "${action}" in
    list)
      python3 "${script_dir}/zgu-env-edit.py" "${yml_file}" list
      ;;
    set|unset|apply)
      local env_edit_args=()
      [[ "${cli_argc}" -ge 4 ]] && env_edit_args+=("${cli_arg4}")
      [[ "${cli_argc}" -ge 5 ]] && env_edit_args+=("${cli_arg5}")
      if ! python3 "${script_dir}/zgu-env-edit.py" "${yml_file}" "${action}" "${env_edit_args[@]}"; then
        zgu_cli_error "$(t game_tools.env_write_failed_cli "${target_name}")"
        return 1
      fi
      zgu_cli_ok "$(t game_tools.env_saved_cli "${target_name}")"
      ;;
    *)
      zgu_cli_error "$(t game_tools.env_invalid_action_cli "${action}")"
      return 1
      ;;
  esac
}

# --- 5. Tool selection (CLI only) ---
case "${cli_tool}" in
  winetricks) run_winetricks ;;
  regedit) run_regedit ;;
  winecfg) run_winecfg ;;
  console) run_console ;;
  exe) run_exe "${cli_exe_path}" ;;
  folder) run_folder ;;
  favorite) run_favorite "${cli_exe_path}" ;;
  env) run_env ;;
  *)
    zgu_cli_error "$(t game_tools.invalid_tool_cli "${cli_tool}")"
    exit 1
    ;;
esac
exit $?
