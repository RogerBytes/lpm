#!/bin/bash

# --- Where lpm keeps ITS files inside a game's prefix ---
#
# Everything lpm adds to a prefix lives in ONE folder, "<prefix>/lpm/":
#
#   lpm/config.yml              copy of the Lutris YAML (first member of a .zgp archive)
#   lpm/launcher.yml            LPM Launcher entries
#   lpm/settings/               loading-screen switches and settings
#       no-loadingscreen, keep-focus, max-wait-s, extra-loading-ms,
#       loading-message.txt, ignore-windows.txt
#   lpm/scripts/                wine trace wrapper + the game's pre/post-launch scripts
#   lpm/gamepad/                AntiMicroX profile
#   lpm/images/splash/          loading-screen images
#   lpm/images/icon/            game icon
#   lpm/lsfg-vk/                lsfg-vk.dll copy
#   lpm/extras/                 bonus content (manuals, soundtrack...)
#   lpm/.launcher-choice        temporary file (never packed)
#
# Older prefixes (and older .zgp archives) have the same files scattered at the prefix root
# under other names. For those, every READ falls back to the old location when the new one
# does not exist. Every WRITE goes to the new location. This fallback lives ONLY here: when
# all old games are re-created, delete the "legacy" column of zgu_lpm_rel and nothing else.

ZGU_LPM_DIRNAME="lpm"

# zgu_lpm_rel <key> <new|legacy>: path relative to "<prefix>/lpm" (new) or to "<prefix>" (legacy).
zgu_lpm_rel() {
  local key="$1" which="$2" new legacy
  case "${key}" in
    config)           new="config.yml";                 legacy="zgp-game-config.yml" ;;
    launcher)         new="launcher.yml";               legacy="lpm-launcher.yml" ;;
    launcher_choice)  new=".launcher-choice";           legacy=".lpm-launcher-choice" ;;
    no_loadingscreen) new="settings/no-loadingscreen";  legacy=".lpm-no-loadingscreen" ;;
    keep_focus)       new="settings/keep-focus";        legacy=".lpm-keep-focus" ;;
    max_wait)         new="settings/max-wait-s";        legacy="lpm-max-wait-s" ;;
    extra_loading)    new="settings/extra-loading-ms";  legacy="lpm-extra-loading-ms" ;;
    loading_message)  new="settings/loading-message.txt"; legacy="lpm-loading-message.txt" ;;
    ignore_windows)   new="settings/ignore-windows.txt"; legacy="lpm-ignore-windows.txt" ;;
    scripts)          new="scripts";                    legacy="scripts" ;;
    gamepad)          new="gamepad";                    legacy="lpm_gamepad" ;;
    splash)           new="images/splash";              legacy="splash" ;;
    icon)             new="images/icon";                legacy="icon" ;;
    lsfg)             new="lsfg-vk";                    legacy="lsfg-vk" ;;
    extras)           new="extras";                     legacy="extras" ;;
    *) return 1 ;;
  esac
  if [[ "${which}" = "legacy" ]]; then
    printf '%s' "${legacy}"
  else
    printf '%s' "${new}"
  fi
}

# zgu_lpm_dir <prefix>: the lpm folder of a prefix.
zgu_lpm_dir() {
  printf '%s/%s' "${1%/}" "${ZGU_LPM_DIRNAME}"
}

# zgu_lpm_path <prefix> <key>: NEW location, where to WRITE.
zgu_lpm_path() {
  printf '%s/%s/%s' "${1%/}" "${ZGU_LPM_DIRNAME}" "$(zgu_lpm_rel "$2" new)"
}

# zgu_lpm_legacy_path <prefix> <key>: OLD location (prefix root).
zgu_lpm_legacy_path() {
  printf '%s/%s' "${1%/}" "$(zgu_lpm_rel "$2" legacy)"
}

