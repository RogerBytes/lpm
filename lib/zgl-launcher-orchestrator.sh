#!/bin/bash

# --- lpm launcher: SINGLE entry point of all shortcuts (.desktop) created by lpm ---
#
# Called directly by "Exec=" of the .desktop (see zgu_write_game_shortcut in
# zgu-desktop-utils.sh), identical for all Wine games, with or without the LPM Launcher
# (multi-entry "picker"). Role: show the loading background (black, or splash/splash.png if
# present) with a small "loading" indicator (translated text + spinner) at the bottom right,
# never covered by a banner, THEN hand over to Lutris for the real launch.
#
# Usage: zgl-launcher-orchestrator.sh <game_id> <version:package|flatpak>
#
# Deliberately only TWO arguments, both safe without escaping (an integer, a fixed word):
# "slug"/"game_dir" never go through the .desktop "Exec=", whose escaping rules differ from
# a shell's and where a path with spaces would be an unnecessary risk. This script queries
# the Lutris database (pga.db) itself to get "slug"/"directory" from "game_id", with the same
# query, base paths and "games_dir/slug" fallback as zgp-game-shortcutter.sh /
# zgp-game-installer.sh (see zgu-lutris-utils.sh).
#
# Design:
#   - Loading screen enabled for ALL lpm shortcuts by default; disabled per game by the
#     presence of "${game_dir}/.lpm-no-loadingscreen" ("Loading screen" checkbox unchecked
#     when creating/regenerating the shortcut, see zgp-game-shortcutter.sh /
#     zgp-game-installer.sh). Then: direct launch, zero overhead.
#   - The multi-entry picker (several executables per game) is handled by
#     zgl-launcher-runtime.sh, triggered by Lutris via system.prelaunch_command. THIS script
#     does not check whether that feature is active; the two are independent. The picker
#     reuses the background already opened by THIS script (fixed-path control file below).
#   - Once the background is up, this script "exec"s the normal Lutris command (the same as
#     the one used in Exec= before the orchestrator): the bash process is replaced by lutris
#     (same PID), so no wrapper stays in the process tree and window/dock tracking
#     (WM_CLASS, StartupWMClass) is unaffected.
#   - No check/closing of an already-running Lutris instance: end of loading is detected by
#     the appearance of THE GAME WINDOW (detached watcher below), not by the end of the
#     Lutris process. "lutris lutris:rungameid/<id>" really launches the game either way;
#     only the blocking behaviour of the calling process differs, and it is not used.

set -u

game_id="${1:-}"
version="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# --- Final Lutris command: the same as the one used in Exec= before the orchestrator ---
launch_lutris() {
  if [[ "${version}" = "flatpak" ]]; then
    exec env LUTRIS_SKIP_INIT=1 flatpak run net.lutris.Lutris "lutris:rungameid/${game_id}"
  else
    exec env LUTRIS_SKIP_INIT=1 lutris "lutris:rungameid/${game_id}"
  fi
  # "exec" never returns on success: reaching here means exec failed (lutris/flatpak not
  # found); last resort, log and exit with an error.
  zgu_log "launcher-orchestrator" "ERROR" "game_id=${game_id} reason=lutris_exec_failed"
  exit 1
}

# --- Missing arguments: never block a launch for that, fall back to a direct launch ---
if [[ -z "${game_id}" ]] || [[ -z "${version}" ]]; then
  zgu_log "launcher-orchestrator" "WARN" "reason=missing_arguments argv=$*"
  launch_lutris
fi

has_display=false
if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  has_display=true
fi

# --- No display possible (no GUI session, python3 or sqlite3 missing...): direct launch;
# no point querying the Lutris database for a screen that cannot be shown. ---
if [[ "${has_display}" = false ]] || ! command -v python3 >/dev/null 2>&1 || ! command -v sqlite3 >/dev/null 2>&1; then
  launch_lutris
fi

# --- Lutris database to query: same paths and convention ("version" = "flatpak" or
# "package", never "native"; see zgp-game-shortcutter.sh) as elsewhere in the project. No call
# to zgu_resolve_lutris_version: the version is already known (argument, fixed when the
# shortcut was created). ---
if [[ "${version}" = "flatpak" ]]; then
  lutris_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
  lutris_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
  lutris_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
else
  lutris_db="${HOME}/.local/share/lutris/pga.db"
  lutris_system_file="${HOME}/.config/lutris/system.yml"
  lutris_config_dir="${HOME}/.config/lutris/games"
