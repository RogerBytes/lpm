#!/bin/bash

# --- lpm isolate ---
#
# Isolates a WHOLE store at once: splits every game living in a shared giga-prefix (Epic Games
# Store, EA App/EA Desktop, Ubisoft Connect, Battle.net) into its own independent wineprefix,
# one game = one prefix, for every game of the targeted store (never a single game with the
# others left behind). Key distinction used throughout this file: the "base" (shared launcher:
# binaries, config, credentials, session; identical and copied for every instance) vs the "game
# folder" (subfolder specific to one game, included only in its instance and excluded from all
# others).
#
# --- Arguments from the lpm router ---
# $1 = confirm_flag ("yes" if -y): skips the final confirmation (number of games to isolate) in strict CLI mode, same convention as the other lib/ scripts.
# $2 = store to isolate entirely (optional): internal code (egs/ea/ubisoft/battlenet), common alias (e.g. "epic", "blizzard"), or slug of a game currently detected in that giga-prefix (only used to find the store to target; ALL games of that store are isolated, not just the named one). Empty => no store found/selected: clean error (see below).
confirm_flag="${1:-}"
shift || true
cli_store_arg="${1:-}"

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

# 1. Dependency check
for cmd in sqlite3 realpath; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgu_cli_error "$(t isolate.cmd_missing "${cmd}")"
    exit 1
  fi
done

if ! command -v python3 >/dev/null 2>&1; then
  zgu_cli_error "$(t isolate.cmd_missing "python3")"
  exit 1
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t isolate.pyyaml_missing_cli)"
  exit 1
fi

# 2. Close Lutris first to release the database (same as install/uninstall/pack)
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Detect Flatpak vs native package + resolve Lutris paths (same centralized detection logic
# as zgu_get_default_runner above)

zgu_load_lutris_env || {
  zgu_cli_error "$(t isolate.lutris_missing_cli)"
  exit 1
}

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t isolate.db_missing "${lutris_db}")"
  exit 1
fi

mkdir -p "${lutris_config_dir}"
mkdir -p "${games_dir}"

real_games_dir=$(realpath -e "${games_dir}" 2>/dev/null)
if [[ -z "${real_games_dir}" ]]; then
  zgu_cli_error "$(t isolate.db_missing "${games_dir}")"
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# --- Store detection (Epic/EA/Ubisoft/Battle.net) for a given giga-prefix ---
# See zgu_detect_isolation_store in zgu-lutris-utils.sh (sourced above): shared with
# zgp-isolable-lister.sh ("lpm list-isolable") so both commands always agree on the detected
# store.

# Turns a free-form game name into a safe slug identifier (lowercase, [a-z0-9-] only, collapsed
# dashes). Only used for the EA App rename suffix (spec decision #3: the slug "ea-app" is shared
# between the launcher and each EA game, so it is renamed to "ea-app-<suffix>" at isolation
# instead of being targeted by rowid).
zgp_ascii_suffix() {
  local s="$1"
  s="${s,,}"
  s=$(printf '%s' "${s}" | tr -c 'a-z0-9' '-')
  s=$(printf '%s' "${s}" | sed -E 's/-+/-/g; s/^-//; s/-$//')
  printf '%s' "${s}"
}

