#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# File descriptor 3 = copy of the script's REAL stdout (what the GUI/terminal reads), taken once
# here before any pipe. Needed for the "[PROGRESS] <pct>" lines emitted during extraction:
# inside "pv | bsdtar", fd 1 is the next command's input, so writing there would mix text into
# the archive data sent to bsdtar and corrupt the extraction.
exec 3>&1

# --- Arguments passed by bin/lpm ---
# $1 = mode (always "cli"; kept for consistency with the other lib/ scripts, value unused here)
# $2 = confirm_flag ("yes" if -y)
# $3 = allow_scripts_flag ("yes" if --allow-scripts)
# $4 = ignore_hash_flag ("yes" if --ignore-hash)
# $5+ = targets (.zgp files), plus these options recognized anywhere among them:
#   -s, --shortcut=<menu|desktop|both|none>   shortcuts to create (default "both")
#   --desktop-dir=<path>                      folder for the desktop shortcut, instead of the one from
#                                             zgu_get_desktop_dir() (no effect with shortcut_mode "menu"/"none")
#   -n, --no-loadingscreen                    disable the lpm loading screen for the created shortcut(s)
#                                             (default enabled; see zgl-launcher-orchestrator.sh; no effect
#                                             with shortcut_mode "none")
shift || true
confirm_flag="${1:-}"
shift || true
allow_scripts_flag="${1:-}"
shift || true
ignore_hash_flag="${1:-}"
shift || true

shortcut_mode="both"
desktop_dir_override=""
loadingscreen_enabled=true
cli_targets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--shortcut)
      shortcut_mode="${2:-both}"
      shift $(( $# >= 2 ? 2 : 1 ))
      ;;
    --shortcut=*)
      shortcut_mode="${1#--shortcut=}"
      shift
      ;;
    --desktop-dir=*)
      desktop_dir_override="${1#--desktop-dir=}"
      shift
      ;;
    -n|--no-loadingscreen)
      loadingscreen_enabled=false
      shift
      ;;
    *)
      cli_targets+=("$1")
      shift
      ;;
  esac
done

case "${shortcut_mode}" in
  menu | desktop | both | none) ;;
  *)
    zgu_cli_error "$(t install_game.invalid_shortcut_mode_cli "${shortcut_mode}")"
    exit 1
    ;;
esac

# Path configuration
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

# Wine/Proton builds directory: zgu_write_game_shortcut checks for "toolmanifest.vdf" there
# (same test as umu-run) to tell a Proton runner from plain Wine. See zgu-desktop-utils.sh.
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

games_dir="${HOME}/Games"

# 1. Dependency check
# sqlite3, pv and bsdtar are always required. bsdtar (package "libarchive-tools" on
# Debian/Ubuntu) replaces GNU tar: by default it refuses archive members that escape the
# destination via "../" or a malicious symlink (SECURE_NODOTDOT / SECURE_SYMLINKS). A .zgp may
# come from an untrusted third party, so this must apply at extraction time. bsdtar reads zstd
# natively, so zstd is not a separate dependency.
for cmd in sqlite3 pv bsdtar; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    t install_game.cmd_missing "${cmd}"
    exit 1
  fi
done

# python3 itself is checked separately from PyYAML so the user gets the message matching the
# real cause.
if ! command -v python3 >/dev/null 2>&1; then
  t install_game.cmd_missing "python3"
  exit 1
fi

# PyYAML is used to read/write the embedded YAML (zgp-game-config.yml).
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t install_game.pyyaml_missing_cli)"
  exit 1
fi

# 2. Close Lutris first to release the database
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Detect Flatpak vs native package (function from zgu-lutris-utils.sh; also handles both
# being installed)
version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  t install_game.lutris_missing_cli
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_db="${lutris_flatpak_db}"
    lutris_system_file="${lutris_flatpak_system_file}"
    runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  package)
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_db="${lutris_package_db}"
    lutris_system_file="${lutris_package_system_file}"
    runner_dir="${lutris_package_runner_dir}"
    ;;
  *)
    # Should never happen: $version is only set to "flatpak" or "package" above (otherwise
    # exit 1). Safeguard in case that invariant changes.
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

