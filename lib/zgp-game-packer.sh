#!/bin/bash

# --- Arguments from the lpm router ---
# $1 = optional compression level (e.g. "5" or empty)
# $2 = generate_hash_flag ("yes" if --hash)
# $3, $4, ... = target game folders
compression_arg="${1:-}"
shift || true
generate_hash_flag="${1:-}"
shift || true
cli_games=("$@")

# Paths and base variables
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

GENERATE_HASH=false
[[ "${generate_hash_flag}" = "yes" ]] && GENERATE_HASH=true

OUTPUT_DIR="${HOME}"

# Lutris paths (Flatpak vs native package), using the same detection as all other lib/ scripts
# (via zgu-lutris-utils.sh). Checking for leftover files could read the wrong database if an old
# Flatpak or native profile still lies around.
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

GAMES_DIR="${HOME}/Games"

# Detect Flatpak vs native package (function from zgu-lutris-utils.sh; also handles both being
# installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${lutris_version}" ]]; then
  # Explicit detection (aligned with the other lib/ scripts): a silent fallback to native
  # paths would give a "folder not found" message later, much less clear than the real cause
  # (Lutris not installed).
  zgu_cli_error "$(t pack_game.lutris_missing_cli)"
  exit 1
fi
case "${lutris_version}" in
  flatpak)
    lutris_db_path="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_system_file="${lutris_flatpak_system_file}"
    ;;
  native)
    lutris_db_path="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_system_file="${lutris_package_system_file}"
    ;;
esac

# Custom Games path (if set in Lutris): read dynamically as in zgp-game-installer.sh and
# zgp-game-uninstaller.sh. This global preference lives in system.yml ("system: game_path:"),
# NOT in runners/wine.yml (which only holds Wine runner options such as
# system_winetricks/version).
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && GAMES_DIR="${extracted_path}"
fi

# Anonymize any user path (Windows "Users\\<name>\\" / "Users\<name>\\" and POSIX
# "/home/<name>/") to "anonuser", whatever the user name: a fixed list of known names would
# silently miss any other (former tester, other machine, inherited .reg...). The embedded YAML
# is cleaned dynamically the same way (see below); .reg / goglog.ini / lutris.json go through
# this shared function.
anonymize_user_paths() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  # Windows paths, escaped in .reg files ("Users\\\\<name>\\\\") and unescaped
  sed -i -E 's#([Uu]sers\\\\)[^\\"'"'"']+(\\\\)#\1anonuser\2#g' "${f}"
  sed -i -E 's#([Uu]sers\\)[^\\"'"'"']+(\\)#\1anonuser\2#g' "${f}"
  # POSIX paths ("/home/<name>/")
  sed -i -E 's#(/home/)[^/"'"'"']+(/)#\1anonuser\2#g' "${f}"
  # Safety net: the current $USER, even outside a path context
  local current_user="${USER:-$(id -un 2>/dev/null)}"
  [[ -n "${current_user}" ]] && sed -i "s|${current_user}|anonuser|g" "${f}"
  return 0
}

# Global default Lutris runner (shared function, see zgu-lutris-utils.sh)
default_runner=$(zgu_get_default_runner)

# zstd check (always required)
if ! command -v zstd >/dev/null 2>&1; then
  zgu_cli_error "$(t pack_game.zstd_missing)"
  exit 1
fi

# python3 itself is checked separately from PyYAML so the user gets the message matching the
# real cause. Same style as the zstd check above (stderr only, no dedicated Zenity dialog).
if ! command -v python3 >/dev/null 2>&1; then
  zgu_cli_error "$(t pack_game.python3_missing)"
  exit 1
fi

# PyYAML is required to clean/rewrite the Lutris YAML embedded in the .zgp. Without it, the
# package could be created with an uncleaned zgp-game-config.yml (absolute paths, missing runner
# version) and no visible error.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t pack_game.pyyaml_missing_cli)"
  exit 1
fi

if [[ ! -d "${GAMES_DIR}" ]]; then
  zgu_cli_error "$(t pack_game.games_dir_missing "${GAMES_DIR}")"
  exit 1
fi

