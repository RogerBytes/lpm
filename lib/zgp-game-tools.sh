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
# shellcheck source=./zgu-lpm-paths.sh
source "${script_dir}/zgu-lpm-paths.sh"

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




# Lutris RUNTIME_DIR: DATA_DIR/runtime (Lutris settings.py); its bundled winetricks lives there
# (RUNTIME_DIR/winetricks/winetricks).

zgu_load_lutris_env || {
  zgu_cli_error "$(t game_tools.lutris_missing_cli)"
  exit 1
}

if ! command -v sqlite3 >/dev/null 2>&1 || [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t game_tools.no_games_found_cli "${games_dir}")"
  exit 1
fi

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
# Checks the environment (config file, python yaml). Arg: yml_file. Returns 1 with an error
# message otherwise. Shared by the gamepad and mangohud commands.
tools_check_env() {
  local yml_file="$1"
  if [[ -z "${target_configpath}" ]] || [[ ! -f "${yml_file}" ]]; then
    zgu_cli_error "$(t game_tools.env_config_missing_cli "${target_name}")"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
    zgu_cli_error "$(t game_tools.env_yaml_missing_cli)"
    return 1
  fi
  return 0
}

mango_status() {
  local yml_file="$1" state
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
}

mango_on() {
  local yml_file="$1"
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
}

mango_off() {
  local yml_file="$1"
  # removing a key that is already absent is not an error
  if grep -Eq '^[[:space:]]+mangohud:' "${yml_file}" 2>/dev/null; then
    if ! python3 "${script_dir}/zgu-yaml-edit.py" "${yml_file}" unset system mangohud >/dev/null 2>&1; then
      zgu_cli_error "$(t game_tools.mangohud_write_failed_cli "${target_name}")"
      return 1
    fi
  fi
  zgu_cli_ok "$(t game_tools.mangohud_off_cli "${target_name}")"
}

run_mangohud() {
  local action="${1:-status}" yml_file="${lutris_config_dir}/${target_configpath}.yml"
  case "${action}" in
    on|off|status) ;;
    *)
      zgu_cli_error "$(t game_tools.mangohud_invalid_action_cli "${action}")"
      return 1
      ;;
  esac
  tools_check_env "${yml_file}" || return 1
  case "${action}" in
    status) mango_status "${yml_file}" ;;
    on) mango_on "${yml_file}" ;;
    off) mango_off "${yml_file}" ;;
  esac
}

if [[ "${cli_tool}" = "mangohud" ]]; then
  run_mangohud "${cli_exe_path}"
  exit $?
fi

prefix_dir=$(zgu_resolve_prefix_dir_by_slug "${target_slug}" "${lutris_db}" "${games_dir}")
if [[ -z "${prefix_dir}" ]]; then
  zgu_cli_error "$(t game_tools.prefix_not_found_cli "${target_name}")"
  exit 1
fi

# --- Gamepad: AntiMicroX profile for a game ---
# Lutris itself launches AntiMicroX with a profile for the game when its YAML has
# "system.antimicro_config: <profile file>". lpm creates a blank profile in
# <prefix>/lpm/gamepad/ (never overwritten once it exists, so the user's settings are safe),
# points that option to it, and can open it in AntiMicroX for editing (nothing is watched).
# An antimicro_config that points elsewhere belongs to the user and is never replaced.
# Actions: on | off | edit | status (default status; status prints on, off or other).
# State of run_gamepad (set by run_gamepad, read by the gp_* steps).
gp_yml="" gp_profile_dir="" gp_profile_file="" gp_current=""

