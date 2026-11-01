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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-sgdb.sh
source "${script_dir}/zgu-sgdb.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-games-cli.sh
source "${script_dir}/zgu-games-cli.sh"
# shellcheck source=./zgu-lpm-paths.sh
source "${script_dir}/zgu-lpm-paths.sh"
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

zgp_parse_url_args "$@"

# The SteamGridDB key is strictly personal to the user (see zgp_sgdb_ensure_key below): never
# shared, never bundled with lpm. Kept in a dedicated file with 600 permissions (owner
# read/write only).
sgdb_key=""

# --- 1. Dependency check ---
zgp_icon_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

zgp_require_image_tools icon zgp_icon_report_error_early identify
zgp_require_lutris_db icon zgp_icon_report_error_early
zgp_games_load icon zgp_icon_report_error_early blacklist
zgp_games_select_targets icon

# --- 7. Processing one game ---
#
# Returns 0 if an icon was applied, 1 otherwise (game not found on SteamGridDB, no icon
# available, download/conversion failed, or cancelled by the user). Never silent: every failure
# goes through zgp_icon_report_skip, printed on stderr.
zgp_icon_report_skip() {
  local msg="$1"
  echo "${msg}" >&2
}

# Finds the icon URL to use into icon_chosen_url (forced_url, else SteamGridDB search).
# Args: slug g_name. Returns 1 when nothing usable was found / user cancelled.
zgp_icon_choose_url() {
  local slug="$1" g_name="$2"
  icon_chosen_url=""
  if [[ -n "${forced_url}" ]]; then
    icon_chosen_url="${forced_url}"
    return 0
  fi
  local search_results
  search_results=$(zgp_sgdb_search "${g_name}")
  if [[ -z "${search_results}" ]]; then
    zgp_icon_report_skip "$(t icon.not_found_on_sgdb "${g_name}")"
    zgu_log "icon" "ERROR" "slug=${slug} reason=game_not_found_sgdb"
    return 1
  fi
  if ! zgp_sgdb_pick_game icon "${g_name}" "${search_results}"; then
    zgp_icon_report_skip "$(t icon.cancelled_by_user "${g_name}")"
    return 1
  fi

  local icons_urls
  icons_urls=$(zgp_sgdb_icons "${sgdb_pick_id}" "${sgdb_pick_name}")
  if [[ -z "${icons_urls}" ]]; then
    zgp_icon_report_skip "$(t icon.no_icon_available "${g_name}")"
    zgu_log "icon" "ERROR" "slug=${slug} reason=no_icon_available"
    return 1
  fi

  # In CLI the first candidate icon is always taken (already the best found by zgp_sgdb_icons:
  # "clienticon", then "official", then the rest). The GUI visual picker ("--url") is what
  # imposes a choice other than the first result.
  icon_chosen_url=$(printf '%s\n' "${icons_urls}" | head -n1 | cut -f1)
  return 0
}

# Downloads icon_chosen_url into <prefix>/lpm/images/icon (.ico converted to .png).
# Args: slug g_name prefix_dir. Returns 1 on failure.
zgp_icon_download() {
  local slug="$1" g_name="$2" prefix_dir="$3" chosen_url="${icon_chosen_url}"
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
  return 0
}

# Regenerates the shortcuts that already exist so they point to the new icon (never creates
# new ones). Args: slug g_name prefix_dir g_id g_exe g_configpath.
zgp_icon_refresh_shortcuts() {
  local slug="$1" g_name="$2" prefix_dir="$3" g_id="$4" g_exe="$5" g_configpath="$6"
  # Only the shortcuts already present for this game (menu and/or desktop); see
  # zgu_write_game_shortcut in zgu-desktop-utils.sh, which re-reads the icon at generation time.
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
}

zgp_icon_process_one() {
  local slug="$1" g_name="$2" prefix_dir="$3" g_id="$4" g_exe="$5" g_configpath="$6"

  zgp_icon_choose_url "${slug}" "${g_name}" || return 1
  zgp_icon_download "${slug}" "${g_name}" "${prefix_dir}" || return 1
  zgp_icon_refresh_shortcuts "${slug}" "${g_name}" "${prefix_dir}" "${g_id}" "${g_exe}" "${g_configpath}"

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
