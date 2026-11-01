#!/bin/bash

# --- Steps shared by the commands that work on a list of Lutris games ---
#
# Library (no code runs when it is sourced). The commands icon / splash / logo (images), launcher /
# lsfg (on-off toggles), shortcut and uninstall-game all start the same way: read the Wine games
# of the Lutris database, hide the ones living in a store prefix (Epic, EA, Ubisoft...), then pick
# the games named on the command line. That code exists once, here.
#
# The calling script has already set up the Lutris paths (zgu_load_lutris_env: lutris_db,
# games_dir...) and sourced zgl-lang-loader.sh ("t"), zgu-cli-utils.sh and zgu-lutris-utils.sh.
# Messages come from the language keys "<lang>.none_found", "<lang>.slug_not_found"... of the
# command (<lang> = icon, logo, splash, launcher, lsfg, shortcut, uninstall_game).

# shellcheck disable=SC2034 # the globals set here are read by the calling scripts
# shellcheck disable=SC2154 # lutris_db, games_dir, cli_*, forced_url... are defined by the calling script

# "--url <url>" (optional) and the target slugs of the image commands. Sets cli_targets and
# forced_url. Args: the command-line arguments.
zgp_parse_url_args() {
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
}

# Checks the tools the image commands need. Args: lang report_fn [identify]. Sets convert_bin
# (and identify_bin when "identify" is given: ImageMagick 7 has a single "magick" binary,
# ImageMagick 6 two separate ones; both are accepted).
zgp_require_image_tools() {
  local lang="$1" report="$2" with_identify="${3:-}" cmd
  for cmd in sqlite3 curl python3 realpath; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      "${report}" "$(t "${lang}.cmd_missing" "${cmd}")"
      exit 1
    fi
  done

  convert_bin=()
  identify_bin=()
  if command -v magick >/dev/null 2>&1; then
    convert_bin=(magick)
    identify_bin=(magick identify)
  elif command -v convert >/dev/null 2>&1 && { [[ -z "${with_identify}" ]] || command -v identify >/dev/null 2>&1; }; then
    convert_bin=(convert)
    identify_bin=(identify)
  else
    "${report}" "$(t "${lang}.imagemagick_missing")"
    exit 1
  fi

  if ! python3 -c "import sys" >/dev/null 2>&1; then
    "${report}" "$(t "${lang}.cmd_missing" "python3")"
    exit 1
  fi
}

# Detects Lutris and checks that its database exists (exits otherwise). Args: lang report_fn.
zgp_require_lutris_db() {
  local lang="$1" report="$2"
  zgu_load_lutris_env || {
    "${report}" "$(t "${lang}.lutris_missing")"
    exit 1
  }
  if [[ ! -f "${lutris_db}" ]]; then
    "${report}" "$(t "${lang}.db_missing" "${lutris_db}")"
    exit 1
  fi
}

