#!/bin/bash

# --- lpm splash [slug...|--all] ---
#
# Fetches a loading banner (SteamGridDB "Hero": a wide image meant as a wallpaper/backdrop,
# NOT the square icon or the library thumbnail) for one or more installed games and saves it
# as $GAMEDIR/splash/splash.png -- the image the LPM Launcher shows full-screen while
# loading (see zgl-launcher-manager.sh / zgu-launcher-screen.py).
#
# Separate command, never hooked into "lpm launcher ... on": it is the only feature that
# depends on a third-party service (network + API key), so a SteamGridDB outage or a missing
# key must not block enabling the launcher. "lpm launcher ... on" installs no default image;
# without $GAMEDIR/splash/splash.png the orchestrator simply shows a plain black loading
# screen (see zgl-launcher-manager.sh / zgl-launcher-orchestrator.sh). Structure mirrors
# zgp-game-icon.sh ("lpm icon").
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
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# Same as zgp-game-icon.sh: strictly personal key, never shared or bundled with lpm; uses
# the SAME key file as "lpm icon", so one SteamGridDB account covers both commands.
sgdb_key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/steamgriddb.key"
sgdb_api="https://www.steamgriddb.com/api/v2"
sgdb_key=""

# --- 1. Dependency check ---
zgp_splash_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

for cmd in sqlite3 curl python3 realpath; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_splash_report_error_early "$(t splash.cmd_missing "${cmd}")"
    exit 1
  fi
done

# ImageMagick: every fetched image (png/jpeg/webp) is passed through "convert"/"magick"
# before being saved as "splash.png" -- not only .ico files as in "lpm icon" (Heroes are
# never .ico). This guarantees a valid PNG whatever the source format:
# zgu-launcher-screen.py loads the image with cairo.ImageSurface.create_from_png(), which
# only accepts PNG, so a file merely renamed ".png" would break loading.
convert_bin=()
if command -v magick >/dev/null 2>&1; then
  convert_bin=(magick)
elif command -v convert >/dev/null 2>&1; then
  convert_bin=(convert)
else
  zgp_splash_report_error_early "$(t splash.imagemagick_missing)"
  exit 1
fi

if ! python3 -c "import sys" >/dev/null 2>&1; then
  zgp_splash_report_error_early "$(t splash.cmd_missing "python3")"
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
  zgp_splash_report_error_early "$(t splash.lutris_missing)"
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
  zgp_splash_report_error_early "$(t splash.db_missing "${lutris_db}")"
  exit 1
fi

# --- 3. Fetch Wine games from the Lutris DB ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_splash_report_error_early "$(t splash.none_found)"
  exit 0
fi

declare -A name_by_slug
declare -A dir_by_slug

# Games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) are
# outside lpm's one-game-one-prefix model and never listed here: writing a banner into
# $GAMEDIR/splash/ only makes sense if that folder belongs to THIS game (same filter as
# zgp-game-icon.sh/zgp-game-uninstaller.sh/zgp-game-shortcutter.sh, see
# zgu_get_blacklisted_slugs).
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
  zgp_splash_report_error_early "$(t splash.none_found)"
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
      zgu_cli_error "$(t splash.slug_blacklisted "${target_slug}")"
      exit 1
    else
      zgu_cli_error "$(t splash.slug_not_found "${target_slug}")"
      exit 1
    fi
  done
fi