# zgu_lpm_find <prefix> <key>: path to READ. The new location if it exists, else the old
# one if it exists, else the new one (so a later write or "does not exist" test is right).
zgu_lpm_find() {
  local new legacy
  new="$(zgu_lpm_path "$1" "$2")"
  legacy="$(zgu_lpm_legacy_path "$1" "$2")"
  if [[ -e "${new}" ]]; then
    printf '%s' "${new}"
  elif [[ -e "${legacy}" ]]; then
    printf '%s' "${legacy}"
  else
    printf '%s' "${new}"
  fi
}

# zgu_lpm_exists <prefix> <key>: true if the item exists at the new OR the old location.
zgu_lpm_exists() {
  [[ -e "$(zgu_lpm_path "$1" "$2")" ]] || [[ -e "$(zgu_lpm_legacy_path "$1" "$2")" ]]
}

# zgu_lpm_remove <prefix> <key>: removes the item at BOTH locations (files and folders).
zgu_lpm_remove() {
  rm -rf -- "$(zgu_lpm_path "$1" "$2")" "$(zgu_lpm_legacy_path "$1" "$2")" 2>/dev/null
  return 0
}

# zgu_lpm_prune <prefix>: removes "<prefix>/lpm" folders left empty (settings/, images/, lpm/).
zgu_lpm_prune() {
  local base="${1%/}/${ZGU_LPM_DIRNAME}"
  [[ -d "${base}" ]] || return 0
  find "${base}" -mindepth 1 -type d -empty -delete 2>/dev/null
  rmdir "${base}" 2>/dev/null
  return 0
}

# zgu_lpm_migrate <prefix>: moves the lpm files of an OLD-layout prefix (prefix root) into
# "<prefix>/lpm" with their new names, so that a game installed from an old .zgp is brought to
# the current layout at once (no new export needed). Safe to run again (nothing left to move =
# nothing happens) and never overwrites: if the new location already exists the old item stays
# where it is (folders are merged child by child, existing files win). Nothing is moved when
# "<prefix>/lpm" is a link (a forged archive could aim it elsewhere).
# Prints nothing. The temporary choice file is deleted instead of moved.
# Also fixes the hook paths "$GAMEDIR/scripts/" -> "$GAMEDIR/lpm/scripts/" in the bundled
# config.yml, since the "scripts" folder moves.
zgu_lpm_migrate() {
  local prefix="${1%/}" key legacy new child
  [[ -d "${prefix}" ]] || return 0
  [[ -L "${prefix}/${ZGU_LPM_DIRNAME}" ]] && return 0
  for key in config launcher launcher_choice no_loadingscreen keep_focus max_wait extra_loading \
             loading_message ignore_windows scripts gamepad splash icon lsfg extras; do
    legacy="$(zgu_lpm_legacy_path "${prefix}" "${key}")"
    new="$(zgu_lpm_path "${prefix}" "${key}")"
    [[ -e "${legacy}" || -L "${legacy}" ]] || continue
    if [[ "${key}" = "launcher_choice" ]]; then
      rm -rf -- "${legacy}" 2>/dev/null
      continue
    fi
    mkdir -p -- "$(dirname "${new}")" 2>/dev/null || continue
    if [[ ! -e "${new}" && ! -L "${new}" ]]; then
      mv -- "${legacy}" "${new}" 2>/dev/null
    elif [[ -d "${legacy}" && ! -L "${legacy}" && -d "${new}" && ! -L "${new}" ]]; then
      for child in "${legacy}"/* "${legacy}"/.[!.]*; do
        [[ -e "${child}" || -L "${child}" ]] || continue
        mv -n -- "${child}" "${new}/" 2>/dev/null
      done
      rmdir -- "${legacy}" 2>/dev/null
    fi
  done
  new="$(zgu_lpm_path "${prefix}" config)"
  if [[ -f "${new}" ]] && grep -q 'GAMEDIR/scripts/' "${new}" 2>/dev/null; then
    sed -i 's|\$GAMEDIR/scripts/|$GAMEDIR/lpm/scripts/|g' "${new}" 2>/dev/null
  fi
  return 0
}