# Reads the Wine games of the database into global arrays, all indexed by slug: name_by_slug,
# dir_by_slug, id_by_slug, exe_by_slug, configpath_by_slug; sorted_slugs lists the slugs in name
# order; blacklisted_slugs holds the hidden store-prefix games. Exits 0 with "<lang>.none_found"
# when there is nothing. Args: lang report_fn [blacklist] [sanitize]
#   blacklist: hide the games living in a store prefix
#   sanitize:  replace "/" by "-" in game names (they become file or menu names)
zgp_games_load() {
  local lang="$1" report="$2" flag use_blacklist=0 sanitize=0
  shift 2
  for flag in "$@"; do
    case "${flag}" in
      blacklist) use_blacklist=1 ;;
      sanitize) sanitize=1 ;;
    esac
  done

  local games_list
  games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)
  if [[ -z "${games_list}" ]]; then
    "${report}" "$(t "${lang}.none_found")"
    exit 0
  fi

  declare -gA name_by_slug=() dir_by_slug=() id_by_slug=() exe_by_slug=() configpath_by_slug=()
  declare -gA blacklisted_slugs=()
  sorted_slugs=()

  local bl_slug
  if [[ "${use_blacklist}" -eq 1 ]]; then
    while IFS= read -r bl_slug; do
      [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
    done < <(zgu_get_blacklisted_slugs "${lutris_db}")
  fi

  local g_id g_name g_slug g_dir g_exe g_configpath
  while IFS=$'\x1f' read -r g_id g_name g_slug g_dir g_exe g_configpath; do
    [[ -z "${g_slug}" ]] && continue
    [[ "${sanitize}" -eq 1 ]] && [[ -z "${g_name}" ]] && continue
    [[ -n "${blacklisted_slugs[${g_slug}]:-}" ]] && continue
    [[ "${sanitize}" -eq 1 ]] && g_name="${g_name//\//-}"
    [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"

    name_by_slug["${g_slug}"]="${g_name}"
    dir_by_slug["${g_slug}"]="${g_dir}"
    id_by_slug["${g_slug}"]="${g_id}"
    exe_by_slug["${g_slug}"]="${g_exe}"
    configpath_by_slug["${g_slug}"]="${g_configpath}"
    sorted_slugs+=("${g_slug}")
  done <<< "${games_list}"

  if [[ ${#sorted_slugs[@]} -eq 0 ]]; then
    "${report}" "$(t "${lang}.none_found")"
    exit 0
  fi
}

# Image commands: cli_targets ("--all" or slugs) -> targets. "--url" needs exactly one target.
# Arg: lang.
zgp_games_select_targets() {
  local lang="$1" target_slug
  targets=()
  if [[ "${cli_targets[0]}" = "--all" ]]; then
    targets=("${sorted_slugs[@]}")
  else
    for target_slug in "${cli_targets[@]}"; do
      if [[ -n "${name_by_slug[${target_slug}]:-}" ]]; then
        targets+=("${target_slug}")
      elif [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
        zgu_cli_error "$(t "${lang}.slug_blacklisted" "${target_slug}")"
        exit 1
      else
        zgu_cli_error "$(t "${lang}.slug_not_found" "${target_slug}")"
        exit 1
      fi
    done
  fi

  if [[ -n "${forced_url}" ]] && [[ ${#targets[@]} -ne 1 ]]; then
    zgu_cli_error "$(t "${lang}.force_url_single_target")"
    exit 1
  fi
}

# On/off commands (launcher, lsfg): picks the cli_slugs that can take "action" (on = not active
# yet, off = active). "<lang>.already_active" / "already_inactive" when a slug is already in the
# requested state, unless if_needed=1 (then it is silently skipped). Args: lang is_active_fn
# (called with the configpath of a game, returns 0 if the feature is active).
zgp_games_toggle_targets() {
  local lang="$1" is_active="$2" g_slug target_slug
  declare -A active_by_slug=() eligible_lookup=()
  for g_slug in "${sorted_slugs[@]}"; do
    "${is_active}" "${configpath_by_slug[${g_slug}]}" && active_by_slug["${g_slug}"]=1
  done

  if [[ "${action}" = "status" ]]; then
    for g_slug in "${sorted_slugs[@]}"; do
      [[ -n "${active_by_slug[${g_slug}]:-}" ]] && echo "${g_slug}"
    done
    exit 0
  fi

  for g_slug in "${sorted_slugs[@]}"; do
    if [[ "${action}" = "on" ]]; then
      [[ -z "${active_by_slug[${g_slug}]:-}" ]] && eligible_lookup["${g_slug}"]=1
    else
      [[ -n "${active_by_slug[${g_slug}]:-}" ]] && eligible_lookup["${g_slug}"]=1
    fi
  done

  targets=()
  for target_slug in "${cli_slugs[@]}"; do
    if [[ -z "${name_by_slug[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t "${lang}.slug_not_found" "${target_slug}")"
      exit 1
    fi
    if [[ -z "${eligible_lookup[${target_slug}]:-}" ]]; then
      [[ "${if_needed:-0}" -eq 1 ]] && continue
      if [[ "${action}" = "on" ]]; then
        zgu_cli_error "$(t "${lang}.already_active" "${target_slug}")"
      else
        zgu_cli_error "$(t "${lang}.already_inactive" "${target_slug}")"
      fi
      exit 1
    fi
    targets+=("${target_slug}")
  done
}
