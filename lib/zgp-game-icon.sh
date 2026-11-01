#!/bin/bash

# --- lpm icon [slug...] ---
#
# Automatically fetches an icon for one or more installed games via SteamGridDB (square
# community icons + official "Steam Client Icon" when they exist), and regenerates the game's
# existing shortcuts (menu and/or desktop) to use it.
#
# Separate command, never hooked into install/shortcut: it is the only lpm feature that depends
# on a third-party service (network + API key). A SteamGridDB outage or a missing key must never
# make an installation or shortcut creation fail.
#
# $1, $2... = target game slugs (always non-empty).
#
# "--url <url>" (optional, anywhere in the arguments): bypasses the SteamGridDB search and
# first-result selection and applies the image at this URL directly. Used by gui/page_images
# (manual mode, "Automatic download" unchecked) once the image is chosen in the GTK visual
# picker (see lib/zgl-sgdb-images.sh); only one target slug at a time in that case, see the
# check below.
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
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# The SteamGridDB key is strictly personal to the user (see zgp_sgdb_ensure_key below): never
# shared, never bundled with lpm. Kept in a dedicated file with 600 permissions (owner
# read/write only).
sgdb_key=""

# --- 1. Dependency check ---
zgp_icon_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

for cmd in sqlite3 curl python3 realpath; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_icon_report_error_early "$(t icon.cmd_missing "${cmd}")"
    exit 1
  fi
done

# ImageMagick: needed to convert ".ico" icons (common, originally extracted from Windows
# executables) to ".png", the only format the freedesktop Desktop Entry spec reliably expects
# for "Icon=" (see zgp_icon_fetch_and_place below). ImageMagick 7 merges convert/identify into a
# single "magick" binary; ImageMagick 6 keeps two separate binaries. Both forms are accepted.
convert_bin=()
identify_bin=()
if command -v magick >/dev/null 2>&1; then
  convert_bin=(magick)
  identify_bin=(magick identify)
elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
  convert_bin=(convert)
  identify_bin=(identify)
else
  zgp_icon_report_error_early "$(t icon.imagemagick_missing)"
  exit 1
fi

# --- 2. Flatpak vs native package detection + Lutris path resolution ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_icon_report_error_early "$(t icon.lutris_missing)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_system_file="${lutris_flatpak_system_file}"
    runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  package)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_system_file="${lutris_package_system_file}"
    runner_dir="${lutris_package_runner_dir}"
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
  zgp_icon_report_error_early "$(t icon.db_missing "${lutris_db}")"
  exit 1
fi

# --- 3. Fetch Wine games from the Lutris database ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_icon_report_error_early "$(t icon.none_found)"
  exit 0
fi

declare -A name_by_slug
declare -A dir_by_slug
declare -A id_by_slug
declare -A exe_by_slug
declare -A configpath_by_slug

# Games living in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) are
# outside lpm's one-game-one-prefix principle and are never offered here. Same filter as
# zgp-game-shortcutter.sh/zgp-game-uninstaller.sh (see zgu_get_blacklisted_slugs).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

sorted_slugs=()

