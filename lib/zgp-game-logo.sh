#!/bin/bash

# --- lpm logo [slug...|--all] ---
#
# Fetches a transparent logo (SteamGridDB "Logo": the game title as a cut-out image meant to
# be overlaid on a banner, NOT a full-screen background) for one or more installed games and
# saves it as $GAMEDIR/lpm/images/splash/logo.png -- the image shown permanently on top of everything
# (black screen, picker, banner) in the LPM Launcher (see zgl-launcher-orchestrator.sh /
# zgu-launcher-screen.py).
#
# Separate command, never hooked into "lpm launcher ... on": it is the only feature that
# depends on a third-party service (network + API key), so a SteamGridDB outage or a missing
# key must not block enabling the launcher. Without $GAMEDIR/lpm/images/splash/logo.png the
# orchestrator simply draws no logo. Structure mirrors zgp-game-icon.sh and
# zgp-game-splash.sh ("lpm icon"/"lpm splash").
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

# Same as zgp-game-icon.sh/zgp-game-splash.sh: strictly personal key, never shared or
# bundled with lpm; uses the SAME key file as "lpm icon"/"lpm splash", so one SteamGridDB
# account covers all three commands.
sgdb_key=""

# --- 1. Dependency check ---
zgp_logo_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

zgp_require_image_tools logo zgp_logo_report_error_early
zgp_require_lutris_db logo zgp_logo_report_error_early
zgp_games_load logo zgp_logo_report_error_early blacklist
zgp_games_select_targets logo

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

logo_fail_detail=""
zgp_logo_save_from_url() {
  local slug="$1" game_dir="$2" chosen_url="$3"

  local splash_dir
  splash_dir="$(zgu_lpm_path "${game_dir}" splash)"
  mkdir -p "${splash_dir}"

  local ext="${chosen_url%%[?#]*}"
  ext="${ext##*.}"
  ext="${ext,,}"
  # No usable extension in the URL (none, or a path/odd chars): neutral name, the content decides.
  [[ "${ext}" =~ ^[a-z0-9]{1,5}$ ]] || ext="img"
  local raw_file="${splash_dir}/.lpm-download.${ext}"

  if ! zgu_image_download "${chosen_url}" "${raw_file}"; then
    logo_fail_detail="download_failed url=${chosen_url} ${zgu_image_err}"
    rm -f "${raw_file}"
    return 1
  fi

  # "-background none" keeps the logo's original transparency instead of replacing it with a
  # background (unlike zgp-game-splash.sh: a full-screen banner is always opaque, a logo is
  # not).
  if ! zgu_image_to_png "${raw_file}" "${splash_dir}/logo.png" -background none; then
    logo_fail_detail="conversion_failed url=${chosen_url} ${zgu_image_err}"
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
    zgu_log "logo" "ERROR" "slug=${slug} reason=${logo_fail_detail:-download_or_conversion_failed}"
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
