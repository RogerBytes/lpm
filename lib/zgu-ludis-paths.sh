#!/bin/bash

# --- Where ludis keeps ITS files inside a game's prefix ---
#
# Everything ludis adds to a prefix lives in ONE folder, "<prefix>/ludis/":
#
#   ludis/config.yml              copy of the Lutris YAML (first member of a .zgp archive)
#   ludis/launcher.yml            Ludis Launcher entries
#   ludis/settings/               loading-screen switches and settings
#       no-loadingscreen, keep-focus, max-wait-s, extra-loading-ms,
#       loading-message.txt, ignore-windows.txt, overlay-fps (on | off; absent = follow the global setting)
#   ludis/scripts/                wine trace wrapper + the game's pre/post-launch scripts
#   ludis/gamepad/                AntiMicroX profile
#   ludis/images/splash/          loading-screen images
#   ludis/images/icon/            game icon
#   ludis/lsfg-vk/                lsfg-vk.dll copy
#   ludis/extras/                 bonus content (manuals, soundtrack...)
#   ludis/.launcher-choice        temporary file (never packed)
#
# Older prefixes (and older .zgp archives) have the same files scattered at the prefix root
# under other names. For those, every READ falls back to the old location when the new one
# does not exist. Every WRITE goes to the new location. This fallback lives ONLY here: when
# all old games are re-created, delete the "legacy" column of zgu_ludis_rel and nothing else.

ZGU_LUDIS_DIRNAME="ludis"
# Name of the folder before the project was renamed (read as a fallback, then moved by zgu_ludis_adopt_old_dir).
ZGU_LUDIS_OLD_DIRNAME="lpm"

# zgu_ludis_rel <key> <new|legacy>: path relative to "<prefix>/ludis" (new) or to "<prefix>" (legacy).
zgu_ludis_rel() {
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
    overlay_fps)      new="settings/overlay-fps";       legacy="lpm-overlay-fps" ;;
    saves_auto)       new="settings/saves-auto";        legacy="saves-auto" ;;
    saves_folders)    new="settings/saves-folders.txt"; legacy="saves-folders.txt" ;;
    saves_extra)      new="settings/saves-extra.txt";   legacy="saves-extra.txt" ;;
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

# zgu_ludis_dir <prefix>: the ludis folder of a prefix.
zgu_ludis_dir() {
  printf '%s/%s' "${1%/}" "${ZGU_LUDIS_DIRNAME}"
}

# zgu_ludis_path <prefix> <key>: NEW location, where to WRITE.
zgu_ludis_path() {
  printf '%s/%s/%s' "${1%/}" "${ZGU_LUDIS_DIRNAME}" "$(zgu_ludis_rel "$2" new)"
}

# zgu_ludis_legacy_path <prefix> <key>: OLD location (prefix root).
zgu_ludis_legacy_path() {
  printf '%s/%s' "${1%/}" "$(zgu_ludis_rel "$2" legacy)"
}

# zgu_ludis_find <prefix> <key>: path to READ. The new location if it exists, else the old
# one if it exists, else the new one (so a later write or "does not exist" test is right).
zgu_ludis_find() {
  local new legacy old
  new="$(zgu_ludis_path "$1" "$2")"
  legacy="$(zgu_ludis_legacy_path "$1" "$2")"
  old="${1%/}/${ZGU_LUDIS_OLD_DIRNAME}/$(zgu_ludis_rel "$2" new)"
  if [[ -e "${new}" ]]; then
    printf '%s' "${new}"
  elif [[ -e "${old}" ]]; then
    printf '%s' "${old}"
  elif [[ -e "${legacy}" ]]; then
    printf '%s' "${legacy}"
  else
    printf '%s' "${new}"
  fi
}

# zgu_ludis_exists <prefix> <key>: true if the item exists at the new OR the old location.
zgu_ludis_exists() {
  [[ -e "$(zgu_ludis_path "$1" "$2")" ]] || [[ -e "$(zgu_ludis_legacy_path "$1" "$2")" ]] \
    || [[ -e "${1%/}/${ZGU_LUDIS_OLD_DIRNAME}/$(zgu_ludis_rel "$2" new)" ]]
}