while IFS=$'\x1f' read -r g_id g_name g_slug g_dir g_exe g_configpath; do
  [[ -z "${g_slug}" ]] && continue
  [[ -n "${blacklisted_slugs[${g_slug}]:-}" ]] && continue
  [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"

  name_by_slug["${g_slug}"]="${g_name}"
  dir_by_slug["${g_slug}"]="${g_dir}"
  id_by_slug["${g_slug}"]="${g_id}"
  exe_by_slug["${g_slug}"]="${g_exe}"
  configpath_by_slug["${g_slug}"]="${g_configpath}"
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

if [[ ${#sorted_slugs[@]} -eq 0 ]]; then
  zgp_icon_report_error_early "$(t icon.none_found)"
  exit 0
fi

# --- 4. Target game selection ---
# "cli_targets" is always non-empty here.
targets=()

if [[ "${cli_targets[0]}" = "--all" ]]; then
  targets=("${sorted_slugs[@]}")
else
  for target_slug in "${cli_targets[@]}"; do
    if [[ -n "${name_by_slug[${target_slug}]:-}" ]]; then
      targets+=("${target_slug}")
    elif [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t icon.slug_blacklisted "${target_slug}")"
      exit 1
    else
      zgu_cli_error "$(t icon.slug_not_found "${target_slug}")"
      exit 1
    fi
  done
fi

if [[ -n "${forced_url}" ]] && [[ ${#targets[@]} -ne 1 ]]; then
  zgu_cli_error "$(t icon.force_url_single_target)"
  exit 1
fi

# --- 7. Processing one game ---
#
# Returns 0 if an icon was applied, 1 otherwise (game not found on SteamGridDB, no icon
# available, download/conversion failed, or cancelled by the user). Never silent: every failure
# goes through zgp_icon_report_skip, printed on stderr.
zgp_icon_report_skip() {
  local msg="$1"
  echo "${msg}" >&2
}

zgp_icon_process_one() {
  local slug="$1" g_name="$2" prefix_dir="$3" g_id="$4" g_exe="$5" g_configpath="$6"

  local chosen_url=""

  # "--url" already supplied by the caller (gui/page_images, manual mode): the user picked
  # this image in the GTK visual picker (see lib/zgl-sgdb-images.sh), so the
  # search/disambiguation/automatic choice below is skipped entirely, going straight to
  # download/conversion/placement, unchanged.
  if [[ -n "${forced_url}" ]]; then
    chosen_url="${forced_url}"
  else
  local search_results
  search_results=$(zgp_sgdb_search "${g_name}")
  if [[ -z "${search_results}" ]]; then
    zgp_icon_report_skip "$(t icon.not_found_on_sgdb "${g_name}")"
    zgu_log "icon" "ERROR" "slug=${slug} reason=game_not_found_sgdb"
    return 1
  fi

  local n_matches
  n_matches=$(printf '%s\n' "${search_results}" | grep -c . )

  local chosen_game_id="" chosen_game_name=""
  if [[ "${n_matches}" -gt 1 ]]; then
    t icon.pick_game_text_cli "${g_name}"
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
    read -r -p "$(t icon.pick_game_prompt_cli)" choice
    chosen_game_id="${idx_to_id[${choice}]:-}"
    chosen_game_name="${idx_to_name[${choice}]:-}"

    if [[ -z "${chosen_game_id}" ]]; then
      zgp_icon_report_skip "$(t icon.cancelled_by_user "${g_name}")"
      return 1
    fi
  else
    chosen_game_id=$(printf '%s\n' "${search_results}" | head -n1 | cut -f1)
    chosen_game_name=$(printf '%s\n' "${search_results}" | head -n1 | cut -f2)
  fi

  # The CONFIRMED SteamGridDB name (that of the chosen row), never the raw Lutris name
  # ("g_name"): Lutris may hold a user-customized or misspelled name (e.g. "Crossybara"
  # instead of "Crossbar Cards"). The SteamGridDB autocomplete tolerates this (fuzzy search),
  # but the official store.steampowered.com search used by zgp_sgdb_icons to find the Steam
  # AppID (see above) does not, and returns 0 results, which made the Client Icon fail for
  # Crossbar Cards.
  #
  # Found here by looking up "chosen_game_id" in "search_results" (single source of truth,
  # always overriding the value already set by the branches above). Falls back to "g_name"
  # only if the chosen ID is, unexpectedly, not found in "search_results".
  local sr_gid sr_name
  while IFS=$'\t' read -r sr_gid sr_name; do
    if [[ "${sr_gid}" = "${chosen_game_id}" ]]; then
      chosen_game_name="${sr_name}"
      break
    fi
  done <<< "${search_results}"
  [[ -z "${chosen_game_name}" ]] && chosen_game_name="${g_name}"

  local icons_urls
  icons_urls=$(zgp_sgdb_icons "${chosen_game_id}" "${chosen_game_name}")
  if [[ -z "${icons_urls}" ]]; then
    zgp_icon_report_skip "$(t icon.no_icon_available "${g_name}")"
    zgu_log "icon" "ERROR" "slug=${slug} reason=no_icon_available"
    return 1
  fi

  # In CLI the first candidate icon is always taken (already the best found by zgp_sgdb_icons:
  # "clienticon", then "official", then the rest, see above). The GUI visual picker (see
  # "--url" above) is what imposes a choice other than the first result.
  chosen_url=$(printf '%s\n' "${icons_urls}" | head -n1 | cut -f1)
  fi

  # --- Download + .ico -> .png conversion if needed ---
  local icon_dir
  icon_dir="$(zgu_lpm_path "${prefix_dir}" icon)"
  mkdir -p "${icon_dir}"
  # Purge old icons (same filter as zgu_write_game_shortcut above; nothing else in this
  # folder, e.g. extras packed in a .zgp do not live here).
  find "${icon_dir}" "$(zgu_lpm_legacy_path "${prefix_dir}" icon)" -maxdepth 1 -type f \( -name "*.png" -o -name "*.ico" -o -name "*.svg" -o -name "*.xpm" \) -delete 2>/dev/null

  local ext="${chosen_url##*.}"
  ext="${ext,,}"
  local raw_file="${icon_dir}/.lpm-download.${ext}"

  if ! curl -sLf --max-time 30 "${chosen_url}" -o "${raw_file}" 2>/dev/null; then
    zgp_icon_report_skip "$(t icon.download_failed "${g_name}")"
    zgu_log "icon" "ERROR" "slug=${slug} reason=download_failed"
    rm -f "${raw_file}"
    return 1
  fi

  if [[ "${ext}" = "ico" ]]; then
    # A .ico can stack several resolutions in one file: take the largest (3rd column of
    # "identify", numerically sorted), the same method as an established comparable tool
    # (steamtinkerlaunch).
    local biggest
    biggest=$("${identify_bin[@]}" "${raw_file}" 2>/dev/null | sort -n -k3 | tail -n1 | grep -oP '\[\K[^\]]+')
    [[ -z "${biggest}" ]] && biggest=0
    if ! "${convert_bin[@]}" "${raw_file}[${biggest}]" "${icon_dir}/icon.png" 2>/dev/null; then
      zgp_icon_report_skip "$(t icon.convert_failed "${g_name}")"
      zgu_log "icon" "ERROR" "slug=${slug} reason=ico_conversion_failed"
      rm -f "${raw_file}"
      return 1
    fi
    rm -f "${raw_file}"
  else
    mv "${raw_file}" "${icon_dir}/icon.${ext}"
  fi

  # --- Regenerate existing shortcuts (never creates new ones: only those already present for
  # this game, menu and/or desktop) so they point to the new icon; see zgu_write_game_shortcut
  # in zgu-desktop-utils.sh, which re-reads <prefix_dir>/icon at (re)generation time. ---
  local menu_file="${HOME}/.local/share/applications/net.lutris.${slug}.desktop"
  local desktop_dir desktop_file
  desktop_dir=$(zgu_get_desktop_dir)
  desktop_file="${desktop_dir}/${slug}.desktop"

  local has_menu=false has_desktop=false
  [[ -f "${menu_file}" ]] && has_menu=true
  [[ -f "${desktop_file}" ]] && has_desktop=true

  if [[ "${has_menu}" = true ]] || [[ "${has_desktop}" = true ]]; then
    zgu_write_game_shortcut "${g_name}" "${slug}" "${prefix_dir}" "${g_id}" "${version}" "${has_menu}" "${has_desktop}" "${g_exe}" "${g_configpath}" "${lutris_config_dir}" "${runner_dir}"
  fi

  zgu_log "icon" "OK" "slug=${slug} name=${g_name}"
  t icon.done_cli "${g_name}"
  return 0
}

# --- 8. Execution ---
zgp_sgdb_ensure_key icon || { zgp_icon_report_error_early "$(t icon.no_key_cancelled)"; exit 1; }

exit_code=0
for target_slug in "${targets[@]}"; do
  zgp_icon_process_one "${target_slug}" "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}" "${id_by_slug[${target_slug}]}" "${exe_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}" || exit_code=1
done

exit "${exit_code}"
