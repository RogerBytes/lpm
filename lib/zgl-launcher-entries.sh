#!/bin/bash

# --- lpm launcher-entries <slug> get|set ---
#
# Counterpart of manually editing lpm-launcher.yml (still possible, see
# zgl-launcher-manager.sh): only reads/writes the LPM Launcher picker entries (title,
# prompt, and per entry: label, executable, working directory, launch arguments). It never
# enables/disables the LPM Launcher ("lpm launcher ... on|off") nor changes anything else.
#
# "get": prints on stdout a JSON object {"title", "prompt", "drive_c", "entries": [...]}. Each
# entry carries both its WINDOWS executable/workdir as stored in the YAML ("exe_win"/
# "workdir_win") AND their LINUX conversion ("exe_linux"/"workdir_linux"), so the GUI can
# offer native file choosers. "drive_c" is the Linux path of this prefix's "drive_c", used to
# restrict those choosers.
#
# Windows <-> Linux conversion is deliberately limited to "drive_c" (pure text replacement,
# no "winepath"): "C:\Games\..." always maps to "<prefix>/drive_c/Games/...", and spawning
# Wine (possibly starting wineserver) only slowed "get" down. Other drive letters (mapped via
# dosdevices/) are unsupported: their "_linux" field stays empty, which is never blocking, and
# the native chooser is restricted to "drive_c" anyway.
#
# "set" <json_file>: FULLY replaces title/prompt/entries from a JSON of the same format. An
# empty "workdir_linux" is accepted (derived from the executable's folder). Preserves
# "original_exe" and "bat_path" if already in the file (written by "lpm launcher ... on"):
# merge, not a full replacement. Creates lpm-launcher.yml if missing.

slug="${1:-}"
action="${2:-}"
json_file="${3:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

if [[ -z "${slug}" ]] || { [[ "${action}" != "get" ]] && [[ "${action}" != "set" ]]; }; then
  zgu_cli_error "$(t launcher_entries.cli_usage)"
  exit 1
fi
if [[ "${action}" = "set" ]] && [[ -z "${json_file}" ]]; then
  zgu_cli_error "$(t launcher_entries.cli_usage)"
  exit 1
fi

for cmd in python3 sqlite3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgu_cli_error "$(t launcher.cmd_missing "${cmd}")"
    exit 1
  fi
done
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t launcher.pyyaml_missing_cli)"
  exit 1
fi

# --- Lutris resolution (same approach as zgl-launcher-manager.sh / zgl-launcher-orchestrator.sh) ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgu_cli_error "$(t launcher.lutris_missing)"
  exit 1
fi

if [[ "${version}" = "flatpak" ]]; then
  lutris_db="${lutris_flatpak_db}"
  lutris_config_dir="${lutris_flatpak_config_dir}"
  lutris_system_file="${lutris_flatpak_system_file}"
else
  lutris_db="${lutris_package_db}"
  lutris_config_dir="${lutris_package_config_dir}"
  lutris_system_file="${lutris_package_system_file}"
fi

if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t launcher.db_missing "${lutris_db}")"
  exit 1
fi

safe_slug="${slug//\'/\'\'}"
row=$(sqlite3 "${lutris_db}" "SELECT COALESCE(directory,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' AND slug='${safe_slug}' LIMIT 1;" 2>/dev/null)
if [[ -z "${row}" ]]; then
  zgu_cli_error "$(t launcher.slug_not_found "${slug}")"
  exit 1
fi
IFS=$'\x1f' read -r game_dir configpath <<< "${row}"
[[ -z "${game_dir}" ]] && game_dir="${games_dir}/${slug}"

if [[ -z "${configpath}" ]]; then
  zgu_cli_error "$(t launcher.yml_missing "${slug}")"
  exit 1
fi
yml_path="${lutris_config_dir}/${configpath}.yml"
if [[ ! -f "${yml_path}" ]]; then
  zgu_cli_error "$(t launcher.yml_missing "${slug}")"
  exit 1
fi

launcher_yml="${game_dir}/lpm-launcher.yml"