# Epic Games Store: the game folder (MandatoryAppFolderName) is read from the .item manifest
# whose DisplayName matches the game name, not by blind folder scanning.
# Args: giga_dir game_name. Prints relative paths; returns 0 if any found.
zgp_paths_egs() {
  local giga_dir="$1" game_name="$2"
  local manifests_dir="${giga_dir}/drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests"
  local folder_name="" p
  if [[ -d "${manifests_dir}" ]]; then
    folder_name=$(GAME_NAME="${game_name}" MANIFESTS_DIR="${manifests_dir}" python3 -c '
import json, os, glob
target = os.environ["GAME_NAME"].strip().lower()
for path in glob.glob(os.path.join(os.environ["MANIFESTS_DIR"], "*.item")):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            data = json.load(f)
        if str(data.get("DisplayName", "")).strip().lower() == target:
            print(data.get("MandatoryAppFolderName", ""))
            break
    except Exception:
        continue
' 2>/dev/null)
  fi
  if [[ -n "${folder_name}" ]]; then
    p="drive_c/Program Files/Epic Games/${folder_name}"
    [[ -d "${giga_dir}/${p}" ]] && { echo "${p}"; return 0; }
  fi
  return 1
}

# EA App. Args: giga_dir game_name.
zgp_paths_ea() {
  local giga_dir="$1" game_name="$2" found=1 candidate
  for candidate in \
    "drive_c/Program Files/EA Games/${game_name}" \
    "drive_c/ProgramData/EA Desktop/InstallData/${game_name}" \
    "drive_c/Program Files/Common Files/EAInstaller/${game_name}" \
    "drive_c/users/steamuser/Documents/Electronic Arts/${game_name}"; do
    if [[ -e "${giga_dir}/${candidate}" ]]; then
      echo "${candidate}"
      found=0
    fi
  done
  for candidate in \
    "drive_c/proton_shortcuts/${game_name}.desktop" \
    "drive_c/users/Public/Desktop/${game_name}.lnk"; do
    [[ -e "${giga_dir}/${candidate}" ]] && echo "${candidate}"
  done
  return "${found}"
}

# Ubisoft Connect. Args: giga_dir game_name old_args.
zgp_paths_ubisoft() {
  local giga_dir="$1" game_name="$2" old_args="$3" found=1 p candidate
  p="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/${game_name}"
  if [[ -d "${giga_dir}/${p}" ]]; then
    echo "${p}"
    found=0
  fi
  # The numeric ID (data/<ID>/ folder) is the same one used in the "uplay://launch/<ID>"
  # launch argument already present in the game's existing args; read from there, not guessed.
  local uid
  uid=$(printf '%s' "${old_args}" | grep -oE 'uplay://launch/[0-9]+' | head -n1 | grep -oE '[0-9]+$')
  if [[ -n "${uid}" ]]; then
    p="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/data/${uid}"
    [[ -d "${giga_dir}/${p}" ]] && { echo "${p}"; found=0; }
  fi
  for candidate in \
    "drive_c/proton_shortcuts/${game_name}.desktop" \
    "drive_c/users/${USER}/Desktop/${game_name}.url"; do
    [[ -e "${giga_dir}/${candidate}" ]] && echo "${candidate}"
  done
  return "${found}"
}

# Battle.net: one game = one top-level folder under "Program Files (x86)/", at the same level
# as "Battle.net/" (not nested inside it); "Battle.net" itself is the base, excluded.
# Args: giga_dir game_name.
zgp_paths_battlenet() {
  local giga_dir="$1" game_name="$2" p
  p="drive_c/Program Files (x86)/${game_name}"
  if [[ -d "${giga_dir}/${p}" ]] && [[ "${game_name}" != "Battle.net" ]]; then
    echo "${p}"
    return 0
  fi
  return 1
}

# Resolves, for a given store and giga-prefix, the set of paths (relative to giga_dir) belonging
# specifically to the targeted game, never the base, never other games. Writes the paths found
# (one per line) to stdout; copies and deletes nothing. Returns 1 if nothing game-specific was
# found (the game cannot then be isolated safely: better to fail cleanly than guess a wrong
# folder).
#
# Based on an empirical survey per store (folder patterns observed for each launcher); some
# patterns (e.g. Ubisoft "AppData/Roaming/<Variant>Air") have no confirmed generic rule and are
# deliberately omitted rather than guessed.
zgp_resolve_game_paths() {
  local store="$1" giga_dir="$2" game_name="$3" old_args="$4"
  case "${store}" in
    egs) zgp_paths_egs "${giga_dir}" "${game_name}" ;;
    ea) zgp_paths_ea "${giga_dir}" "${game_name}" ;;
    ubisoft) zgp_paths_ubisoft "${giga_dir}" "${game_name}" "${old_args}" ;;
    battlenet) zgp_paths_battlenet "${giga_dir}" "${game_name}" ;;
    *) return 1 ;;
  esac
}

