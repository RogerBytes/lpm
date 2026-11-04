#!/bin/bash

# --- lpm splash [slug...|--all] ---
#
# Fetches a loading banner (SteamGridDB "Hero": a wide image meant as a wallpaper/backdrop,
# NOT the square icon or the library thumbnail) for one or more installed games and saves it
# as $GAMEDIR/lpm/images/splash/splash.png -- the image the LPM Launcher shows full-screen while
# loading (see zgl-launcher-manager.sh / zgu-launcher-screen.py).
#
# Separate command, never hooked into "lpm launcher ... on": it is the only feature that
# depends on a third-party service (network + API key), so a SteamGridDB outage or a missing
# key must not block enabling the launcher. "lpm launcher ... on" installs no default image;
# without $GAMEDIR/lpm/images/splash/splash.png the orchestrator simply shows a plain black loading
# screen (see zgl-launcher-manager.sh / zgl-launcher-orchestrator.sh). Structure mirrors
# zgp-game-icon.sh ("lpm icon").
#
# Independent of the launcher's activation state: $GAMEDIR/lpm/images/splash/ is created here if
# missing.
#
# $1, $2... = target game slugs (always non-empty in CLI), or "--all" for all eligible
# games.
#
# "--url <url>" (optional): see zgp-game-icon.sh -- same mechanism, single target slug.

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
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

zgp_parse_url_args "$@"

# Same as zgp-game-icon.sh: strictly personal key, never shared or bundled with lpm; uses
# the SAME key file as "lpm icon", so one SteamGridDB account covers both commands.
sgdb_key=""

# --- 1. Dependency check ---
zgp_splash_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

zgp_require_image_tools splash zgp_splash_report_error_early
zgp_require_lutris_db splash zgp_splash_report_error_early
zgp_games_load splash zgp_splash_report_error_early blacklist
zgp_games_select_targets splash

# --- 7. Process one game ---
#
# Returns 0 if a banner was saved, 1 otherwise (game not found on SteamGridDB, no banner
# available, download/conversion failed, or user cancelled). Never silent: each failure goes
# through zgp_splash_report_skip, printed on stderr.
zgp_splash_report_skip() {
  local msg="$1"
  echo "${msg}" >&2
}

# Finds the banner URL into splash_chosen_url (forced_url, else SteamGridDB search).
# Args: slug g_name. Returns 1 when nothing usable was found / user cancelled.
splash_chosen_url=""
zgp_splash_choose_url() {
  local slug="$1" g_name="$2"
  splash_chosen_url=""
  # "--url" already set by the caller (gui/page_images, manual mode): search skipped.
  if [[ -n "${forced_url}" ]]; then
    splash_chosen_url="${forced_url}"
    return 0
  fi
  local search_results
  search_results=$(zgp_sgdb_search "${g_name}")
  if [[ -z "${search_results}" ]]; then
    zgp_splash_report_skip "$(t splash.not_found_on_sgdb "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=game_not_found_sgdb"
    return 1
  fi
  if ! zgp_sgdb_pick_game splash "${g_name}" "${search_results}"; then
    zgp_splash_report_skip "$(t splash.cancelled_by_user "${g_name}")"
    return 1
  fi

  local banners_urls
  banners_urls=$(zgp_sgdb_heroes "${sgdb_pick_id}")
  if [[ -z "${banners_urls}" ]]; then
    zgp_splash_report_skip "$(t splash.no_banner_available "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=no_banner_available"
    return 1
  fi
  # In CLI the first candidate banner is always taken; the GUI has a visual picker ("--url").
  splash_chosen_url=$(printf '%s\n' "${banners_urls}" | head -n1 | cut -f1)
  return 0
}

# Downloads splash_chosen_url and converts it to PNG. Args: slug g_name game_dir.
zgp_splash_download() {
  local slug="$1" g_name="$2" game_dir="$3" chosen_url="${splash_chosen_url}"
  local splash_dir
  splash_dir="$(zgu_lpm_path "${game_dir}" splash)"
  mkdir -p "${splash_dir}"

  local ext="${chosen_url%%[?#]*}"
  ext="${ext##*.}"
  ext="${ext,,}"
  # No usable extension in the URL (none, or a path/odd chars): neutral name, the content decides.
  [[ "${ext}" =~ ^[a-z0-9]{1,5}$ ]] || ext="img"
  # Unique temporary file: splash and logo of the same game share this directory and can run
  # at the same time; a shared name made them overwrite each other's download (corrupted PNGs).
  local raw_file
  raw_file="$(mktemp "${splash_dir}/.lpm-download.XXXXXX.${ext}")" || return 1

  if ! zgu_image_download "${chosen_url}" "${raw_file}"; then
    zgp_splash_report_skip "$(t splash.download_failed "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=download_failed url=${chosen_url} ${zgu_image_err}"
    rm -f "${raw_file}"
    return 1
  fi
  if ! zgu_image_to_png "${raw_file}" "${splash_dir}/splash.png"; then
    zgp_splash_report_skip "$(t splash.convert_failed "${g_name}")"
    zgu_log "splash" "ERROR" "slug=${slug} reason=conversion_failed url=${chosen_url} ${zgu_image_err}"
    rm -f "${raw_file}"
    return 1
  fi
  rm -f "${raw_file}"
  return 0
}

zgp_splash_process_one() {
  local slug="$1" g_name="$2" game_dir="$3"

  zgp_splash_choose_url "${slug}" "${g_name}" || return 1
  zgp_splash_download "${slug}" "${g_name}" "${game_dir}" || return 1

  zgu_log "splash" "OK" "slug=${slug} name=${g_name}"
  t splash.done_cli "${g_name}"
  return 0
}

# --- 8. Execution ---
zgp_sgdb_ensure_key splash || { zgp_splash_report_error_early "$(t splash.no_key_cancelled)"; exit 1; }

exit_code=0
for target_slug in "${targets[@]}"; do
  zgp_splash_process_one "${target_slug}" "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}" || exit_code=1
done

exit "${exit_code}"