declare -A folder_by_name  # game_real_name -> absolute real prefix path (from pga.db)
declare -A slug_by_name    # game_real_name -> slug (to re-read configpath below)
games_to_export=()

# Games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) can never
# be packed with lpm. A .zgp would mix several games in one archive, and the
# cleanup/anonymization applied below (meant to be replayed on install on another machine) would
# damage the shared prefix for the other games still using it (see zgu_get_blacklisted_slugs in
# zgu-lutris-utils.sh).
declare -A blacklisted_slugs
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
  while IFS= read -r bl_slug; do
    [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
  done < <(zgu_get_blacklisted_slugs "${lutris_db_path}")
fi

# Resolves a Lutris slug (runner='wine' game) to the real, safe path of its prefix.
# Discovery goes through pga.db (column "directory") rather than scanning GAMES_DIR/*/ one level
# deep: a one-level scan would miss games nested deeper (e.g. gog/<game>/, like Lutris GOG
# games) and would pack an intermediate folder (e.g. "gog/") wholesale if several games lived
# there, mixing their prefixes in one archive.
# "directory" may come from ANY wine game in pga.db, not only those managed by lpm: same
# anti-escape guard as zgp-game-uninstaller.sh (the resolved path must remain a real subfolder
# of GAMES_DIR).
# Output: real path on stdout, nothing if not found/unsafe (return code 1).
resolve_prefix_dir_by_slug() {
  local slug="$1" safe_slug raw_dir real_dir real_games_dir
  safe_slug="${slug//\'/\'\'}"
  raw_dir=$(sqlite3 "${lutris_db_path}" "SELECT directory FROM games WHERE slug='${safe_slug}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  [[ -z "${raw_dir}" ]] && return 1

  real_dir=$(realpath -e "${raw_dir}" 2>/dev/null)
  real_games_dir=$(realpath -e "${GAMES_DIR}" 2>/dev/null)
  if [[ -z "${real_dir}" ]] || [[ -z "${real_games_dir}" ]] || [[ "${real_dir}" != "${real_games_dir}/"* ]]; then
    return 1
  fi
  echo "${real_dir}"
}

# --all (CLI only): replaces the lone "--all" argument with the sorted list of all
# non-blacklisted wine game slugs from pga.db, so the CLI loop below processes each slug as if
# typed by the user.
pack_all_mode=false
pack_skipped=0
if [[ ${#cli_games[@]} -eq 1 ]] && [[ "${cli_games[0]}" = "--all" ]]; then
  pack_all_mode=true
  all_wine_slugs=()
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
    while IFS= read -r all_slug; do
      [[ -z "${all_slug}" ]] && continue
      [[ -n "${blacklisted_slugs[${all_slug}]:-}" ]] && continue
      all_wine_slugs+=("${all_slug}")
    done < <(sqlite3 "${lutris_db_path}" "SELECT slug FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)
  fi
  if [[ ${#all_wine_slugs[@]} -eq 0 ]]; then
    zgu_cli_error "$(t pack_game.no_prefix_found "${GAMES_DIR}")"
    exit 1
  fi
  cli_games=("${all_wine_slugs[@]}")
fi

# --- Target game selection ---
# "cli_games" is always non-empty here (bin/lpm has no interactive entry point).
# No argument: explicit error (not a false "completed successfully").
if [[ ${#cli_games[@]} -eq 0 ]]; then
  zgu_cli_error "$(t common.missing_target_cli "lpm pack")"
  exit 1
fi

LEVEL="${compression_arg:-3}"

for target_slug_raw in "${cli_games[@]}"; do
  # basename() neutralizes any path traversal attempt ("../", absolute path...) in the
  # CLI-provided slug, for consistency with the rest of the project.
  target_slug=$(basename -- "${target_slug_raw}")

  if [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
    zgu_cli_error "$(t pack_game.slug_blacklisted_cli "${target_slug}")"
    exit 1
  fi

  resolved_dir=$(resolve_prefix_dir_by_slug "${target_slug}")
  if [[ -z "${resolved_dir}" ]]; then
    zgu_cli_error "$(t pack_game.folder_not_found_cli "${target_slug_raw}" "${GAMES_DIR}")"
    # With --all, a game whose folder is missing must not prevent packing the others: it is
    # reported, processing continues, and the command ends with an error (exit code 1).
    if [[ "${pack_all_mode}" = true ]]; then
      pack_skipped=1
      continue
    fi
    exit 1
  fi

  game_real_name=""
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
    safe_target_slug="${target_slug//\'/\'\'}"
    game_real_name=$(sqlite3 "${lutris_db_path}" "SELECT name FROM games WHERE slug='${safe_target_slug}' LIMIT 1;" 2>/dev/null)
  fi
  [[ -z "${game_real_name}" ]] && game_real_name="${target_slug}"
  # A "/" in the name would target a wrong archive path (same neutralization as
  # zgp-game-installer.sh).
  game_real_name="${game_real_name//\//-}"

  # Anti-overwrite check in CLI
  archive_path="${OUTPUT_DIR}/${game_real_name}.zgp"
  if [[ -f "${archive_path}" ]]; then
    zgu_cli_error "$(t pack_game.archive_exists_cli "${game_real_name}" "${OUTPUT_DIR}")"
    zgu_cli_error "$(t pack_game.archive_exists_hint)"
    exit 1
  fi

  games_to_export+=("${game_real_name}")
  folder_by_name["${game_real_name}"]="${resolved_dir}"
  slug_by_name["${game_real_name}"]="${target_slug}"
done

# --- Cancellation (SIGTERM/SIGINT sent by the GUI "Cancel" button to the whole process group):
# removes the HALF-WRITTEN .zgp of the current game (and its hash file) plus the temporary
# "zgp-game-config.yml" copied into its prefix. Archives already completed in the batch are
# never touched here (the GUI offers to delete them, see the "[EXPORTED]" lines). KNOWN
# LIMITATION: the prefix cleanup done before archiving (symlinks, dosdevices, Temp, anonymized
# user names...) is applied directly to the installed game, as in a normal export; a cancel
# cannot undo it, but it has no effect on how the game runs (Wine/Proton recreate those items).
# Exit code 130. ---
inprogress_archive=""
inprogress_yml=""

lpm_cancel_cleanup() {
  trap '' TERM INT
  [[ -n "${inprogress_archive}" ]] && rm -f -- "${inprogress_archive}" \
    "${OUTPUT_DIR}/hash/$(basename -- "${inprogress_archive}").sha256"
  [[ -n "${inprogress_yml}" ]] && rm -f -- "${inprogress_yml}"
  zgu_log "pack" "INFO" "archive=${inprogress_archive} raison=annule_nettoye"
  echo "[CANCELLED]"
  t pack_game.cancelled_run_cli
  exit 130
}
trap lpm_cancel_cleanup TERM INT

# Descriptor 3 = real script stdout (see zgp-game-installer.sh for details): needed to emit
# "[PROGRESS] <pct>" from inside the tar | pv | zstd pipe.
exec 3>&1
export_idx=0
export_total_count="${#games_to_export[@]}"

# Process each selected game
for game_real_name in "${games_to_export[@]}"; do
  WINEPREFIX_DIR="${folder_by_name[${game_real_name}]}"
  game_slug="${slug_by_name[${game_real_name}]}"

  [[ -z "${WINEPREFIX_DIR}" ]] && continue
  [[ ! -d "${WINEPREFIX_DIR}" ]] && continue
  export_idx=$((export_idx + 1))

  # Flat archive root named after the real prefix folder (dirname/basename of the path
  # resolved from pga.db) rather than GAMES_DIR + name: works whatever the prefix depth (e.g.
  # gog/<game>/), and the archive always has a flat root named after the game folder, which is
  # all zgp-game-installer.sh knows.
  PARENT_DIR=$(dirname -- "${WINEPREFIX_DIR}")
  WINEPREFIX_NAME=$(basename -- "${WINEPREFIX_DIR}")

  configpath=""

  if [[ -n "${game_slug}" ]] && command -v sqlite3 >/dev/null 2>&1 && [[ -f "${lutris_db_path}" ]]; then
    safe_game_slug="${game_slug//\'/\'\'}"
    configpath=$(sqlite3 "${lutris_db_path}" "SELECT configpath FROM games WHERE slug='${safe_game_slug}' LIMIT 1;" 2>/dev/null)
  fi

  ARCHIVE_NAME="${game_real_name}"
  archive_path="${OUTPUT_DIR}/${ARCHIVE_NAME}.zgp"

  # Robust search for the inner game subfolder (2>/dev/null: if "drive_c/Games" does not exist
  # for this prefix, fall back silently below instead of printing a useless "find: No such
  # file or directory")
  GAME_DIR=$(basename "$(find "${WINEPREFIX_DIR}/drive_c/Games" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1)")
  [[ -z "${GAME_DIR}" ]] && GAME_DIR="${WINEPREFIX_NAME}"

  ini_parent_dir="${WINEPREFIX_DIR}/drive_c/Games/${GAME_DIR}"
  goglog="${ini_parent_dir}/goglog.ini"
  lutris_json="${WINEPREFIX_DIR}/lutris.json"

  if [[ -f "${goglog}" ]]; then
    anonymize_user_paths "${goglog}"
  fi

  if [[ -f "${lutris_json}" ]]; then
    anonymize_user_paths "${lutris_json}"
  fi

  # Remove symlinks and useless temporary folders
  [[ -d "${WINEPREFIX_DIR}/dosdevices" ]] && rm -rf "${WINEPREFIX_DIR}/dosdevices"
  [[ -L "${WINEPREFIX_DIR}/drive_c/users/steamuser" ]] && unlink "${WINEPREFIX_DIR}/drive_c/users/steamuser"
  [[ -L "${WINEPREFIX_DIR}/drive_c/users/${USER}" ]] && unlink "${WINEPREFIX_DIR}/drive_c/users/${USER}"
  [[ -d "${WINEPREFIX_DIR}/drive_c/users/${USER}" ]] && mv -n "${WINEPREFIX_DIR}/drive_c/users/${USER}" "${WINEPREFIX_DIR}/drive_c/users/steamuser"
  [[ -L "${WINEPREFIX_DIR}/pfx" ]] && unlink "${WINEPREFIX_DIR}/pfx"

  for link_name in "Application Data" "Desktop" "Music" "Pictures" "Videos" "Documents" "My Documents" "Downloads"; do
    [[ -L "${WINEPREFIX_DIR}/drive_c/users/steamuser/${link_name}" ]] && unlink "${WINEPREFIX_DIR}/drive_c/users/steamuser/${link_name}"
  done

  # "Local Settings" (old XP path: Local Settings/Application Data, Temp, History...) is fully
  # rebuilt by Proton/Wine at the next prefix initialization. If it survives packing, it may
  # contain both "Application Data" (real folder, not yet migrated) AND "Application Data
  # BACKUP" (leftover from a Proton migration already done before packing): on reinstall,
  # Proton retries its automatic migration and fails with "Directory not empty". Removed
  # unconditionally (like the links above) rather than chasing each subfolder/BACKUP.
  [[ -e "${WINEPREFIX_DIR}/drive_c/users/steamuser/Local Settings" || -L "${WINEPREFIX_DIR}/drive_c/users/steamuser/Local Settings" ]] \
    && rm -rf -- "${WINEPREFIX_DIR}/drive_c/users/steamuser/Local Settings"

  [[ -d "${WINEPREFIX_DIR}/drive_c/ProgramData/Package Cache/" ]] && rm -rf -- "${WINEPREFIX_DIR}/drive_c/ProgramData/Package Cache/"*
  [[ -d "${WINEPREFIX_DIR}/drive_c/users/steamuser/Temp" ]] && rm -rf -- "${WINEPREFIX_DIR}/drive_c/users/steamuser/Temp/"*
  [[ -d "${WINEPREFIX_DIR}/drive_c" ]] && mkdir -p "${WINEPREFIX_DIR}/drive_c/users/steamuser/Temp"

  find "${WINEPREFIX_DIR}/drive_c" -type l ! -exec test -e {} \; -delete
  # "{}" is passed as a positional argument rather than interpolated into the script text: a
  # file name with special characters (`, $, quotes...) cannot be interpreted as bash code.
  #
  # Copy-then-replace (not delete-then-copy): "cp -L" resolves the link target itself,
  # relative or absolute, whereas a manual "readlink" followed by "cp" fails silently for
  # RELATIVE links (the target is relative to the link's folder, not the script's cwd), after
  # the link was already removed, so the file would vanish from the .zgp. Copying to a temp
  # file first leaves the original link intact if the copy fails.
  find "${WINEPREFIX_DIR}/drive_c" -type l -exec bash -c '
    for link; do
      tmp="${link}.zgp-tmp"
      if cp -rL -- "${link}" "${tmp}" 2>/dev/null; then
        rm -f -- "${link}"
        mv -- "${tmp}" "${link}"
      else
        rm -f -- "${tmp}"
      fi
    done
  ' _ {} +
  find "${WINEPREFIX_DIR}/drive_c/windows/system32" -type f -name '*.orig' -delete
  find "${WINEPREFIX_DIR}/drive_c/windows/syswow64" -type f -name '*.orig' -delete

  for reg_file in "system.reg" "user.reg" "userdef.reg"; do
    if [[ -f "${WINEPREFIX_DIR}/${reg_file}" ]]; then
      anonymize_user_paths "${WINEPREFIX_DIR}/${reg_file}"
    fi
  done

  # --- NO SEPARATE META FILE FOR THE REAL GAME NAME ---
  # The Lutris YAML embedded below (zgp-game-config.yml) already has a root "name" key with
  # the real name, and the cleanup below never removes it (only "script", "version" and "slug"
  # are removed). The installer reads "name" directly from that YAML.

  # --- CLEAN EMBEDDING OF THE LUTRIS YAML (if available) ---
  if [[ -n "${configpath}" ]] && [[ -f "${lutris_config_dir}/${configpath}.yml" ]]; then
    inprogress_yml="${WINEPREFIX_DIR}/zgp-game-config.yml"
    cp "${lutris_config_dir}/${configpath}.yml" "${WINEPREFIX_DIR}/zgp-game-config.yml"

    # The absolute wineprefix path (e.g. /home/user/Games/mariovania) is replaced by Lutris'
    # native "$GAMEDIR" placeholder in all paths of the embedded YAML, resolved at install
    # time from the configured games folder (see zgp-game-installer.sh).
    # The replacement must cover the whole path (not only the "/home/<name>/" segment):
    # otherwise a custom games folder, or one different from the packaging machine, stays
    # frozen in the YAML and breaks the install.
    YML_PATH="${WINEPREFIX_DIR}/zgp-game-config.yml" WINEPREFIX_DIR_ENV="${WINEPREFIX_DIR}" DEFAULT_RUNNER="${default_runner}" ERR_YAML_LABEL="$(t pack_game.yaml_cleanup_error)" python3 -c '
import yaml, re, os

yml_path = os.environ["YML_PATH"]
prefix_dir = os.environ.get("WINEPREFIX_DIR_ENV", "")
default_runner = os.environ.get("DEFAULT_RUNNER", "")
prefix_pattern = re.escape(prefix_dir) if prefix_dir else None

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        data.pop("script", None)
        data.pop("version", None)
        data.pop("slug", None)

        # GAMEID (system.env.GAMEID) is generated by lpm at install time (see
        # zgu_write_game_shortcut in zgu-desktop-utils.sh) from the game Lutris id in
        # this machine database, an auto-incremented counter that differs between
        # machines. Keeping it in the exported .zgp would reference a stale id after
        # reinstalling elsewhere (or even here), with a real risk of collision between
        # two different games sharing the same old id. Removed specifically (not all of
        # "env", which may hold legitimate settings such as WINEDLLOVERRIDES/MANGOHUD):
        # each install recomputes it automatically.
        system_cfg = data.get("system")
        if isinstance(system_cfg, dict):
            env_cfg = system_cfg.get("env")
            if isinstance(env_cfg, dict):
                env_cfg.pop("GAMEID", None)

        def clean_paths(obj):
            if isinstance(obj, dict):
                return {k: clean_paths(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [clean_paths(v) for v in obj]
            elif isinstance(obj, str):
                s = obj
                if prefix_pattern:
                    s = re.sub(prefix_pattern + r"(?=/|$)", "$GAMEDIR", s)
                # Safety net: anonymize any user path still referencing
                # /home/<name> outside the prefix, for paths not covered by the
                # placeholder above
                s = re.sub(r"/home/[^/]+/", "/home/anonuser/", s)
                return s
            return obj

        data = clean_paths(data)

        if not isinstance(data.get("wine"), dict):
            data["wine"] = {}
        if not data["wine"].get("version"):
            data["wine"]["version"] = default_runner

        with open(yml_path, "w") as f:
            yaml.dump(data, f, sort_keys=False)
except Exception as e:
    err_label = os.environ.get("ERR_YAML_LABEL", "YAML cleanup error")
    print(f"{err_label}: {e}")
' 2>/dev/null
  fi
  # ---------------------------------------------------------

  # Array (not a single string): "zstd '--ultra -22'" passed ONE argument "--ultra -22" to
  # zstd, which rejected it ("Incorrect parameters"), so levels 20 to 22 always failed.
  if [[ "${LEVEL}" -gt 19 ]]; then
    zstd_args=(--ultra "-${LEVEL}")
  else
    zstd_args=("-${LEVEL}")
  fi

  # --- RUN THE COMPRESSION ---
  # Use pv for a clean text progress bar if available, otherwise a plain message.
  t pack_game.compressing_cli "${export_idx}" "${export_total_count}" "${game_real_name}" "${LEVEL}"
  inprogress_archive="${archive_path}"
  if command -v pv >/dev/null 2>&1; then
    source_size=$(du -sb "${WINEPREFIX_DIR}" 2>/dev/null | cut -f1)
    [[ -z "${source_size}" ]] && source_size=0

    tar -C "${PARENT_DIR}" -cf - "${WINEPREFIX_NAME}" | pv -n -s "${source_size}" 2> >(while IFS= read -r _lpm_pct; do
      # tar adds its headers: the stream may exceed the folder size -> capped at 100.
      [[ "${_lpm_pct}" =~ ^[0-9]+$ ]] || continue
      (( _lpm_pct > 100 )) && _lpm_pct=100
      printf '[PROGRESS] %s\n' "${_lpm_pct}" >&3
    done) | zstd "${zstd_args[@]}" > "${archive_path}"
    tar_exit="${PIPESTATUS[0]}"
  else
    tar -C "${PARENT_DIR}" -cf - "${WINEPREFIX_NAME}" | zstd "${zstd_args[@]}" > "${archive_path}"
    tar_exit="${PIPESTATUS[0]}"
  fi

  if [[ "${tar_exit}" -ne 0 ]] || [[ ! -s "${archive_path}" ]]; then
    zgu_cli_error "$(t pack_game.compression_failed_cli "${ARCHIVE_NAME}")"
    zgu_log "pack" "ERREUR" "slug=${game_slug} nom=${game_real_name} raison=compression_echouee code=${tar_exit}"
    rm -f "${archive_path}"
    [[ -n "${inprogress_yml}" ]] && rm -f -- "${inprogress_yml}"
    exit 1
  fi

  # The .zgp may embed sensitive data (Wine registry: license keys, paths...): restricted to
  # owner-only permissions so another local user cannot read it before a deliberate share.
  chmod 600 "${archive_path}"

  if [[ "${GENERATE_HASH}" = true ]]; then
    zgu_write_hash_sidecar "${archive_path}" "${OUTPUT_DIR}"
  fi

  zgu_log "pack" "OK" "slug=${game_slug} nom=${game_real_name} archive=${archive_path}"
  # Line read by the GUI (see CommandPage.run_command): this archive is done, offered for
  # deletion if the batch is cancelled afterwards.
  printf '[EXPORTED] %s\n' "${archive_path}"
  inprogress_archive=""

  zgu_cli_ok "$(t pack_game.done_cli "${archive_path}")"

  # Clean up the embedded temporary files before finishing
  rm -f "${WINEPREFIX_DIR}/zgp-game-config.yml"
  inprogress_yml=""

done

[[ "${pack_skipped}" -eq 0 ]] || exit 1
zgu_cli_ok "$(t pack_game.cli_done)"
exit 0