# Reads system.antimicro_config of the Lutris yml into gp_current.
gp_read_current() {
  gp_current=$(YML_PATH="${gp_yml}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    system = data.get("system")
    print(str(system.get("antimicro_config") or "") if isinstance(system, dict) else "")
except Exception:
    print("")
' 2>/dev/null)
}

gp_status() {
  if [[ -z "${gp_current}" ]]; then
    echo "off"
  elif [[ "${gp_current}" = "${gp_profile_file}" ]]; then
    echo "on"
  else
    echo "other"
  fi
  return 0
}

gp_edit() {
  if [[ ! -f "${gp_profile_file}" ]]; then
    zgu_cli_error "$(t game_tools.gamepad_missing_profile_cli "${target_name}")"
    return 1
  fi
  if command -v antimicrox >/dev/null 2>&1; then
    setsid antimicrox --profile "${gp_profile_file}" >/dev/null 2>&1 &
  elif command -v antimicro >/dev/null 2>&1; then
    setsid antimicro --profile "${gp_profile_file}" >/dev/null 2>&1 &
  elif command -v flatpak >/dev/null 2>&1 && flatpak info io.github.antimicrox.antimicrox >/dev/null 2>&1; then
    setsid flatpak run io.github.antimicrox.antimicrox --profile "${gp_profile_file}" >/dev/null 2>&1 &
  else
    zgu_cli_error "$(t game_tools.gamepad_missing_cli)"
    return 1
  fi
  zgu_cli_ok "$(t game_tools.gamepad_edit_cli "${gp_profile_file}")"
  return 0
}

gp_off() {
  if [[ -n "${gp_current}" ]] && [[ "${gp_current}" != "${gp_profile_file}" ]]; then
    zgu_cli_error "$(t game_tools.gamepad_other_cli "${target_name}" "${gp_current}")"
    return 1
  fi
  if [[ -n "${gp_current}" ]]; then
    if ! python3 "${script_dir}/zgu-yaml-edit.py" "${gp_yml}" unset system antimicro_config >/dev/null 2>&1; then
      zgu_cli_error "$(t game_tools.gamepad_write_failed_cli "${target_name}")"
      return 1
    fi
  fi
  zgu_cli_ok "$(t game_tools.gamepad_off_cli "${target_name}")"
  return 0
}

# Writes the default AntiMicroX profile if missing. Returns 1 if it cannot be created.
gp_write_default_profile() {
  [[ -f "${gp_profile_file}" ]] && return 0
  mkdir -p "${gp_profile_dir}" 2>/dev/null
  if ! cat > "${gp_profile_file}" 2>/dev/null <<'AMGP'
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
    zgu_cli_error "$(t game_tools.gamepad_create_failed_cli "${gp_profile_file}")"
    return 1
  fi
  return 0
}

gp_on() {
  if [[ -n "${gp_current}" ]] && [[ "${gp_current}" != "${gp_profile_file}" ]]; then
    zgu_cli_error "$(t game_tools.gamepad_other_cli "${target_name}" "${gp_current}")"
    return 1
  fi
  gp_write_default_profile || return 1
  if [[ "${gp_current}" != "${gp_profile_file}" ]]; then
    if ! python3 "${script_dir}/zgu-yaml-edit.py" "${gp_yml}" set system antimicro_config "${gp_profile_file}" >/dev/null 2>&1; then
      zgu_cli_error "$(t game_tools.gamepad_write_failed_cli "${target_name}")"
      return 1
    fi
  fi
  zgu_cli_ok "$(t game_tools.gamepad_on_cli "${target_name}" "${gp_profile_file}")"
  if ! command -v antimicrox >/dev/null 2>&1 && ! command -v antimicro >/dev/null 2>&1 \
     && ! { command -v flatpak >/dev/null 2>&1 && flatpak info io.github.antimicrox.antimicrox >/dev/null 2>&1; }; then
    echo "$(t game_tools.gamepad_missing_warn_cli)" >&2
  fi
  return 0
}

run_gamepad() {
  local action="${1:-status}"
  gp_yml="${lutris_config_dir}/${target_configpath}.yml"
  gp_profile_dir="$(zgu_lpm_find "${prefix_dir}" gamepad)"
  gp_profile_file="${gp_profile_dir}/lpm-gamepad.gamecontroller.amgp"
  case "${action}" in
    on|off|edit|status) ;;
    *)
      zgu_cli_error "$(t game_tools.gamepad_invalid_action_cli "${action}")"
      return 1
      ;;
  esac
  tools_check_env "${gp_yml}" || return 1
  gp_read_current
  case "${action}" in
    status) gp_status ;;
    edit) gp_edit ;;
    off) gp_off ;;
    on) gp_on ;;
  esac
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
  # Same as Lutris' "Open Wine console": "<resolved wine binary> wineconsole". "wineconsole" is
  # built INTO Wine (Proton included), even without a separate "bin/wineconsole" file. Running
  # "wine cmd.exe" detached shows nothing (cmd.exe tries to attach to an existing terminal),
  # whereas "wine wineconsole" opens Wine's own graphical console host; "cmd" is passed
  # explicitly rather than relying on an undocumented default.
  # Start directory: Wine maps its Windows current directory to the process's UNIX one, so we cd
  # into "<prefix>/drive_c" first (the prefix root if it is missing), otherwise the console would
  # open wherever lpm was started.
  local console_start_dir="${prefix_dir}/drive_c"
  [[ -d "${console_start_dir}" ]] || console_start_dir="${prefix_dir}"
  (
    # prefix_dir exists (checked by zgu_resolve_prefix_dir_by_slug); if both cd still failed,
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
# Adds <real_folder> as "Place0" in the native Windows Open/Save dialogs of this game
# (comdlg32, not the modern IFileOpenDialog): registry key
# HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Comdlg32\Placesbar, values
# "Place0" to "Place4" (Wine: dlls/comdlg32/filedlg.c), read FROM THE GAME'S PREFIX. Only Place0
# is written, and it is overwritten when the command is re-run.
# The Linux path is converted with "winepath -w" first (Wine expects a Windows path), using the
# runner configured for this game, else the generic winepath from PATH, as in
# zgl-launcher-manager.sh.
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
