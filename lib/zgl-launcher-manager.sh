#!/bin/bash

# --- lpm launcher [slug...] [on|off] ---
#
# Enables/disables the "LPM Launcher" (black screen + splash + gamepad lock, with an
# optional multi-executable picker) for one or more Lutris Wine/Proton games.
#
#   1. "on" asks NO single/multi choice: the number of entries actually used is re-read from
#      the YAML at every game launch (see zgl-launcher-runtime.sh). "on" always writes the
#      same thing: a first entry auto-filled from the game.exe/working_dir already set in
#      Lutris, PLUS a second commented example entry in lpm-launcher.yml, to uncomment/adapt
#      by hand if the game has several executables (episodes, DLC, campaigns...).
#   2. "Already active" detection: a game has the launcher if its game.exe points to
#      lpm-launch.bat, re-read from the YAML on each run (no separate tracking file).
#   3. Enable: saves the original exe/working_dir ("original_exe" key of the new
#      lpm-launcher.yml), converts native Linux paths to Windows paths (C:\...) via
#      winepath -w (only needed for the auto-filled entry; users type Windows paths for
#      entries added by hand). Creates $GAMEDIR/scripts/lpm-launcher.sh (relay, calls
#      zgl-launcher-runtime.sh). NO default splash image is copied: a missing
#      $GAMEDIR/splash/splash.png means "plain black loading screen" for the orchestrator
#      (see lib/zgl-launcher-orchestrator.sh); an existing splash.png is never touched.
#      Sets system.prelaunch_command and points game.exe to lpm-launch.bat.
#   4. Disable: restores the original exe from "original_exe", removes
#      system.prelaunch_command (only if it references our relay script), then DELETES the
#      files the launcher added: lpm-launcher.yml (so the entries are gone too),
#      scripts/lpm-launcher.sh, every lpm-launch.bat. Never touches splash/, the other files
#      of scripts/ (loading screen), nor any game/Windows file.
#   5. Wine/Proton games only (runner='wine'), shared prefixes included (non-destructive,
#      same principle as "lpm tools"/"lpm lsfg").
#   6. "--if-needed" (optional, before or after the slugs): a game already in the requested
#      state is silently skipped instead of failing the whole command (default behaviour
#      UNCHANGED without the flag; in CLI group selection, picking an already-active game is
#      probably a mistake worth reporting). Added for "gui/*.py" (page_launcher), where the
#      enabled/disabled state follows from the form content (entries -> active, none ->
#      inactive), so "already in the requested state" is not an error there.
#   7. "lpm launcher status" (no slug): lists, one per line, the slugs of Wine/Proton games
#      that already have the LPM Launcher active (same detection as item 2,
#      zgp_launcher_is_active, re-read on each call, nothing cached). Applies and modifies
#      nothing. Added for "gui/*.py" (page_launcher) to highlight (bold) active games in the
#      selection list.

cli_args=("$@")
if_needed=0
_filtered_args=()
for _a in "${cli_args[@]}"; do
  if [[ "${_a}" = "--if-needed" ]]; then
    if_needed=1
  else
    _filtered_args+=("${_a}")
  fi
done
cli_args=("${_filtered_args[@]}")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# --- 0. CLI syntax validation (bin/lpm has no interactive entry point: no menu/Zenity
# selection, only this explicit terminal command) ---
cli_action=""
cli_slugs=()

last_arg="${cli_args[-1]:-}"
if [[ "${last_arg}" = "off" ]] || [[ "${last_arg}" = "on" ]]; then
  cli_action="${last_arg}"
  cli_slugs=("${cli_args[@]:0:$(( ${#cli_args[@]} - 1 ))}")
