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

# Looks the logo up on SteamGridDB; sets logo_found_url (empty if none). Args: g_name.
# Returns 1 only when the user cancelled the game choice.
logo_found_url=""
zgp_logo_find_on_sgdb() {
  local g_name="$1"
  logo_found_url=""
  local search_results logos_urls=""
  search_results=$(zgp_sgdb_search "${g_name}")
  [[ -n "${search_results}" ]] || return 0
  if ! zgp_sgdb_pick_game logo "${g_name}" "${search_results}"; then
    zgp_logo_report_skip "$(t logo.cancelled_by_user "${g_name}")"
    return 1
  fi
  logos_urls=$(zgp_sgdb_logos "${sgdb_pick_id}")
  # In CLI the first candidate logo is always taken.
  [[ -n "${logos_urls}" ]] && logo_found_url=$(printf '%s\n' "${logos_urls}" | head -n1 | cut -f1)
  return 0
}

# Steam fallback, only if SteamGridDB gave nothing; sets logo_found_url. Arg: g_name.
zgp_logo_find_on_steam() {
  local g_name="$1" steam_appid steam_url
  steam_appid=$(zgp_steam_find_appid "${g_name}")
  [[ -n "${steam_appid}" ]] || return 0
  steam_url=$(zgp_steam_logo_url "${steam_appid}")
  if curl -sLf --max-time 15 -o /dev/null "${steam_url}" 2>/dev/null; then
    logo_found_url="${steam_url}"
  fi
}

# Finds the logo URL into logo_chosen_url (forced_url, else SteamGridDB then Steam).
# Args: slug g_name. Returns 1 when nothing usable was found / user cancelled.
logo_chosen_url=""
zgp_logo_choose_url() {
  local slug="$1" g_name="$2"
  logo_chosen_url=""
  # "--url" already set by the caller (gui/page_images): search and Steam fallback skipped.
  if [[ -n "${forced_url}" ]]; then
    logo_chosen_url="${forced_url}"
    return 0
  fi
  zgp_logo_find_on_sgdb "${g_name}" || return 1
  [[ -z "${logo_found_url}" ]] && zgp_logo_find_on_steam "${g_name}"
  if [[ -z "${logo_found_url}" ]]; then
    zgp_logo_report_skip "$(t logo.no_logo_available "${g_name}")"
    zgu_log "logo" "ERROR" "slug=${slug} reason=no_logo_available"
    return 1
  fi
  logo_chosen_url="${logo_found_url}"
  return 0
}

zgp_logo_process_one() {
  local slug="$1" g_name="$2" game_dir="$3"

  zgp_logo_choose_url "${slug}" "${g_name}" || return 1
  if ! zgp_logo_save_from_url "${slug}" "${game_dir}" "${logo_chosen_url}"; then
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