# Custom Games path (if set in Lutris): this global preference lives in system.yml under
# "system: game_path:", not in runners/wine.yml. The awk matches any "game_path:" line
# regardless of indentation or parent key.
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  if [[ -n "${extracted_path}" ]]; then
    games_dir="${extracted_path}"
  fi
fi

mkdir -p "${lutris_config_dir}"
mkdir -p "$(dirname "${lutris_db}")"
mkdir -p "${games_dir}"

# ---------------------------------------------------------------------------------------------

games_to_install=()
declare -A filepath_by_name
create_menu=false
create_desktop=false
# Loading screen (see lib/zgl-launcher-orchestrator.sh): "loadingscreen_enabled" is already
# resolved above from -n/--no-loadingscreen.

# Strict CLI mode only: bin/lpm has no interactive entry point.
if [[ ${#cli_targets[@]} -eq 0 ]]; then
  zgu_cli_error "$(t common.missing_target_cli "lpm install")"
  exit 1
fi

for target in "${cli_targets[@]}"; do
  if [[ -f "${target}" ]]; then
    filename=$(basename "${target}" .zgp)
    games_to_install+=("${filename}")
    filepath_by_name["${filename}"]="${target}"
  else
    zgu_cli_error "$(t install_game.file_not_found "${target}")"
    exit 1
  fi
done

# Interactive confirmation when -y is absent
if [[ "${confirm_flag}" != "yes" ]]; then
  t install_game.confirm_cli_header
  for name in "${games_to_install[@]}"; do
    t install_game.confirm_cli_item "${name}" "${filepath_by_name[${name}]}"
  done
  read -r -p "$(t install_game.confirm_cli_prompt)" response || response="n"  # EOF (no terminal) = cancel, never an implicit confirmation
  case "${response}" in
    [nN])
      t install_game.cancelled_cli
      exit 0
      ;;
    *)
      ;;
  esac
fi

# Resolve "shortcut_mode" (see -s/--shortcut above) into the two booleans expected by
# zgu_write_game_shortcut. Its validity was already checked, so there is no "*)" case.
case "${shortcut_mode}" in
  both) create_menu=true; create_desktop=true ;;
  menu) create_menu=true; create_desktop=false ;;
  desktop) create_menu=false; create_desktop=true ;;
  none) create_menu=false; create_desktop=false ;;
esac