fi

# --- Database not found: silent direct launch (just a log); a game launch must never fail
# for that. ---
if [[ ! -f "${lutris_db}" ]]; then
  zgu_log "launcher-orchestrator" "WARN" "game_id=${game_id} reason=db_not_found db=${lutris_db}"
  launch_lutris
fi

# --- slug + directory, by id: same query (columns) and "games_dir/slug" fallback as
# zgp-game-shortcutter.sh / zgp-game-installer.sh. game_id comes from Exec= (the .desktop
# itself, not free user input) but is interpolated as-is into the SQL as elsewhere in the
# project; filtered here to a pure integer as a precaution. ---
game_id="${game_id//[^0-9]/}"
if [[ -z "${game_id}" ]]; then
  zgu_log "launcher-orchestrator" "WARN" "reason=invalid_game_id"
  launch_lutris
fi

row=$(sqlite3 "${lutris_db}" "SELECT slug || char(31) || directory || char(31) || name || char(31) || COALESCE(configpath,'') FROM games WHERE id = ${game_id} AND runner = 'wine' LIMIT 1;" 2>/dev/null)

if [[ -z "${row}" ]]; then
  zgu_log "launcher-orchestrator" "WARN" "game_id=${game_id} reason=game_not_in_db"
  launch_lutris
fi

IFS=$'\x1f' read -r slug game_dir game_name configpath <<< "${row}"

if [[ -z "${slug}" ]]; then
  zgu_log "launcher-orchestrator" "WARN" "game_id=${game_id} reason=empty_slug_in_db"
  launch_lutris
fi

# Title shown at the bottom right of the loading screen (see zgu-launcher-screen.py): the
# game name by default; replaced by zgl-launcher-runtime.sh once the picker is resolved, ONLY
# if the game has several active LPM Launcher entries. \n/\r are stripped: "name" comes from
# the Lutris database (possibly forged by a third party via a shared .zgp package) and the
# control file protocol is line-based.
title_text="${game_name//[$'\n\r']/}"

# Custom Games path (if set in Lutris): same fallback as zgp-game-shortcutter.sh /
# zgp-game-installer.sh, used only if "directory" is empty in the database.
games_dir="${HOME}/Games"
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi
[[ -z "${game_dir}" ]] && game_dir="${games_dir}/${slug}"

# --- FIXED-path control file (derived from game_dir, no random mktemp), so that
# zgl-launcher-runtime.sh (started separately, later, by Lutris) finds the same file with no
# data passed between the two scripts. sha256sum of game_dir rather than its basename: robust
# even if the game directory name does not match the slug (Lutris "directory" column). ---
ctrl_key=$(printf '%s' "${game_dir}" | sha256sum | cut -c1-24)
control_file="${TMPDIR:-/tmp}/lpm-launcher-ctrl-${ctrl_key}"

# --- Loading screen disabled for this game, or folder not found: direct launch, nothing else
# (so no LPM Launcher picker either; see zgl-launcher-runtime.sh for its fallback here). ---
if [[ ! -d "${game_dir}" ]] || [[ -f "${game_dir}/.lpm-no-loadingscreen" ]]; then
  launch_lutris
fi

session_kind="x11"
if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  session_kind="wayland"
fi

# --- LPM Launcher (multi-entry picker): the YAML is read HERE, BEFORE the first background
# display, only to know whether a picker will be shown (the gamepad is not started yet). It
# decides the INITIAL background: if a picker follows, the splash must only appear AFTER the
# choice, never before only to vanish at once (flicker). ---
launcher_yml="${game_dir}/lpm-launcher.yml"
# NOT under /tmp: the /tmp of the Flatpak Lutris sandbox is invisible from the host, so
# zgl-launcher-runtime.sh (running INSIDE it for Flatpak Lutris) would never find a file
# written HERE on the host. "${game_dir}" is visible from both sides.
launcher_choice_file="${game_dir}/.lpm-launcher-choice"
rm -f "${launcher_choice_file}" 2>/dev/null

# Protocol of the picker embedded in the single window (see zgu-launcher-screen.py, file
# header): two fixed-path files derived from "control_file", never mixed into its 4 lines.
# Cleaned here as a precaution (leftover of an interrupted launch), before knowing whether
# a picker will be shown this time.
picker_request_file="${control_file}.picker-req"
picker_result_file="${control_file}.picker-res"
rm -f "${picker_request_file}" "${picker_result_file}" 2>/dev/null

