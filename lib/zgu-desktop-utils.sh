#!/bin/bash

# --- Shared utility: detection of the user's "Desktop" folder ---
#
# Uses the standard XDG mechanism (xdg-user-dir, backed by ~/.config/user-dirs.dirs): the only
# reliable source, since desktop environments use it themselves, whatever the system language and
# even if the user renamed or moved their Desktop folder. A hardcoded "Desktop"/"Bureau" would fail
# on a system in another language (e.g. "Schreibtisch", "Escritorio"), silently never creating or
# removing the shortcut.
#
# Fallback to the Desktop/Bureau heuristic if xdg-user-dir is missing or returns nothing usable. If
# neither "~/Bureau" nor "~/Desktop" exists on disk, return "$HOME" rather than a nonexistent
# "~/Desktop" (zgu_write_game_shortcut checks the folder exists before writing).
# shellcheck source=./zgu-lpm-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/zgu-lpm-paths.sh"

zgu_get_desktop_dir() {
  if command -v xdg-user-dir >/dev/null 2>&1; then
    local xdg_desktop
    xdg_desktop=$(xdg-user-dir DESKTOP 2>/dev/null)
    # xdg-user-dir returns $HOME as-is when XDG_DESKTOP_DIR is not configured: not a real answer, so
    # continue to the fallback.
    if [[ -n "${xdg_desktop}" ]] && [[ "${xdg_desktop}" != "${HOME}" ]]; then
      echo "${xdg_desktop}"
      return 0
    fi
  fi

  if [[ -d "${HOME}/Bureau" ]]; then
    echo "${HOME}/Bureau"
  elif [[ -d "${HOME}/Desktop" ]]; then
    echo "${HOME}/Desktop"
  else
    echo "${HOME}"
  fi
}

# Folder of this file (where lib/zgu-umu-gameid.py sits), whatever the script that sources it.
ZGU_DESKTOP_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Pieces of zgu_write_game_shortcut (each one does one thing; see the header above) ---

# zgu_shortcut_icon <prefix_dir>: prints the icon of the shortcut, an image of the game folder
# "lpm/images/icon" or our generic fallback icon.
zgu_shortcut_icon() {
  local icon_path="lpm-game-generic" icon_src_dir icon_file
  icon_src_dir="$(zgu_lpm_find "$1" icon)"
  if [[ -d "${icon_src_dir}" ]]; then
    icon_file=$(find "${icon_src_dir}" -maxdepth 1 -type f \( -name "*.png" -o -name "*.ico" -o -name "*.svg" -o -name "*.xpm" \) -print -quit 2>/dev/null)
    # icon_file is a real file name possibly forged by a third party (shared .zgp package) and injected
    # as-is into "Icon=${icon_path}" of the generated .desktop: a newline in the name could add an
    # arbitrary "Exec=" line (silent execution on double-click, since the .desktop is marked
    # "metadata::trusted true"). Same filter as for slug/game_real_name elsewhere in the project.
    icon_file="${icon_file//[$'\n\r\t']/}"
    [[ -n "${icon_file}" ]] && icon_path="${icon_file}"
  fi
  printf '%s' "${icon_path}"
}

# zgu_shortcut_wm_class <executable_path> <game_id> <configpath> <lutris_config_dir> <runner_dir>:
# prints the StartupWMClass of the shortcut (empty if unknown).
# Wine WM_CLASS = executable file name as-is (case and extension kept, e.g. "Notepad.exe"), never
# the full path. executable_path comes from the Lutris database (column "executable"), so it may be
# forged by a third party (shared .zgp): same anti-injection filter as for icon_file/slug/
# game_real_name, before landing in "StartupWMClass=" of the generated .desktop.
# Proton/umu fallback (see the header): lib/zgu-umu-gameid.py adds the missing GAMEID to the game's
# YAML and prints the class umu-run will give the window. It does nothing if a required ingredient
# is missing (configpath/lutris_config_dir/runner_dir not provided, YAML file not found, or
# python3/PyYAML absent) -- the classic wine behavior then stays unchanged.
zgu_shortcut_wm_class() {
  local executable_path="$1" game_id="$2" configpath="$3" config_dir="$4" runner_dir="$5"
  local wm_class="" proton_wm_class yml_path="${4}/${3}.yml"
  if [[ -n "${executable_path}" ]]; then
    wm_class=$(basename -- "${executable_path}")
    wm_class="${wm_class//[$'\n\r\t']/}"
  fi

  if [[ -n "${configpath}" ]] && [[ -n "${config_dir}" ]] && [[ -n "${runner_dir}" ]] \
     && [[ -f "${yml_path}" ]] \
     && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    proton_wm_class=$(YML_PATH="${yml_path}" RUNNER_DIR="${runner_dir}" GAME_ID="${game_id}" \
      python3 "${ZGU_DESKTOP_UTILS_DIR}/zgu-umu-gameid.py" 2>/dev/null)
    [[ -n "${proton_wm_class}" ]] && wm_class="${proton_wm_class}"
  fi
  printf '%s' "${wm_class}"
}

