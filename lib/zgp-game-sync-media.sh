#!/bin/bash

# --- lpm sync-media <slugs...|--all> ---
#
# Downloads the "native" Lutris media (banner, icon, cover art -- those shown INSIDE the
# Lutris library itself) for games that don't have them yet, mirroring Lutris's own logic
# (lutris/services/lutris.py::sync_media and
# lutris/services/base.py::LutrisBanner/LutrisIcon/LutrisCoverart): the lutris.net API is
# queried ONLY for games missing at least one of the three media, and only what is actually
# missing is downloaded -- never what already exists.
#
# Unrelated to "lpm icon"/"splash"/"logo" (SteamGridDB, for the icons of the .desktop
# shortcuts created BY lpm): these are the thumbnails Lutris shows in ITS OWN game library,
# an entirely separate system. Separate command, never hooked in elsewhere (same philosophy
# as "icon"): it depends on the network (lutris.net here), and an outage must never make
# anything else fail.
#
# $1, $2... = target game slugs in CLI, or "--all" for all installed Wine games (always
# non-empty in CLI).
cli_targets=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# Default Lutris API URL (lutris/settings.py::SITE_URL) -- lpm does not read Lutris's
# internal configuration for a possible override (the "website" setting, very rarely
# changed), only this official default.
site_url="https://lutris.net"

# --- 1. Dependency check ---
for cmd in sqlite3 curl python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgu_cli_error "$(t sync_media.cmd_missing "${cmd}")"
    exit 1
  fi
done

# --- 2. Flatpak vs native package detection + path resolution ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_data_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris"
lutris_package_data_dir="${HOME}/.local/share/lutris"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgu_cli_error "$(t sync_media.lutris_missing)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_data_dir="${lutris_flatpak_data_dir}"
    ;;
  package)
    lutris_db="${lutris_package_db}"
    lutris_data_dir="${lutris_package_data_dir}"
    ;;
  *)
    # Should never happen: "${version}" is only set to "flatpak" or "package" above (else
    # exit 1). Safeguard in case that invariant changes.
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t sync_media.db_missing "${lutris_db}")"
  exit 1
fi

# Exact paths of the 3 native Lutris media (see lutris/settings.py and lutris/services/base.py):
#  - banner and cover art: in Lutris's own data folder (so flatpak/native differ, as above)
#    -- always saved as ".jpg" by a Lutris download, whatever the source format (an existing
#    ".png", placed manually or by an older version, is still accepted for READING, see
#    zgp_sync_media_process_one, but never produced by a download here).
#  - icon: ALWAYS in the shared system icon theme (hicolor), never in Lutris's data folder --
#    so the SAME path whether Lutris is flatpak or native (the Lutris flatpak exposes this
#    folder to the system so its own shortcuts work; it is not a sandboxed path).
banner_dir="${lutris_data_dir}/banners"
coverart_dir="${lutris_data_dir}/coverart"
icon_dir="${HOME}/.local/share/icons/hicolor/128x128/apps"
mkdir -p "${banner_dir}" "${coverart_dir}" "${icon_dir}"

# --- 3. Fetch Wine slugs from the Lutris DB ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(slug,'') FROM games WHERE runner='wine' ORDER BY slug ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgu_cli_error "$(t sync_media.none_found)"
  exit 0
fi

# Games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) are
# outside lpm's one-game-one-prefix model and never listed here (same filter as
# zgp-game-shortcutter.sh/zgp-game-icon.sh, see zgu_get_blacklisted_slugs).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

declare -A known_slugs
sorted_slugs=()
while IFS= read -r g_slug; do
  [[ -z "${g_slug}" ]] && continue
  [[ -n "${blacklisted_slugs[${g_slug}]:-}" ]] && continue
  [[ -n "${known_slugs[${g_slug}]:-}" ]] && continue  # duplicates (several configs for the same game)
  known_slugs["${g_slug}"]=1
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