# "Base" paths (shared, copied in full for each isolated game) per store. Ubisoft is a special
# case handled in zgp_copy_socle (the base IS the launcher folder minus the per-game "games/"
# and "data/" subfolders, never a fixed list).
zgp_socle_paths() {
  local store="$1"
  case "${store}" in
    egs)
      echo "drive_c/Program Files/Epic Games/Launcher"
      echo "drive_c/Program Files/Epic Games/DirectXRedist"
      echo "drive_c/Program Files/Epic Games/GameInputRedist"
      echo "drive_c/users/${USER}/AppData/Local/EpicGamesLauncher"
      echo "drive_c/ProgramData/Epic/EpicGamesLauncher"
      ;;
    ea)
      echo "drive_c/Program Files/Electronic Arts/EA Desktop"
      echo "drive_c/users/steamuser/AppData/Roaming/Electronic Arts"
      echo "drive_c/users/steamuser/AppData/Local/Electronic Arts/EA Desktop/CEF"
      ;;
    battlenet)
      echo "drive_c/Program Files (x86)/Battle.net"
      echo "drive_c/ProgramData/Battle.net/Agent"
      echo "drive_c/ProgramData/Battle.net/Setup"
      echo "drive_c/ProgramData/Battle.net_components/battlenet_helpersvc"
      echo "drive_c/ProgramData/Blizzard Entertainment/Battle.net/Cache"
      echo "drive_c/users/${USER}/AppData/Roaming/Battle.net/Battle.net.config"
      ;;
  esac
}

# Total size (bytes) of the given entries of src_root; missing entries count 0. Links are not
# followed (du), so a link can never inflate the figure with data from outside the prefix.
zgp_rel_size_bytes() {
  local src_root="$1"; shift
  local total=0 rel size
  for rel in "$@"; do
    [[ -e "${src_root}/${rel}" ]] || continue
    size=$(du -sb -- "${src_root}/${rel}" 2>/dev/null | cut -f1)
    total=$((total + ${size:-0}))
  done
  echo "${total}"
}

# Copies an entry (file or folder) from src_root/rel to dst_root/rel, preserving attributes (cp
# -a) and creating parent folders as needed. Does nothing if the source is absent. Returns 1 if
# the copy fails.
zgp_copy_rel_cli() {
  local src_root="$1" dst_root="$2" rel="$3"
  local src="${src_root}/${rel}" dst="${dst_root}/${rel}"
  [[ -e "${src}" ]] || return 0
  mkdir -p "$(dirname "${dst}")" || return 1
  cp -a -- "${src}" "${dst}"
}

# ---------------------------------------------------------------------------------------------
# --- Build the list of candidate blacklisted games (with detected store) ---
declare -A bl_name_by_slug
declare -A bl_dir_by_slug
sorted_bl_slugs=()

while IFS=$'\x1f' read -r b_slug b_name b_dir; do
  [[ -z "${b_slug}" ]] && continue
  bl_name_by_slug["${b_slug}"]="${b_name}"
  bl_dir_by_slug["${b_slug}"]="${b_dir}"
  sorted_bl_slugs+=("${b_slug}")
done < <(
  while IFS= read -r bl; do
    [[ -z "${bl}" ]] && continue
    safe_bl="${bl//\'/\'\'}"
    sqlite3 "${lutris_db}" "SELECT slug || char(31) || name || char(31) || directory FROM games WHERE runner='wine' AND slug='${safe_bl}' LIMIT 1;" 2>/dev/null
  done < <(zgu_get_blacklisted_slugs "${lutris_db}")
)

# ---------------------------------------------------------------------------------------------
# --- Group blacklisted games by detected store ---
# "lpm isolate" works per STORE, never per single game: all games currently living in a store's
# giga-prefix are isolated in one pass, each getting its own independent prefix (200 games in
# the store = 200 prefixes). A store can in theory be spread over several giga-prefixes
# (distinct "directory" in the database); they are all merged under the same store code so
# "isolate store X" covers every X game wherever it lives.
declare -A store_slugs      # store code -> matching slugs, space-separated
declare -A dir_store_cache  # resolved giga_dir -> store code (per-folder memoization)

for b_slug in "${sorted_bl_slugs[@]}"; do
  b_dir="${bl_dir_by_slug[${b_slug}]}"
  real_b_dir=$(realpath -e "${b_dir}" 2>/dev/null)
  [[ -z "${real_b_dir}" ]] && continue

  if [[ -z "${dir_store_cache[${real_b_dir}]+x}" ]]; then
    dir_store_cache["${real_b_dir}"]=$(zgu_detect_isolation_store "${lutris_db}" "${real_b_dir}")
  fi
  b_store="${dir_store_cache[${real_b_dir}]}"
  [[ -z "${b_store}" ]] && continue

  # The launcher itself (see zgu_is_store_launcher_name) is never a game to isolate: it is
  # already duplicated in each isolated game's prefix. Excluded here, before any attempt,
  # instead of failing on every run.
  zgu_is_store_launcher_name "${b_store}" "${bl_name_by_slug[${b_slug}]}" && continue

  store_slugs["${b_store}"]+="${b_slug} "