# zgu_shortcut_write_menu <slug> <create_menu> <content>: writes the menu shortcut, or removes it
# when create_menu is not true (see the header: only the menu shortcut can be removed).
zgu_shortcut_write_menu() {
  local slug="$1" create_menu="$2" content="$3"
  local menu_desktop_file="${HOME}/.local/share/applications/net.lutris.${slug}.desktop"
  if [[ "${create_menu}" = true ]]; then
    mkdir -p "${HOME}/.local/share/applications"
    echo "${content}" > "${menu_desktop_file}"
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  elif [[ -f "${menu_desktop_file}" ]]; then
    rm -f "${menu_desktop_file}"
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi
}

# zgu_shortcut_write_desktop <slug> <game_real_name> <prefix_dir> <desktop_dir_override> <content>:
# writes the shortcut in the desktop/custom folder (trusted, executable) and, when the game has
# extras, a link to them next to it.
zgu_shortcut_write_desktop() {
  local slug="$1" game_real_name="$2" prefix_dir="$3" desktop_dir_override="$4" content="$5"
  local desktop_dir
  if [[ -n "${desktop_dir_override}" ]]; then
    desktop_dir="${desktop_dir_override}"
  else
    desktop_dir=$(zgu_get_desktop_dir)
  fi
  [[ -d "${desktop_dir}" ]] || return 0

  echo "${content}" > "${desktop_dir}/${slug}.desktop"
  chmod +x "${desktop_dir}/${slug}.desktop"
  gio set "${desktop_dir}/${slug}.desktop" metadata::trusted true 2>/dev/null || true

  local extras_src_dir bonus_dir_name
  extras_src_dir="$(zgu_lpm_find "${prefix_dir}" extras)"
  if [[ -d "${extras_src_dir}" ]]; then
    bonus_dir_name="${game_real_name} $(t install_game.bonus_folder_suffix)"
    rm -rf "${desktop_dir}/${bonus_dir_name:?}"
    ln -s "${extras_src_dir}" "${desktop_dir}/${bonus_dir_name}"
  fi
}