# zgu_ludis_remove <prefix> <key>: removes the item at BOTH locations (files and folders).
zgu_ludis_remove() {
  rm -rf -- "$(zgu_ludis_path "$1" "$2")" "$(zgu_ludis_legacy_path "$1" "$2")" \
    "${1%/}/${ZGU_LUDIS_OLD_DIRNAME}/$(zgu_ludis_rel "$2" new)" 2>/dev/null
  return 0
}

# zgu_ludis_prune <prefix>: removes "<prefix>/ludis" folders left empty (settings/, images/, ludis/).
zgu_ludis_prune() {
  local base="${1%/}/${ZGU_LUDIS_DIRNAME}"
  [[ -d "${base}" ]] || return 0
  find "${base}" -mindepth 1 -type d -empty -delete 2>/dev/null
  rmdir "${base}" 2>/dev/null
  return 0
}

# zgu_ludis_adopt_old_dir <prefix> [lutris yml]: the folder of a prefix was called "lpm" before the
# project became Ludis. Moves "<prefix>/lpm" to "<prefix>/ludis" (children merged one by one when
# "ludis" already exists, existing files win) and rewrites "<prefix>/lpm/" -> "<prefix>/ludis/" in
# the given Lutris YAML (hook and profile paths). Nothing happens for a link. Safe to run again.
zgu_ludis_adopt_old_dir() {
  local prefix="${1%/}" yml="${2:-}" old new child esc pat
  old="${prefix}/${ZGU_LUDIS_OLD_DIRNAME}"; new="${prefix}/${ZGU_LUDIS_DIRNAME}"
  if [[ -d "${old}" && ! -L "${old}" && ! -L "${new}" ]]; then
    if [[ ! -e "${new}" ]]; then
      mv -- "${old}" "${new}" 2>/dev/null
    elif [[ -d "${new}" ]]; then
      for child in "${old}"/* "${old}"/.[!.]*; do
        [[ -e "${child}" || -L "${child}" ]] || continue
        mv -n -- "${child}" "${new}/" 2>/dev/null
      done
      rmdir -- "${old}" 2>/dev/null
    fi
  fi
  if [[ -n "${yml}" && -f "${yml}" ]]; then
    esc="$(printf '%s' "${prefix}" | sed -e 's/[\\&|]/\\&/g')"
    pat="$(printf '%s' "${prefix}/${ZGU_LUDIS_OLD_DIRNAME}/" | sed -e 's/[][\\.*^$|]/\\&/g')"
    sed -i -e "s|${pat}|${esc}/${ZGU_LUDIS_DIRNAME}/|g" -e 's|\$GAMEDIR/lpm/|$GAMEDIR/ludis/|g' "${yml}" 2>/dev/null
  fi
  return 0
}

# zgu_ludis_migrate <prefix>: moves the ludis files of an OLD-layout prefix (prefix root) into
# "<prefix>/ludis" with their new names, so that a game installed from an old .zgp is brought to
# the current layout at once (no new export needed). Safe to run again (nothing left to move =
# nothing happens) and never overwrites: if the new location already exists the old item stays
# where it is (folders are merged child by child, existing files win). Nothing is moved when
# "<prefix>/ludis" is a link (a forged archive could aim it elsewhere).
# Prints nothing. The temporary choice file is deleted instead of moved.
# Also fixes the hook paths "$GAMEDIR/scripts/" -> "$GAMEDIR/ludis/scripts/" in the bundled
# config.yml, since the "scripts" folder moves.
zgu_ludis_migrate() {
  local prefix="${1%/}" key legacy new child
  [[ -d "${prefix}" ]] || return 0
  [[ -L "${prefix}/${ZGU_LUDIS_DIRNAME}" ]] && return 0
  for key in config launcher launcher_choice no_loadingscreen keep_focus max_wait extra_loading \
             loading_message ignore_windows scripts gamepad splash icon lsfg extras; do
    legacy="$(zgu_ludis_legacy_path "${prefix}" "${key}")"
    new="$(zgu_ludis_path "${prefix}" "${key}")"
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
  new="$(zgu_ludis_path "${prefix}" config)"
  if [[ -f "${new}" ]] && grep -q 'GAMEDIR/scripts/' "${new}" 2>/dev/null; then
    sed -i 's|\$GAMEDIR/scripts/|$GAMEDIR/ludis/scripts/|g' "${new}" 2>/dev/null
  fi
  if [[ -f "${new}" ]] && grep -q 'GAMEDIR/lpm_gamepad/' "${new}" 2>/dev/null; then
    sed -i 's|\$GAMEDIR/lpm_gamepad/|$GAMEDIR/ludis/gamepad/|g' "${new}" 2>/dev/null
  fi
  return 0
}

# zgu_ludis_fix_yml_paths <prefix> <lutris yml>: after a migration, rewrites in the Lutris YAML the
# absolute paths that pointed to an old location of a moved item (the AntiMicroX profile
# "system.antimicro_config" and the pre/post-launch scripts). Only exact "<prefix>/<old>/" starts
# are changed, so a path outside the prefix is never touched. No-op if nothing matches.
zgu_ludis_fix_yml_paths() {
  local prefix="${1%/}" yml="$2" old_gp old_sc esc
  [[ -f "${yml}" ]] || return 0
  old_gp="${prefix}/$(zgu_ludis_rel gamepad legacy)/"
  old_sc="${prefix}/$(zgu_ludis_rel scripts legacy)/"
  # "|" is the sed delimiter and "&" / "\" are special in the replacement: escape the prefix.
  esc="$(printf '%s' "${prefix}" | sed -e 's/[\\&|]/\\&/g')"
  local pat_gp pat_sc
  pat_gp="$(printf '%s' "${old_gp}" | sed -e 's/[][\\.*^$|]/\\&/g')"
  pat_sc="$(printf '%s' "${old_sc}" | sed -e 's/[][\\.*^$|]/\\&/g')"
  sed -i \
    -e "s|${pat_gp}|${esc}/${ZGU_LUDIS_DIRNAME}/$(zgu_ludis_rel gamepad new)/|g" \
    -e "s|${pat_sc}|${esc}/${ZGU_LUDIS_DIRNAME}/$(zgu_ludis_rel scripts new)/|g" \
    "${yml}" 2>/dev/null
  return 0
}


# --- FPS overlay (MangoHud) shown / hidden from the in-game Ludis menu ---
# Global setting: key "overlay_fps" (on | off, default OFF) of <XDG config>/ludis/menu.conf.
# Per game: "<prefix>/ludis/settings/overlay-fps" holding "on" or "off"; no file = follow the global
# setting. The game is started with MangoHud loaded but HIDDEN only when the result is "on".

zgu_overlay_fps_conf() {
  printf '%s/ludis/menu.conf' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

# zgu_overlay_fps_global: prints "on" or "off".
zgu_overlay_fps_global() {
  local conf value
  conf="$(zgu_overlay_fps_conf)"
  value="$(sed -n 's/^[[:space:]]*overlay_fps[[:space:]]*=[[:space:]]*//p' "${conf}" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
  case "${value,,}" in
    on|1|yes|true) printf 'on' ;;
    *) printf 'off' ;;
  esac
}