picker_title="" picker_prompt=""
entry_labels=()
will_show_picker=false

if [[ -f "${launcher_yml}" ]] && [[ "${has_display}" = true ]] \
    && command -v python3 >/dev/null 2>&1; then
  parsed=$(YML_PATH="${launcher_yml}" python3 -c '
import os, sys, yaml

try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

title = str(data.get("title") or "")
prompt = str(data.get("prompt") or "")
entries = data.get("entries") or []
if not isinstance(entries, list):
    sys.exit(1)

print("TITLE\x1f" + title.replace("\x1f", " ").replace("\n", " "))
print("PROMPT\x1f" + prompt.replace("\x1f", " ").replace("\n", " "))
for e in entries:
    if not isinstance(e, dict):
        continue
    label = str(e.get("label") or "").replace("\x1f", " ").replace("\n", " ")
    if not label:
        continue
    print("ENTRY\x1f" + label)
' 2>/dev/null)

  while IFS=$'\x1f' read -r kind a; do
    case "${kind}" in
      TITLE) picker_title="${a}" ;;
      PROMPT) picker_prompt="${a}" ;;
      ENTRY)  entry_labels+=("${a}") ;;
    esac
  done <<< "${parsed}"

  [[ ${#entry_labels[@]} -gt 1 ]] && will_show_picker=true
fi

# --- Background: splash image if present, else plain black, EXCEPT when a picker will be
# shown: then NONE until the choice (see block above). ---
splash_image="${game_dir}/splash/splash.png"
bg_state="NONE"
if [[ "${will_show_picker}" = false ]] && [[ -f "${splash_image}" ]]; then
  bg_state="${splash_image}"
fi

# --- Logo: next to the splash (same folder). Drawn DIRECTLY by zgu-launcher-screen.py in its
# own window (see its file header), no separate process: the picker never covers that area
# (top of the screen, above its always-centered frame), so no "always on top" window is
# needed. If absent, zgu-launcher-screen.py shows the title there instead; passed even if
# missing, the existence check is done on the Python side.
logo_image="${game_dir}/splash/logo.png"

# Known in advance (see YAML block above, "will_show_picker"): "1" if this game has a single
# entry (or none), so no label is ever shown on the loading screen; see <no_label> in the
# header of zgu-launcher-screen.py, which then recenters the banner instead of reserving an
# empty band.
no_label_flag="1"
[[ "${will_show_picker}" = true ]] && no_label_flag="0"

# Also known in advance: "1" if this game will show a banner (splash.png present); see
# <has_banner> in the header of zgu-launcher-screen.py. Only used together with
# no_label_flag="1" above (while a picker remains possible the layout never changes).
has_banner_flag="0"
[[ -f "${splash_image}" ]] && has_banner_flag="1"

{
  printf '%s\n' "${bg_state}"
  printf '%s\n' "IND_SHOW"
  printf '%s\n' "${title_text}"
  printf '%s\n' ""
} > "${control_file}" 2>/dev/null

indicator_text="$(t launcher.loading_text)"

blackscreen_pid=""

# zgu-launcher-screen.py reads the gamepad itself via SDL2, in its own process (see that
# file): no separate bridge is started here. A bridge injecting keys through xdotool/ydotool
# into the focused window depended on the window manager (X11: focus stealing prevention;
# Wayland: no portable equivalent). Reading the gamepad inside the window and acting on its
# own widgets avoids this (see also zgu-gamepad-nav-utils.sh, no caller left).
# Forced foreground recovery by the loading screen (see on_active_changed in
# zgu-launcher-screen.py): DISABLED by default. A fullscreen Wine game that loses focus gets
# iconified, so forcing focus back always minimized it; a fullscreen game naturally covers the
# loading screen. A game whose window is recreated several times at startup (e.g. Momodora)
# can re-enable it by creating an empty ".lpm-keep-focus" file in its folder (never created
# automatically, same convention as ".lpm-no-loadingscreen").
# WM_CLASS of the game = StartupWMClass of the .desktop generated by lpm (see
# zgu_write_game_shortcut): the loading window reuses it to group under the same panel icon as
# the game. Empty if the menu shortcut does not exist (behaviour unchanged).
screen_wm_class=""
shortcut_file="${HOME}/.local/share/applications/net.lutris.${slug}.desktop"
if [[ -f "${shortcut_file}" ]]; then
  screen_wm_class=$(sed -n 's/^StartupWMClass=//p' "${shortcut_file}" | head -n1)
  screen_wm_class="${screen_wm_class//[$'\n\r\t']/}"
fi
keep_focus_env=0
[[ -f "${game_dir}/.lpm-keep-focus" ]] && keep_focus_env=1
LPM_HELP_ALTTAB="$(t launcher.help_alttab)" LPM_HELP_QUIT="$(t launcher.help_quit)" LPM_HELP_F4="$(t launcher.help_f4)" LPM_HELP_ALTENTER="$(t launcher.help_altenter)" LPM_HELP_F11="$(t launcher.help_f11)" LPM_WM_CLASS="${screen_wm_class}" LPM_WINDOW_TITLE="${title_text}" LPM_KEEP_FOCUS="${keep_focus_env}" python3 "${script_dir}/zgu-launcher-screen.py" "${control_file}" "${indicator_text}" "${logo_image}" "${no_label_flag}" "${has_banner_flag}" >/dev/null 2>&1 &
blackscreen_pid=$!
disown "${blackscreen_pid}" 2>/dev/null

sleep 0.3  # let the background render before Lutris (or the picker) does anything

zgu_log "launcher-orchestrator" "OK" "slug=${slug} action=background_started ctrl=${control_file}"

# --- LPM Launcher (multi-entry picker): resolved HERE, on the host, NOT by
# zgl-launcher-runtime.sh (started later by Lutris), which for Flatpak Lutris runs inside its
# sandbox, where neither gamepad nor mouse reliably reached Zenity. The choice is made HERE and
# passed to zgl-launcher-runtime.sh via a fixed-path file derived from game_dir, like the
# control file. The runtime script then only reads it and writes lpm-launch.bat (its own
# picker remains a fallback if THIS script did not run: lpm shortcut bypassed, game launched
# another way).
#
# YAML already read above (entry_labels/picker_title/picker_prompt/will_show_picker), before
# the first background display; see that block for why.
#
# The picker is INTEGRATED in the single window launched above (see zgu-launcher-screen.py,
# "Gtk.Overlay"): no second process/window, so no stacking ("always on top") issue; GTK4
# removed "set_keep_above" with no portable equivalent. The request goes through
# "picker_request_file", the answer comes back through "picker_result_file"; see their format
# in the header of zgu-launcher-screen.py.
if [[ "${will_show_picker}" = true ]]; then
    # IND_HIDE: the loading indicator disappears during the choice. Background is already "NONE"
    # since the first display (see above), only the indicator changes. Title unchanged.
    {
      printf '%s\n' "NONE"
      printf '%s\n' "IND_HIDE"
      printf '%s\n' "${title_text}"
      printf '%s\n' ""
    } > "${control_file}" 2>/dev/null

    {
      printf '%s\n' "${picker_title}"
      printf '%s\n' "${picker_prompt}"
      printf '%s\n' "$(t launcher.picker_validate_button)"
      printf '%s\n' "$(t launcher.picker_cancel_button)"
      for entry in "${entry_labels[@]}"; do
        printf '%s\n' "${entry}"
      done
    } > "${picker_request_file}" 2>/dev/null

    # Wait for the result by polling, like the control file itself, with no time limit (the
    # user may take as long as needed). Also exits if the window ended meanwhile (crash,
    # "kill -9"...), otherwise the loop would wait forever for a file that never comes.
    picker_rc=1
    selection=""
    while true; do
      if [[ -f "${picker_result_file}" ]]; then
        mapfile -t _picker_result_lines < "${picker_result_file}" 2>/dev/null
        rm -f "${picker_result_file}" 2>/dev/null
        if [[ "${_picker_result_lines[0]:-}" = "OK" ]]; then
          selection="${_picker_result_lines[1]:-}"
          picker_rc=0
        fi
        break
      fi
      if [[ -n "${blackscreen_pid}" ]] && ! kill -0 "${blackscreen_pid}" 2>/dev/null; then
        zgu_log "launcher-orchestrator" "WARN" "slug=${slug} reason=window_closed_during_picker"
        break
      fi
      sleep 0.1
    done
    rm -f "${picker_request_file}" 2>/dev/null

    if [[ "${picker_rc}" -ne 0 ]] || [[ -z "${selection}" ]]; then
      # Cancelled (Cancel button, Escape, B button, all treated alike, see
      # zgu-launcher-screen.py) OR error/window gone: the flow is stopped ENTIRELY, the game is NOT
      # launched ("cancel" must mean cancel).
      rm -f "${launcher_choice_file}" 2>/dev/null
      zgu_log "launcher-orchestrator" "INFO" "slug=${slug} reason=picker_cancelled action=full_stop"
      echo "STOP" > "${control_file}" 2>/dev/null
      sleep 0.3
      [[ -n "${blackscreen_pid}" ]] && kill "${blackscreen_pid}" 2>/dev/null
      rm -f "${control_file}" 2>/dev/null
      exit 0
    fi

    # Written as soon as a choice is validated: its mere PRESENCE tells zgl-launcher-runtime.sh
    # that THIS script ran and decided; absence means fallback on its own picker.
    printf '%s' "${selection}" > "${launcher_choice_file}" 2>/dev/null

    # Background AFTER the choice: the splash (if any) only appears from now on, never before
    # the picker (bg_state was "NONE" until here).
    post_choice_bg="NONE"
    [[ -f "${splash_image}" ]] && post_choice_bg="${splash_image}"

    # Title UNCHANGED (still the game name, see zgu-launcher-screen.py): the chosen label is
    # added on its own line, never in its place.
    {
      printf '%s\n' "${post_choice_bg}"
      printf '%s\n' "IND_SHOW"
      printf '%s\n' "${title_text}"
      printf '%s\n' "${selection//[$'\n\r']/}"
    } > "${control_file}" 2>/dev/null
    zgu_log "launcher-orchestrator" "OK" "slug=${slug} action=picker_choice entry=${selection}"
fi

# --- Universal game window detection (WIN_CreateWindowEx via WINEDEBUG) ---------
#
# Replaces X11-only detection (xdotool, see below) with a signal independent of the display
# server (X11/Wayland), the runner (Wine-GE, Proton/umu, plain Wine) and the game graphics
# API (validated on three runners and two engines): Wine traces the creation of EVERY Win32
# window via WIN_CreateWindowEx before talking to the display server. The REAL game window
# is told apart from internal technical windows (Shell_TrayWnd, WineDdeServerName,
# SDLHelperWindowInputMsgWindow...) by a significant size (all others: 0x0 or tiny); see the
# generated relay below for the exact trace format.
#
# "prefix_command" (Lutris system option, YAML key "system: prefix_command") is NOT
# interpreted by a shell: a REAL script is needed to set WINEDEBUG="+win" and redirect the
# trace to a file. Patched at EVERY launch (this script runs each time): idempotent (YAML
# only written if the value changes) and chains only ONCE; a user-defined "Command prefix"
# (e.g. gamemoderun) is always kept, never overwritten (see the Python script below).
#
# NEVER a machine-fixed path (neither "${script_dir}/..." under /usr/lib/lpm or
# /usr/local/lib/lpm, nor /tmp). With Flatpak Lutris, a path under /usr is invisible from
# inside the sandbox (/usr there is the Flatpak runtime's, not the host's) and made Lutris'
# "exec" fail, and a trace file written in the sandbox's PRIVATE /tmp is never seen by this
# script running on the host (same trap as "launcher_choice_file" above). For the same
# reason a "lpm ..." command would not work either: "lpm" is installed under /usr (or
# /usr/local), not in the sandbox PATH.
#
# Hence the same convention as "${game_dir}/scripts/lpm-launcher.sh" for the LPM Launcher
# (see zgl-launcher-manager.sh): a GENERATED relay (never copied from a separate file of the
# lpm install) under "${game_dir}/scripts", already proven visible on both sides of the
# sandbox (see "launcher_choice_file"), containing all the logic (a few lines). Portable in
# a .zgp export: no absolute path specific to this machine or install mode (.deb vs
# install.sh); the relay is regenerated at every launch anyway.
winetrace_scripts_dir="${game_dir}/scripts"
winetrace_wrapper="${winetrace_scripts_dir}/lpm-winetrace.sh"
trace_file="${winetrace_scripts_dir}/lpm-winetrace.log"
rm -f "${trace_file}" 2>/dev/null

use_winetrace=false

if [[ -n "${configpath}" ]] && command -v python3 >/dev/null 2>&1 \
    && python3 -c "import yaml" >/dev/null 2>&1; then
  # "scripts/" may not exist yet (no game necessarily enables the LPM Launcher, the only other
  # place creating it; see zgl-launcher-manager.sh): create it here if needed.
  mkdir -p "${winetrace_scripts_dir}" 2>/dev/null

  cat > "${winetrace_wrapper}" <<'WRAPPER_EOF'
#!/bin/bash
# Relay generated by lpm (universal game-window detection) -- do not edit by hand, it is
# rewritten on every launch.
#
# Usage: lpm-winetrace.sh <trace_file> <real_command...>
#
# Lutris does not interpret "prefix_command" with a shell (it splits it into words and runs the
# resulting argv directly), so this real bash script does the redirection instead: it sets
# WINEDEBUG="+win", then execs the real command (everything after the first argument) while
# filtering its stderr live into <trace_file>, keeping only lines containing "WIN_CreateWindowEx".
set -u
trace_file="${1:-}"
shift || true
if [[ -z "${trace_file}" ]] || [[ $# -eq 0 ]]; then
  exec "$@"
fi
export WINEDEBUG="+win"
exec "$@" 2> >(grep --line-buffered "WIN_CreateWindowEx" >> "${trace_file}")
WRAPPER_EOF
  chmod +x "${winetrace_wrapper}" 2>/dev/null

  if [[ -x "${winetrace_wrapper}" ]]; then
    yml_path="${lutris_config_dir}/${configpath}.yml"
    if [[ -f "${yml_path}" ]]; then
      patch_result=$(YML_PATH="${yml_path}" WRAPPER="${winetrace_wrapper}" TRACE_FILE="${trace_file}" python3 -c '
import os
import shutil
import sys

import yaml

yml_path = os.environ["YML_PATH"]
wrapper_cmd = os.environ["WRAPPER"]
trace_file_path = os.environ["TRACE_FILE"]
wanted_prefix = f"{wrapper_cmd} {trace_file_path}"

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

system_cfg = data.get("system")
if not isinstance(system_cfg, dict):
    system_cfg = {}
    data["system"] = system_cfg

# Never overwrite a user "Command prefix": if our wrapper is already there (previous launch),
# strip the user-specific tail and rebuild it behind the up-to-date wrapper (the trace path
# is normally identical, so this usually changes nothing).
current = str(system_cfg.get("prefix_command") or "")
if current.startswith(wanted_prefix):
    user_tail = current[len(wanted_prefix):].lstrip()
else:
    user_tail = current
new_value = wanted_prefix if not user_tail else f"{wanted_prefix} {user_tail}"

if new_value == current:
    print("OK")
    sys.exit(0)

system_cfg["prefix_command"] = new_value

try:
    shutil.copy2(yml_path, yml_path + ".lpm-bak")
    with open(yml_path, "w") as f:
        yaml.dump(data, f, sort_keys=False)
except Exception:
    sys.exit(1)

try:
    os.remove(yml_path + ".lpm-bak")
except OSError:
    pass

print("OK")
' 2>/dev/null)

      [[ "${patch_result}" = "OK" ]] && use_winetrace=true
    fi
  fi
fi

if [[ "${use_winetrace}" = false ]]; then
  zgu_log "launcher-orchestrator" "WARN" "slug=${slug} reason=winetrace_unavailable_fallback_xdotool"
fi

# --- Detached watcher: game window detection + minimum display time, then full cleanup.
# Runs independently: THIS script "exec"s right after and disappears (replaced by lutris),
# the watcher keeps running in the background. ---
MIN_DISPLAY_MS=1000

# Decides whether ONE line of the Wine window trace ("WIN_CreateWindowEx ...") is the creation
# of the GAME window (return 0) or of an internal/technical one (return 1). Kept as a function
# so tests/cli_smoke.sh can replay real traces through it.
#
# 1. Wine's own windows are ignored by class name, whatever their size or style: recent Wine
#    creates its taskbar "Shell_TrayWnd" at startup with a title-bar style and a real size
#    (166x52 seen with GE-Proton), which was taken for the game window, so the loading screen
#    closed several seconds before the game (Bloodborne).
# 2. Size criterion: width and height above WIN_SIZE_THRESHOLD.
# 3. Title-bar criterion (e.g. Kirby Soft And Wet 106x132, Bloodborne "SDL_app" 7x33): some
#    games create their real window very small and resize it later without creating a new one.
#    An application window has a title bar (WS_CAPTION bits, 0x00C00000, in "style="), unlike
#    Wine/SDL technical windows (style 0 or popup only): accepted from WIN_CAPTION_MIN_SIZE
#    (1, i.e. any non-empty window) regardless of its size.
# The "x" between two numbers immediately followed by "parent=" is the only place of the format
# with this pattern (confirmed on real captures), so no false positive from a hexadecimal field
# (ex=, style=, inst=...).
WIN_SIZE_THRESHOLD=200
WIN_CAPTION_MIN_SIZE=1
WIN_CAPTION_STYLE_MASK=$(( 0x00C00000 ))
WIN_IGNORED_CLASSES=(Shell_TrayWnd IPTip_Main_Window WineAppBar SDLHelperWindowInputMsgWindow XaliaOverlayBox)
zgl_trace_line_is_game_window() {
  local line="$1" ignored_class win_w win_h
  for ignored_class in "${WIN_IGNORED_CLASSES[@]}"; do
    [[ "${line}" == *"->L\"${ignored_class}\""* ]] && return 1
  done
  [[ "${line}" =~ ([0-9]+)x([0-9]+)[[:space:]]+parent= ]] || return 1
  win_w="${BASH_REMATCH[1]}"
  win_h="${BASH_REMATCH[2]}"
  if [[ "${win_w}" -gt "${WIN_SIZE_THRESHOLD}" ]] && [[ "${win_h}" -gt "${WIN_SIZE_THRESHOLD}" ]]; then
    return 0
  fi
  if [[ "${win_w}" -ge "${WIN_CAPTION_MIN_SIZE}" ]] && [[ "${win_h}" -ge "${WIN_CAPTION_MIN_SIZE}" ]] \
     && [[ "${line}" =~ style=([0-9A-Fa-f]{1,8})[[:space:]] ]] \
     && [[ $(( 0x${BASH_REMATCH[1]} & WIN_CAPTION_STYLE_MASK )) -eq "${WIN_CAPTION_STYLE_MASK}" ]]; then
    return 0
  fi
  return 1
}

# Safety margin AFTER the game window detection (or after the fixed wait on Wayland): the
# new window may not be fully initialized (e.g. a frame generation tool like LSFG can cause a
# small hitch right after it appears). Without it the background vanished exactly then.
POST_WINDOW_GRACE_MS=1000

(
  start_ms=$(date +%s%3N 2>/dev/null || echo 0)
  max_wait_s=60
  waited=0
  window_detected=""

  # Extra per-game margin: VISIBLE file (no leading dot) at the prefix root, created with "0"
  # if missing, never overwritten, so a user-edited value survives all later launches. Added to
  # POST_WINDOW_GRACE_MS above; useful for a game whose window appears before it is really
  # playable (e.g. shader compilation right after the window appears).
  extra_ms_file="${game_dir}/lpm-extra-loading-ms"
  [[ -f "${extra_ms_file}" ]] || printf '0' > "${extra_ms_file}" 2>/dev/null
  extra_ms=$(tr -cd '0-9' < "${extra_ms_file}" 2>/dev/null)
  [[ -z "${extra_ms}" ]] && extra_ms=0

  if [[ "${use_winetrace}" = true ]]; then
    # Universal detection (X11/Wayland alike, any runner): re-reads the trace file (already
    # filtered live by the lpm-winetrace.sh relay, so every line contains "WIN_CreateWindowEx")
    # looking for the creation of the game window (rules in zgl_trace_line_is_game_window above).
    while [[ "${waited}" -lt "${max_wait_s}" ]]; do
      if [[ -s "${trace_file}" ]]; then
        while IFS= read -r trace_line; do
          if zgl_trace_line_is_game_window "${trace_line}"; then
            window_detected="1"
            break
          fi
        done < "${trace_file}"
      fi
      [[ -n "${window_detected}" ]] && break
      sleep 1
      waited=$(( waited + 1 ))
    done
  elif [[ "${session_kind}" = "x11" ]] && command -v xdotool >/dev/null 2>&1; then
    before_windows=$(xdotool search --onlyvisible "" 2>/dev/null | sort)
    while [[ "${waited}" -lt "${max_wait_s}" ]]; do
      sleep 1
      waited=$(( waited + 1 ))
      after_windows=$(xdotool search --onlyvisible "" 2>/dev/null | sort)
      new_windows=$(comm -13 <(echo "${before_windows}") <(echo "${after_windows}"))
      if [[ -n "${new_windows}" ]]; then
        window_detected="1"
        break
      fi
    done
  elif [[ "${session_kind}" = "x11" ]]; then
    # xdotool missing on an X11 session: degrades to the Wayland fixed wait, but LOGGED (same
    # symptoms as Wayland: always exactly 12s, even for a game starting in 2s). "lpm check" also
    # recommends installing xdotool on an X11 session; see zgc-dependency-checker.sh.
    zgu_log "launcher-orchestrator" "WARN" "slug=${slug} reason=xdotool_missing_fixed_wait_fallback"
    sleep 12
  else
    # Wayland: xdotool cannot list/detect windows of other applications, so a reasonable fixed
    # wait. This fallback should only happen without PyYAML/configpath (see "use_winetrace"
    # above): universal detection works on both Wayland and X11.
    sleep 12
  fi

  # Post-detection safety margin (see POST_WINDOW_GRACE_MS above) + extra per-game margin (see
  # extra_ms above). Applies in all cases (window detected via trace/xdotool, or fixed wait
  # elapsed).
  total_grace_ms=$(( POST_WINDOW_GRACE_MS + extra_ms ))
  sleep "$(awk -v ms="${total_grace_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"

  # Minimum duration: avoids a flash if the game starts abnormally fast.
  if [[ "${start_ms}" != "0" ]]; then
    now_ms=$(date +%s%3N 2>/dev/null || echo 0)
    elapsed_ms=$(( now_ms - start_ms ))
    if [[ "${elapsed_ms}" -lt "${MIN_DISPLAY_MS}" ]]; then
      remaining_ms=$(( MIN_DISPLAY_MS - elapsed_ms ))
      sleep "$(awk -v ms="${remaining_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"
    fi
  fi

  # --- Timeout without any window appearing (detectable when universal detection is active,
  # "use_winetrace", or as fallback on X11 with xdotool; no reliable signal otherwise, so never
  # a false warning there): instead of vanishing silently as if all went well, shows a warning
  # a few seconds before closing, reusing the "title" line (see zgu-launcher-screen.py). The
  # "loading"/spinner indicator is hidden at the same time. ---
  if { [[ "${use_winetrace}" = true ]] || { [[ "${session_kind}" = "x11" ]] && command -v xdotool >/dev/null 2>&1; }; } \
      && [[ -z "${window_detected}" ]]; then
    zgu_log "launcher-orchestrator" "WARN" "slug=${slug} reason=no_window_detected_after_delay delay_s=${max_wait_s}"
    {
      printf '%s\n' "${bg_state}"
      printf '%s\n' "IND_HIDE"
      printf '%s\n' "$(t launcher.launch_timeout_warning)"
    } > "${control_file}" 2>/dev/null
    sleep 4
  fi

  echo "STOP" > "${control_file}" 2>/dev/null
  sleep 0.3
  [[ -n "${blackscreen_pid}" ]] && kill "${blackscreen_pid}" 2>/dev/null
  rm -f "${control_file}" 2>/dev/null
  rm -f "${trace_file}" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
disown $! 2>/dev/null

# --- Gamepad "quit game" combo (SIGTERM to the prefix Wine processes); see
# zgu-gamepad-exit-watcher.py for details (why a script apart from the gamepad bridge, why no
# grab(), why no safety net). Started HERE, just before handing over to Lutris (the "exec"
# below never returns, so the orchestrator loses track of the game: the watcher must already
# run before that point).
#
# "pkill" before restarting: this script stops by itself once the combo is used, but NOT if
# the game is quit another way (undetectable from here), so without this cleanup an orphan
# instance from a previous session would stay active next to the new one. Assumes one game
# at a time (consistent with the rest of lpm).
if [[ "${has_display}" = true ]] && command -v python3 >/dev/null 2>&1; then
  pkill -f "zgu-gamepad-exit-watcher.py" 2>/dev/null
  python3 "${script_dir}/zgu-gamepad-exit-watcher.py" "${session_kind}" "${game_dir}" >/dev/null 2>&1 &
  disown $! 2>/dev/null

  # --- Gamepad "switch window" combo (Alt+Tab); see zgu-gamepad-alttab-watcher.py. Unlike the
  # quit combo above, this one runs during the WHOLE game session (not one-shot) and stops by
  # itself when the game ends; same "pkill" before restart in case an instance is left over.
  pkill -f "zgu-gamepad-alttab-watcher.py" 2>/dev/null
  python3 "${script_dir}/zgu-gamepad-alttab-watcher.py" "${session_kind}" "${game_dir}" >/dev/null 2>&1 &
  disown $! 2>/dev/null
fi

launch_lutris
