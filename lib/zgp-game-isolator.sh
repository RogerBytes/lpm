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
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgu_cli_error "$(t isolate.lutris_missing_cli)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_db="${lutris_flatpak_db}"
    lutris_system_file="${lutris_flatpak_system_file}"
    ;;
  package)
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_db="${lutris_package_db}"
    lutris_system_file="${lutris_package_system_file}"
    ;;
  *)
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

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
zgp_slugify() {
  local s="$1"
  s="${s,,}"
  s=$(printf '%s' "${s}" | tr -c 'a-z0-9' '-')
  s=$(printf '%s' "${s}" | sed -E 's/-+/-/g; s/^-//; s/-$//')
  printf '%s' "${s}"
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
  local found=0 p

  case "${store}" in
    egs)
      # The game folder (MandatoryAppFolderName) is read from the .item manifest whose
      # DisplayName matches the game name, not by blind folder scanning.
      local manifests_dir="${giga_dir}/drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests"
      local folder_name=""
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
        [[ -d "${giga_dir}/${p}" ]] && { echo "${p}"; found=1; }
      fi
      ;;

    ea)
      local candidate
      for candidate in \
        "drive_c/Program Files/EA Games/${game_name}" \
        "drive_c/ProgramData/EA Desktop/InstallData/${game_name}" \
        "drive_c/Program Files/Common Files/EAInstaller/${game_name}" \
        "drive_c/users/steamuser/Documents/Electronic Arts/${game_name}"; do
        if [[ -e "${giga_dir}/${candidate}" ]]; then
          echo "${candidate}"
          found=1
        fi
      done
      for candidate in \
        "drive_c/proton_shortcuts/${game_name}.desktop" \
        "drive_c/users/Public/Desktop/${game_name}.lnk"; do
        [[ -e "${giga_dir}/${candidate}" ]] && echo "${candidate}"
      done
      ;;

    ubisoft)
      p="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/${game_name}"
      if [[ -d "${giga_dir}/${p}" ]]; then
        echo "${p}"
        found=1
      fi
      # The numeric ID (data/<ID>/ folder) is the same one used in the
      # "uplay://launch/<ID>" launch argument already present in the game's existing args;
      # it is read from there rather than guessed.
      local uid
      uid=$(printf '%s' "${old_args}" | grep -oE 'uplay://launch/[0-9]+' | head -n1 | grep -oE '[0-9]+$')
      if [[ -n "${uid}" ]]; then
        p="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/data/${uid}"
        [[ -d "${giga_dir}/${p}" ]] && { echo "${p}"; found=1; }
      fi
      for candidate in \
        "drive_c/proton_shortcuts/${game_name}.desktop" \
        "drive_c/users/${USER}/Desktop/${game_name}.url"; do
        [[ -e "${giga_dir}/${candidate}" ]] && echo "${candidate}"
      done
      ;;

    battlenet)
      # One game = one top-level folder under "Program Files (x86)/", at the same level as
      # "Battle.net/" (not nested inside it). "Battle.net" itself is explicitly excluded
      # (it is the base).
      p="drive_c/Program Files (x86)/${game_name}"
      if [[ -d "${giga_dir}/${p}" ]] && [[ "${game_name}" != "Battle.net" ]]; then
        echo "${p}"
        found=1
      fi
      ;;
  esac

  [[ "${found}" -eq 1 ]]
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
# Returns 0 on success, 1 otherwise. Errors go through zgp_isolate_report_error above (stderr);
# normal progress (copy in progress, etc.) is printed separately via the "t
# isolate.copying_*_cli" messages.
zgp_isolate_one() {
  local slug="$1"
  local giga_dir="${bl_dir_by_slug[${slug}]}"
  local game_name="${bl_name_by_slug[${slug}]}"
  local safe_slug="${slug//\'/\'\'}"

  # Security: giga_dir comes from the Lutris database, possibly hand-edited or from a game
  # added outside lpm. Same guard as resolve_prefix_dir_by_slug (zgp-game-packer.sh) and
  # safe_delete_prefix_dir (zgp-game-uninstaller.sh): the real path must stay a subfolder of
  # games_dir.
  local real_giga_dir
  real_giga_dir=$(realpath -e "${giga_dir}" 2>/dev/null)
  if [[ -z "${real_giga_dir}" ]] || [[ "${real_giga_dir}" != "${real_games_dir}/"* ]]; then
    zgp_isolate_report_error "$(t isolate.game_paths_not_found "${game_name}")"
    zgu_log "isolate" "ERROR" "slug=${slug} reason=invalid_giga_prefix"
    return 1
  fi
  giga_dir="${real_giga_dir}"

  local store
  store=$(zgu_detect_isolation_store "${lutris_db}" "${giga_dir}")
  if [[ -z "${store}" ]]; then
    zgp_isolate_report_error "$(t isolate.store_unknown "${game_name}")"
    zgu_log "isolate" "ERROR" "slug=${slug} reason=unknown_store"
    return 1
  fi

  # Full existing row (id, executable, configpath, installer_slug). A plain UPDATE is not
  # enough for EA App (slug "ea-app" shared between the launcher and each game, spec decision
  # #3): targeting by "id" rather than "slug" for the DELETE below never touches the shared
  # launcher row, for any store.
  local old_row old_id old_executable old_configpath old_installer_slug
  old_row=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') || char(31) || COALESCE(installer_slug,'') FROM games WHERE slug='${safe_slug}' AND directory='${giga_dir//\'/\'\'}' LIMIT 1;" 2>/dev/null)
  IFS=$'\x1f' read -r old_id old_executable old_configpath old_installer_slug <<< "${old_row}"
  # Security: "id" also comes from the Lutris database, possibly hand-edited. Unlike
  # "directory"/"configpath" below, it is not escaped anywhere: it is used unquoted in "DELETE
  # ... WHERE id=${old_id}" below (id is numeric, never put in quotes). Without this
  # validation, a corrupted id containing SQL (e.g. "1); DROP TABLE games; --") would be
  # injected directly.
  if [[ -z "${old_id}" ]] || [[ ! "${old_id}" =~ ^[0-9]+$ ]]; then
    zgp_isolate_report_error "$(t isolate.game_paths_not_found "${game_name}")"
    zgu_log "isolate" "ERROR" "slug=${slug} reason=invalid_db_id"
    return 1
  fi

  # Security: configpath comes from the Lutris database, possibly hand-edited (same distrust
  # as "directory" above). Unlike "directory", it is not an absolute path but a plain
  # identifier with no folder component (always generated here and at install time as
  # "<slug>-<timestamp>", see new_config_id below and config_id in zgp-game-installer.sh), so
  # anything containing a "/" is rejected before building a path with it, to stop a configpath
  # like "../../etc/cron.d/x" from moving old_yml, and above all the final "rm -f", out of
  # lutris_config_dir.
  if [[ -z "${old_configpath}" ]] || [[ "${old_configpath}" == *"/"* ]]; then
    zgp_isolate_report_error "$(t isolate.configpath_invalid "${game_name}")"
    zgu_log "isolate" "ERROR" "slug=${slug} reason=invalid_configpath"
    return 1
  fi

  # Launch args (proprietary protocol) read from the YAML already in place, never rebuilt by
  # hand: for every store handled here, the game is always launched via the shared launcher +
  # a game identifier as parameter.
  local old_yml="${lutris_config_dir}/${old_configpath}.yml"
  local old_args=""
  if [[ -f "${old_yml}" ]]; then
    old_args=$(YML_PATH="${old_yml}" python3 -c '
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

  # Resolve the game-specific paths (never the base, never another game of the same
  # giga-prefix): fail cleanly rather than guess if nothing is found.
  local game_rel_paths=()
  local rp
  while IFS= read -r rp; do
    [[ -n "${rp}" ]] && game_rel_paths+=("${rp}")
  done < <(zgp_resolve_game_paths "${store}" "${giga_dir}" "${game_name}" "${old_args}")

  if [[ ${#game_rel_paths[@]} -eq 0 ]]; then
    zgp_isolate_report_error "$(t isolate.game_paths_not_found "${game_name}")"
    zgu_log "isolate" "ERROR" "slug=${slug} store=${store} reason=game_paths_not_found"
    return 1
  fi

  # Slug of the isolated game: renamed only for EA App (slug "ea-app" shared between the
  # launcher and each game, spec decision #3), unchanged for the 3 other stores (slug already
  # unique per game, confirmed via pga.db).
  local new_slug="${slug}"
  if [[ "${store}" = "ea" ]]; then
    local suffix
    suffix=$(zgp_slugify "${game_name}")
    new_slug="${slug}-${suffix}"
    local n=2
    while [[ -d "${games_dir}/${new_slug}" ]] || [[ -n "$(sqlite3 "${lutris_db}" "SELECT 1 FROM games WHERE slug='${new_slug//\'/\'\'}' LIMIT 1;" 2>/dev/null)" ]]; do
      new_slug="${slug}-${suffix}-${n}"
      n=$((n + 1))
    done
  fi

  local new_prefix_dir="${games_dir}/${new_slug}"
  if [[ -e "${new_prefix_dir}" ]]; then
    zgp_isolate_report_error "$(t isolate.already_exists "${game_name}" "${new_prefix_dir}")"
    zgu_log "isolate" "ERROR" "slug=${slug} store=${store} reason=target_prefix_already_exists"
    return 1
  fi

  mkdir -p "${new_prefix_dir}" || {
    zgp_isolate_report_error "$(t isolate.mkdir_failed "${game_name}" "${new_prefix_dir}")"
    zgu_log "isolate" "ERROR" "slug=${slug} store=${store} reason=mkdir_failed"
    return 1
  }

  # --- 1. Copy the base (launcher, credentials, session) ---
  if [[ "${store}" = "ubisoft" ]]; then
    # Special case: the base IS "Ubisoft Game Launcher/" minus the per-game "games/" and
    # "data/" subfolders (handled as the game folder below).
    local ubi_root="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
    local entry entry_rel
    while IFS= read -r entry; do
      entry_rel="${ubi_root}/$(basename "${entry}")"
      t isolate.copying_base_cli "${game_name}"
      zgp_copy_rel_cli "${giga_dir}" "${new_prefix_dir}" "${entry_rel}" || {
        zgp_isolate_report_error "$(t isolate.copy_failed "${game_name}")"
        zgu_log "isolate" "ERROR" "slug=${slug} store=${store} reason=copy_failed"
        rm -rf "${new_prefix_dir}"
        return 1
      }
    done < <(find "${giga_dir}/${ubi_root}" -mindepth 1 -maxdepth 1 ! -name games ! -name data 2>/dev/null)
  else
    local socle_rel
    while IFS= read -r socle_rel; do
      [[ -z "${socle_rel}" ]] && continue
      t isolate.copying_base_cli "${game_name}"
      zgp_copy_rel_cli "${giga_dir}" "${new_prefix_dir}" "${socle_rel}" || {
        zgp_isolate_report_error "$(t isolate.copy_failed "${game_name}")"
        zgu_log "isolate" "ERROR" "slug=${slug} store=${store} reason=copy_failed"
        rm -rf "${new_prefix_dir}"
        return 1
      }
    done < <(zgp_socle_paths "${store}")
  fi

  # --- 2. Copy the game folder (only this one, never the other games) ---
  for rp in "${game_rel_paths[@]}"; do
    t isolate.copying_game_cli "${game_name}"
    zgp_copy_rel_cli "${giga_dir}" "${new_prefix_dir}" "${rp}" || {
      zgp_isolate_report_error "$(t isolate.copy_failed "${game_name}")"
      zgu_log "isolate" "ERROR" "slug=${slug} store=${store} reason=copy_failed"
      rm -rf "${new_prefix_dir}"
      return 1
    }
  done

  mkdir -p "${new_prefix_dir}/dosdevices"
  ln -sf "../drive_c" "${new_prefix_dir}/dosdevices/c:"
  [[ ! -e "${new_prefix_dir}/pfx" ]] && ln -sf "." "${new_prefix_dir}/pfx"

  # --- 3. Clone the Lutris YAML: same keys as the original (notably game.args, which carries
  # the proprietary game identifier -- AppName/offerIds/ID/product code -- unchanged by
  # isolation; only the prefix path changes), paths substituted giga_dir -> new prefix. Same
  # anti-hook policy as at install (zgp-game-installer.sh): a possibly hand-edited source YAML
  # must not be able to carry a command run automatically by Lutris; it is commented out, not
  # deleted.
  t isolate.registering
  local timestamp new_config_id new_yml new_executable=""
  timestamp=$(date +%s%N)
  new_config_id="${new_slug}-${timestamp}"
  new_yml="${lutris_config_dir}/${new_config_id}.yml"

  if [[ -f "${old_yml}" ]]; then
    OLD_YML="${old_yml}" NEW_YML="${new_yml}" OLD_PREFIX="${giga_dir}" NEW_PREFIX="${new_prefix_dir}" python3 -c '
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

    # Launch hooks (prelaunch_command...): neutralized as a COMMENT (marker
    # "lpm:hook-disabled", restorable), as at install, never deleted.
    [[ -f "${new_yml}" ]] && zgu_apply_hook_policy "${new_yml}" false broad

    if [[ -f "${new_yml}" ]]; then
      new_executable=$(YML_PATH="${new_yml}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("game", {}).get("exe", ""))
except Exception:
    pass
' 2>/dev/null)
    fi
  fi

  # Fallback if the source YAML was missing/unreadable or yielded no exe: direct prefix
  # substitution on the path already known in the database (old_executable), same logic.
  if [[ -z "${new_executable}" ]]; then
    new_executable="${old_executable/${giga_dir}/${new_prefix_dir}}"
  fi
  [[ "${new_executable}" != /* ]] && new_executable="${new_prefix_dir}/${new_executable}"

  local safe_name="${game_name//\'/\'\'}"
  local safe_new_slug="${new_slug//\'/\'\'}"
  local safe_new_config_id="${new_config_id//\'/\'\'}"
  local safe_prefix_dir="${new_prefix_dir//\'/\'\'}"
  local safe_executable="${new_executable//\'/\'\'}"
  local safe_installer_slug="${old_installer_slug//\'/\'\'}"

  # DELETE by id (never by slug): the slug may be shared by several rows (EA App case, spec
  # decision #3). The fresh id re-read just above in the same run removes exactly the isolated
  # game's row without ever risking the shared launcher row, for any store.
  sqlite3 "${lutris_db}" "DELETE FROM games WHERE id=${old_id};"
  sqlite3 "${lutris_db}" <<EOF
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
EOF

  # --- 4. Purge only the game-specific folders in the original giga-prefix (never the base,
  # which stays shared by the games still living there; spec decision #5): done only after
  # confirming the copy produced a non-empty prefix, so game files are never lost if the copy
  # failed midway.
  if [[ -n "$(find "${new_prefix_dir}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    t isolate.purging
    for rp in "${game_rel_paths[@]}"; do
      local src="${giga_dir}/${rp}" real_src
      real_src=$(realpath -e "${src}" 2>/dev/null)
      if [[ -n "${real_src}" ]] && [[ "${real_src}" == "${giga_dir}/"* ]]; then
        rm -rf "${real_src}"
      fi
    done
  fi

  rm -f "${lutris_config_dir}/${old_configpath}.yml" 2>/dev/null

  zgu_log "isolate" "OK" "slug=${slug} new_slug=${new_slug} store=${store} name=${game_name}"
  zgu_cli_ok "$(t isolate.done_cli "${game_name}")"
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