elif [[ ${#cli_args[@]} -eq 1 ]] && [[ "${cli_args[0]}" = "status" ]]; then
  # See item 7 of the file header: no slug required, read-only.
  cli_action="status"
fi
if [[ -z "${cli_action}" ]]; then
  zgu_cli_error "$(t launcher.cli_usage)"
  exit 1
fi
if [[ "${cli_action}" != "status" ]] && [[ ${#cli_slugs[@]} -eq 0 ]]; then
  zgu_cli_error "$(t launcher.cli_usage)"
  exit 1
fi

zgp_launcher_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

for cmd in python3 sqlite3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_launcher_report_error_early "$(t launcher.cmd_missing "${cmd}")"
    exit 1
  fi
done
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t launcher.pyyaml_missing_cli)"
  exit 1
fi

# --- 1. Flatpak vs native package detection + Lutris path resolution ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
lutris_flatpak_runners_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runners_dir="${HOME}/.local/share/lutris/runners/wine"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_launcher_report_error_early "$(t launcher.lutris_missing)"
  exit 1
fi

if [[ "${version}" = "flatpak" ]]; then
  lutris_db="${lutris_flatpak_db}"
  lutris_config_dir="${lutris_flatpak_config_dir}"
  lutris_system_file="${lutris_flatpak_system_file}"
  lutris_runners_dir="${lutris_flatpak_runners_dir}"
else
  lutris_db="${lutris_package_db}"
  lutris_config_dir="${lutris_package_config_dir}"
  lutris_system_file="${lutris_package_system_file}"
  lutris_runners_dir="${lutris_package_runners_dir}"
fi

if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if [[ ! -f "${lutris_db}" ]]; then
  zgp_launcher_report_error_early "$(t launcher.db_missing "${lutris_db}")"
  exit 1
fi

# --- 2. Enable/disable choice (CLI only) ---
action="${cli_action}"

# --- 3. List of Wine/Proton games, filtered by current state in the YAML ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_launcher_report_error_early "$(t launcher.none_found)"
  exit 0
fi

declare -A name_by_slug dir_by_slug configpath_by_slug
sorted_slugs=()

while IFS=$'\x1f' read -r _g_id g_name g_slug g_dir g_configpath; do
  [[ -z "${g_slug}" ]] && continue
  [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"
  name_by_slug["${g_slug}"]="${g_name}"
  dir_by_slug["${g_slug}"]="${g_dir}"
  configpath_by_slug["${g_slug}"]="${g_configpath}"
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

# Returns 0 (true) if game.exe already points to lpm-launch.bat AND system.prelaunch_command
# is present and active (not just commented/absent) for this game. Checking only "game.exe"
# gave a false positive after reinstalling from a .zgp: the package config keeps "game.exe"
# (rewritten before packaging) but not "system.prelaunch_command" (added separately by
# "lpm launcher ... on", never captured in the .zgp), so the missing hook was never rewritten.
zgp_launcher_is_active() {
  local configpath="$1" yml_file
  [[ -z "${configpath}" ]] && return 1
  yml_file="${lutris_config_dir}/${configpath}.yml"
  [[ -f "${yml_file}" ]] || return 1
  YML_PATH="${yml_file}" python3 -c '
import os, sys, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    exe = (data.get("game") or {}).get("exe") or ""
    prelaunch = (data.get("system") or {}).get("prelaunch_command") or ""
    ok = (
        os.path.basename(exe) == "lpm-launch.bat"
        and prelaunch.rstrip("/\\").endswith("/scripts/lpm-launcher.sh")
    )
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)
' 2>/dev/null
}

declare -A active_by_slug
for g_slug in "${sorted_slugs[@]}"; do
  if zgp_launcher_is_active "${configpath_by_slug[${g_slug}]}"; then
    active_by_slug["${g_slug}"]=1
  fi
done

if [[ "${action}" = "status" ]]; then
  # See item 7 of the file header: plain read, nothing to apply.
  for g_slug in "${sorted_slugs[@]}"; do
    [[ -n "${active_by_slug[${g_slug}]:-}" ]] && echo "${g_slug}"
  done
  exit 0
fi

eligible_slugs=()
for g_slug in "${sorted_slugs[@]}"; do
  if [[ "${action}" = "on" ]]; then
    [[ -z "${active_by_slug[${g_slug}]:-}" ]] && eligible_slugs+=("${g_slug}")
  else
    [[ -n "${active_by_slug[${g_slug}]:-}" ]] && eligible_slugs+=("${g_slug}")
  fi
done

targets=()

# --- Target selection (CLI only) ---
declare -A eligible_lookup
for g_slug in "${eligible_slugs[@]}"; do
  eligible_lookup["${g_slug}"]=1
done

for target_slug in "${cli_slugs[@]}"; do
  if [[ -z "${name_by_slug[${target_slug}]:-}" ]]; then
    zgu_cli_error "$(t launcher.slug_not_found "${target_slug}")"
    exit 1
  fi
  if [[ -z "${eligible_lookup[${target_slug}]:-}" ]]; then
    if [[ "${if_needed}" -eq 1 ]]; then
      # See item 6 of the file header: already in the requested state, the game is just excluded
      # from the targets (no error, no action).
      continue
    fi
    if [[ "${action}" = "on" ]]; then
      zgu_cli_error "$(t launcher.already_active "${target_slug}")"
    else
      zgu_cli_error "$(t launcher.already_inactive "${target_slug}")"
    fi
    exit 1
  fi
  targets+=("${target_slug}")
done

# --- 4. Apply: enable ---
zgp_launcher_apply_on() {
  local slug="$1" game_dir="$2" configpath="$3"
  local yml_file="${lutris_config_dir}/${configpath}.yml"

  if [[ ! -f "${yml_file}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.yml_missing "${slug}")"
    zgu_log "launcher" "ERROR" "slug=${slug} reason=yaml_not_found"
    return 1
  fi

  # Reads the current exe/working_dir/prefix/version and resolves the effective working_dir
  # exactly like Lutris (explicit working_dir, else the exe folder; see Lutris source
  # lutris/runners/wine.py, _get_explicit_working_dir()).
  local current_data
  current_data=$(YML_PATH="${yml_file}" GAME_PATH="${game_dir}" python3 -c '
import os, sys, yaml

with open(os.environ["YML_PATH"], "r") as f:
    data = yaml.safe_load(f) or {}

game = data.get("game") or {}
exe = str(game.get("exe") or "")
if exe and not os.path.isabs(exe):
    exe = os.path.join(os.environ.get("GAME_PATH",""), exe)

working_dir = str(game.get("working_dir") or "")
if not working_dir and exe:
    working_dir = os.path.dirname(exe)

prefix = str(game.get("prefix") or "")
version = str((data.get("wine") or {}).get("version") or "")

if not exe:
    sys.exit(1)

print(exe)
print(working_dir)
print(prefix)
print(version)
' 2>/dev/null)

  if [[ -z "${current_data}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.no_current_exe "${slug}")"
    zgu_log "launcher" "ERROR" "slug=${slug} reason=no_current_exe"
    return 1
  fi

  local current_exe current_workdir current_prefix current_version
  { IFS= read -r current_exe; IFS= read -r current_workdir; IFS= read -r current_prefix; IFS= read -r current_version; } <<< "${current_data}"

  [[ -z "${current_prefix}" ]] && current_prefix="${game_dir}"

  # Linux -> Windows path conversion. A path inside "<prefix>/drive_c" is converted by plain
  # text replacement ("<prefix>/drive_c/Games/x.exe" -> "C:\Games\x.exe"): no Wine process is
  # started (winepath would start wineserver and could pop up a Wine window, e.g. "updating the
  # prefix", just to write a YAML file). Same rule as zgl-launcher-entries.sh.
  # "winepath" is only the fallback for a path outside drive_c (other drive letter): first the
  # one next to the wine binary of the runner used by this game, else a generic one from PATH.
  local drive_c_root="${current_prefix%/}/drive_c"
  local winepath_bin="" winepath_resolved=0

  zgp_launcher_to_windows_path() {
    local linux_path="$1" rel
    if [[ "${linux_path}" = "${drive_c_root}" ]]; then
      printf 'C:\\\n'
      return 0
    fi
    if [[ "${linux_path}" = "${drive_c_root}/"* ]]; then
      rel="${linux_path#"${drive_c_root}"/}"
      printf 'C:\\%s\n' "${rel//\//\\}"
      return 0
    fi
    if [[ "${winepath_resolved}" -eq 0 ]]; then
      winepath_resolved=1
      local wine_bin
      wine_bin=$(zgu_get_wine_binary "${lutris_runners_dir}" "${current_version}" 2>/dev/null)
      if [[ -n "${wine_bin}" ]] && [[ -x "$(dirname "${wine_bin}")/winepath" ]]; then
        winepath_bin="$(dirname "${wine_bin}")/winepath"
      elif command -v winepath >/dev/null 2>&1; then
        winepath_bin="winepath"
      fi
    fi
    [[ -n "${winepath_bin}" ]] || return 1
    WINEPREFIX="${current_prefix}" "${winepath_bin}" -w "${linux_path}" 2>/dev/null | tr -d '\r'
  }

  local win_exe="" win_workdir=""
  win_exe=$(zgp_launcher_to_windows_path "${current_exe}")
  win_workdir=$(zgp_launcher_to_windows_path "${current_workdir}")

  if [[ -z "${win_exe}" ]] || [[ -z "${win_workdir}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.winepath_failed "${slug}")"
    zgu_log "launcher" "ERROR" "slug=${slug} reason=winepath_failed"
    return 1
  fi

  # FIXED location of lpm-launch.bat, INSIDE drive_c (never the root of $GAMEDIR). Lutris runs
  # a ".bat" via "cmd /C <name>" with the .bat folder as process working directory; a folder
  # outside drive_c (e.g. the prefix root) is only reachable from Wine if the prefix has a Z:
  # drive (mapping of "/"), often missing in per-game isolated prefixes, and the game then
  # does not start at all.
  #
  # Chosen root: the direct subfolder of "drive_c/Games/" containing the exe (at its root or in
  # any of its subfolders, whatever the depth); NOT "working_dir" (may be unset, and not
  # necessarily that root) nor "dirname(exe)" (may be arbitrarily deep). Example: exe in
  #   drive_c/Games/Jeu/sous/sous/sous/sous/sous/exe
  # with another folder "drive_c/Games/Truc" beside it: the ".bat" goes in
  #   drive_c/Games/Jeu/lpm-launch.bat
  # i.e. the first level under "Games/" leading to the exe, never deeper. "Games/" is the
  # standard install folder used by Lutris/lpm installers.
  local drive_c games_root bat_dir bat_path_linux
  drive_c="${current_prefix}/drive_c"
  games_root="${drive_c}/Games"

  if [[ "${current_exe}" = "${games_root}/"* ]]; then
    local rel_to_games top_component
    rel_to_games="${current_exe#"${games_root}"/}"
    top_component="${rel_to_games%%/*}"
    bat_dir="${games_root}/${top_component}"
  else
    # Fallback: install outside the drive_c/Games/<game>/... convention, so the rule above
    # cannot apply. Uses "current_workdir" (resolved above: explicit config working_dir, else
    # dirname(exe)), and logs it.
    bat_dir="${current_workdir}"
    zgu_log "launcher" "WARN" "slug=${slug} reason=exe_outside_games_convention bat_dir=${bat_dir}"
  fi

  bat_path_linux="${bat_dir}/lpm-launch.bat"

  # Writes lpm-launch.bat NOW, at activation, not only at the first real launch
  # (zgl-launcher-runtime.sh rewrites it anyway with the chosen entry). Required: "game.exe"
  # is pointed to this path below, in this same activation; if the file does not exist yet,
  # Lutris reports it missing/misbehaves before the first launch. Same content as the template
  # of zgl-launcher-runtime.sh, with the default auto-filled entry (win_workdir/win_exe,
  # resolved above).
  mkdir -p "${bat_dir}" 2>/dev/null
  {
    printf '@echo off\r\n'
    printf 'cd /d "%s"\r\n' "${win_workdir}"
    printf 'start "" "%s"\r\n' "${win_exe}"
  } > "${bat_path_linux}" 2>/dev/null

  # --- Write lpm-launcher.yml (auto-filled entry + commented example) --
  # ONLY if it does not exist yet. "off" deletes it (item 4 of the file header), so a file
  # that exists here comes from a hand edit or a restored .zgp; overwriting it on "on" would
  # lose that customization, including on a repair re-enable after a reinstall that dropped
  # system.prelaunch_command (see zgp_launcher_is_active above). ---
  if [[ ! -f "${game_dir}/lpm-launcher.yml" ]]; then
    local default_label
    default_label="$(t launcher.default_entry_label)"

    YML_PATH="${game_dir}/lpm-launcher.yml" TITLE="${name_by_slug[${slug}]}" PROMPT="$(t launcher.default_prompt)" \
      LABEL="${default_label}" WORKDIR="${win_workdir}" EXE="${win_exe}" ORIGINAL_EXE="${current_exe}" \
      BAT_PATH_LINUX="${bat_path_linux}" python3 -c '
import os, yaml

data = {
    "title": os.environ["TITLE"],
    "prompt": os.environ["PROMPT"],
    "original_exe": os.environ["ORIGINAL_EXE"],
    "bat_path": os.environ["BAT_PATH_LINUX"],
    "entries": [
        {"label": os.environ["LABEL"], "workdir": os.environ["WORKDIR"], "exe": os.environ["EXE"]},
    ],
}
with open(os.environ["YML_PATH"], "w") as f:
    yaml.dump(data, f, sort_keys=False, allow_unicode=True)
' 2>/dev/null
    if [[ $? -ne 0 ]]; then
      zgp_launcher_report_error_early "$(t launcher.yaml_write_failed "${slug}")"
      zgu_log "launcher" "ERROR" "slug=${slug} reason=yaml_write_failed"
      return 1
    fi

    {
      echo "# $(t launcher.example_entry_comment)"
      echo "#  - label: \"$(t launcher.example_entry_label)\""
      echo "#    workdir: \"C:\\\\Games\\\\...\""
      echo "#    exe: \"C:\\\\Games\\\\...\\\\game.exe\""
    } >> "${game_dir}/lpm-launcher.yml"
  else
    # lpm-launcher.yml already exists (hand-written, restored from a .zgp, or left by an
    # earlier "off"). Its entries are kept, but the two keys lpm itself relies on are brought
    # up to date:
    #  - "bat_path": where Lutris REALLY runs lpm-launch.bat (the one just written above). Both
    #    keys hold absolute Linux paths, so they are also wrong after an import on another
    #    machine. Without it, the runtime falls back to "<game>/lpm-launch.bat", rewrites THAT
    #    file with the chosen entry, while Lutris keeps running the other one (always the
    #    default entry: the picker seems to ignore the choice).
    #  - "original_exe": the exe to restore on "off". Only set when game.exe does not already
    #    point to an lpm-launch.bat (then the real original exe is unknown and an existing
    #    value is never overwritten with the .bat).
    # Comment lines at the end of the file are kept.
    YML_PATH="${game_dir}/lpm-launcher.yml" ORIGINAL_EXE="${current_exe}" \
      BAT_PATH_LINUX="${bat_path_linux}" python3 -c '
import os, yaml

path = os.environ["YML_PATH"]
with open(path, "r") as f:
    text = f.read()
data = yaml.safe_load(text)
if not isinstance(data, dict):
    raise SystemExit(1)

changed = False
if data.get("bat_path") != os.environ["BAT_PATH_LINUX"]:
    data["bat_path"] = os.environ["BAT_PATH_LINUX"]
    changed = True
original = os.environ["ORIGINAL_EXE"]
if os.path.basename(original) != "lpm-launch.bat" and data.get("original_exe") != original:
    data["original_exe"] = original
    changed = True

if changed:
    comments = [l for l in text.splitlines() if l.lstrip().startswith("#")]
    out = yaml.dump(data, sort_keys=False, allow_unicode=True, width=1000000)
    if comments:
        out += "\n".join(comments) + "\n"
    with open(path, "w") as f:
        f.write(out)
' 2>/dev/null
    if [[ $? -ne 0 ]]; then
      zgp_launcher_report_error_early "$(t launcher.yaml_write_failed "${slug}")"
      zgu_log "launcher" "ERROR" "slug=${slug} reason=yaml_update_failed"
      return 1
    fi
  fi

  # --- scripts/ folder ---
  #
  # No default splash image is copied here: with the orchestrator
  # (lib/zgl-launcher-orchestrator.sh), a missing "${game_dir}/splash/splash.png" explicitly
  # means "plain black loading screen". The splash/ folder itself is no longer created either:
  # the orchestrator creates it when the user drops a real image there. An existing splash.png
  # (custom, or splash/ of a game enabled earlier) is never touched or deleted by "lpm launcher
  # ... on".
  mkdir -p "${game_dir}/scripts"

  cat > "${game_dir}/scripts/lpm-launcher.sh" <<EOF
#!/bin/bash
# Relay generated by "lpm launcher" -- do not edit by hand, it is rewritten on every
# (re)activation. The real logic lives in the lpm installation.
#
# This relay always lives under HOME, so it stays visible inside a Flatpak Lutris sandbox,
# which does not share "/usr" by default. The real script ("${script_dir}/
# zgl-launcher-runtime.sh") may be invisible there when lpm is installed under /usr, even
# with the "host"/"host-os" permission: that permission does not replace the sandbox "/usr"
# (always the Flatpak runtime's), it exposes the host "/usr" at "/run/host/usr" instead
# (documented Flatpak behaviour). So try the direct path, then that second one, before giving up.
# If neither works, write a line straight to lpm.log (same format as zgu_log, without relying on
# the unreachable lpm installation) so "lpm log --grep launcher-runtime" says the picker could
# not be shown, and why.
# s'afficher, et pourquoi.
runtime_script=""
for candidate in "${script_dir}/zgl-launcher-runtime.sh" "/run/host${script_dir}/zgl-launcher-runtime.sh"; do
  if [[ -r "\${candidate}" ]]; then
    runtime_script="\${candidate}"
    break
  fi
done

if [[ -z "\${runtime_script}" ]]; then
  # Hardcoded path under HOME, never via XDG_DATA_HOME: a Flatpak Lutris redefines that
  # variable to its private data dir, so the line would land in a file "lpm log" never reads.
  # lpm.log must stay in the same place whether written from a normal shell or a Flatpak sandbox.
  log_dir="\${HOME}/.local/share/lpm"
  mkdir -p "\${log_dir}" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' \
    "\$(date +%FT%T%z 2>/dev/null)" "launcher-runtime" "ERROR" \
    "gamedir=${game_dir} reason=runtime_not_found_in_sandbox script_dir=${script_dir}" \
    >> "\${log_dir}/lpm.log" 2>/dev/null
  # No GUI notification here: the failure is already logged above, and this relay must never
  # block the game from starting over a problem it cannot reliably display (zenity itself may
  # be unreachable in exactly this case).
  exit 0
fi

exec bash "\${runtime_script}" "${game_dir}"
EOF
  chmod +x "${game_dir}/scripts/lpm-launcher.sh"

  # --- Wiring into the Lutris config: game.exe + system.prelaunch_command ---
  #
  # NO "bash" before the relay path: the file is already executable (chmod +x above) and has
  # its own shebang.
  #
  # "prelaunch_wait: true" is REQUIRED: by default (absent), Lutris runs prelaunch_command IN THE
  # BACKGROUND and immediately goes on with the real launch, in parallel (see Lutris source,
  # lutris/game.py start_prelaunch_command(), and lutris/sysoptions.py where "prelaunch_wait"
  # has default=False). Without it, Wine may run lpm-launch.bat before this script has finished
  # writing it, which made the game unplayable at the very first launch.
# Line-based text editing (zgu-yaml-edit.py): yaml.dump would destroy the Lutris YAML comments,
# including hooks disabled by LPM ("# lpm:hook-disabled"). Falls back to the full rewrite
# below if targeted editing is not possible.
if {
  yaml_edit_py="${script_dir}/zgu-yaml-edit.py"
  python3 "${yaml_edit_py}" "${yml_file}" set game exe "${bat_path_linux}" &&
  python3 "${yaml_edit_py}" "${yml_file}" set system prelaunch_command "${game_dir}/scripts/lpm-launcher.sh" &&
  python3 "${yaml_edit_py}" "${yml_file}" set system prelaunch_wait true --bool
} >/dev/null 2>&1; then
  :
else
  YML_PATH="${yml_file}" BAT_PATH="${bat_path_linux}" \
    PRELAUNCH="${game_dir}/scripts/lpm-launcher.sh" python3 -c '
import os, yaml

yml_path = os.environ["YML_PATH"]
with open(yml_path, "r") as f:
    data = yaml.safe_load(f) or {}

if "game" not in data or not isinstance(data.get("game"), dict):
    data["game"] = {}
data["game"]["exe"] = os.environ["BAT_PATH"]

if "system" not in data or not isinstance(data.get("system"), dict):
    data["system"] = {}
data["system"]["prelaunch_command"] = os.environ["PRELAUNCH"]
data["system"]["prelaunch_wait"] = True

with open(yml_path, "w") as f:
    yaml.dump(data, f, sort_keys=False)
' 2>/dev/null
fi
  if [[ $? -ne 0 ]]; then
    zgp_launcher_report_error_early "$(t launcher.yaml_patch_failed "${slug}")"
    zgu_log "launcher" "ERROR" "slug=${slug} reason=lutris_yaml_patch_failed"
    return 1
  fi

  zgu_log "launcher" "OK" "slug=${slug} action=on"

  # The path of lpm-launcher.yml to edit by hand is already given by zgu_cli_ok in the calling
  # loop; no folder-opening offer via Zenity here (bin/lpm has no interactive entry point).

  # --- Flatpak Lutris: permission reminder, best-effort ---
  #
  # A Flatpak Lutris runs in a sandbox that may NOT see "/usr/lib/lpm" (or wherever the running
  # lpm is installed). Without the right permission, the relay ($GAMEDIR/scripts/lpm-launcher.sh,
  # always visible under $HOME) cannot reach the runtime script (the relay logs this case in
  # lpm.log, see above).
  #
  # IMPORTANT ("Not sharing "/usr/lib/lpm" with sandbox: Path "/usr" is reserved by Flatpak"):
  # Flatpak always refuses a precise "--filesystem=<path>" under /usr, even after an "override"
  # that seems to succeed (only the actual mount at launch is refused). With lpm under /usr
  # (default of install.sh, /usr/local/lib/lpm), a "--filesystem=${script_dir}:ro" reminder is
  # ineffective; the only permission that works for a path under /usr is the broad
  # "host"/"host-os" (it mounts the real host system as-is). So: if lpm is installed under
  # /usr, ask/apply "host-os"; otherwise (non-standard install outside /usr) the precise path
  # is enough and more restrictive, hence preferred. Informational reminder, never blocking.
  if [[ "${version}" = "flatpak" ]] && command -v flatpak >/dev/null 2>&1; then
    local fp_perms="" fp_ok=false fp_needs_hostos=false
    fp_perms=$(flatpak info --show-permissions net.lutris.Lutris 2>/dev/null)
    case "${script_dir}" in
      /usr/*) fp_needs_hostos=true ;;
    esac
    if printf '%s' "${fp_perms}" | grep -Eq "filesystems=.*host(-os)?(:ro)?(;|$)"; then
      fp_ok=true
    elif [[ "${fp_needs_hostos}" = false ]] && printf '%s' "${fp_perms}" | grep -qF "${script_dir}"; then
      fp_ok=true
    fi
    if [[ "${fp_ok}" = false ]]; then
      # Offer to apply it ourselves instead of only printing the command: the user confirms and
      # lpm runs "flatpak override". Falls back to the manual reminder if refused or if no
      # interactive terminal is available.
      local flatpak_question apply_now=false
      if [[ "${fp_needs_hostos}" = true ]]; then
        flatpak_question="$(t launcher.flatpak_permission_question_hostos "${script_dir}")"
      else
        flatpak_question="$(t launcher.flatpak_permission_question "${script_dir}")"
      fi

      if [[ -t 0 ]]; then
        echo "${flatpak_question}" >&2
        local reponse=""
        read -r -p "[o/N] " reponse </dev/tty 2>/dev/null
        [[ "${reponse,,}" =~ ^(o|oui|y|yes)$ ]] && apply_now=true
      fi

      if [[ "${apply_now}" = true ]]; then
        local override_target="${script_dir}"
        [[ "${fp_needs_hostos}" = true ]] && override_target="host-os"
        if flatpak override --user net.lutris.Lutris --filesystem="${override_target}:ro" >/dev/null 2>&1; then
          local ok_msg
          ok_msg="$(t launcher.flatpak_permission_applied_ok)"
          echo "${ok_msg}" >&2
          zgu_log "launcher" "OK" "slug=${slug} action=flatpak_override_applied target=${override_target}"
        else
          local fail_msg
          if [[ "${fp_needs_hostos}" = true ]]; then
            fail_msg="$(t launcher.flatpak_permission_applied_fail_hostos)"
          else
            fail_msg="$(t launcher.flatpak_permission_applied_fail "${script_dir}")"
          fi
          echo "${fail_msg}" >&2
          zgu_log "launcher" "ERROR" "slug=${slug} reason=flatpak_override_failed target=${override_target}"
        fi
      else
        local flatpak_hint
        if [[ "${fp_needs_hostos}" = true ]]; then
          flatpak_hint="$(t launcher.flatpak_permission_hint_hostos "${script_dir}")"
        else
          flatpak_hint="$(t launcher.flatpak_permission_hint "${script_dir}")"
        fi
        echo "${flatpak_hint}" >&2
      fi
    fi
  fi

  return 0
}

# --- 5. Apply: disable ---
zgp_launcher_apply_off() {
  local slug="$1" game_dir="$2" configpath="$3"
  local yml_file="${lutris_config_dir}/${configpath}.yml"
  local launcher_yml="${game_dir}/lpm-launcher.yml"

  if [[ ! -f "${launcher_yml}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.launcher_yml_missing "${slug}")"
    zgu_log "launcher" "ERROR" "slug=${slug} reason=lpm_launcher_yml_not_found"
    return 1
  fi

  local original_exe
  original_exe=$(YML_PATH="${launcher_yml}" python3 -c '
import os, yaml
with open(os.environ["YML_PATH"], "r") as f:
    data = yaml.safe_load(f) or {}
print(data.get("original_exe") or "")
' 2>/dev/null)

  if [[ -z "${original_exe}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.no_original_exe "${slug}")"
    zgu_log "launcher" "ERROR" "slug=${slug} reason=original_exe_missing"
    return 1
  fi

# Line-based text editing (zgu-yaml-edit.py), see zgp_launcher_apply_on above.
if {
  yaml_edit_py="${script_dir}/zgu-yaml-edit.py"
  python3 "${yaml_edit_py}" "${yml_file}" set game exe "${original_exe}" &&
  current_prelaunch=$(YML_PATH="${yml_file}" python3 -c '
import os, yaml
with open(os.environ["YML_PATH"], "r") as f:
    data = yaml.safe_load(f) or {}
system = data.get("system")
print(str(system.get("prelaunch_command") or "") if isinstance(system, dict) else "")
') &&
  if [[ "${current_prelaunch}" == *"scripts/lpm-launcher.sh"* ]]; then
    python3 "${yaml_edit_py}" "${yml_file}" unset system prelaunch_command &&
    python3 "${yaml_edit_py}" "${yml_file}" unset system prelaunch_wait
  fi
} >/dev/null 2>&1; then
  :
else
  YML_PATH="${yml_file}" ORIGINAL_EXE="${original_exe}" RELAY_MARKER="scripts/lpm-launcher.sh" python3 -c '
import os, yaml

yml_path = os.environ["YML_PATH"]
with open(yml_path, "r") as f:
    data = yaml.safe_load(f) or {}

if "game" not in data or not isinstance(data.get("game"), dict):
    data["game"] = {}
data["game"]["exe"] = os.environ["ORIGINAL_EXE"]

system = data.get("system")
if isinstance(system, dict):
    current = str(system.get("prelaunch_command") or "")
    if os.environ["RELAY_MARKER"] in current:
        system.pop("prelaunch_command", None)
        system.pop("prelaunch_wait", None)

with open(yml_path, "w") as f:
    yaml.dump(data, f, sort_keys=False)
' 2>/dev/null
fi
  if [[ $? -ne 0 ]]; then
    zgp_launcher_report_error_early "$(t launcher.yaml_patch_failed "${slug}")"
    zgu_log "launcher" "ERROR" "slug=${slug} reason=lutris_yaml_patch_failed"
    return 1
  fi

  # --- Removal of the files the LPM Launcher itself added (only AFTER the Lutris config was
  # restored above). Exactly these, by name, nothing else:
  #   <game dir>/lpm-launcher.yml, <game dir>/scripts/lpm-launcher.sh,
  #   every "lpm-launch.bat" (the one named by "bat_path", the one at the root of the game
  #   folder, and the ones in <game dir>/drive_c/Games/*/), and the temporary
  #   .lpm-launcher-choice.
  # Never touched: the game files, anything else inside the prefix (Windows files), splash/
  # and the other files of scripts/ (loading screen: lpm-winetrace*), which are not the
  # launcher's. "scripts/" is removed only if it ends up empty (rmdir). ---
  local bat_in_yml bat_file
  bat_in_yml=$(YML_PATH="${launcher_yml}" python3 -c '
import os, yaml
with open(os.environ["YML_PATH"], "r") as f:
    data = yaml.safe_load(f) or {}
print(data.get("bat_path") or "")
' 2>/dev/null)

  for bat_file in "${bat_in_yml}" "${game_dir}/lpm-launch.bat" "${game_dir}"/drive_c/Games/*/lpm-launch.bat; do
    [[ -n "${bat_file}" ]] || continue
    [[ "$(basename "${bat_file}")" = "lpm-launch.bat" ]] || continue
    [[ -f "${bat_file}" ]] && rm -f -- "${bat_file}"
  done
  rm -f -- "${game_dir}/scripts/lpm-launcher.sh" "${game_dir}/.lpm-launcher-choice" "${launcher_yml}"
  rmdir "${game_dir}/scripts" 2>/dev/null

  zgu_log "launcher" "OK" "slug=${slug} action=off"
  return 0
}

exit_code=0
n_ok=0
for target_slug in "${targets[@]}"; do
  if [[ "${action}" = "on" ]]; then
    if zgp_launcher_apply_on "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}"; then
      n_ok=$(( n_ok + 1 ))
      zgu_cli_ok "$(t launcher.done_one_on_cli "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}/lpm-launcher.yml")"
    else
      exit_code=1
    fi
  else
    if zgp_launcher_apply_off "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}"; then
      n_ok=$(( n_ok + 1 ))
      zgu_cli_ok "$(t launcher.done_one_off_cli "${name_by_slug[${target_slug}]}")"
    else
      exit_code=1
    fi
  fi
done

exit "${exit_code}"