# --- Shared utility: generates the .desktop shortcut(s) of an lpm game ---
#
# zgu_write_game_shortcut <display_name> <slug> <prefix_dir> <game_id> <version> <create_menu> <create_desktop> [<executable_path>] [<configpath>] [<lutris_config_dir>] [<runner_dir>] [<desktop_dir_override>]
#
# "desktop_dir_override" (12th, optional): a custom desktop folder (typically chosen in the GUI)
# instead of the one detected by zgu_get_desktop_dir().
#
# "create_menu" = false REMOVES the existing menu shortcut (its location is always
# "${HOME}/.local/share/applications/net.lutris.<slug>.desktop"). That is impossible for the
# "folder" shortcut (create_desktop): its location is chosen at each run and never remembered, so
# "create_desktop" = false does nothing; only game uninstallation removes it, at the default
# location.
#
# Used by zgp-game-installer.sh and zgp-game-shortcutter.sh. Assumes "t" (zgl-lang-loader.sh) is
# already loaded.
#
# Icon: the first image of <prefix_dir>/lpm/images/icon, else "lpm-game-generic" (our own icon,
# assets/icons/lpm-game-generic.svg, installed in hicolor by install.sh; different on purpose from
# the .zgp and .zgr icons).
#
# StartupWMClass: without it the taskbar shows the icon Wine announces for the window instead of
# the shortcut icon, because the panel matches the window to the .desktop through WM_CLASS, which
# Wine sets to the bare executable name.
#
# Proton/umu: a window launched via umu-run has WM_CLASS "steam_app_<id>", where <id> comes only
# from a GAMEID of the form "umu-<id>" (umu/umu_run.py). Without GAMEID, every Proton game gets the
# same generic WM_CLASS and the panel merges them. GAMEID cannot be set from the .desktop (Lutris
# builds the environment only from the game's config), so the Python call below adds
# GAMEID="umu-<game_id>" to the game's Lutris config ONLY if the game uses Proton
# (toolmanifest.vdf in its runner folder) and GAMEID is not already set. A backup (.lpm-bak) of
# the YAML is kept during the write. If python3/PyYAML is missing, the game does not use Proton or
# an incompatible GAMEID exists: silent fallback to the classic behavior.
zgu_write_game_shortcut() {
  local game_real_name="$1" slug="$2" prefix_dir="$3" game_id="$4" version="$5"
  local create_menu="$6" create_desktop="$7" executable_path="${8:-}" configpath="${9:-}"
  local lutris_config_dir="${10:-}" runner_dir="${11:-}" desktop_dir_override="${12:-}"

  local icon_path wm_class
  icon_path="$(zgu_shortcut_icon "${prefix_dir}")"
  wm_class="$(zgu_shortcut_wm_class "${executable_path}" "${game_id}" "${configpath}" "${lutris_config_dir}" "${runner_dir}")"

  # All lpm .desktop shortcuts go through the orchestrator (lib/zgl-launcher-orchestrator.sh), the
  # single entry point -- see its header for the full design. Only "game_id" (integer) and "version"
  # (fixed word "flatpak"/"package") go through Exec=: both always safe without special escaping,
  # unlike "slug"/"game_dir" (paths that may contain spaces and would need Desktop Entry escaping rules,
  # distinct from shell ones). The orchestrator re-queries the Lutris database for the rest.
  # shellcheck disable=SC2154 # script_dir: assigned by the caller before sourcing this file
  # (zgp-game-shortcutter.sh / zgp-game-installer.sh), same convention as elsewhere in the project --
  # bash dynamic scope, not an undefined variable.
  local exec_cmd="${script_dir}/zgl-launcher-orchestrator.sh ${game_id} ${version}"

  local shortcut_content="[Desktop Entry]
Type=Application
Name=${game_real_name}
Icon=${icon_path}
Exec=${exec_cmd}
Categories=Game"
  [[ -n "${wm_class}" ]] && shortcut_content="${shortcut_content}
StartupWMClass=${wm_class}"

  zgu_shortcut_write_menu "${slug}" "${create_menu}" "${shortcut_content}"
  [[ "${create_desktop}" = true ]] && \
    zgu_shortcut_write_desktop "${slug}" "${game_real_name}" "${prefix_dir}" "${desktop_dir_override}" "${shortcut_content}"
  return 0
}

# --- Shared utility: neutralizes/restores the Lutris launch hooks of a game ---
#
# zgu_apply_hook_policy <yml_path> <allow_hooks: true|false> [mode: fixed|broad]
#
# Lutris launch hooks (prelaunch_command, prelaunch_wait, postexit_command) run arbitrary code at
# game launch/exit. A hook is never deleted, only commented out with the marker
# "lpm:hook-disabled" (so a comment of the user is never mistaken for it), and restored when the
# switch goes back to "allowed". Secure by default: allow_hooks=false neutralizes any active hook.
#
# "mode" (default "fixed") chooses the targeted keys:
#   - "fixed": only prelaunch_command/prelaunch_wait/postexit_command ("lpm shortcut").
#   - "broad": any key ending in "_command"/"_script"/"_wait" or containing "exec", anywhere in
#     the YAML, as in zgp-game-installer.sh: used at install, where the YAML of a shared .zgp may
#     be forged.
#
# Acts only if the file exists AND contains a targeted key (never creates a file or a key).
# Idempotent both ways.
#
# Exception, the old LPM Launcher relay: a prelaunch_command/prelaunch_wait pointing to
# "${game_dir}/scripts/lpm-launcher.sh" is lpm's own (generated only by lpm, never by a .zgp), so
# it is left alone, in both modes; otherwise every shortcut regeneration would break games of
# lpm 0.9.5 and earlier that still have it.
zgu_apply_hook_policy() {
  local yml_path="$1"
  local allow_hooks="$2"
  local mode="${3:-fixed}"

  [[ -f "${yml_path}" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local disabled_comment
  disabled_comment="$(t shortcut.hook_disabled_comment)"

  python3 "${ZGU_DESKTOP_UTILS_DIR}/zgu-hook-policy.py" "${yml_path}" "${allow_hooks}" "${disabled_comment}" "${mode}"
}