# --- WINEPREFIX resolution (for "drive_c" only; no Wine version/binary resolution needed) ---
current_prefix=$(YML_PATH="${yml_path}" python3 -c '
import os, yaml
with open(os.environ["YML_PATH"]) as f:
    data = yaml.safe_load(f) or {}
print(str((data.get("game") or {}).get("prefix") or ""))
' 2>/dev/null)
[[ -z "${current_prefix}" ]] && current_prefix="${game_dir}"
drive_c="${current_prefix}/drive_c"

if [[ "${action}" = "get" ]]; then
  result=$(YML_PATH="${launcher_yml}" DRIVE_C="${drive_c}" python3 -c '
import json
import os

import yaml

yml_path = os.environ["YML_PATH"]
drive_c = os.environ["DRIVE_C"]

data = {}
if os.path.isfile(yml_path):
    try:
        with open(yml_path, "r") as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}

entries = data.get("entries") or []
if not isinstance(entries, list):
    entries = []


def to_unix(win_path):
    # Pure text replacement (see header): only "C:\..." is supported, any other drive letter
    # returns "".
    win_path = str(win_path or "")
    if len(win_path) < 2 or win_path[1] != ":" or win_path[0].lower() != "c":
        return ""
    rel = win_path[2:].replace("\\", "/").lstrip("/")
    return os.path.join(drive_c, rel) if rel else drive_c


out_entries = []
for e in entries:
    if not isinstance(e, dict):
        continue
    exe_win = str(e.get("exe") or "")
    workdir_win = str(e.get("workdir") or "")
    out_entries.append({
        "label": str(e.get("label") or ""),
        "args": str(e.get("args") or ""),
        "exe_win": exe_win,
        "workdir_win": workdir_win,
        "exe_linux": to_unix(exe_win),
        "workdir_linux": to_unix(workdir_win),
    })

print(json.dumps({
    "title": str(data.get("title") or ""),
    "prompt": str(data.get("prompt") or ""),
    "drive_c": drive_c,
    "entries": out_entries,
}))
' 2>/dev/null)

  if [[ -z "${result}" ]]; then
    zgu_cli_error "$(t launcher_entries.read_failed "${slug}")"
    exit 1
  fi
  printf '%s\n' "${result}"
  exit 0
fi

# --- action = "set" ---
if [[ ! -f "${json_file}" ]]; then
  zgu_cli_error "$(t launcher_entries.json_missing)"
  exit 1
fi

mkdir -p "${game_dir}" 2>/dev/null

result=$(YML_PATH="${launcher_yml}" JSON_PATH="${json_file}" DRIVE_C="${drive_c}" python3 -c '
import json
import os
import sys

import yaml

yml_path = os.environ["YML_PATH"]
json_path = os.environ["JSON_PATH"]
drive_c = os.environ["DRIVE_C"]

try:
    with open(json_path, "r") as f:
        payload = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(payload, dict):
    sys.exit(1)

entries_in = payload.get("entries") or []
if not isinstance(entries_in, list):
    sys.exit(1)

# Merge into the EXISTING file: "original_exe" and "bat_path" are written by
# "lpm launcher ... on" (zgl-launcher-manager.sh), never by this command, and must survive
# as-is.
data = {}
if os.path.isfile(yml_path):
    try:
        with open(yml_path, "r") as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}


def to_win(linux_path):
    # Pure text replacement (see header): a LINUX path received here comes from the native file
    # chooser (gui/*.py), restricted to "drive_c".
    linux_path = str(linux_path or "")
    if not linux_path:
        return ""
    drive_c_norm = drive_c.rstrip("/")
    if linux_path == drive_c_norm:
        return "C:\\"
    prefix = drive_c_norm + "/"
    if not linux_path.startswith(prefix):
        # Outside drive_c (user navigated elsewhere in the native chooser): unsupported, fall back
        # to the Linux path instead of failing; "get" will show it as an empty "exe_win".
        return linux_path
    rel = linux_path[len(prefix):]
    return "C:\\" + rel.replace("/", "\\")


entries_out = []
for e in entries_in:
    if not isinstance(e, dict):
        continue
    label = str(e.get("label") or "").strip()
    # Optional "exe_win"/"workdir_win": LITERAL Windows form, takes precedence over conversion
    # from "exe_linux"/"workdir_linux" (see LauncherEntryRow in gui/*.py). An entry read back
    # from "get" and sent unchanged is stored identically (no lossy round-trip: spaces, drive
    # letter case...), and the workdir can be hand-edited as Windows text.
    # "exe_linux"/"workdir_linux" are the only paths available right after a new native file
    # chooser selection (Linux only); that is the only case where conversion (to_win) happens.
    exe_win = str(e.get("exe_win") or "").strip()
    exe_linux = str(e.get("exe_linux") or "").strip()
    workdir_win = str(e.get("workdir_win") or "").strip()
    workdir_linux = str(e.get("workdir_linux") or "").strip()
    args = str(e.get("args") or "").strip()
    if not label or not (exe_win or exe_linux):
        continue
    exe_final = exe_win if exe_win else to_win(exe_linux)
    if workdir_win:
        workdir_final = workdir_win
    elif workdir_linux:
        workdir_final = to_win(workdir_linux)
    elif exe_linux:
        # Empty workdir accepted: derived from the executable folder (converted too), matching
        # the GUI prefill.
        workdir_final = to_win(os.path.dirname(exe_linux))
    else:
        workdir_final = exe_final.rsplit("\\", 1)[0] if "\\" in exe_final else exe_final
    entry = {"label": label, "workdir": workdir_final, "exe": exe_final}
    if args:
        entry["args"] = args
    entries_out.append(entry)

data["title"] = str(payload.get("title") or "")
data["prompt"] = str(payload.get("prompt") or "")
data["entries"] = entries_out

try:
    with open(yml_path, "w") as f:
        yaml.dump(data, f, sort_keys=False, allow_unicode=True)
except Exception:
    sys.exit(1)

print("OK")
' 2>/dev/null)

if [[ "${result}" != "OK" ]]; then
  zgu_cli_error "$(t launcher_entries.write_failed "${slug}")"
  exit 1
fi

zgu_cli_ok "$(t launcher_entries.write_done "${slug}")"
exit 0