# --- Integrity check (sha256) of the whole batch, before any extraction ---
#
# Done once per batch, after games_to_install is final. Nothing is touched until this block has
# decided which games remain.
if [[ "${ignore_hash_flag}" != "yes" ]]; then
  hash_mismatch_names=()
  for name in "${games_to_install[@]}"; do
    filepath="${filepath_by_name[${name}]}"
    if hash_file=$(zgu_find_hash_sidecar "${filepath}"); then
      zgu_verify_archive_hash "${filepath}" "${hash_file}" || hash_mismatch_names+=("${name}")
    fi
  done

  if [[ ${#hash_mismatch_names[@]} -gt 0 ]]; then
    zgu_cli_error "$(t install_game.hash_mismatch_cli_header)"
    for name in "${hash_mismatch_names[@]}"; do
      zgu_cli_error "$(t install_game.hash_mismatch_cli_item "${name}")"
    done
    read -r -p "$(t install_game.hash_mismatch_cli_prompt)" hash_response
    case "${hash_response}" in
      [yY])
        : # install anyway; games_to_install is left unchanged
        ;;
      *)
        declare -A hash_excluded
        for name in "${hash_mismatch_names[@]}"; do
          hash_excluded["${name}"]=1
        done
        hash_filtered_games=()
        for name in "${games_to_install[@]}"; do
          [[ -n "${hash_excluded[${name}]:-}" ]] || hash_filtered_games+=("${name}")
        done
        games_to_install=("${hash_filtered_games[@]}")
        ;;
    esac
  fi
fi

if [[ ${#games_to_install[@]} -eq 0 ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------------------------

install_idx=0
# Computed before the loop: needed from the first game to display "[n/total]".
install_total_count=${#games_to_install[@]}
# Count of real successes, so the final notify-send reflects what was actually installed. Kept
# in a file rather than a shell variable so it survives if run_post_install is ever called from
# a subshell.
install_success_file=$(mktemp)

# --- Cancellation (SIGTERM/SIGINT sent by the GUI "Cancel" button to the whole process group):
# removes ONLY the game being installed (temp extraction, or a moved prefix not yet finished,
# including Lutris entry, YAML config and menu/desktop shortcuts). Completed games of the batch
# are never touched here (the GUI then offers to uninstall them via "lpm uninstall"), and the
# .zgp is never deleted. A pre-existing prefix is never affected, since installation refuses any
# game whose folder already exists ("deja_installe"). Exit code 130 + "[CANCELLED]" line.
inprogress_prefix=""
inprogress_slug=""
temp_extract_dir=""

lpm_cancel_cleanup() {
  trap '' TERM INT
  if [[ -n "${temp_extract_dir}" ]] && [[ "${temp_extract_dir}" == "${games_dir}/.zgp-extract-"* ]]; then
    rm -rf "${temp_extract_dir}"
  fi
  if [[ -n "${inprogress_prefix}" ]] && [[ -n "${inprogress_slug}" ]]; then
    real_games_dir=$(realpath -e "${games_dir}" 2>/dev/null)
    real_prefix=$(realpath -e "${inprogress_prefix}" 2>/dev/null)
    if [[ -n "${real_games_dir}" ]] && [[ -n "${real_prefix}" ]] && [[ "${real_prefix}" == "${real_games_dir}/"* ]]; then
      rm -rf "${real_prefix}"
    fi
    safe_cancel_slug="${inprogress_slug//\'/\'\'}"
    sqlite3 "${lutris_db}" "DELETE FROM games WHERE slug='${safe_cancel_slug}';" 2>/dev/null
    rm -f "${lutris_config_dir}/${inprogress_slug}-"*.yml
    rm -f "${HOME}/.local/share/applications/net.lutris.${inprogress_slug}.desktop"
    cancel_desktop_dir="${desktop_dir_override:-$(zgu_get_desktop_dir)}"
    rm -f "${cancel_desktop_dir}/${inprogress_slug}.desktop"
    if [[ -n "${game_real_name:-}" ]]; then
      rm -f "${cancel_desktop_dir}/${game_real_name} $(t install_game.bonus_folder_suffix)"
    fi
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
    zgu_log "install" "INFO" "slug=${inprogress_slug} reason=cancelled_cleaned_up"
  fi
  rm -f "${install_success_file}"
  echo "[CANCELLED]"
  t install_game.cancelled_run_cli
  exit 130
}
trap lpm_cancel_cleanup TERM INT

# Process each selected game
for name in "${games_to_install[@]}"; do
  install_idx=$((install_idx + 1))
  filepath="${filepath_by_name[${name}]}"

  # 1. Extract into a temp folder directly inside $games_dir (guarantees an instant rename)
  temp_extract_dir=$(mktemp -d "${games_dir}/.zgp-extract-XXXXXX")
  file_size=$(stat -c %s "${filepath}" 2>/dev/null || stat -f %z "${filepath}" 2>/dev/null)

  # "[n/total] ..." is parsed by the GUI (CommandPage.run_command in gui/*.py) to show which
  # game out of how many in the progress text; same convention as zgp-game-uninstaller.sh.
  t install_game.progress_cli "${install_idx}" "${install_total_count}" "$(basename -- "${filepath}")"
  # bsdtar rather than tar -I zstd: see the dependency check above for the
  # SECURE_NODOTDOT/SECURE_SYMLINKS protections.
  # umask 022 during extraction: without "--no-same-permissions", bsdtar keeps the archive's
  # permission bits, so a forged .zgp could plant a world-writable (777) file in the games
  # folder, or an unreadable (000) one to sabotage the install.
  _lpm_old_umask=$(umask)
  umask 022
  # "pv -n" emits the extracted percentage as a number on STDERR, leaving stdout intact to
  # carry the archive data to bsdtar. pv's stderr is redirected (2>) to a process substitution
  # ">(...)" that rereads each percentage and reprints it as "[PROGRESS] <pct>" to fd 3 (see
  # "exec 3>&1" at the top), not stdout, which here is already piped to bsdtar. Same mechanism
  # in zgr-runner-installer.sh.
  pv -n -s "${file_size:-0}" "${filepath}" 2> >(while IFS= read -r _lpm_pct; do
    printf '[PROGRESS] %s\n' "${_lpm_pct}" >&3
  done) | bsdtar -xf - -C "${temp_extract_dir}"
  # PIPESTATUS[1] = bsdtar's exit code (only "pv" and "bsdtar" are in the "|" pipe; the
  # process substitution on stderr is not).
  tar_exit="${PIPESTATUS[1]}"
  umask "${_lpm_old_umask}"

  # 1bis. Verify the extraction: if tar failed (corrupt, truncated or invalid archive), abort
  # this game cleanly without touching Lutris or creating shortcuts
  if [[ "${tar_exit}" -ne 0 ]]; then
    err_msg="$(t install_game.corrupt_archive "${name}" "${tar_exit}")"
    echo "${err_msg}" >&2
    zgu_log "install" "ERROR" "file=${name} reason=corrupt_archive code=${tar_exit}"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  # 2. Find the real slug from what was actually extracted
  # find + head rather than "ls -1 | head -n 1" (SC2012); the real protection against
  # pathological file names comes from the checks below (-d, anti-symlink, realpath).
  slug=$(basename "$(find "${temp_extract_dir}" -mindepth 1 -maxdepth 1 | head -n 1)")
  if [[ -z "${slug}" ]] || [[ ! -d "${temp_extract_dir}/${slug}" ]]; then
    zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
    zgu_log "install" "ERROR" "file=${name} reason=slug_not_found"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  # 2bis. Anti-traversal hardening: a .zgp may come from an untrusted third party. A symlink
  # named like a top-level entry (e.g. pointing to /etc or $HOME) would pass the "-d" test
  # above while pointing outside $temp_extract_dir, so any symlink is refused and the resolved
  # real path must also be a direct child of $temp_extract_dir.
  if [[ -L "${temp_extract_dir}/${slug}" ]]; then
    zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
    zgu_log "install" "ERROR" "file=${name} reason=slug_symlink"
    rm -rf "${temp_extract_dir}"
    continue
  fi
  # shellcheck disable=SC2249 # reject filter, not a dispatch: a slug that matches none of
  # these dangerous patterns continues normally below, as intended.
  case "${slug}" in
    */*|.|..)
      zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
      zgu_log "install" "ERROR" "file=${name} reason=slug_path_traversal"
      rm -rf "${temp_extract_dir}"
      continue
      ;;
  esac

  # Reject any control character (newline, CR...) in the slug: a Linux folder name may legally
  # contain them, and the slug is the fallback for icon_path, which is injected as-is into the
  # generated .desktop ("Icon=${icon_path}"). A "\n" in a forged .zgp's slug could add an
  # arbitrary "Exec=" line to a .desktop marked "metadata::trusted true", which runs without
  # warning on double-click. Same risk as for game_real_name below; rejected here, upstream,
  # rather than sanitized afterwards.
  case "${slug}" in
    *[$'\n\r\t']*)
      zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
      zgu_log "install" "ERROR" "file=${name} reason=slug_control_character"
      rm -rf "${temp_extract_dir}"
      continue
      ;;
  esac
  real_slug_dir=$(realpath -e "${temp_extract_dir}/${slug}" 2>/dev/null)
  real_temp_dir=$(realpath -e "${temp_extract_dir}" 2>/dev/null)
  if [[ -z "${real_slug_dir}" ]] || [[ -z "${real_temp_dir}" ]] || [[ "${real_slug_dir%/*}" != "${real_temp_dir}" ]]; then
    zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
    zgu_log "install" "ERROR" "file=${name} reason=slug_invalid_real_path"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  prefix_dir="${games_dir}/${slug}"

  # 3. Strict check: if the prefix already exists, refuse the installation outright
  if [[ -d "${prefix_dir}" ]]; then
    err_msg="$(t install_game.already_installed "${slug}")"
    echo "${err_msg}" >&2
    zgu_log "install" "ERROR" "file=${name} slug=${slug} reason=already_installed"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  # 4. Instant final move (0 seconds)
  if ! mv "${temp_extract_dir}/${slug}" "${games_dir}/"; then
    err_msg="$(t install_game.move_failed "${name}")"
    echo "${err_msg}" >&2
    zgu_log "install" "ERROR" "file=${name} slug=${slug} reason=move_failed"
    rm -rf "${temp_extract_dir}"
    continue
  fi
  rm -rf "${temp_extract_dir}"
  temp_extract_dir=""
  inprogress_prefix="${prefix_dir}"
  inprogress_slug="${slug}"

  run_post_install() {
    t install_game.analyzing "${name}"

    timestamp=$(date +%s%N)
    config_id="${slug}-${timestamp}"

    # The display name (.desktop shortcut, messages...) comes straight from the "name" field
    # of the bundled zgp-game-config.yml, which is a copy of the original Lutris YAML where
    # it is a root key.
    bundled_yml="${prefix_dir}/zgp-game-config.yml"
    game_real_name=""

    if [[ -f "${bundled_yml}" ]]; then
      # No "command -v python3" test: python3 is a mandatory dependency checked at the
      # top.
      # $bundled_yml derives from $slug, possibly forged by whoever created the shared
      # .zgp (see the SQL escaping note below): passed via the environment rather than
      # interpolated into the Python code, so an apostrophe or other special character
      # cannot break the string literal and inject Python code.
      game_real_name=$(BUN_YML="${bundled_yml}" python3 -c '
import yaml, os
try:
    with open(os.environ["BUN_YML"]) as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("name", "") or "")
except Exception:
    pass
' 2>/dev/null)
    fi

    # game_real_name comes from a zgp-game-config.yml possibly forged by the .zgp's creator.
    # It is reused as-is in the generated .desktop ("Name=${game_real_name}") and in
    # bonus_dir_name: an injected newline could add an arbitrary "Exec=" key to the
    # .desktop, and a "/" or "../" could make the rm -rf of bonus_dir_name escape
    # desktop_dir. So control characters (CR/LF first) and path separators are stripped
    # before any other use.
    game_real_name="${game_real_name//[$'\n\r']/ }"
    game_real_name="${game_real_name//\//-}"

    [[ -z "${game_real_name}" ]] && game_real_name="${name}"

    t install_game.processing_registry
    for reg in "system.reg" "user.reg" "userdef.reg" "lutris.json"; do
      if [[ -f "${prefix_dir}/${reg}" ]]; then
        sed -i "s|anonuser|${USER}|g" "${prefix_dir}/${reg}"
      fi
    done

    # find + head -n 1 rather than a glob passed to basename: with several subfolders in
    # "Games/", basename would take the second as a suffix to strip (or fail with "extra
    # operand" on 3+), silently skipping this goglog.ini patch. Same mechanism as
    # zgp-game-packer.sh.
    gamefolder=$(basename "$(find "${prefix_dir}/drive_c/Games" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1)")
    if [[ -n "${gamefolder}" ]]; then
      ini_parent_dir="${prefix_dir}/drive_c/Games/${gamefolder}"
      goglog="${ini_parent_dir}/goglog.ini"
      if [[ -f "${goglog}" ]]; then
        sed -i "s|anonuser|${USER}|g" "${goglog}"
      fi
    fi

    mkdir -p "${prefix_dir}/dosdevices"
    ln -sf "../drive_c" "${prefix_dir}/dosdevices/c:"
    if [[ ! -e "${prefix_dir}/pfx" ]]; then
      ln -sf "." "${prefix_dir}/pfx"
    fi

    # Safety net for archives packaged before this cleanup (see zgp-game-packer.sh): "Local
    # Settings" may contain a leftover Proton migration ("Application Data BACKUP"
    # non-empty) that makes the automatic migration fail at first launch with "Directory not
    # empty". Removed unconditionally, as at pack time.
    if [[ -e "${prefix_dir}/drive_c/users/steamuser/Local Settings" || -L "${prefix_dir}/drive_c/users/steamuser/Local Settings" ]]; then
      rm -rf -- "${prefix_dir}/drive_c/users/steamuser/Local Settings"
    fi

    # Safety net for archives packaged before this cleanup (see zgp-game-packer.sh): Proton's
    # "version" file makes Proton skip the repair of its own files in the prefix, which the
    # export removed (links to the runner, e.g. system32/umu.exe). Removed so that Proton
    # rebuilds them at the first launch (slower, once). The game data is not touched.
    [[ -f "${prefix_dir}/version" ]] && rm -f -- "${prefix_dir}/version"

    t install_game.registering_lutris
    safe_name="${game_real_name//\'/\'\'}"
    # slug and config_id derive from the folder name extracted from the .zgp, so they may be
    # forged by the package creator. Without escaping, a folder name containing an
    # apostrophe would allow SQL injection in the queries below.
    safe_slug="${slug//\'/\'\'}"
    safe_config_id="${config_id//\'/\'\'}"

    # bundled_yml was resolved earlier (real game name); reused here.
    yml_config_file="${lutris_config_dir}/${config_id}.yml"

    executable_path=""

    if [[ -f "${bundled_yml}" ]]; then
      # --- Detect auto-run hooks (prelaunch_command, etc.) ---
      # Read-only: lists in advance the keys that the cleanup below would strip (see
      # strip_exec_hooks below). A .zgp may come from an untrusted third party or from the
      # user's own "lpm pack"; lpm cannot tell which, so rather than silently stripping
      # these hooks it informs the user and asks (see the confirmation below).
      detected_hooks=$(BUN_YML="${bundled_yml}" python3 -c '
import os, yaml

def find_hooks(obj, path=""):
    found = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            kl = k.lower() if isinstance(k, str) else ""
            cur_path = f"{path}.{k}" if path else str(k)
            if kl.endswith("_command") or kl.endswith("_script") or kl.endswith("_wait") or "exec" in kl:
                found.append((cur_path, v))
                continue
            found.extend(find_hooks(v, cur_path))
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            found.extend(find_hooks(item, f"{path}[{i}]"))
    return found

try:
    with open(os.environ["BUN_YML"], "r") as f:
        data = yaml.safe_load(f)
    for hook_path, hook_value in find_hooks(data):
        print(f"{hook_path}\x1f{hook_value}")
except Exception:
    pass
' 2>/dev/null)

      # Strip by default (safe): keep_hooks becomes "yes" only if explicitly confirmed
      # below, by an interactive answer or the --allow-scripts flag (see bin/lpm). It is
      # separate from -y: -y skips the general install confirmation, not the authorization
      # to run a script at every game launch; these are different risks.
      keep_hooks="no"
      if [[ -n "${detected_hooks}" ]]; then
        if [[ "${allow_scripts_flag}" = "yes" ]]; then
          keep_hooks="yes"
          # Shown on every path (CLI writes to the terminal, GUI writes to the
          # progress stream), same convention as the other "t install_game.*" calls
          # from run_post_install, e.g. "install_game.finalizing" below.
          t install_game.hooks_auto_allowed_cli "${game_real_name}"
        else
          t install_game.hooks_confirm_header_cli "${game_real_name}"
          while IFS=$'\x1f' read -r hook_path hook_value; do
            [[ -z "${hook_path}" ]] && continue
            t install_game.hooks_list_item_cli "${hook_path}" "${hook_value}"
          done <<< "${detected_hooks}"
          read -r -p "$(t install_game.hooks_confirm_prompt_cli)" hooks_response
          case "${hooks_response}" in
            [oOyY]) keep_hooks="yes" ;;
            *) keep_hooks="no" ;;
          esac
        fi
      fi

      BUN_YML="${bundled_yml}" YML_OUT="${yml_config_file}" PFX_DIR="${prefix_dir}" USER_HOME="${HOME}" ERR_YAML_LABEL="$(t install_game.yaml_processing_error)" python3 -c '
import os, yaml, re
try:
    with open(os.environ["BUN_YML"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        data.pop("script", None)
        data.pop("version", None)

        def update_paths(obj):
            if isinstance(obj, dict):
                return {k: update_paths(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [update_paths(v) for v in obj]
            elif isinstance(obj, str):
                res = re.sub(r"/home/[^/]+", os.environ["USER_HOME"], obj)
                res = res.replace("$GAMEDIR", os.environ["PFX_DIR"])
                return res
            return obj

        data = update_paths(data)

        # zgp-game-config.yml comes from the shared .zgp, possibly forged or hand-edited
        # to add a hook. Lutris runs any command/script automatically at game launch or
        # exit (prelaunch_script/postexit_script under "game",
        # prelaunch_command/postexit_command under "system") without asking.
        # Neutralization (if not authorized) is done on the bash side by
        # zgu_apply_hook_policy (mode "broad"), by COMMENTING rather than deleting, so
        # the command can be re-authorized later (page "Raccourci de lancement"). This
        # block therefore writes the YAML as-is.
        #
        # IMPORTANT: zgu_apply_hook_policy must run AFTER zgu_write_game_shortcut (see
        # below), not here: zgu_write_game_shortcut sometimes rewrites the whole YAML
        # (Proton/GAMEID detection) through a standard parser that never sees commented
        # lines, so neutralizing before would erase the comment, and the command with
        # it.

        if "game" not in data:
            data["game"] = {}
        data["game"]["prefix"] = os.environ["PFX_DIR"]

        with open(os.environ["YML_OUT"], "w") as f:
            yaml.dump(data, f, sort_keys=False)
except Exception as e:
    err_label = os.environ.get("ERR_YAML_LABEL", "YAML processing error")
    print(f"{err_label}: {e}")
' 2>/dev/null
      rm -f "${bundled_yml}"

      # Executable path re-read from the ALREADY PATCHED YAML (game.prefix, "$GAMEDIR" and
      # "/home/<user>" already resolved for this machine), not the raw bundled one:
      # otherwise a literal "$GAMEDIR" (or the packager's "anonuser") would end up in the
      # Lutris DB, pointing to a nonexistent path on another machine or games folder.
      if [[ -f "${yml_config_file}" ]]; then
        executable_path=$(YML_OUT="${yml_config_file}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_OUT"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("game", {}).get("exe", ""))
except Exception:
    pass
' 2>/dev/null)
      fi
    fi

    if [[ ! -f "${yml_config_file}" ]]; then
      t install_game.yml_missing
    fi

    if [[ "${executable_path}" != /* ]]; then
      executable_path="${prefix_dir}/${executable_path}"
    fi

    safe_prefix_dir="${prefix_dir//\'/\'\'}"
    safe_executable_path="${executable_path//\'/\'\'}"

    sqlite3 "${lutris_db}" "DELETE FROM games WHERE slug='${safe_slug}';"
    sqlite3 "${lutris_db}" <<EOF
INSERT INTO games (name, slug, installer_slug, parent_slug, runner, executable, directory, configpath, updated, installed, installed_at)
VALUES (
  '${safe_name}',
  '${safe_slug}',
  '${safe_slug}',
  '',
  'wine',
  '${safe_executable_path}',
  '${safe_prefix_dir}',
  '${safe_config_id}',
  strftime('%s','now'),
  1,
  strftime('%s','now')
);
EOF

    t install_game.creating_shortcuts
    game_id=$(sqlite3 "${lutris_db}" "SELECT id FROM games WHERE slug='${safe_slug}';")

    zgu_write_game_shortcut "${game_real_name}" "${slug}" "${prefix_dir}" "${game_id}" "${version}" "${create_menu}" "${create_desktop}" "${executable_path}" "${config_id}" "${lutris_config_dir}" "${runner_dir}" "${desktop_dir_override}"

    # --- Reconnect the LPM Launcher if this game already had it: "scripts/lpm-launcher.sh"
    # and "lpm-launcher.yml" live inside the game folder so they survive reinstallation, but
    # "system.prelaunch_command" lives in the LUTRIS config, rewritten here from the bundled
    # YAML, which never contains it (it is added separately by "lpm launcher ... on").
    # Without this block the picker would stay unreachable after a reinstall (see
    # zgp_launcher_is_active in zgl-launcher-manager.sh). Adds the key ONLY if entirely
    # absent, never overwriting a hook already present and confirmed (keep_hooks). Must run
    # HERE: after zgu_write_game_shortcut (same reason as zgu_apply_hook_policy below) and
    # before zgu_apply_hook_policy, so its "lpm's own relay" exemption applies on the first
    # pass. ---
    if [[ -f "${prefix_dir}/scripts/lpm-launcher.sh" ]] && [[ -f "${yml_config_file}" ]]; then
      YML_PATH="${yml_config_file}" RELAY_PATH="${prefix_dir}/scripts/lpm-launcher.sh" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    system = data.setdefault("system", {})
    if "prelaunch_command" not in system:
        system["prelaunch_command"] = os.environ["RELAY_PATH"]
        system["prelaunch_wait"] = True
        with open(os.environ["YML_PATH"], "w") as f:
            yaml.dump(data, f, sort_keys=False)
except Exception:
    pass
' 2>/dev/null
    fi

    # Neutralize (never delete) unauthorized hooks; see the YAML handling comment above and
    # zgu_apply_hook_policy in zgu-desktop-utils.sh. keep_hooks was resolved earlier. MUST
    # run AFTER zgu_write_game_shortcut (which may rewrite ${yml_config_file} entirely),
    # never before.
    if [[ -n "${yml_config_file}" ]] && [[ -f "${yml_config_file}" ]]; then
      install_allow_hooks="false"
      [[ "${keep_hooks}" = "yes" ]] && install_allow_hooks="true"
      zgu_apply_hook_policy "${yml_config_file}" "${install_allow_hooks}" "broad"
    fi

    # Loading screen marker (see lib/zgl-launcher-orchestrator.sh): idempotent, same logic
    # as zgp-game-shortcutter.sh: created if unchecked, absent (screen active) otherwise,
    # which is the default for a freshly extracted game folder.
    if [[ "${loadingscreen_enabled}" = false ]]; then
      : > "${prefix_dir}/.lpm-no-loadingscreen" 2>/dev/null
    fi

    zgu_log "install" "OK" "slug=${slug} name=${game_real_name}"
    # The slug (not just "1"): reused after the loop for the best-effort Lutris native media
    # update, see "install_success_file".
    echo "${slug}" >> "${install_success_file}"
    # Line read by the GUI (see CommandPage.run_command): this game is done, so no longer
    # subject to cancel cleanup, but offered for removal if the batch is cancelled.
    printf '[INSTALLED] %s\n' "${slug}"
    inprogress_prefix=""
    inprogress_slug=""

    t install_game.finalizing
  }

  run_post_install
done

# Final notification reflecting the REAL outcome (see install_success_file above): full success,
# full failure, or partial.
install_succeeded_slugs=()
if [[ -f "${install_success_file}" ]]; then
  mapfile -t install_succeeded_slugs < "${install_success_file}" 2>/dev/null
fi
rm -f "${install_success_file}"
install_success_count=${#install_succeeded_slugs[@]}
# install_total_count is computed before the loop.

if [[ "${install_success_count}" -eq "${install_total_count}" ]] && [[ "${install_total_count}" -gt 0 ]]; then
  notify-send "$(t install_game.notify_title)" "$(t install_game.notify_body)" 2>/dev/null
elif [[ "${install_success_count}" -eq 0 ]]; then
  notify-send "$(t install_game.notify_title_none)" "$(t install_game.notify_body_none)" 2>/dev/null
else
  notify-send "$(t install_game.notify_title_partial)" "$(t install_game.notify_body_partial "${install_success_count}" "${install_total_count}")" 2>/dev/null
fi

# Best-effort update of Lutris native media (banner/icon/cover, see "lpm sync-media") for the
# games just installed. Outside the install loop: a lutris.net network problem must never fail
# an installation.
if [[ ${#install_succeeded_slugs[@]} -gt 0 ]]; then
  # Run in the background, detached ("&" + "disown"): nothing here needs to wait for
  # sync-media (purely cosmetic); each game's result remains available via "lpm log" (see
  # zgu_log in zgp-game-sync-media.sh).
  bash "${script_dir}/zgp-game-sync-media.sh" "${install_succeeded_slugs[@]}" >/dev/null 2>&1 &
  disown
fi

# Exit code reflects the real outcome: 1 if at least one archive could not be installed (the GUI
# and scripts rely on it).
if [[ "${install_success_count}" -lt "${install_total_count}" ]]; then
  exit 1
fi
exit 0
