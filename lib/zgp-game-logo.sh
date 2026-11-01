#!/bin/bash

# --- lpm logo [slug...|--all] ---
#
# Fetches a transparent logo (SteamGridDB "Logo": the game title as a cut-out image meant to
# be overlaid on a banner, NOT a full-screen background) for one or more installed games and
# saves it as $GAMEDIR/splash/logo.png -- the image shown permanently on top of everything
# (black screen, picker, banner) in the LPM Launcher (see zgl-launcher-orchestrator.sh /
# zgu-launcher-screen.py).
#
# Separate command, never hooked into "lpm launcher ... on": it is the only feature that
# depends on a third-party service (network + API key), so a SteamGridDB outage or a missing
# key must not block enabling the launcher. Without $GAMEDIR/splash/logo.png the
# orchestrator simply draws no logo. Structure mirrors zgp-game-icon.sh and
# zgp-game-splash.sh ("lpm icon"/"lpm splash").
#
# Independent of the launcher's activation state: $GAMEDIR/splash/ is created here if
# missing.
#
# $1, $2... = target game slugs (always non-empty in CLI), or "--all" for all eligible
# games.
#
# "--url <url>" (optional): see zgp-game-icon.sh -- same mechanism, single target slug.
cli_targets=()
forced_url=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" = "--url" ]]; then
    forced_url="${2:-}"
    shift $(( $# >= 2 ? 2 : 1 ))
  else
    cli_targets+=("$1")
    shift
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-sgdb.sh
source "${script_dir}/zgu-sgdb.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-lpm-paths.sh
source "${script_dir}/zgu-lpm-paths.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# Same as zgp-game-icon.sh/zgp-game-splash.sh: strictly personal key, never shared or
# bundled with lpm; uses the SAME key file as "lpm icon"/"lpm splash", so one SteamGridDB
# account covers all three commands.
sgdb_key=""

# --- 1. Dependency check ---
zgp_logo_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

for cmd in sqlite3 curl python3 realpath; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_logo_report_error_early "$(t logo.cmd_missing "${cmd}")"
    exit 1
  fi
done

# ImageMagick: every fetched image (png/jpeg/webp) is passed through "convert"/"magick"
# before being saved as "logo.png". This guarantees a valid PNG whatever the source format
# and preserves transparency (no background added, unlike the square crop of "lpm icon").
# cairo.ImageSurface.create_from_png() (zgu-launcher-screen.py) only accepts PNG.
convert_bin=()
if command -v magick >/dev/null 2>&1; then
  convert_bin=(magick)
elif command -v convert >/dev/null 2>&1; then
  convert_bin=(convert)
else
  zgp_logo_report_error_early "$(t logo.imagemagick_missing)"
  exit 1
fi

if ! python3 -c "import sys" >/dev/null 2>&1; then
  zgp_logo_report_error_early "$(t logo.cmd_missing "python3")"
  exit 1
fi

# --- 2. Flatpak vs native package detection + Lutris path resolution ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_logo_report_error_early "$(t logo.lutris_missing)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_system_file="${lutris_flatpak_system_file}"
    ;;
  package)
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
  zgp_logo_report_error_early "$(t logo.db_missing "${lutris_db}")"
  exit 1
fi

# --- 3. Fetch Wine games from the Lutris DB ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_logo_report_error_early "$(t logo.none_found)"
  exit 0
fi

declare -A name_by_slug
declare -A dir_by_slug

# Games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) are
# outside lpm's one-game-one-prefix model and never listed here (same filter as
# zgp-game-icon.sh/zgp-game-splash.sh, see zgu_get_blacklisted_slugs).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

sorted_slugs=()

while IFS=$'\x1f' read -r g_name g_slug g_dir; do
  [[ -z "${g_slug}" ]] && continue
  [[ -n "${blacklisted_slugs[${g_slug}]:-}" ]] && continue
  [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"

  name_by_slug["${g_slug}"]="${g_name}"
  dir_by_slug["${g_slug}"]="${g_dir}"
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

if [[ ${#sorted_slugs[@]} -eq 0 ]]; then
  zgp_logo_report_error_early "$(t logo.none_found)"
  exit 0
fi

# --- 4. Target selection ---
# ("cli_targets" is always non-empty here; the former interactive Zenity mode was removed.)
targets=()

if [[ "${cli_targets[0]}" = "--all" ]]; then
  targets=("${sorted_slugs[@]}")
else
  for target_slug in "${cli_targets[@]}"; do
    if [[ -n "${name_by_slug[${target_slug}]:-}" ]]; then
      targets+=("${target_slug}")
    elif [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t logo.slug_blacklisted "${target_slug}")"
      exit 1
    else
      zgu_cli_error "$(t logo.slug_not_found "${target_slug}")"
      exit 1
    fi
  done
fi

if [[ -n "${forced_url}" ]] && [[ ${#targets[@]} -ne 1 ]]; then
  zgu_cli_error "$(t logo.force_url_single_target)"
  exit 1
fi

zgp_steam_logo_url() {
  local appid="$1"
  printf 'https://cdn.cloudflare.steamstatic.com/steam/apps/%s/logo.png' "${appid}"
}

# --- 7. Process one game ---
#
# Returns 0 if a logo was saved, 1 otherwise (game not found on SteamGridDB or Steam, no
# logo available, download/conversion failed, or user cancelled). Never silent: each failure
# goes through zgp_logo_report_skip, printed on stderr.
zgp_logo_report_skip() {
  local msg="$1"
  echo "${msg}" >&2
}

zgp_logo_save_from_url() {
  local slug="$1" game_dir="$2" chosen_url="$3"

  local splash_dir
  splash_dir="$(zgu_lpm_path "${game_dir}" splash)"
  mkdir -p "${splash_dir}"

  local ext="${chosen_url##*.}"
  ext="${ext,,}"
  local raw_file="${splash_dir}/.lpm-download.${ext}"

  if ! curl -sLf --max-time 30 "${chosen_url}" -o "${raw_file}" 2>/dev/null; then
    rm -f "${raw_file}"
    return 1
  fi

  # "-background none" keeps the logo's original transparency instead of replacing it with a
  # background (unlike zgp-game-splash.sh: a full-screen banner is always opaque, a logo is
  # not).
  if ! "${convert_bin[@]}" "${raw_file}" -background none "${splash_dir}/logo.png" 2>/dev/null; then
    rm -f "${raw_file}"
    return 1
  fi
  rm -f "${raw_file}"
  return 0
}

zgp_logo_process_one() {
  local slug="$1" g_name="$2" game_dir="$3"

  local chosen_url=""

  # "--url" already set by the caller (gui/page_images, manual mode) -- see zgp-game-icon.sh
  # for this short-circuit (it also skips the Steam fallback below, since an image is
  # already chosen).
  if [[ -n "${forced_url}" ]]; then
    chosen_url="${forced_url}"
  else
  local search_results
  search_results=$(zgp_sgdb_search "${g_name}")

  local chosen_game_id="" chosen_game_name="" logos_urls=""

  if [[ -n "${search_results}" ]]; then
    local n_matches
    n_matches=$(printf '%s\n' "${search_results}" | grep -c .)

    if [[ "${n_matches}" -gt 1 ]]; then
      t logo.pick_game_text_cli "${g_name}"
      local -A idx_to_id=() idx_to_name=()
      local idx=1 g_gid g_sgdb_name
      while IFS=$'\t' read -r g_gid g_sgdb_name; do
        [[ -z "${g_gid}" ]] && continue
        printf '  %d) %s\n' "${idx}" "${g_sgdb_name}"
        idx_to_id["${idx}"]="${g_gid}"
        idx_to_name["${idx}"]="${g_sgdb_name}"
        idx=$((idx + 1))
      done <<< "${search_results}"
      local choice
      read -r -p "$(t logo.pick_game_prompt_cli)" choice
      chosen_game_id="${idx_to_id[${choice}]:-}"
      chosen_game_name="${idx_to_name[${choice}]:-}"

      if [[ -z "${chosen_game_id}" ]]; then
        zgp_logo_report_skip "$(t logo.cancelled_by_user "${g_name}")"
        return 1
      fi
    else
      chosen_game_id=$(printf '%s\n' "${search_results}" | head -n1 | cut -f1)
      chosen_game_name=$(printf '%s\n' "${search_results}" | head -n1 | cut -f2)
    fi

    local sr_gid sr_name
    while IFS=$'\t' read -r sr_gid sr_name; do
      if [[ "${sr_gid}" = "${chosen_game_id}" ]]; then
        chosen_game_name="${sr_name}"
        break
      fi
    done <<< "${search_results}"
    [[ -z "${chosen_game_name}" ]] && chosen_game_name="${g_name}"

    logos_urls=$(zgp_sgdb_logos "${chosen_game_id}")
  fi

  if [[ -n "${logos_urls}" ]]; then
    # The former Zenity visual picker was removed (no interactive entry point in bin/lpm);
    # in CLI the first candidate logo is always taken.
    chosen_url=$(printf '%s\n' "${logos_urls}" | head -n1 | cut -f1)
  fi

  # --- Steam fallback: only if SteamGridDB gave nothing (game not found, or found with no
  # published logo); same logic as zgp-game-icon.sh for Client Icons. ---
  if [[ -z "${chosen_url}" ]]; then
    local steam_appid
    steam_appid=$(zgp_steam_find_appid "${g_name}")
    if [[ -n "${steam_appid}" ]]; then
      local steam_url
      steam_url=$(zgp_steam_logo_url "${steam_appid}")
      if curl -sLf --max-time 15 -o /dev/null "${steam_url}" 2>/dev/null; then
        chosen_url="${steam_url}"
      fi
    fi
  fi

  if [[ -z "${chosen_url}" ]]; then
    zgp_logo_report_skip "$(t logo.no_logo_available "${g_name}")"
    zgu_log "logo" "ERROR" "slug=${slug} reason=no_logo_available"
    return 1
  fi
  fi

  if ! zgp_logo_save_from_url "${slug}" "${game_dir}" "${chosen_url}"; then
    zgp_logo_report_skip "$(t logo.download_failed "${g_name}")"
    zgu_log "logo" "ERROR" "slug=${slug} reason=download_or_conversion_failed"
    return 1
  fi

  zgu_log "logo" "OK" "slug=${slug} name=${g_name}"
  t logo.done_cli "${g_name}"
  return 0
}

# --- 8. Execution ---
zgp_sgdb_ensure_key logo || { zgp_logo_report_error_early "$(t logo.no_key_cancelled)"; exit 1; }

exit_code=0
for target_slug in "${targets[@]}"; do
  zgp_logo_process_one "${target_slug}" "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}" || exit_code=1
done

exit "${exit_code}"