done

# Translates a user argument (store code, common alias, or slug of an isolable game) into the
# internal store code (egs/ea/ubisoft/battlenet). Prints nothing, returns 1 if nothing matches;
# the caller decides the error message.
zgp_resolve_store_arg() {
  local raw="$1" arg
  arg="${raw,,}"
  case "${arg}" in
    egs|epic|epicgames|epic-games|"epic games"|"epic games store")
      echo "egs"; return 0 ;;
    ea|eaapp|ea-app|eadesktop|ea-desktop|"ea app"|"ea desktop")
      echo "ea"; return 0 ;;
    ubisoft|uplay|ubisoftconnect|ubisoft-connect|"ubisoft connect")
      echo "ubisoft"; return 0 ;;
    battlenet|battle.net|"battle net"|blizzard)
      echo "battlenet"; return 0 ;;
  esac

  # Otherwise: possibly the slug of a currently isolable game; reuse the store already
  # resolved above for its folder rather than detecting it again.
  local slug_dir real_slug_dir slug_store
  slug_dir="${bl_dir_by_slug[${raw}]:-}"
  [[ -z "${slug_dir}" ]] && return 1
  real_slug_dir=$(realpath -e "${slug_dir}" 2>/dev/null)
  [[ -z "${real_slug_dir}" ]] && return 1
  slug_store="${dir_store_cache[${real_slug_dir}]:-}"
  [[ -z "${slug_store}" ]] && return 1
  echo "${slug_store}"
}

# ---------------------------------------------------------------------------------------------
# --- Select the store to isolate entirely ---
target_store=""

if [[ -n "${cli_store_arg}" ]]; then
  target_store=$(zgp_resolve_store_arg "${cli_store_arg}")
  if [[ -z "${target_store}" ]] || [[ -z "${store_slugs[${target_store}]:-}" ]]; then
    zgu_cli_error "$(t isolate.store_arg_invalid "${cli_store_arg}")"
    exit 1
  fi
fi

if [[ -z "${target_store}" ]] || [[ -z "${store_slugs[${target_store}]:-}" ]]; then
  zgu_cli_error "$(t isolate.none_found)"
  exit 0
fi

read -r -a slugs_to_isolate <<< "${store_slugs[${target_store}]}"

# ---------------------------------------------------------------------------------------------
# --- Confirmation ---
if [[ "${confirm_flag}" != "yes" ]]; then
  t isolate.confirm_cli_store "$(zgu_store_display_name "${target_store}")" "${#slugs_to_isolate[@]}"
  for s in "${slugs_to_isolate[@]}"; do
    t isolate.confirm_cli_item "${bl_name_by_slug[${s}]}" "${s}"
  done
  read -r -p "$(t isolate.confirm_cli_prompt)" response || response="n"  # EOF (no terminal) = cancel, never an implicit confirmation
  case "${response}" in
    [nN]) t isolate.cancelled_cli; exit 0 ;;
    *) ;;
  esac
fi

# Reports an isolation failure for a given game: always printed on stderr.
zgp_isolate_report_error() {
  local msg="$1"
  echo "${msg}" >&2
}

# ---------------------------------------------------------------------------------------------
# --- Isolating one game ---
#
# zgp_isolate_one runs one step function after the other; each step returns 1 after reporting its
# own error (zgp_iso_fail), and a step that already wrote something removes it before returning
# (see zgp_iso_copy_one). The steps share the state of the game being isolated through the
# "iso_*" variables below (one game is processed at a time).
iso_slug=""; iso_game_name=""; iso_giga_dir=""; iso_store=""
iso_old_id=""; iso_old_executable=""; iso_old_configpath=""; iso_old_installer_slug=""
iso_old_yml=""; iso_old_args=""; iso_game_rel_paths=()
iso_new_slug=""; iso_new_prefix_dir=""; iso_new_config_id=""; iso_new_yml=""; iso_new_executable=""

