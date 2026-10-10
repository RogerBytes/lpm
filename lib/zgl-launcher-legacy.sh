#!/bin/bash

# --- LPM Launcher: conversion of the OLD format to the current one ---
#
# Usage: zgl-launcher-legacy.sh <lutris game yml> <game dir>
#
# !!! DO NOT REMOVE this script nor its callers (orchestrator, "lpm launcher on", install).
# !!! Packages (.zgp) and games made with lpm <= 0.9.5 can be installed or launched years from
# !!! now: they still carry the old format, and this is what converts them. A test in
# !!! tests/cli_smoke.sh ("legacy launcher") fails if the conversion disappears.
#
# Old format: Lutris ran a relay (<game dir>/scripts/lpm-launcher.sh) as the game's
# "system.prelaunch_command" just before the game, which wrote lpm-launch.bat from the choice
# made in the picker. Current format: the orchestrator (lib/zgl-launcher-orchestrator.sh,
# entry point of every lpm shortcut) writes lpm-launch.bat itself, on the host, BEFORE launching
# Lutris. No prelaunch command, no relay.
#
# What this script does (idempotent, silent, never fails the caller):
#   1. Removes from the Lutris YAML the prelaunch command if it is the relay (and its
#      "prelaunch_wait"), plus the lines of it that a hook policy had commented out
#      ("lpm:hook-disabled"): a later restoration would otherwise bring back a command
#      pointing to a deleted file. Any other prelaunch command is left alone.
#   2. Deletes <game dir>/scripts/lpm-launcher.sh (and "scripts/" if it is then empty).
#   3. Repairs "bat_path" in <game dir>/lpm-launcher.yml: the lpm-launch.bat that Lutris really
#      runs is the "game.exe" of its YAML (absolute path, wrong after an import on another
#      machine, absent from hand-written files).
#
# Exit status: 0 if the Lutris YAML no longer references the relay, 1 if it still does (the
# caller then keeps the old mechanism working).

yml="${1:-}"
game_dir="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -n "${yml}" ]] && [[ -f "${yml}" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

relay_in_yml() {
  grep -Eq '^[[:space:]]*prelaunch_command:.*/scripts/lpm-launcher\.sh' "${yml}" 2>/dev/null
}

# --- 1. Relay in the Lutris YAML ---
if grep -q 'scripts/lpm-launcher\.sh' "${yml}" 2>/dev/null; then
  # Commented-out copies (hook policy) FIRST: a comment left between the keys makes the targeted
  # edit of zgu-yaml-edit.py refuse to write.
  if grep -q 'lpm:hook-disabled.*scripts/lpm-launcher\.sh\|scripts/lpm-launcher\.sh.*lpm:hook-disabled' "${yml}" 2>/dev/null; then
    grep -v 'lpm:hook-disabled.*scripts/lpm-launcher\.sh\|scripts/lpm-launcher\.sh.*lpm:hook-disabled' "${yml}" > "${yml}.lpm-tmp" 2>/dev/null \
      && mv -f "${yml}.lpm-tmp" "${yml}" 2>/dev/null
    rm -f "${yml}.lpm-tmp" 2>/dev/null
  fi
  if relay_in_yml; then
    python3 "${script_dir}/zgu-yaml-edit.py" "${yml}" unset system prelaunch_command >/dev/null 2>&1 || YML_PATH="${yml}" python3 -c '
import os, yaml

path = os.environ["YML_PATH"]
with open(path, "r") as f:
    data = yaml.safe_load(f) or {}
system = data.get("system")
if isinstance(system, dict) and str(system.get("prelaunch_command") or "").rstrip("/\\").endswith("/scripts/lpm-launcher.sh"):
    system.pop("prelaunch_command", None)
    with open(path, "w") as f:
        yaml.dump(data, f, sort_keys=False)
' >/dev/null 2>&1
    # Its "prelaunch_wait" (set together with it) goes too, unless another prelaunch command
    # remains.
    if ! grep -Eq '^[[:space:]]*prelaunch_command:' "${yml}" 2>/dev/null; then
      python3 "${script_dir}/zgu-yaml-edit.py" "${yml}" unset system prelaunch_wait >/dev/null 2>&1 || YML_PATH="${yml}" python3 -c '
import os, yaml

path = os.environ["YML_PATH"]
with open(path, "r") as f:
    data = yaml.safe_load(f) or {}
system = data.get("system")
if isinstance(system, dict) and "prelaunch_wait" in system and not system.get("prelaunch_command"):
    system.pop("prelaunch_wait", None)
    with open(path, "w") as f:
        yaml.dump(data, f, sort_keys=False)
' >/dev/null 2>&1
    fi
  fi
fi

# The relay is only deleted once the Lutris YAML no longer points to it.
if ! relay_in_yml && [[ -n "${game_dir}" ]]; then
  rm -f -- "${game_dir}/scripts/lpm-launcher.sh" 2>/dev/null
  rmdir "${game_dir}/scripts" 2>/dev/null
fi

# --- 3. bat_path of lpm-launcher.yml, from the game.exe Lutris really runs ---
launcher_yml="${game_dir}/lpm-launcher.yml"
if [[ -n "${game_dir}" ]] && [[ -f "${launcher_yml}" ]]; then
  YML_PATH="${yml}" LAUNCHER_YML="${launcher_yml}" python3 -c '
import os, yaml

try:
    with open(os.environ["YML_PATH"], "r") as f:
        lutris = yaml.safe_load(f) or {}
    exe = str((lutris.get("game") or {}).get("exe") or "")
    if os.path.basename(exe) != "lpm-launch.bat":
        raise SystemExit(0)
    path = os.environ["LAUNCHER_YML"]
    with open(path, "r") as f:
        text = f.read()
    data = yaml.safe_load(text)
    if not isinstance(data, dict) or data.get("bat_path") == exe:
        raise SystemExit(0)
    data["bat_path"] = exe
    comments = [l for l in text.splitlines() if l.lstrip().startswith("#")]
    out = yaml.dump(data, sort_keys=False, allow_unicode=True, width=1000000)
    if comments:
        out += "\n".join(comments) + "\n"
    with open(path, "w") as f:
        f.write(out)
except SystemExit:
    raise
except Exception:
    pass
' >/dev/null 2>&1
fi

relay_in_yml && exit 1
exit 0
