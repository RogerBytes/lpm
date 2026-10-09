#!/bin/bash

# --- lpm launcher: runs at every game launch, via system.prelaunch_command ---
#
# Called ONLY by the small relay script $GAMEDIR/scripts/lpm-launcher.sh (see
# lib/zgl-launcher-manager.sh, "lpm launcher ... on"), never directly by the user.
#
# Usage: zgl-launcher-runtime.sh <gamedir>
#
# Steps, in order:
#   1. Reads lpm-launcher.yml (the only hardcoded path: passed as argument).
#   2. If the YAML has several entries: shows the picker. A single entry: no menu, direct
#      launch.
#   3. Rewrites lpm-launch.bat (emptied then rewritten) with the chosen entry.
#
# Background/splash, "loading" indicator, gamepad lock and game window detection are handled
# by the orchestrator (lib/zgl-launcher-orchestrator.sh), the single entry point of all
# lpm .desktop shortcuts; normally it is already running when this script starts. This
# script only finds the already-open control file (fixed path derived from "gamedir",
# identical to the orchestrator's computation) to write IND_HIDE/IND_SHOW around the picker;
# it never creates nor closes it. With several entries, it also replaces the displayed title
# (line 3 of the control file, set to the game name by the orchestrator) with the chosen
# entry label. If the control file does not exist (game not started via the lpm shortcut, or
# loading screen disabled with ".lpm-no-loadingscreen"), the picker still works, without a
# background.
#
# This script ALWAYS returns control (exit 0), even on error (missing YAML, etc.):
# system.prelaunch_command must never block the game launch indefinitely. Errors are logged
# and, if possible, shown in a Zenity box; the game then launches with the existing .bat
# (possibly stale).

set -u

gamedir="${1:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

bail() {
  local msg="$1"
  # No graphical notification here: this case is abnormal but already fully logged, and this
  # script must NEVER block the game launch (see file header).
  zgu_log "launcher-runtime" "ERREUR" "gamedir=${gamedir} raison=${msg}"
  exit 0
}

[[ -n "${gamedir}" ]] || bail "gamedir_manquant"
[[ -d "${gamedir}" ]] || bail "gamedir_introuvable"

yaml_path="${gamedir}/lpm-launcher.yml"
[[ -f "${yaml_path}" ]] || bail "yaml_introuvable"

# --- 1. Read the YAML (title, prompt, active entries; entries commented with "#" are
# ignored by yaml.safe_load) ---
parsed=$(YML_PATH="${yaml_path}" python3 -c '
import os, sys, yaml

try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

title = str(data.get("title") or "")
prompt = str(data.get("prompt") or "")
bat_path = str(data.get("bat_path") or "")
entries = data.get("entries") or []
if not isinstance(entries, list):
    sys.exit(1)

print("TITLE\x1f" + title.replace("\x1f", " ").replace("\n", " "))
print("PROMPT\x1f" + prompt.replace("\x1f", " ").replace("\n", " "))
print("BATPATH\x1f" + bat_path.replace("\x1f", " ").replace("\n", " "))
for e in entries:
    if not isinstance(e, dict):
        continue
    label = str(e.get("label") or "").replace("\x1f", " ").replace("\n", " ")
    workdir = str(e.get("workdir") or "").replace("\x1f", " ").replace("\n", " ")
    exe = str(e.get("exe") or "").replace("\x1f", " ").replace("\n", " ")
    # "args" (launch arguments, appended after the executable in lpm-launch.bat): optional,
    # empty string by default, absent from older lpm-launcher.yml files.
    args = str(e.get("args") or "").replace("\x1f", " ").replace("\n", " ")
    if not label or not workdir or not exe:
        continue
    print("ENTRY\x1f" + label + "\x1f" + workdir + "\x1f" + exe + "\x1f" + args)
' 2>/dev/null)

[[ -z "${parsed}" ]] && bail "yaml_invalide_ou_vide"

title="" prompt="" bat_path_yaml=""
entry_labels=() entry_workdirs=() entry_exes=() entry_args=()

while IFS=$'\x1f' read -r kind a b c d; do
  case "${kind}" in
    TITLE) title="${a}" ;;
    PROMPT) prompt="${a}" ;;
    BATPATH) bat_path_yaml="${a}" ;;
    ENTRY)
      entry_labels+=("${a}")
      entry_workdirs+=("${b}")
      entry_exes+=("${c}")
      entry_args+=("${d}")
      ;;
  esac
done <<< "${parsed}"