if [[ ${#sorted_slugs[@]} -eq 0 ]]; then
  zgu_cli_error "$(t sync_media.none_found)"
  exit 0
fi

# --- 4. Target selection ---
targets=()
if [[ "${cli_targets[0]}" = "--all" ]]; then
  targets=("${sorted_slugs[@]}")
else
  for target_slug in "${cli_targets[@]}"; do
    if [[ -n "${known_slugs[${target_slug}]:-}" ]]; then
      targets+=("${target_slug}")
    elif [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t sync_media.slug_blacklisted "${target_slug}")"
      exit 1
    else
      zgu_cli_error "$(t sync_media.slug_not_found "${target_slug}")"
      exit 1
    fi
  done
fi

# --- 5. Process one game: the API is only needed if at least one medium is missing ---
zgp_sync_media_process_one() {
  local slug="$1"
  local banner_path="${banner_dir}/${slug}.jpg"
  local cover_path="${coverart_dir}/${slug}.jpg"
  local icon_path="${icon_dir}/lutris_${slug}.png"

  local has_banner=false has_cover=false has_icon=false
  [[ -s "${banner_path}" ]] && has_banner=true
  [[ -s "${banner_dir}/${slug}.png" ]] && has_banner=true
  [[ -s "${cover_path}" ]] && has_cover=true
  [[ -s "${coverart_dir}/${slug}.png" ]] && has_cover=true
  [[ -s "${icon_path}" ]] && has_icon=true

  if [[ "${has_banner}" = true ]] && [[ "${has_cover}" = true ]] && [[ "${has_icon}" = true ]]; then
    zgu_log "sync-media" "OK" "slug=${slug} reason=already_complete"
    return 0
  fi

  # An HTTP code other than 200 (most often 404) just means this game is not listed on
  # lutris.net (e.g. an itch.io/custom game added by other means than lpm) -- never an
  # error, simply nothing to download. Only a failure of "curl" itself (network down,
  # DNS...) is a real error.
  local tmp_response http_code
  tmp_response=$(mktemp)
  http_code=$(curl -s --max-time 15 -w '%{http_code}' -o "${tmp_response}" "${site_url}/api/games/${slug}" 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    rm -f "${tmp_response}"
    zgu_cli_error "$(t sync_media.api_unreachable "${slug}")"
    zgu_log "sync-media" "ERROR" "slug=${slug} reason=api_unreachable"
    return 1
  fi
  if [[ "${http_code}" != "200" ]]; then
    rm -f "${tmp_response}"
    zgu_log "sync-media" "OK" "slug=${slug} reason=game_not_found_on_lutris_net"
    t sync_media.nothing_found_cli "${slug}"
    return 0
  fi

  local response
  response=$(cat "${tmp_response}")
  rm -f "${tmp_response}"

  # "<x>_url" fields are tried before "<x>" -- same priority order as
  # lutris/services/lutris.py::_get_response_game_banner/_get_response_game_icon (cover art
  # has only one possible field: "coverart").
  local banner_url icon_url cover_url
  banner_url=$(RESP="${response}" python3 -c '
import os, json
try:
    data = json.loads(os.environ.get("RESP", "") or "{}")
except Exception:
    data = {}
print(data.get("banner_url") or data.get("banner") or "")
' 2>/dev/null)
  icon_url=$(RESP="${response}" python3 -c '
import os, json
try:
    data = json.loads(os.environ.get("RESP", "") or "{}")
except Exception:
    data = {}
print(data.get("icon_url") or data.get("icon") or "")
' 2>/dev/null)
  cover_url=$(RESP="${response}" python3 -c '
import os, json
try:
    data = json.loads(os.environ.get("RESP", "") or "{}")
except Exception:
    data = {}
print(data.get("coverart") or "")
' 2>/dev/null)

  local downloaded_any=false

  if [[ "${has_banner}" = false ]] && [[ -n "${banner_url}" ]]; then
    if curl -sLf --max-time 30 "${banner_url}" -o "${banner_path}" 2>/dev/null; then
      downloaded_any=true
    else
      rm -f "${banner_path}"
    fi
  fi

  if [[ "${has_cover}" = false ]] && [[ -n "${cover_url}" ]]; then
    if curl -sLf --max-time 30 "${cover_url}" -o "${cover_path}" 2>/dev/null; then
      downloaded_any=true
    else
      rm -f "${cover_path}"
    fi
  fi

  if [[ "${has_icon}" = false ]] && [[ -n "${icon_url}" ]]; then
    if curl -sLf --max-time 30 "${icon_url}" -o "${icon_path}" 2>/dev/null; then
      downloaded_any=true
      # Same as Lutris itself after an icon download
      # (ServiceMedia.run_system_update_desktop_icons): refreshes the system icon cache so
      # the new icon appears immediately instead of waiting for a periodic refresh.
      # Best-effort: absent on some minimal systems, must never make the rest fail.
      gtk-update-icon-cache -q -t -f "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
    else
      rm -f "${icon_path}"
    fi
  fi

  if [[ "${downloaded_any}" = true ]]; then
    zgu_log "sync-media" "OK" "slug=${slug}"
    t sync_media.done_cli "${slug}"
  else
    zgu_log "sync-media" "OK" "slug=${slug} reason=no_media_available"
    t sync_media.nothing_found_cli "${slug}"
  fi
  return 0
}

# --- 6. Execution ---
exit_code=0
for target_slug in "${targets[@]}"; do
  zgp_sync_media_process_one "${target_slug}" || exit_code=1
done

exit "${exit_code}"