# Reports a failure of the current game: message on stderr + one log line.
# $1 = message to show, $2 = reason written in the log.
zgp_iso_fail() {
  zgp_isolate_report_error "$1"
  zgu_log "isolate" "ERROR" "slug=${iso_slug}${iso_store:+ store=${iso_store}} reason=$2"
}

# Step 1: reads and validates everything known about the game (database row, YAML, store,
# game-specific paths). Fills the iso_* variables; nothing is written anywhere.
# Checks that the giga-prefix directory stays under games_dir (iso_giga_dir is set to its real
# path). Returns 1 with an error otherwise.
zgp_iso_check_giga_dir() {
  # Security: giga_dir comes from the Lutris database, possibly hand-edited or from a game
  # added outside lpm. Same guard as zgu_resolve_prefix_dir_by_slug (zgu-lutris-utils.sh) and
  # safe_delete_prefix_dir (zgp-game-uninstaller.sh): the real path must stay a subfolder of
  # games_dir.
  local real_giga_dir
  real_giga_dir=$(realpath -e "${iso_giga_dir}" 2>/dev/null)
  if [[ -z "${real_giga_dir}" ]] || [[ "${real_giga_dir}" != "${real_games_dir}/"* ]]; then
    zgp_iso_fail "$(t isolate.game_paths_not_found "${iso_game_name}")" "invalid_giga_prefix"
    return 1
  fi
  iso_giga_dir="${real_giga_dir}"

  iso_store=$(zgu_detect_isolation_store "${lutris_db}" "${iso_giga_dir}")
  if [[ -z "${iso_store}" ]]; then
    zgp_iso_fail "$(t isolate.store_unknown "${iso_game_name}")" "unknown_store"
    return 1
  fi
  return 0
}

