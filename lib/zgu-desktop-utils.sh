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

# --- Shared utility: generates the .desktop shortcut(s) of an lpm game ---
#
# zgu_write_game_shortcut <nom_affiche> <slug> <prefix_dir> <game_id> <version> <create_menu> <create_desktop> [<executable_path>] [<configpath>] [<lutris_config_dir>] [<runner_dir>] [<desktop_dir_override>]
#
# "desktop_dir_override" (12th argument, optional): lets the caller force a custom desktop path
# (typically chosen in the GUI) instead of the folder auto-detected by zgu_get_desktop_dir().
#
# "create_menu" = false REMOVES the existing menu shortcut (if any): since creation is optional,
# disabling it must remove what it created. Idempotent. Possible ONLY for the menu shortcut, whose
# location is always the same ("${HOME}/.local/share/applications/net.lutris.<slug>.desktop"), never
# for the "folder" shortcut (create_desktop): its location is user-customizable on each run and is
# never remembered (no persistence, see DesktopPathRow in gui/*.py), so lpm cannot reliably know where
# an earlier one was written and must not guess (risk of hitting the wrong file in a folder the user
# manages). "create_desktop" = false therefore stays a plain "do nothing"; only game uninstallation
# (zgp-game-uninstaller.sh) removes the "folder" shortcut, and only at the default location
# (zgu_get_desktop_dir(), never a custom path).
#
# Used by both zgp-game-installer.sh (right after installing a .zgp) and zgp-game-shortcutter.sh
# (afterwards, on an installed game) -- one shared logic. Assumes "t" (zgl-lang-loader.sh) is
# already loaded by the caller.
#
# Icon resolution: looks for an image in <prefix_dir>/icon (placed by the user, or packaged in the
# .zgp). Otherwise falls back to "lpm-game-generic", our own fallback icon
# (assets/icons/lpm-game-generic.svg, installed in the hicolor theme by install.sh): a copy of the
# generic system "applications-games" background with a gamepad glyph, deliberately DIFFERENT from
# the "package" glyph (.zgp) and the "glass" glyph (.zgr, see install.sh) to avoid visual confusion
# between a .zgp file, the lpm launcher itself and a game shortcut. It does not depend on the icon
# theme installed on the user's machine ("Icon=lutris_${slug}" would be a made-up theme name that
# matches nothing: Lutris downloads an icon under that name itself, lpm does not).
#
# StartupWMClass: without it, the running game window shows NOT the shortcut icon in the taskbar
# but the one Wine announces for the window (icon embedded in the executable, or none). The panel
# matches the window to the .desktop via the X11 WM_CLASS property, and Wine sets it to the bare
# executable name (e.g. "Notepad.exe"), which matches nothing in a .desktop generated without this
# field. Confirmed by a Wine developer message on wine-devel (April 2017) and by the freedesktop
# Desktop Entry spec, which defines StartupWMClass for this case.
#
# PROTON/UMU SPECIAL CASE (Proton runner, e.g. GE-Proton): the above only applies to classic wine.
# Verified with xprop: a window launched via umu-run has WM_CLASS "steam_app_<id>", never the
# executable name -- and <id> does NOT come from the raw GAMEID content but from a pattern in the
# umu-run source (umu/umu_run.py): GAMEID is only recognized as "umu-<id>", in which case <id>
# becomes STEAM_COMPAT_APP_ID/SteamAppId, hence WM_CLASS "steam_app_<id>". With no GAMEID at all,
# umu-run falls back to a generic WM_CLASS ("steam_app_default" or "steam_app_0") IDENTICAL for all
# Proton games on the machine -- so two different Proton games would be wrongly merged in the panel,
# or the pinned shortcut would match none of them.
#
# GAMEID cannot be set from the .desktop itself: the shortcut only asks Lutris to launch the game
# ("lutris:rungameid/<id>"), and Lutris then invokes umu-run, building the environment ONLY from its
# own config (get_env(os_env=False) in wine.py), not from the .desktop environment. The only lever is
# the game's Lutris config (system: env: GAMEID), hence the Python call below that adds
# GAMEID="umu-<game_id>" (reusing the Lutris game id, unique per game) ONLY if the game uses a Proton
# runner (toolmanifest.vdf in its build folder, the same check umu-run does to validate a
# PROTONPATH) and ONLY if GAMEID is not already set by the user (never overwritten). A backup
# (.lpm-bak) of the YAML is kept during the write, then removed once the write is confirmed.
# If python3/PyYAML is missing, the game does not use Proton, or an incompatible custom GAMEID is
# already present: silent fallback to the classic wine behavior (executable name) above.
zgu_write_game_shortcut() {
  local game_real_name="$1"
  local slug="$2"
  local prefix_dir="$3"
  local game_id="$4"
  local version="$5"
  local create_menu="$6"
  local create_desktop="$7"
  local executable_path="${8:-}"
  local configpath="${9:-}"
  local lutris_config_dir="${10:-}"
  local runner_dir="${11:-}"
  local desktop_dir_override="${12:-}"

  local icon_path="lpm-game-generic"
  if [[ -d "${prefix_dir}/icon" ]]; then
    local icon_file
    icon_file=$(find "${prefix_dir}/icon" -maxdepth 1 -type f \( -name "*.png" -o -name "*.ico" -o -name "*.svg" -o -name "*.xpm" \) -print -quit 2>/dev/null)
    # icon_file is a real file name possibly forged by a third party (shared .zgp package) and injected
    # as-is into "Icon=${icon_path}" of the generated .desktop: a newline in the name could add an
    # arbitrary "Exec=" line (silent execution on double-click, since the .desktop is marked
    # "metadata::trusted true"). Same filter as for slug/game_real_name elsewhere in the project.
    icon_file="${icon_file//[$'\n\r\t']/}"
    [[ -n "${icon_file}" ]] && icon_path="${icon_file}"
  fi

  # All lpm .desktop shortcuts go through the orchestrator (lib/zgl-launcher-orchestrator.sh), the
  # single entry point -- see its header for the full design. Only "game_id" (integer) and "version"
  # (fixed word "flatpak"/"package") go through Exec=: both always safe without special escaping,
  # unlike "slug"/"game_dir" (paths that may contain spaces and would need Desktop Entry escaping rules,
  # distinct from shell ones). The orchestrator re-queries the Lutris database for the rest.
  # shellcheck disable=SC2154 # script_dir: assigned by the caller before sourcing this file
  # (zgp-game-shortcutter.sh / zgp-game-installer.sh), same convention as elsewhere in the project --
  # bash dynamic scope, not an undefined variable.
  local exec_cmd="${script_dir}/zgl-launcher-orchestrator.sh ${game_id} ${version}"

  # Wine WM_CLASS = executable file name as-is (case and extension kept, e.g. "Notepad.exe"), never
  # the full path. executable_path comes from the Lutris database (column "executable"), so it may be
  # forged by a third party (shared .zgp): same anti-injection filter as for icon_file/slug/
  # game_real_name, before landing in "StartupWMClass=${wm_class}" of the generated .desktop.
  local wm_class=""
  if [[ -n "${executable_path}" ]]; then
    wm_class=$(basename -- "${executable_path}")
    wm_class="${wm_class//[$'\n\r\t']/}"
  fi

  # Proton/umu fallback (see the detailed comment above): does nothing if a required ingredient is
  # missing (configpath/lutris_config_dir/runner_dir not provided, YAML file not found, or
  # python3/PyYAML absent) -- the classic wine behavior above then stays unchanged.
  if [[ -n "${configpath}" ]] && [[ -n "${lutris_config_dir}" ]] && [[ -n "${runner_dir}" ]] \
     && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then

    local yml_path="${lutris_config_dir}/${configpath}.yml"
    if [[ -f "${yml_path}" ]]; then
      local proton_wm_class
      proton_wm_class=$(YML_PATH="${yml_path}" RUNNER_DIR="${runner_dir}" GAME_ID="${game_id}" python3 -c '
import os, re, sys

yml_path = os.environ["YML_PATH"]
runner_dir = os.environ["RUNNER_DIR"]
game_id = os.environ["GAME_ID"]

try:
    import yaml
except Exception:
    sys.exit(0)

try:
    with open(yml_path, "r") as f:
        raw_text = f.read()
    data = yaml.safe_load(raw_text)
except Exception:
    sys.exit(0)

if not isinstance(data, dict):
    sys.exit(0)

wine_version = data.get("wine", {}).get("version", "") if isinstance(data.get("wine"), dict) else ""
if not wine_version:
    sys.exit(0)

# Same check umu-run does to validate a PROTONPATH: a classic wine build folder never has this file.
if not os.path.isfile(os.path.join(runner_dir, wine_version, "toolmanifest.vdf")):
    sys.exit(0)

system_cfg = data.get("system")
env_cfg = system_cfg.get("env") if isinstance(system_cfg, dict) else None

existing = env_cfg.get("GAMEID") if isinstance(env_cfg, dict) else None
if existing:
    # Never overwrite a GAMEID already set by hand: the expected WM_CLASS is only deduced if it follows
    # the pattern recognized by umu-run (see umu_run.py); otherwise we cannot know the result, so bail out.
    m = re.match(r"^umu-([\d\w]+)$", str(existing))
    if m:
        print(f"steam_app_{m.group(1)}")
    sys.exit(0)

# --- Targeted text insertion: never "yaml.safe_load" + "yaml.dump" to rewrite the whole file. A
# standard YAML parser ignores comments (a line "# prelaunch_command: ...  # lpm:hook-disabled" does
# not exist for it), so a full roundtrip would silently erase every hook currently neutralized by
# zgu_apply_hook_policy. Only the missing GAMEID line is added, by plain text manipulation of the
# file lines; "data"/"raw_text" above only DECIDE whether a write is needed, never produce it.
lines = raw_text.splitlines()


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def find_top_block(key):
    """Intervalle [start, end) (end exclu) du bloc top-level "<key>:", ou None si la
    cle n existe pas a l indentation 0."""
    for i, line in enumerate(lines):
        if line.startswith(key + ":") and indent_of(line) == 0:
            j = i + 1
            while j < len(lines) and (lines[j].strip() == "" or indent_of(lines[j]) > 0):
                j += 1
            return i, j
    return None


def child_indent(start, end, own_indent):
    """Indentation de la premiere ligne non vide du bloc -- repli a "own_indent + 2"
    (convention 2-espaces constatee partout ailleurs dans ce projet) si le bloc est
    vide."""
    for k in range(start + 1, end):
        if lines[k].strip() != "":
            return indent_of(lines[k])
    return own_indent + 2


system_block = find_top_block("system")

if system_block is None:
    # No "system:" key at all -- appended at end of file with its "env:" and the GAMEID key.
    if lines and lines[-1].strip() != "":
        lines.append("")
    lines.extend(["system:", "  env:", f"    GAMEID: umu-{game_id}"])
else:
    sys_start, sys_end = system_block
    sys_child_indent = child_indent(sys_start, sys_end, 0)
    env_block = None
    for i in range(sys_start + 1, sys_end):
        if lines[i].strip().startswith("env:") and indent_of(lines[i]) == sys_child_indent:
            j = i + 1
            while j < sys_end and (lines[j].strip() == "" or indent_of(lines[j]) > sys_child_indent):
                j += 1
            env_block = (i, j)
            break

    if env_block is None:
        # "system:" exists but without "env:" -- inserted as first child of the block.
        lines[sys_start + 1:sys_start + 1] = [
            " " * sys_child_indent + "env:",
            " " * (sys_child_indent + 2) + f"GAMEID: umu-{game_id}",
        ]
    else:
        env_start, env_end = env_block
        # "env: {}" (inline empty mapping, as written by a YAML dump) cannot take an indented
        # child: it is turned into a block "env:" first. Any other inline value is left alone
        # (nothing is written) rather than producing an invalid file.
        env_inline = lines[env_start].split("env:", 1)[1].split("#", 1)[0].strip()
        if env_inline == "{}":
            lines[env_start] = lines[env_start].split("env:", 1)[0] + "env:"
        elif env_inline != "":
            sys.exit(0)
        env_child_indent = child_indent(env_start, env_end, indent_of(lines[env_start]))
        lines.insert(env_end, " " * env_child_indent + f"GAMEID: umu-{game_id}")

try:
    with open(yml_path, "w") as f:
        f.write("\n".join(lines) + "\n")
except Exception:
    sys.exit(0)

print(f"steam_app_{game_id}")
' 2>/dev/null)

      [[ -n "${proton_wm_class}" ]] && wm_class="${proton_wm_class}"
    fi
  fi

  local shortcut_content="[Desktop Entry]
Type=Application
Name=${game_real_name}
Icon=${icon_path}
Exec=${exec_cmd}
Categories=Game"

  [[ -n "${wm_class}" ]] && shortcut_content="${shortcut_content}
StartupWMClass=${wm_class}"

  local menu_desktop_file="${HOME}/.local/share/applications/net.lutris.${slug}.desktop"
  if [[ "${create_menu}" = true ]]; then
    mkdir -p "${HOME}/.local/share/applications"
    echo "${shortcut_content}" > "${menu_desktop_file}"
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  elif [[ -f "${menu_desktop_file}" ]]; then
    rm -f "${menu_desktop_file}"
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi

  if [[ "${create_desktop}" = true ]]; then
    local desktop_dir
    if [[ -n "${desktop_dir_override}" ]]; then
      desktop_dir="${desktop_dir_override}"
    else
      desktop_dir=$(zgu_get_desktop_dir)
    fi
    if [[ -d "${desktop_dir}" ]]; then
      echo "${shortcut_content}" > "${desktop_dir}/${slug}.desktop"
      chmod +x "${desktop_dir}/${slug}.desktop"
      gio set "${desktop_dir}/${slug}.desktop" metadata::trusted true 2>/dev/null || true

      if [[ -d "${prefix_dir}/extras" ]]; then
        local bonus_dir_name bonus_suffix
        bonus_suffix="$(t install_game.bonus_folder_suffix)"
        bonus_dir_name="${game_real_name} ${bonus_suffix}"
        rm -rf "${desktop_dir}/${bonus_dir_name:?}"
        ln -s "${prefix_dir}/extras" "${desktop_dir}/${bonus_dir_name}"
      fi
    fi
  fi
}

# --- Shared utility: neutralizes/restores the Lutris launch hooks of a game ---
#
# zgu_apply_hook_policy <yml_path> <allow_hooks: true|false> [mode: fixed|broad]
#
# Lutris launch hooks (prelaunch_command, prelaunch_wait, postexit_command -- "system:" section of
# the PER-GAME config YAML, see sysoptions.py in Lutris) run arbitrary code at game launch/exit.
# The command itself is never deleted/overwritten -- only neutralized by commenting it out (with a
# dedicated marker, "lpm:hook-disabled", allowing later restoration without touching a comment the
# user wrote), and restorable (uncomment) when the switch goes back to "allowed". Secure by default:
# "allow_hooks" = false neutralizes any active hook found.
#
# "mode" (default "fixed") chooses the set of targeted keys:
#   - "fixed": only prelaunch_command/prelaunch_wait/postexit_command -- used by "lpm shortcut"
#     (zgp-game-shortcutter.sh), on a locally installed game.
#   - "broad": same heuristic as zgp-game-installer.sh -- any key ending in "_command"/"_script"/
#     "_wait" or containing "exec", anywhere in the YAML (not only "system:"). Used at install, where
#     the YAML embedded in a shared .zgp may be forged by an untrusted third party -- deliberately
#     wider than a fixed list of known keys.
#
# Acts only if the file exists AND contains a targeted key -- never creates a file or adds a missing
# key. Idempotent both ways (an already neutralized/active line is never touched again).
#
# Exception -- lpm's own relay: "prelaunch_command"/"prelaunch_wait" are NOT a potentially dangerous
# third-party hook when they point to "${game_dir}/scripts/lpm-launcher.sh" -- that file is generated
# ONLY by lpm itself ("lpm launcher ... on", see zgl-launcher-manager.sh), never by a shared .zgp.
# Otherwise "lpm shortcut" (allow_hooks=false by default) would neutralize this hook on EVERY shortcut
# regeneration, silently breaking the LPM Launcher. "allow_hooks" protection stays whole for any other
# hook.
#
# The exception also applies in "broad" mode (install): zgp-game-installer.sh rewrites
# "prelaunch_command"/"prelaunch_wait" with this same path JUST BEFORE calling this function, when
# "scripts/lpm-launcher.sh" already exists in the game folder (LPM Launcher active before packaging);
# without the exception this call would immediately undo that write on every reinstall.
zgu_apply_hook_policy() {
  local yml_path="$1"
  local allow_hooks="$2"
  local mode="${3:-fixed}"

  [[ -f "${yml_path}" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local disabled_comment
  disabled_comment="$(t shortcut.hook_disabled_comment)"

  python3 - "${yml_path}" "${allow_hooks}" "${disabled_comment}" "${mode}" <<'PYEOF'
import re
import sys

yml_path, allow_hooks, disabled_comment, mode = sys.argv[1], sys.argv[2] == "true", sys.argv[3], sys.argv[4]

FIXED_KEYS = {"prelaunch_command", "prelaunch_wait", "postexit_command"}
MARKER = "lpm:hook-disabled"
# Suffix of the relay generated by "lpm launcher ... on" (see zgl-launcher-manager.sh) -- never a
# third-party hook, see the header comment of zgu_apply_hook_policy.
LPM_RELAY_SUFFIX = "/scripts/lpm-launcher.sh"


def is_target_key(key):
    if mode == "broad":
        kl = key.lower()
        return kl.endswith("_command") or kl.endswith("_script") or kl.endswith("_wait") or "exec" in kl
    return key in FIXED_KEYS


# Captures any "identifier:" key -- the real filtering (fixed/broad) is done afterwards by
# is_target_key(), not in the regex itself.
active_re = re.compile(r'^(?P<indent>\s*)(?P<key>[A-Za-z0-9_]+):(?P<rest>.*)$')
disabled_re = re.compile(
    r'^(?P<indent>\s*)#\s*(?P<key>[A-Za-z0-9_]+):(?P<rest>.*?)\s*#\s*' + re.escape(MARKER) + r'.*$'
)

try:
    with open(yml_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except OSError:
    sys.exit(0)

# Pre-pass: does "prelaunch_command" point to lpm's own relay, whether currently active or already
# neutralized (marker "lpm:hook-disabled")? Decides below whether "prelaunch_command" AND
# "prelaunch_wait" must entirely escape neutralization -- "prelaunch_wait" alone (just "true")
# cannot tell by itself.
is_lpm_relay = False
for line in lines:
    stripped = line.rstrip("\n")
    m = active_re.match(stripped) or disabled_re.match(stripped)
    if m and m.group("key") == "prelaunch_command" and m.group("rest").strip().endswith(LPM_RELAY_SUFFIX):
        is_lpm_relay = True
        break

# lpm's own relay entirely escapes "allow_hooks" (see the header comment of zgu_apply_hook_policy),
# in "fixed" mode ("lpm shortcut") as in "broad" mode (install -- zgp-game-installer.sh rewrites this
# path itself just before calling this function, so the value seen here is its own, not a third-party
# .zgp's).
effective_allow = allow_hooks or is_lpm_relay

changed = False
out = []
for line in lines:
    stripped = line.rstrip("\n")
    if effective_allow:
        m = disabled_re.match(stripped)
        if m and is_target_key(m.group("key")):
            out.append(f"{m.group('indent')}{m.group('key')}:{m.group('rest')}\n")
            changed = True
            continue
    else:
        m = active_re.match(stripped)
        if m and is_target_key(m.group("key")):
            out.append(f"{m.group('indent')}# {m.group('key')}:{m.group('rest')}  # {MARKER} ({disabled_comment})\n")
            changed = True
            continue
    out.append(line)

if changed:
    with open(yml_path, "w", encoding="utf-8") as f:
        f.writelines(out)
PYEOF
}