[[ ${#entry_labels[@]} -eq 0 ]] && bail "aucune_entree_valide"

# Fallback for a lpm-launcher.yml generated before the "bat_path" key existed: old
# location, at the root of $gamedir.
bat_path="${bat_path_yaml:-${gamedir}/lpm-launch.bat}"

# --- Orchestrator control file (may or may not be open; see file header). Same EXACT
# derivation as lib/zgl-launcher-orchestrator.sh: sha256sum of gamedir, fixed path, no
# mktemp, so both scripts find the same file without explicit coordination. ---
ctrl_key=$(printf '%s' "${gamedir}" | sha256sum | cut -c1-24)
control_file="${TMPDIR:-/tmp}/lpm-launcher-ctrl-${ctrl_key}"

# Re-reads lines 1 (background) and 3 (title) as-is from the control file; used by
# set_indicator/set_title below to modify ONLY their own line. The orchestrator alone writes
# line 1, this script lines 2 and 3, but all three must survive each rewrite (which replaces
# the whole file).
read_ctrl_lines() {
  local mapfile_lines=()
  mapfile -t mapfile_lines < "${control_file}" 2>/dev/null
  ctrl_bg_line="${mapfile_lines[0]:-NONE}"
  ctrl_title_line="${mapfile_lines[2]:-}"
  [[ -z "${ctrl_bg_line}" ]] && ctrl_bg_line="NONE"
}

set_indicator() {
  # Best-effort: the control file may not exist (game not started via the lpm shortcut, or
  # loading screen disabled); then do nothing, the picker still shows without a background.
  [[ -f "${control_file}" ]] || return 0
  local ctrl_bg_line ctrl_title_line
  read_ctrl_lines
  {
    printf '%s\n' "${ctrl_bg_line}"
    printf '%s\n' "$1"
    printf '%s\n' "${ctrl_title_line}"
  } > "${control_file}" 2>/dev/null
}

set_title() {
  # Same principle: replaces only line 3 (title), preserving background and indicator state.
  [[ -f "${control_file}" ]] || return 0
  local ctrl_bg_line ctrl_title_line ctrl_indicator_line
  read_ctrl_lines
  ctrl_indicator_line=$(sed -n '2p' "${control_file}" 2>/dev/null)
  [[ -z "${ctrl_indicator_line}" ]] && ctrl_indicator_line="IND_SHOW"
  {
    printf '%s\n' "${ctrl_bg_line}"
    printf '%s\n' "${ctrl_indicator_line}"
    printf '%s\n' "$1"
  } > "${control_file}" 2>/dev/null
}

# --- 2. Picker (only if several entries) ---
chosen_workdir="" chosen_exe=""

# Writes an lpm-launch.bat that does NOTHING (just "@echo off"); used only when the picker
# is cancelled ("cancel" must mean cancel, not relaunch the last chosen episode). Lutris
# always runs game.exe after a prelaunch_command regardless of its exit code (prelaunch_wait
# only waits for the script to end; see the "prelaunch_wait" comment in
# zgl-launcher-manager.sh), so launching something cannot be prevented; it can only do
# nothing.
write_noop_bat() {
  mkdir -p "$(dirname "${bat_path}")" 2>/dev/null
  printf '@echo off\r\n' > "${bat_path}" 2>/dev/null
}

if [[ ${#entry_labels[@]} -gt 1 ]]; then
  # Choice already made by the orchestrator (normal case, launch via the lpm shortcut; see
  # zgl-launcher-orchestrator.sh): it shows the picker on the host BEFORE launching Lutris, not
  # this script, which runs inside the sandbox with Flatpak Lutris where neither gamepad nor
  # mouse reliably reached Zenity.
  #
  # NOT under /tmp: the Flatpak Lutris sandbox has its OWN /tmp, invisible from the host and
  # vice versa (and "/run/host/tmp" does not exist, unlike "/run/host/usr"). The choice file
  # must live in "${gamedir}", visible from both sides: Lutris must read/write there to launch
  # the game, with or without Flatpak.
  choice_file="${gamedir}/.lpm-launcher-choice"

  if [[ -f "${choice_file}" ]]; then
    selection=$(cat "${choice_file}" 2>/dev/null)
    rm -f "${choice_file}" 2>/dev/null

    chosen_idx=-1
    if [[ -n "${selection}" ]]; then
      for i in "${!entry_labels[@]}"; do
        if [[ "${entry_labels[$i]}" = "${selection}" ]]; then
          chosen_idx="${i}"
          break
        fi
      done
    fi

    if [[ "${chosen_idx}" -eq -1 ]]; then
      # Picker cancelled on the orchestrator side, or label not found (YAML modified in between):
      # same fallback as below (see write_noop_bat above).
      zgu_log "launcher-runtime" "INFO" "gamedir=${gamedir} raison=picker_annule"
      write_noop_bat
      exit 0
    fi
  else
    # --- Fallback: the orchestrator did not run (lpm shortcut bypassed, game launched another
    # way); this script shows its own picker (zgu-launcher-picker.py, GTK4, NOT Zenity; see
    # zgl-launcher-orchestrator.sh). Unlike the orchestrator picker (embedded in its single
    # window, see zgu-launcher-screen.py), this one is a normal DECORATED window since there is
    # no background in this case. The picker reads the gamepad itself via SDL2 and manages its
    # own keyboard focus (grab_focus), so no separate gamepad bridge is started/stopped here. ---
    set_indicator "IND_HIDE"

    # "env -u LD_LIBRARY_PATH" -- REQUIRED: this script runs at actual game launch
    # (prelaunch_command), with the LD_LIBRARY_PATH prepared by Lutris for Wine (Steam Ubuntu
    # 18.04 runtime, old frozen libraries). With it, GTK4 loads the system libgtk-4.so.1, which
    # depends on a GStreamer symbol missing from that runtime's bundled version, and crashes
    # silently (error hidden by the "2>/dev/null" below). The picker is a native GTK4 window
    # unrelated to Wine/game libraries, so the variable is removed before launching it.
    selection=$(env -u LD_LIBRARY_PATH python3 "${script_dir}/zgu-launcher-picker.py" \
      "${title}" "${prompt}" \
      "$(t launcher.picker_validate_button)" "$(t launcher.picker_cancel_button)" \
      "${entry_labels[@]}" 2>/dev/null)
    picker_rc=$?

    set_indicator "IND_SHOW"

    chosen_idx=-1
    if [[ "${picker_rc}" -eq 0 ]] && [[ -n "${selection}" ]]; then
      for i in "${!entry_labels[@]}"; do
        if [[ "${entry_labels[$i]}" = "${selection}" ]]; then
          chosen_idx="${i}"
          break
        fi
      done
    fi

    if [[ "${chosen_idx}" -eq -1 ]]; then
      # Picker cancelled (window closed without choice, "Cancel" button): writes a .bat that does
      # nothing instead of relaunching the last chosen episode (see write_noop_bat above). Lutris
      # will still run this .bat (unavoidable here), but it does nothing.
      zgu_log "launcher-runtime" "INFO" "gamedir=${gamedir} raison=picker_annule"
      write_noop_bat
      exit 0
    fi
  fi
else
  chosen_idx=0
fi

chosen_workdir="${entry_workdirs[${chosen_idx}]}"
chosen_exe="${entry_exes[${chosen_idx}]}"
chosen_args="${entry_args[${chosen_idx}]:-}"

# Title shown on the loading screen (see zgu-launcher-screen.py): replaced by the chosen
# entry label ONLY if the game has several active LPM Launcher entries; a "normal" game
# (single entry, no picker) keeps the game name set by the orchestrator.
if [[ ${#entry_labels[@]} -gt 1 ]]; then
  set_title "${entry_labels[${chosen_idx}]}"
fi

# --- 3. Write lpm-launch.bat (emptied then rewritten; "start" with an empty title, no direct
# call, to handle paths with spaces and return control to cmd properly). Written to
# "${bat_path}" (resolved above from the YAML, with fallback); this path MUST be inside
# the Wine prefix drive_c so Lutris/cmd.exe can run it (see zgl-launcher-manager.sh). ---
mkdir -p "$(dirname "${bat_path}")" 2>/dev/null
{
  printf '@echo off\r\n'
  printf 'cd /d "%s"\r\n' "${chosen_workdir}"
  if [[ -n "${chosen_args}" ]]; then
    # Pasted as-is after the executable, never reformatted/re-escaped: "args" is free text typed
    # by the user (see zgl-launcher-entries.sh), like Lutris's own "Arguments" field.
    printf 'start "" "%s" %s\r\n' "${chosen_exe}" "${chosen_args}"
  else
    printf 'start "" "%s"\r\n' "${chosen_exe}"
  fi
} > "${bat_path}" 2>/dev/null || bail "ecriture_bat_echouee"

zgu_log "launcher-runtime" "OK" "gamedir=${gamedir} entree=${entry_labels[${chosen_idx}]}"

exit 0