# zgu_overlay_fps_set_global <on|off>: writes the key, keeping the other lines of menu.conf.
zgu_overlay_fps_set_global() {
  local conf tmp
  conf="$(zgu_overlay_fps_conf)"
  mkdir -p "$(dirname "${conf}")" || return 1
  tmp="$(mktemp "${conf}.XXXXXX")" || return 1
  { grep -v -E '^[[:space:]]*overlay_fps[[:space:]]*=' "${conf}" 2>/dev/null; printf 'overlay_fps=%s\n' "$1"; } > "${tmp}" \
    && mv -f "${tmp}" "${conf}"
}

# zgu_overlay_fps_pergame <prefix>: prints "follow", "on" or "off".
zgu_overlay_fps_pergame() {
  local file value
  file="$(zgu_ludis_find "$1" overlay_fps)"
  value="$(tr -d '[:space:]' < "${file}" 2>/dev/null)"
  case "${value,,}" in
    on|off) printf '%s' "${value,,}" ;;
    *) printf 'follow' ;;
  esac
}

# zgu_overlay_fps_set_pergame <prefix> <follow|on|off>
zgu_overlay_fps_set_pergame() {
  local file
  file="$(zgu_ludis_path "$1" overlay_fps)"
  if [[ "$2" = "follow" ]]; then
    zgu_ludis_remove "$1" overlay_fps
    zgu_ludis_prune "$1"
    return 0
  fi
  mkdir -p "$(dirname "${file}")" || return 1
  printf '%s\n' "$2" > "${file}"
}