if [[ -n "${forced_url}" ]] && [[ ${#targets[@]} -ne 1 ]]; then
  zgu_cli_error "$(t splash.force_url_single_target)"
  exit 1
fi

# --- 5. SteamGridDB API key (same as zgp-game-icon.sh: same key file, same validation
# before storing) ---
zgp_sgdb_read_key() {
  [[ -f "${sgdb_key_file}" ]] || return 1
  head -n1 "${sgdb_key_file}" 2>/dev/null | tr -d '[:space:]'
}

zgp_sgdb_save_key() {
  local key="$1"
  mkdir -p "$(dirname "${sgdb_key_file}")"
  printf '%s\n' "${key}" > "${sgdb_key_file}"
  chmod 600 "${sgdb_key_file}"
}

zgp_sgdb_key_valid() {
  local key="$1" code
  [[ -z "${key}" ]] && return 1
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${key}" "${sgdb_api}/search/autocomplete/a" 2>/dev/null)
  [[ "${code}" = "200" ]]
}

zgp_sgdb_ensure_key() {
  sgdb_key=$(zgp_sgdb_read_key)
  if [[ -n "${sgdb_key}" ]] && zgp_sgdb_key_valid "${sgdb_key}"; then
    return 0
  fi

  local candidate first_try=true
  while true; do
    [[ "${first_try}" = false ]] && t splash.key_invalid >&2
    t splash.key_text_cli
    read -r -p "$(t splash.key_prompt_cli)" candidate
    first_try=false

    [[ -z "${candidate}" ]] && return 1

    candidate="${candidate//[$'\n\r\t ']/}"

    if zgp_sgdb_key_valid "${candidate}"; then
      zgp_sgdb_save_key "${candidate}"
      sgdb_key="${candidate}"
      return 0
    fi
  done
}

# --- 6. SteamGridDB calls ---
zgp_sgdb_search() {
  local term="$1" encoded
  encoded=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${term}" 2>/dev/null)
  [[ -z "${encoded}" ]] && return 1
  curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" "${sgdb_api}/search/autocomplete/${encoded}" 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, dict) or not data.get("success"):
    sys.exit(0)
for g in data.get("data", []) or []:
    gid = g.get("id")
    name = g.get("name", "")
    if gid is None:
        continue
    name = str(name).replace("\t", " ").replace("\n", " ").replace("\r", " ")
    print(f"{gid}\t{name}")
'
}

# Output: one line per candidate banner, "full_res_url<TAB>thumbnail_url".
# Uses "/heroes/..." (not grids/icons): the SteamGridDB name for wide wallpaper/backdrop
# images (common sizes 1920x620, 3840x1240), unlike "Grids" (library thumbnails, mostly
# vertical) and "Icons" (used by "lpm icon"). "types=static" excludes animated (webm)
# Heroes, which ImageMagick/Cairo cannot use as-is (and a loading splash does not need
# animation). "mimes=image/png,image/jpeg,image/webp": the three static formats the API
# actually serves, all read by ImageMagick and re-encoded to PNG (see below).
#
# No "Steam Client Hero" fallback like zgp-game-icon.sh (Client Icon): SteamGridDB has
# Heroes for the vast majority of games (far more densely populated than Icons), so a second
# lookup via the Steam AppID is not worth the complexity.
zgp_sgdb_heroes() {
  local game_id="$1"
  curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" \
    "${sgdb_api}/heroes/game/${game_id}?types=static&mimes=image/png,image/jpeg,image/webp" 2>/dev/null | python3 -c '
import sys, json
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(obj, dict) or not obj.get("success"):
    sys.exit(0)
seen = set()
for h in obj.get("data", []) or []:
    url = h.get("url", "")
    thumb = h.get("thumb") or url
    if url and url not in seen:
        seen.add(url)
        print(f"{url}\t{thumb}")
'
}

# --- 7. Process one game ---
#
# Returns 0 if a banner was saved, 1 otherwise (game not found on SteamGridDB, no banner
# available, download/conversion failed, or user cancelled). Never silent: each failure goes
# through zgp_splash_report_skip, printed on stderr.
zgp_splash_report_skip() {
  local msg="$1"
  echo "${msg}" >&2
}

zgp_splash_process_one() {
  local slug="$1" g_name="$2" game_dir="$3"

  local chosen_url=""

  # "--url" already set by the caller (gui/page_images, manual mode) -- see zgp-game-icon.sh
  # for this short-circuit.
  if [[ -n "${forced_url}" ]]; then
    chosen_url="${forced_url}"
  else
  local search_results
  search_results=$(zgp_sgdb_search "${g_name}")
  if [[ -z "${search_results}" ]]; then
    zgp_splash_report_skip "$(t splash.not_found_on_sgdb "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=game_not_found_sgdb"
    return 1
  fi

  local n_matches
  n_matches=$(printf '%s\n' "${search_results}" | grep -c .)

  local chosen_game_id="" chosen_game_name=""
  if [[ "${n_matches}" -gt 1 ]]; then
    t splash.pick_game_text_cli "${g_name}"
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
    read -r -p "$(t splash.pick_game_prompt_cli)" choice
    chosen_game_id="${idx_to_id[${choice}]:-}"
    chosen_game_name="${idx_to_name[${choice}]:-}"

    if [[ -z "${chosen_game_id}" ]]; then
      zgp_splash_report_skip "$(t splash.cancelled_by_user "${g_name}")"
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

  local banners_urls
  banners_urls=$(zgp_sgdb_heroes "${chosen_game_id}")
  if [[ -z "${banners_urls}" ]]; then
    zgp_splash_report_skip "$(t splash.no_banner_available "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=no_banner_available"
    return 1
  fi

  # The former Zenity visual picker was removed (no interactive entry point in bin/lpm); in
  # CLI the first candidate banner is always taken. The visual picker exists again in the
  # GUI (see "--url" above).
  chosen_url=$(printf '%s\n' "${banners_urls}" | head -n1 | cut -f1)
  fi

  # --- Download + systematic conversion to PNG ---
  mkdir -p "${game_dir}/splash"

  local ext="${chosen_url##*.}"
  ext="${ext,,}"
  local raw_file="${game_dir}/splash/.lpm-download.${ext}"

  if ! curl -sLf --max-time 30 "${chosen_url}" -o "${raw_file}" 2>/dev/null; then
    zgp_splash_report_skip "$(t splash.download_failed "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=download_failed"
    rm -f "${raw_file}"
    return 1
  fi

  if ! "${convert_bin[@]}" "${raw_file}" "${game_dir}/splash/splash.png" 2>/dev/null; then
    zgp_splash_report_skip "$(t splash.convert_failed "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=conversion_failed"
    rm -f "${raw_file}"
    return 1
  fi
  rm -f "${raw_file}"

  zgu_log "splash" "OK" "slug=${slug} name=${g_name}"
  t splash.done_cli "${g_name}"
  return 0
}

# --- 8. Execution ---
zgp_sgdb_ensure_key || { zgp_splash_report_error_early "$(t splash.no_key_cancelled)"; exit 1; }

exit_code=0
for target_slug in "${targets[@]}"; do
  zgp_splash_process_one "${target_slug}" "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}" || exit_code=1
done

exit "${exit_code}"