# Reads the existing DB row of the game (iso_old_*), validating what comes from the database.
zgp_iso_read_db_row() {
  local safe_slug="${iso_slug//\'/\'\'}"
  # Full existing row (id, executable, configpath, installer_slug). A plain UPDATE is not
  # enough for EA App (slug "ea-app" shared between the launcher and each game, spec decision
  # #3): targeting by "id" rather than "slug" for the DELETE in zgp_iso_register_db never
  # touches the shared launcher row, for any store.
  local old_row
  old_row=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') || char(31) || COALESCE(installer_slug,'') FROM games WHERE slug='${safe_slug}' AND directory='${iso_giga_dir//\'/\'\'}' LIMIT 1;" 2>/dev/null)
  IFS=$'\x1f' read -r iso_old_id iso_old_executable iso_old_configpath iso_old_installer_slug <<< "${old_row}"
  # Security: "id" also comes from the Lutris database, possibly hand-edited. It is used
  # unquoted in "DELETE ... WHERE id=${iso_old_id}" (id is numeric, never put in quotes).
  # Without this validation, a corrupted id containing SQL (e.g. "1); DROP TABLE games; --")
  # would be injected directly.
  if [[ -z "${iso_old_id}" ]] || [[ ! "${iso_old_id}" =~ ^[0-9]+$ ]]; then
    zgp_iso_fail "$(t isolate.game_paths_not_found "${iso_game_name}")" "invalid_db_id"
    return 1
  fi

  # Security: configpath comes from the Lutris database (same distrust as "directory"). It is a
  # plain identifier with no folder component (always "<slug>-<timestamp>", see
  # zgp_iso_clone_yml and config_id in zgp-game-installer.sh), so anything containing a "/" is
  # rejected before building a path with it, to stop a configpath like "../../etc/cron.d/x"
  # from moving the YAML, and above all the final "rm -f", out of lutris_config_dir.
  if [[ -z "${iso_old_configpath}" ]] || [[ "${iso_old_configpath}" == *"/"* ]]; then
    zgp_iso_fail "$(t isolate.configpath_invalid "${iso_game_name}")" "invalid_configpath"
    return 1
  fi
  return 0
}

# Reads the launch args from the YAML already in place into iso_old_args.
zgp_iso_read_old_args() {
  # Launch args (proprietary protocol) read from the YAML already in place, never rebuilt by
  # hand: for every store handled here, the game is always launched via the shared launcher +
  # a game identifier as parameter.
  iso_old_yml="${lutris_config_dir}/${iso_old_configpath}.yml"
  iso_old_args=""
  if [[ -f "${iso_old_yml}" ]]; then
    iso_old_args=$(YML_PATH="${iso_old_yml}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("game", {}).get("args", ""))
except Exception:
    pass
' 2>/dev/null)
  fi
}

zgp_iso_load_game() {
  iso_slug="$1"
  iso_giga_dir="${bl_dir_by_slug[${iso_slug}]}"
  iso_game_name="${bl_name_by_slug[${iso_slug}]}"
  iso_store=""

  zgp_iso_check_giga_dir || return 1

  iso_store=$(zgu_detect_isolation_store "${lutris_db}" "${iso_giga_dir}")
  if [[ -z "${iso_store}" ]]; then
    zgp_iso_fail "$(t isolate.store_unknown "${iso_game_name}")" "unknown_store"
    return 1
  fi

  zgp_iso_read_db_row || return 1
  zgp_iso_read_old_args

  # Resolve the game-specific paths (never the base, never another game of the same
  # giga-prefix): fail cleanly rather than guess if nothing is found.
  iso_game_rel_paths=()
  local rp
  while IFS= read -r rp; do
    [[ -n "${rp}" ]] && iso_game_rel_paths+=("${rp}")
  done < <(zgp_resolve_game_paths "${iso_store}" "${iso_giga_dir}" "${iso_game_name}" "${iso_old_args}")

  if [[ ${#iso_game_rel_paths[@]} -eq 0 ]]; then
    zgp_iso_fail "$(t isolate.game_paths_not_found "${iso_game_name}")" "game_paths_not_found"
    return 1
  fi
}

# Step 2: chooses the slug and folder of the isolated game. The slug is renamed only for EA App
# (slug "ea-app" shared between the launcher and each game, spec decision #3), unchanged for
# the 3 other stores (slug already unique per game, confirmed via pga.db).
zgp_iso_choose_target() {
  iso_new_slug="${iso_slug}"
  if [[ "${iso_store}" = "ea" ]]; then
    local suffix n=2
    suffix=$(zgp_ascii_suffix "${iso_game_name}")
    iso_new_slug="${iso_slug}-${suffix}"
    while [[ -d "${games_dir}/${iso_new_slug}" ]] || [[ -n "$(sqlite3 "${lutris_db}" "SELECT 1 FROM games WHERE slug='${iso_new_slug//\'/\'\'}' LIMIT 1;" 2>/dev/null)" ]]; do
      iso_new_slug="${iso_slug}-${suffix}-${n}"
      n=$((n + 1))
    done
  fi

  iso_new_prefix_dir="${games_dir}/${iso_new_slug}"
  if [[ -e "${iso_new_prefix_dir}" ]]; then
    zgp_iso_fail "$(t isolate.already_exists "${iso_game_name}" "${iso_new_prefix_dir}")" "target_prefix_already_exists"
    return 1
  fi
}

# Step 3: refuses BEFORE writing anything if the copy would not fit (1 GiB safety margin).
zgp_iso_check_space() {
  local socle_list=() socle_entry need_bytes free_bytes
  while IFS= read -r socle_entry; do
    [[ -n "${socle_entry}" ]] && socle_list+=("${socle_entry}")
  done < <(zgp_socle_paths "${iso_store}")
  need_bytes=$(zgp_rel_size_bytes "${iso_giga_dir}" "${iso_game_rel_paths[@]}" "${socle_list[@]}")
  free_bytes=$(df -B1 --output=avail -- "${games_dir}" 2>/dev/null | tail -n 1 | tr -d ' ')
  if [[ -n "${free_bytes}" ]] && (( need_bytes + 1073741824 > free_bytes )); then
    zgp_iso_fail "$(t isolate.not_enough_space "${iso_game_name}")" "not_enough_space needed=${need_bytes} free=${free_bytes}"
    return 1
  fi
}

# Copies one entry of the shared prefix into the new one. $1 = path relative to both prefixes,
# $2 = progress message key (isolate.copying_base_cli / isolate.copying_game_cli). On failure the
# new prefix is removed entirely, so nothing half-copied is left behind.
zgp_iso_copy_one() {
  t "$2" "${iso_game_name}"
  if ! zgp_copy_rel_cli "${iso_giga_dir}" "${iso_new_prefix_dir}" "$1"; then
    zgp_iso_fail "$(t isolate.copy_failed "${iso_game_name}")" "copy_failed"
    rm -rf "${iso_new_prefix_dir}"
    return 1
  fi
}

# Step 4: creates the new prefix and copies into it the base (launcher, credentials, session),
# then the game folders (only this game's, never the other games).
zgp_iso_copy_prefix() {
  mkdir -p "${iso_new_prefix_dir}" || {
    zgp_iso_fail "$(t isolate.mkdir_failed "${iso_game_name}" "${iso_new_prefix_dir}")" "mkdir_failed"
    return 1
  }

  local entry rp
  if [[ "${iso_store}" = "ubisoft" ]]; then
    # Special case: the base IS "Ubisoft Game Launcher/" minus the per-game "games/" and
    # "data/" subfolders (handled as the game folder below).
    local ubi_root="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
    while IFS= read -r entry; do
      zgp_iso_copy_one "${ubi_root}/$(basename "${entry}")" isolate.copying_base_cli || return 1
    done < <(find "${iso_giga_dir}/${ubi_root}" -mindepth 1 -maxdepth 1 ! -name games ! -name data 2>/dev/null)
  else
    while IFS= read -r entry; do
      [[ -z "${entry}" ]] && continue
      zgp_iso_copy_one "${entry}" isolate.copying_base_cli || return 1
    done < <(zgp_socle_paths "${iso_store}")
  fi

  for rp in "${iso_game_rel_paths[@]}"; do
    zgp_iso_copy_one "${rp}" isolate.copying_game_cli || return 1
  done

  mkdir -p "${iso_new_prefix_dir}/dosdevices"
  ln -sf "../drive_c" "${iso_new_prefix_dir}/dosdevices/c:"
  [[ ! -e "${iso_new_prefix_dir}/pfx" ]] && ln -sf "." "${iso_new_prefix_dir}/pfx"
  return 0
}

# Step 5: clones the Lutris YAML: same keys as the original (notably game.args, which carries
# the proprietary game identifier -- AppName/offerIds/ID/product code -- unchanged by isolation;
# only the prefix path changes), paths substituted giga_dir -> new prefix. Same anti-hook policy
# as at install (zgp-game-installer.sh): a possibly hand-edited source YAML must not be able to
# carry a command run automatically by Lutris; it is commented out, not deleted. Sets
# iso_new_config_id / iso_new_yml / iso_new_executable.
# Writes the cloned Lutris yml (prefix swapped to the new one, "script"/"version" dropped).
zgp_iso_write_cloned_yml() {
  OLD_YML="${iso_old_yml}" NEW_YML="${iso_new_yml}" OLD_PREFIX="${iso_giga_dir}" NEW_PREFIX="${iso_new_prefix_dir}" python3 -c '
import os, yaml, re

old_prefix = os.environ["OLD_PREFIX"]
new_prefix = os.environ["NEW_PREFIX"]
prefix_pattern = re.escape(old_prefix)

def swap_prefix(obj):
    if isinstance(obj, dict):
        return {k: swap_prefix(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [swap_prefix(v) for v in obj]
    elif isinstance(obj, str):
        return re.sub(prefix_pattern + r"(?=/|$)", new_prefix, obj)
    return obj

try:
    with open(os.environ["OLD_YML"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        data.pop("script", None)
        data.pop("version", None)
        data = swap_prefix(data)
        if "game" not in data or not isinstance(data["game"], dict):
            data["game"] = {}
        data["game"]["prefix"] = new_prefix
        with open(os.environ["NEW_YML"], "w") as f:
            yaml.dump(data, f, sort_keys=False)
except Exception:
    pass
' 2>/dev/null
}

# Reads game.exe of the cloned yml into iso_new_executable.
zgp_iso_read_new_executable() {
  iso_new_executable=$(YML_PATH="${iso_new_yml}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("game", {}).get("exe", ""))
except Exception:
    pass
' 2>/dev/null)
}

zgp_iso_clone_yml() {
  t isolate.registering
  iso_new_config_id="${iso_new_slug}-$(date +%s%N)"
  iso_new_yml="${lutris_config_dir}/${iso_new_config_id}.yml"
  iso_new_executable=""

  if [[ -f "${iso_old_yml}" ]]; then
    zgp_iso_write_cloned_yml

    # Launch hooks (prelaunch_command...): neutralized as a COMMENT (marker
    # "lpm:hook-disabled", restorable), as at install, never deleted.
    [[ -f "${iso_new_yml}" ]] && zgu_apply_hook_policy "${iso_new_yml}" false broad
    [[ -f "${iso_new_yml}" ]] && zgp_iso_read_new_executable
  fi

  # Fallback if the source YAML was missing/unreadable or yielded no exe: direct prefix
  # substitution on the path already known in the database (old executable), same logic.
  if [[ -z "${iso_new_executable}" ]]; then
    iso_new_executable="${iso_old_executable/${iso_giga_dir}/${iso_new_prefix_dir}}"
  fi
  [[ "${iso_new_executable}" != /* ]] && iso_new_executable="${iso_new_prefix_dir}/${iso_new_executable}"
  return 0
}

# Step 6: replaces the game's Lutris database row by one pointing to the new prefix. DELETE by id
# (never by slug): the slug may be shared by several rows (EA App case, spec decision #3). The id
# read in zgp_iso_load_game in the same run removes exactly the isolated game's row without ever
# risking the shared launcher row, for any store.
zgp_iso_register_db() {
  local safe_name="${iso_game_name//\'/\'\'}"
  local safe_new_slug="${iso_new_slug//\'/\'\'}"
  local safe_new_config_id="${iso_new_config_id//\'/\'\'}"
  local safe_prefix_dir="${iso_new_prefix_dir//\'/\'\'}"
  local safe_executable="${iso_new_executable//\'/\'\'}"
  local safe_installer_slug="${iso_old_installer_slug//\'/\'\'}"

  sqlite3 "${lutris_db}" "DELETE FROM games WHERE id=${iso_old_id};"
  sqlite3 "${lutris_db}" <<SQL
INSERT INTO games (name, slug, installer_slug, parent_slug, runner, executable, directory, configpath, updated, installed, installed_at)
VALUES (
  '${safe_name}',
  '${safe_new_slug}',
  '${safe_installer_slug:-${safe_new_slug}}',
  '',
  'wine',
  '${safe_executable}',
  '${safe_prefix_dir}',
  '${safe_new_config_id}',
  strftime('%s','now'),
  1,
  strftime('%s','now')
);
SQL
}

# Step 7: purges only the game-specific folders in the original giga-prefix (never the base,
# which stays shared by the games still living there; spec decision #5), and the old YAML. Done
# only after confirming the copy produced a non-empty prefix, so game files are never lost if
# the copy failed midway.
zgp_iso_purge_shared() {
  if [[ -n "$(find "${iso_new_prefix_dir}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    t isolate.purging
    local rp src real_src
    for rp in "${iso_game_rel_paths[@]}"; do
      src="${iso_giga_dir}/${rp}"
      real_src=$(realpath -e "${src}" 2>/dev/null)
      if [[ -n "${real_src}" ]] && [[ "${real_src}" == "${iso_giga_dir}/"* ]]; then
        rm -rf "${real_src}"
      fi
    done
  fi

  rm -f "${lutris_config_dir}/${iso_old_configpath}.yml" 2>/dev/null
}

# Returns 0 on success, 1 otherwise. Errors go through zgp_iso_fail (stderr); normal progress
# (copy in progress, etc.) is printed separately via the "t isolate.copying_*_cli" messages.
zgp_isolate_one() {
  zgp_iso_load_game "$1" || return 1
  zgp_iso_choose_target || return 1
  zgp_iso_check_space || return 1
  zgp_iso_copy_prefix || return 1
  zgp_iso_clone_yml
  zgp_iso_register_db
  zgp_iso_purge_shared

  zgu_log "isolate" "OK" "slug=${iso_slug} new_slug=${iso_new_slug} store=${iso_store} name=${iso_game_name}"
  zgu_cli_ok "$(t isolate.done_cli "${iso_game_name}")"
  return 0
}

# ---------------------------------------------------------------------------------------------
# --- Execution ---
exit_code=0
for target_slug in "${slugs_to_isolate[@]}"; do
  zgp_isolate_one "${target_slug}"
  isolate_one_status=$?
  [[ "${isolate_one_status}" -eq 0 ]] || exit_code=1
done

exit "${exit_code}"