# zgu_overlay_fps_wanted <prefix>: exit status 0 when the overlay must be loaded for this game.
zgu_overlay_fps_wanted() {
  local game
  game="$(zgu_overlay_fps_pergame "$1")"
  [[ "${game}" = "follow" ]] && game="$(zgu_overlay_fps_global)"
  [[ "${game}" = "on" ]]
}


# zgu_ludis_migrate_home: the user folders were called "lpm" before the rename. Moves
# ~/.config/lpm, ~/.local/share/lpm and ~/.cache/lpm to "ludis" when the new one does not exist
# yet, and the log file lpm.log to ludis.log. Safe to run again; silent.
zgu_ludis_migrate_home() {
  local base old new
  for base in "${XDG_CONFIG_HOME:-${HOME}/.config}" "${XDG_DATA_HOME:-${HOME}/.local/share}" "${XDG_CACHE_HOME:-${HOME}/.cache}"; do
    old="${base}/lpm"; new="${base}/ludis"
    [[ -d "${old}" && ! -L "${old}" && ! -e "${new}" && ! -L "${new}" ]] || continue
    mv -- "${old}" "${new}" 2>/dev/null
  done
  old="${XDG_DATA_HOME:-${HOME}/.local/share}/ludis"
  [[ -f "${old}/lpm.log" && ! -e "${old}/ludis.log" ]] && mv -- "${old}/lpm.log" "${old}/ludis.log" 2>/dev/null
  return 0
}


# --- Saves: automatic mode (see lib/zgp-game-saves.sh) ---
# Global: <XDG config>/ludis/saves.conf keys "sync_dir", "auto" (on|off, default OFF) and "interval"
# (minutes, 0 = no periodic copy, default 10). Per game: "<prefix>/ludis/settings/saves-auto"
# holding "on" or "off"; no file = follow the global setting.

zgu_saves_conf_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${XDG_CONFIG_HOME:-${HOME}/.config}/ludis/saves.conf" 2>/dev/null | tail -n 1
}

# zgu_saves_auto_wanted <prefix>: exit status 0 when the automatic mode must run for this game
# (a sync folder is set AND the game setting, else the global one, is on).
zgu_saves_auto_wanted() {
  local game value
  [[ -n "$(zgu_saves_conf_get sync_dir)" ]] || return 1
  game="$(tr -d '[:space:]' < "$(zgu_ludis_find "$1" saves_auto)" 2>/dev/null)"
  case "${game,,}" in
    on) return 0 ;;
    off) return 1 ;;
  esac
  value="$(zgu_saves_conf_get auto | tr -d '[:space:]')"
  [[ "${value,,}" = "on" ]]
}

# zgu_saves_interval: minutes between two copies while playing (0 = none).
zgu_saves_interval() {
  local v
  v="$(zgu_saves_conf_get interval | tr -d '[:space:]')"
  [[ "${v}" =~ ^[0-9]+$ ]] && (( v <= 60 )) || v=10
  printf '%s' "${v}"
}
