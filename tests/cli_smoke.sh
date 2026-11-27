#!/usr/bin/env bash
# CLI smoke test: runs the main "ludis" commands against a fake HOME (fake Lutris, demo
# database, fake Wine runner) and checks exit code + output.
# No GUI, no network, nothing touched outside the temp directory.
# Requires: bash, sqlite3, python3 + PyYAML, zstd/tar (like ludis itself).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp -r "${repo}" "${work}/repo"
chmod +x "${work}/repo/bin/ludis"
R="${work}/repo/bin/ludis"

export HOME="${work}/home"
# GitHub runners define XDG_* for their own home: the tests must only look inside the fake HOME.
export XDG_CONFIG_HOME="${HOME}/.config" XDG_DATA_HOME="${HOME}/.local/share" XDG_CACHE_HOME="${HOME}/.cache"
export LANG=C LC_ALL=C LANGUAGE=en
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "${HOME}/bin" "${HOME}/.config/lutris/games" "${HOME}/.local/share/applications" \
  "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin" \
  "${HOME}/Games/mario/drive_c/windows/system32" "${HOME}/Games/zelda/drive_c/windows/system32"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/bin/lutris"; chmod +x "${HOME}/bin/lutris"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin/wine"
chmod +x "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin/wine"
# Fake wine/wineserver/winetricks first in PATH: if an ludis command ran them, the test would
# start a real Wine (writing into the fake prefix and skewing packaging).
for fake in wine wine64 wineserver winetricks umu-run; do
  printf '#!/bin/sh\nexit 0\n' > "${HOME}/bin/${fake}"; chmod +x "${HOME}/bin/${fake}"
done
# Fake winepath ("winepath -w /a/b" -> Z:\a\b): ludis calls it for the Ludis Launcher, and the
# real one would initialize a real Wine prefix (wineserver) in the test directory.
for dir in "${HOME}/bin" "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin"; do
  printf '#!/bin/sh\nprintf "Z:%%s\\n" "$(printf %%s "$2" | tr / "\\\\")"\n' > "${dir}/winepath"
  chmod +x "${dir}/winepath"
done
export PATH="${HOME}/bin:${PATH}"
sqlite3 "${HOME}/.local/share/lutris/pga.db" "create table games(id integer primary key,name text,slug text,runner text,directory text,configpath text,installer_slug text,parent_slug text,executable text,updated int,installed int,installed_at int);
insert into games(name,slug,runner,directory,configpath) values('Mario','mario','wine','${HOME}/Games/mario','mario-1'),('Zelda','zelda','wine','${HOME}/Games/zelda','zelda-1');"
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/mario-1.yml"
printf 'game:\n  exe: /y.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/zelda-1.yml"

pass=0; fail=0
# check "name" <expected code> "<regex expected in stdout+stderr, or empty>" <ludis arguments...>
check() {
  local name="$1" want_rc="$2" want_re="$3"; shift 3
  local out rc
  out="$(timeout 120 bash "${R}" "$@" </dev/null 2>&1)"; rc=$?
  if [[ "${rc}" -eq "${want_rc}" ]] && { [[ -z "${want_re}" ]] || grep -Eq -- "${want_re}" <<<"${out}"; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAILED: ${name} (expected rc=${want_rc} /${want_re}/, got rc=${rc})" >&2
    sed 's/^/    | /' <<<"${out}" | head -8 >&2
  fi
}
# expect "name" <shell test command>
expect() {
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAILED: ${name}" >&2; fi
}

# --- General
check "version" 0 '^ludis v[0-9]' --version
check "unknown command" 1 'Unknown command' bogus
check "no argument: help, exit code 0" 0 'ludis vsync' 
check "list" 0 'mario +Mario' list
check "list (zelda)" 0 'zelda +Zelda' list

# --- Saves (backup / restore / export / import)
sv_user="${HOME}/Games/zelda/drive_c/users/steamuser"
mkdir -p "${sv_user}/AppData/Roaming/Zelda" "${sv_user}/AppData/Local/Temp" "${sv_user}/Documents/My Games" "${sv_user}/Saved Games" "${HOME}/Games/zelda/drive_c/users/Public"
echo slot1 > "${sv_user}/AppData/Roaming/Zelda/save1.dat"; echo tmp > "${sv_user}/AppData/Local/Temp/junk"; echo doc > "${sv_user}/Documents/My Games/a.ini"
ln -s /etc/passwd "${sv_user}/Documents/evil-link"
check "saves: backup without sync folder is refused" 1 'ludis saves dir' saves zelda backup
check "saves: dir set" 0 '' saves dir "${HOME}/syncsaves"
check "saves: backup" 0 'backed up' saves zelda backup
expect "saves: files copied, Temp and links left out" bash -c 'c="$1/syncsaves/zelda/current"; [ "$(cat "$c/AppData/Roaming/Zelda/save1.dat")" = slot1 ] && [ -f "$c/Documents/My Games/a.ini" ] && [ ! -e "$c/AppData/Local/Temp/junk" ] && [ ! -e "$c/Documents/evil-link" ] && [ ! -L "$c/Documents/evil-link" ]' _ "${HOME}"
check "saves: second backup without change" 0 'unchanged' saves zelda backup
echo slot2 > "${sv_user}/AppData/Roaming/Zelda/save1.dat"
check "saves: changed backup rotates the old one" 0 'backed up' saves zelda backup
expect "saves: previous/ holds the old state as a compressed archive with the old content" bash -c 'p=$(ls "$1"/syncsaves/zelda/previous/*-backup.tar.zst | head -1); [ "$(zstd -dcq "$p" | tar -xOf - ./AppData/Roaming/Zelda/save1.dat)" = slot1 ]' _ "${HOME}"
check "saves: restore" 0 'restored' saves zelda restore
expect "saves: restore brought back the last backup (slot2) and kept the local copy" bash -c '[ "$(cat "$1")" = slot2 ] && ls "$2"/syncsaves/zelda/previous | grep -q before-restore' _ "${sv_user}/AppData/Roaming/Zelda/save1.dat" "${HOME}"
check "saves: export" 0 'exported' saves zelda export "${HOME}/zelda-test"
expect "saves: archive name .zgs and marker inside" bash -c 'zstd -dcq "$1" | tar -tf - | grep -q "ludis-saves$\|\.ludis-saves"' _ "${HOME}/zelda-test.zgs"
echo slot3 > "${sv_user}/AppData/Roaming/Zelda/save1.dat"
check "saves: import" 0 'imported' saves zelda import "${HOME}/zelda-test.zgs"
expect "saves: import put the exported content back (slot2)" bash -c '[ "$(cat "$1")" = slot2 ]' _ "${sv_user}/AppData/Roaming/Zelda/save1.dat"
expect "saves: forged archive with ../ or a link is refused" bash -c 'd=$(mktemp -d); mkdir -p "$d/x"; echo m > "$d/x/.ludis-saves"; ln -s /etc "$d/x/AppData"; tar -C "$d/x" -cf - . | zstd -q -o "$d/bad.zgs"; ! bash "$1" saves zelda import "$d/bad.zgs" </dev/null >/dev/null 2>&1; rc=$?; rm -rf "$d"; exit $rc' _ "${R}"
expect "saves: random file is not a saves archive" bash -c 'echo hello > "$2/notzgs.zgs"; ! bash "$1" saves zelda import "$2/notzgs.zgs" </dev/null >/dev/null 2>&1' _ "${R}" "${HOME}"
check "saves: global auto is off by default" 0 '^off$' saves auto
check "saves: game follows the global setting (off)" 0 'game=follow global=off' saves zelda auto
expect "saves: sync folder set but global off: nothing automatic" bash -c 'source "$1/lib/zgu-ludis-paths.sh"; ! zgu_saves_auto_wanted "$2"' _ "${repo}" "${HOME}/Games/zelda"
check "saves: global auto on" 0 '' saves auto on
check "saves: game auto follows the global setting" 0 'game=follow global=on' saves zelda auto
check "saves: push is quiet and makes a backup when files changed" 0 '^$' saves zelda push
echo slot4 > "${sv_user}/AppData/Roaming/Zelda/save1.dat"; touch -d '-1 minute' "${sv_user}/AppData/Roaming/Zelda/save1.dat"
check "saves: push (changed)" 0 '^$' saves zelda push
expect "saves: push copied the new content" bash -c '[ "$(cat "$1/syncsaves/zelda/current/AppData/Roaming/Zelda/save1.dat")" = slot4 ]' _ "${HOME}"
check "saves: pull right after our own push: up to date" 0 'pull=up-to-date' saves zelda pull
# another machine pushes a newer backup
echo remote5 > "${HOME}/syncsaves/zelda/current/AppData/Roaming/Zelda/save1.dat"; echo "$(( $(date +%s) + 100 )) otherpc" > "${HOME}/syncsaves/zelda/stamp"
check "saves: pull brings the newer backup (local copy kept)" 0 'pull=restored' saves zelda pull
expect "saves: pull restored the remote content and kept slot4 in previous/" bash -c '[ "$(cat "$1")" = remote5 ] && for f in "$2"/syncsaves/zelda/previous/*-before-pull.tar.zst "$2"/syncsaves/zelda/previous/*-conflict.tar.zst; do [ -f "$f" ] && zstd -dcq "$f" | tar -xOf - ./AppData/Roaming/Zelda/save1.dat | grep -q slot4 && exit 0; done; exit 1' _ "${sv_user}/AppData/Roaming/Zelda/save1.dat" "${HOME}"
check "saves: pull again: up to date" 0 'pull=up-to-date' saves zelda pull
check "saves: per-game auto off" 0 '' saves zelda auto off
expect "saves: per-game off wins over the global on" bash -c 'source "$1/lib/zgu-ludis-paths.sh"; ! zgu_saves_auto_wanted "$2"' _ "${repo}" "${HOME}/Games/zelda"
check "saves: per-game follow" 0 '' saves zelda auto follow
expect "saves: auto wanted again (sync folder set, global on)" bash -c 'source "$1/lib/zgu-ludis-paths.sh"; zgu_saves_auto_wanted "$2"' _ "${repo}" "${HOME}/Games/zelda"
check "saves: global auto off" 0 '' saves auto off
expect "saves: global off -> not wanted" bash -c 'source "$1/lib/zgu-ludis-paths.sh"; ! zgu_saves_auto_wanted "$2"' _ "${repo}" "${HOME}/Games/zelda"
check "saves: per-game on wins over the global off" 0 '' saves zelda auto on
expect "saves: per-game on -> wanted" bash -c 'source "$1/lib/zgu-ludis-paths.sh"; zgu_saves_auto_wanted "$2"' _ "${repo}" "${HOME}/Games/zelda"
check "saves: per-game follow again" 0 '' saves zelda auto follow
check "saves: global auto on again" 0 '' saves auto on
check "saves: dir default is Documents/Ludis-saves" 0 'Ludis-saves' saves dir default
expect "saves: default folder created" test -d "${HOME}/Documents/Ludis-saves"
check "saves: back to the test sync folder" 0 '' saves dir "${HOME}/syncsaves"
check "saves: interval default" 0 '^10$' saves interval
check "saves: interval set" 0 'minute' saves interval 25
check "saves: interval refused above 60" 1 '' saves interval 99
# custom folders (stored in the prefix, replace the defaults)
check "saves: folders list = defaults" 0 'AppData' saves zelda folders list
check "saves: folders add" 0 '' saves zelda folders add "AppData/Roaming/Zelda"
check "saves: folders add refuses .." 1 '' saves zelda folders add "../x"
check "saves: folders remove" 0 '' saves zelda folders remove AppData
check "saves: folders remove Documents" 0 '' saves zelda folders remove Documents
check "saves: folders remove Saved Games" 0 '' saves zelda folders remove "Saved Games"
expect "saves: the choice is a file in the prefix" bash -c '[ -f "$1/Games/zelda/ludis/settings/saves-folders.txt" ] && [ "$(cat "$1/Games/zelda/ludis/settings/saves-folders.txt")" = "AppData/Roaming/Zelda" ]' _ "${HOME}"
check "saves: backup with custom folders" 0 'backed up|unchanged' saves zelda backup
expect "saves: only the chosen folder is in the backup" bash -c 'c="$1/syncsaves/zelda/current"; [ -f "$c/AppData/Roaming/Zelda/save1.dat" ] && [ ! -e "$c/Documents" ]' _ "${HOME}"
check "saves: folders reset" 0 '' saves zelda folders reset
# exclusions (built-in + per game) and rotation
mkdir -p "${sv_user}/AppData/Local/dxvk" "${sv_user}/AppData/Roaming/Microsoft/Windows/Recent" "${sv_user}/AppData/LocalLow/Studio/Game/Unity"
echo bin > "${sv_user}/AppData/Local/dxvk/a.dxvk.bin"; echo r > "${sv_user}/AppData/Roaming/Microsoft/Windows/Recent/r.lnk"
echo log > "${sv_user}/AppData/LocalLow/Studio/Game/Player.log"; echo u > "${sv_user}/AppData/LocalLow/Studio/Game/Unity/analytics"
echo keep > "${sv_user}/AppData/LocalLow/Studio/Game/SaveData.json"; echo skipme > "${sv_user}/AppData/LocalLow/Studio/Game/big.cache2"
check "saves: exclude add" 0 '' saves zelda exclude add "*.cache2"
check "saves: exclude list" 0 'cache2' saves zelda exclude list
check "saves: exclude defaults are listed" 0 'dxvk' saves zelda exclude defaults
check "saves: exclude refuses .." 1 '' saves zelda exclude add "../x"
check "saves: backup with exclusions" 0 'backed up|unchanged' saves zelda backup
expect "saves: built-in and per-game exclusions applied, real save kept" bash -c 'c="$1/syncsaves/zelda/current/AppData"; [ -f "$c/LocalLow/Studio/Game/SaveData.json" ] && [ ! -e "$c/Local/dxvk" ] && [ ! -e "$c/Roaming/Microsoft" ] && [ ! -e "$c/LocalLow/Studio/Game/Player.log" ] && [ ! -e "$c/LocalLow/Studio/Game/Unity" ] && [ ! -e "$c/LocalLow/Studio/Game/big.cache2" ]' _ "${HOME}"
check "saves: exclude reset" 0 '' saves zelda exclude reset
check "saves: exclude list empty after reset" 0 '^$' saves zelda exclude list
# rotation: fake snapshots of known ages (compressed files), then a real change triggers it
rp="${HOME}/syncsaves/zelda/previous"; rm -rf "${rp}"; mkdir -p "${rp}"
mk() { touch "${rp}/$(date -d "$1 ago" +%Y%m%d-%H%M%S)-$2.tar.zst"; }
mk "30 minutes" a; mk "40 minutes" b; mk "100 minutes" c; mk "170 minutes" d; mk "5 hours" e; mk "6 hours" f
mk "2 days" g; mk "10 days" h; mk "20 days" i; mk "4 days" before-pull; mk "5 days" conflict
echo rot > "${sv_user}/AppData/Roaming/Zelda/rot.dat"
check "saves: backup triggers the rotation" 0 'backed up' saves zelda backup
expect "saves: rotation keeps only the new backup and the newest safety copy" bash -c 'cd "$1"; [ "$(ls | wc -l)" = 2 ] && ls | grep -q -- "-backup.tar.zst$" && ls | grep -q -- "-before-pull.tar.zst$"' _ "${rp}"
# a backup made less than 15 minutes after the last "previous" replaces current without making a new snapshot
before_list="$(ls "${rp}")"; echo rot2 > "${sv_user}/AppData/Roaming/Zelda/rot.dat"
check "saves: a quick second backup" 0 'backed up' saves zelda backup
expect "saves: ... makes no new snapshot (previous stays the same)" bash -c '[ "$(ls "$1")" = "$2" ]' _ "${rp}" "${before_list}"
expect "saves: ... but current holds the new content" bash -c 'grep -q rot2 "$1/syncsaves/zelda/current/AppData/Roaming/Zelda/rot.dat"' _ "${HOME}"
expect "saves: the snapshot made by the backup is a real compressed archive of the old state" bash -c 'f=$(ls "$1"/*-backup.tar.zst | head -1); zstd -dcq "$f" | tar -t | grep -q "AppData"' _ "${rp}"
check "saves: history lists the snapshots" 0 'backup' saves zelda history
check "saves: path prints the Windows user folder" 0 'users/steamuser' saves zelda path
echo tampered > "${sv_user}/AppData/Roaming/Zelda/save1.dat"
check "saves: restore from an older snapshot by name" 0 'restored' saves zelda restore backup
expect "saves: that restore overwrote save1.dat with the snapshot content" bash -c '[ "$(cat "$1")" != tampered ]' _ "${sv_user}/AppData/Roaming/Zelda/save1.dat"
check "saves: restore from an unknown snapshot fails" 1 '' saves zelda restore nosuchsnapshot
# manual folder: absolute path from a folder picker (inside the user folder, and elsewhere in drive_c)
mkdir -p "${sv_user}/AppData/Roaming/Zelda/Slot" "${HOME}/Games/zelda/drive_c/Games/Zelda/save"; echo extra > "${HOME}/Games/zelda/drive_c/Games/Zelda/save/s1.sav"
check "saves: folders add (absolute path inside the user folder)" 0 '' saves zelda folders add "${sv_user}/AppData/Roaming/Zelda/Slot"
check "saves: folders add (absolute path elsewhere in drive_c)" 0 '' saves zelda folders add "${HOME}/Games/zelda/drive_c/Games/Zelda/save"
check "saves: folders add refuses a path outside the prefix" 1 '' saves zelda folders add "${HOME}/elsewhere"
check "saves: folders list shows both kinds" 0 'AppData/Roaming/Zelda/Slot' saves zelda folders list
check "saves: folders list shows the drive_c entry" 0 'drive_c:Games/Zelda/save' saves zelda folders list
check "saves: backup with an extra folder" 0 'backed up|unchanged' saves zelda backup
expect "saves: the extra folder is in the backup under _extra/" bash -c '[ -f "$1/syncsaves/zelda/current/_extra/Games/Zelda/save/s1.sav" ]' _ "${HOME}"
check "saves: folders reset clears both" 0 '' saves zelda folders reset
# initial copy and reset
ini="${HOME}/Games/zelda/ludis/saves-initial"
check "saves: initial makes the first copy" 0 '[Ii]nitial' saves zelda initial
expect "saves: ... stored in the prefix" test -d "${ini}"
check "saves: initial again keeps the first copy" 0 '' saves zelda initial
echo changed > "${sv_user}/AppData/Roaming/Zelda/save1.dat"; echo newfile > "${sv_user}/AppData/Roaming/Zelda/new.dat"
check "saves: reset without --yes and without a terminal refuses" 1 '' saves zelda reset
check "saves: reset --yes" 0 'reset|restored|initial' saves zelda reset --yes
expect "saves: reset removed files created after the initial copy" bash -c '[ ! -e "$1/new.dat" ]' _ "${sv_user}/AppData/Roaming/Zelda"
expect "saves: reset keeps the current saves once first (safety copy)" bash -c 'ls "$1"/*before-reset* >/dev/null 2>&1 || ls -d "$2"/ludis/saves-before-reset >/dev/null 2>&1' _ "${rp}" "${HOME}/Games/zelda"
expect "saves: monitor stops by itself when the game never shows up" bash -c 'LUDIS_SAVES_GIVEUP=2 timeout 20 python3 "$1/lib/zgu-saves-monitor.py" "$2" zelda 10; [ $? -eq 0 ]' _ "${repo}" "${HOME}/Games/zelda"
# the folder choice travels with the backup and the .zgs (old prefixes learn it)
zs="${HOME}/Games/zelda/ludis/settings"
check "saves: custom folder + exclusion for the config test" 0 '' saves zelda folders add "AppData/Roaming/Zelda/Slot"
check "saves: custom exclusion" 0 '' saves zelda exclude add "*.zzz"
check "saves: backup records the choice" 0 'backed up|unchanged' saves zelda backup
expect "saves: <sync>/<slug>/config holds folder= and exclude= lines" bash -c 'c="$1/syncsaves/zelda/config"; grep -qx "folder=AppData/Roaming/Zelda/Slot" "$c" && grep -qx "exclude=\*.zzz" "$c"' _ "${HOME}"
check "saves: export (with the choice)" 0 'exported' saves zelda export "${HOME}/zelda-cfg"
expect "saves: the .zgs marker carries the choice" bash -c 'zstd -dcq "$1" | tar -xOf - ./.ludis-saves | grep -qx "folder=AppData/Roaming/Zelda/Slot"' _ "${HOME}/zelda-cfg.zgs"
expect "saves: simulate an old prefix: no saves settings of its own" bash -c 'rm -f "$1"/saves-folders.txt "$1"/saves-exclude.txt "$1"/saves-extra.txt' _ "${zs}"
expect "saves: no settings left in the prefix" bash -c '[ ! -e "$1/saves-folders.txt" ] && [ ! -e "$1/saves-exclude.txt" ]' _ "${zs}"
check "saves: restore on an old prefix" 0 'restored' saves zelda restore
expect "saves: the old prefix adopted the folders and the exclusions from the backup" bash -c 'grep -qx "AppData/Roaming/Zelda/Slot" "$1/saves-folders.txt" && grep -qx "\*.zzz" "$1/saves-exclude.txt"' _ "${zs}"
expect "saves: again an old prefix, then import the .zgs" bash -c 'rm -f "$1"/saves-folders.txt "$1"/saves-exclude.txt "$1"/saves-extra.txt' _ "${zs}"
check "saves: import on an old prefix" 0 'imported' saves zelda import "${HOME}/zelda-cfg.zgs"
expect "saves: the import adopted the choice too" bash -c 'grep -qx "AppData/Roaming/Zelda/Slot" "$1/saves-folders.txt"' _ "${zs}"
check "saves: own settings are never replaced (add another folder, restore)" 0 '' saves zelda folders add "Documents/Other"
check "saves: restore keeps them" 0 'restored' saves zelda restore
expect "saves: own list kept as is" bash -c 'grep -qx "Documents/Other" "$1/saves-folders.txt"' _ "${zs}"
check "saves: cleanup" 0 '' saves zelda folders reset
check "saves: cleanup exclusions" 0 '' saves zelda exclude reset
# the backup's config follows the folder choice at once (no new backup needed)
check "saves: change the folders after a backup" 0 '' saves zelda folders add "AppData/Roaming/Zelda/OnlyThis"
expect "saves: config in the sync folder updated at once" bash -c 'grep -qx "folder=AppData/Roaming/Zelda/OnlyThis" "$1/syncsaves/zelda/config"' _ "${HOME}"
check "saves: remove the default folders" 0 '' saves zelda folders remove AppData
expect "saves: config follows the removal too" bash -c 'grep -qx "folder=AppData/Roaming/Zelda/OnlyThis" "$1/syncsaves/zelda/config" && ! grep -qx "folder=AppData" "$1/syncsaves/zelda/config"' _ "${HOME}"
check "saves: exclusion change is recorded at once" 0 '' saves zelda exclude add "*.qqq"
expect "saves: config holds the new exclusion" bash -c 'grep -qx "exclude=\*.qqq" "$1/syncsaves/zelda/config"' _ "${HOME}"
check "saves: cleanup 3" 0 '' saves zelda folders reset
check "saves: cleanup 4" 0 '' saves zelda exclude reset
expect "saves: config emptied by the reset" bash -c '! grep -q "^folder=\|^exclude=" "$1/syncsaves/zelda/config"' _ "${HOME}"
# reinstall scenario: the game is uninstalled and installed again (empty prefix, settings gone)
check "saves: custom folder for the reinstall scenario" 0 '' saves zelda folders add "AppData/Roaming/Zelda/Slot"
check "saves: remove the default folders (scenario)" 0 '' saves zelda folders remove AppData
check "saves: remove Documents (scenario)" 0 '' saves zelda folders remove Documents
check "saves: remove Saved Games (scenario)" 0 '' saves zelda folders remove "Saved Games"
echo precious > "${sv_user}/AppData/Roaming/Zelda/Slot/slot.sav"
check "saves: backup of only the chosen folder" 0 'backed up|unchanged' saves zelda backup
expect "saves: only the chosen folder is in current" bash -c 'c="$1/syncsaves/zelda/current"; [ "$(cat "$c/AppData/Roaming/Zelda/Slot/slot.sav")" = precious ] && [ ! -e "$c/Documents" ]' _ "${HOME}"
rm -rf "${sv_user}/AppData" "${sv_user}/Documents" "${sv_user}/Saved Games"; rm -f "${zs}"/saves-folders.txt "${zs}"/saves-exclude.txt "${zs}"/saves-extra.txt
mkdir -p "${sv_user}/AppData/Local/Junk" "${sv_user}/Documents/Fresh"; echo new > "${sv_user}/Documents/Fresh/first-run.ini"
check "saves: a manual backup on the fresh prefix does not replace the chosen-folder backup" 1 '' saves zelda backup
expect "saves: the backup still holds the precious save and the chosen folder" bash -c 'c="$1/syncsaves/zelda"; [ "$(cat "$c/current/AppData/Roaming/Zelda/Slot/slot.sav")" = precious ] && grep -qx "folder=AppData/Roaming/Zelda/Slot" "$c/config"' _ "${HOME}"
expect "saves: the fresh prefix adopted the chosen folder" bash -c 'grep -qx "AppData/Roaming/Zelda/Slot" "$1/saves-folders.txt"' _ "${zs}"
rm -f "${zs}"/saves-folders.txt; rm -rf "${sv_user}/AppData" "${sv_user}/Documents"; mkdir -p "${sv_user}/Documents"
check "saves: pull on the empty fresh prefix brings the backup back (state of the old install kept)" 0 'pull=restored label=empty-prefix' saves zelda pull
expect "saves: the precious save is back" bash -c '[ "$(cat "$1")" = precious ]' _ "${sv_user}/AppData/Roaming/Zelda/Slot/slot.sav"
check "saves: scenario cleanup" 0 '' saves zelda folders reset
check "saves: unknown game" 1 '' saves nogame status

check "list-runner" 0 'GE-Test' list-runner
check "list-isolable" 0 'No isolable|Nothing' list-isolable
check "isolate without shared store" 0 'Nothing to isolate' isolate
check "sgdb-key get" 0 '"key"' sgdb-key get
# --- ludis isolate: every store (Epic, EA, Battle.net, Ubisoft), game split out of the shared prefix
# Fixture: a shared prefix holding the launcher (base), the game to isolate and ANOTHER game. After
# "ludis isolate -y <store>" the game has its own prefix (base + its own folders, not the other
# game), its Lutris row/YAML point to it, and it is purged from the shared prefix.
iso_db="${HOME}/.local/share/lutris/pga.db"
iso_cfg="${HOME}/.config/lutris/games"
iso_row() { # name slug dir configpath exe
  sqlite3 "${iso_db}" "insert into games(name,slug,runner,directory,configpath,executable,installer_slug) values('$1','$2','wine','$3','$4','$5','$2');"
}
iso_yml() { # configpath prefix exe args
  printf 'game:\n  exe: %s\n  prefix: %s\n  args: %s\nwine:\n  version: GE-Test\nsystem:\n  prelaunch_command: /bin/evil.sh\n' "$3" "$2" "$4" > "${iso_cfg}/$1.yml"
}
iso_mk() { mkdir -p "$(dirname "$1")"; echo data > "$1"; }
iso_cleanup() {
  sqlite3 "${iso_db}" "delete from games where slug in ('epic-store','cool-game','ea-store','mass-effect','mass-effect-mass-effect','bnet','diablo','ubi-store','far-cry');"
  rm -rf "${HOME}/Games/epic" "${HOME}/Games/cool-game" "${HOME}/Games/ea" "${HOME}/Games/mass-effect-mass-effect" "${HOME}/Games/bnet" "${HOME}/Games/diablo" "${HOME}/Games/ubi" "${HOME}/Games/far-cry"
  rm -f "${iso_cfg}"/cool-game-* "${iso_cfg}"/epic-cfg.yml "${iso_cfg}"/mass-* "${iso_cfg}"/diablo-* "${iso_cfg}"/far-cry-* "${iso_cfg}"/ea-cfg.yml "${iso_cfg}"/bnet-cfg.yml "${iso_cfg}"/ubi-cfg.yml
}
iso_check_common() { # name newslug
  expect "isolate ($1): new prefix has the c: link and its own YAML without the evil hook" bash -c 'test -L "$1/Games/$2/dosdevices/c:" && f=$(ls "$1"/.config/lutris/games/$2-*.yml | head -1) && grep -q "prefix: $1/Games/$2" "$f" && ! grep -E "^[[:space:]]*prelaunch_command:" "$f"' _ "${HOME}" "$2"
  expect "isolate ($1): Lutris row moved to the new prefix, old row gone" bash -c 'r=$(sqlite3 "$1" "select directory from games where slug=\"$2\";"); [ "$r" = "$3/Games/$2" ]' _ "${iso_db}" "$2" "${HOME}"
}
# --- Epic Games Store
iso_cleanup
g="${HOME}/Games/epic"
iso_mk "${g}/drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests/a.item"; printf '{"DisplayName":"Cool Game","MandatoryAppFolderName":"CoolGame"}' > "${g}/drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests/a.item"
iso_mk "${g}/drive_c/Program Files/Epic Games/CoolGame/game.exe"; iso_mk "${g}/drive_c/Program Files/Epic Games/OtherGame/other.exe"
iso_mk "${g}/drive_c/Program Files/Epic Games/Launcher/launcher.exe"
iso_row "Epic Games Store" epic-store "${g}" epic-cfg "${g}/x.exe"; iso_row "Cool Game" cool-game "${g}" cool-game-111 "${g}/drive_c/Program Files/Epic Games/CoolGame/game.exe"
iso_yml cool-game-111 "${g}" "${g}/drive_c/Program Files/Epic Games/CoolGame/game.exe" ""
check "isolate: Epic game" 0 'Cool Game' isolate -y egs
expect "isolate (egs): own prefix has base + its folder, not the other game" bash -c 'p="$1/Games/cool-game/drive_c/Program Files/Epic Games"; test -f "$p/CoolGame/game.exe" && test -f "$p/Launcher/launcher.exe" && test ! -e "$p/OtherGame"' _ "${HOME}"
expect "isolate (egs): purged from the shared prefix, other game and base kept" bash -c 'p="$1/Games/epic/drive_c/Program Files/Epic Games"; test ! -e "$p/CoolGame" && test -f "$p/OtherGame/other.exe" && test -f "$p/Launcher/launcher.exe"' _ "${HOME}"
expect "isolate (egs): old YAML removed" test ! -e "${iso_cfg}/cool-game-111.yml"
iso_check_common egs cool-game
# --- Battle.net
iso_cleanup
g="${HOME}/Games/bnet"
iso_mk "${g}/drive_c/Program Files (x86)/Battle.net/b.exe"; iso_mk "${g}/drive_c/Program Files (x86)/Diablo/d.exe"; iso_mk "${g}/drive_c/Program Files (x86)/Other/o.exe"
iso_row "Battle.net" bnet "${g}" bnet-cfg "${g}/x.exe"; iso_row "Diablo" diablo "${g}" diablo-111 "${g}/drive_c/Program Files (x86)/Diablo/d.exe"
iso_yml diablo-111 "${g}" "${g}/drive_c/Program Files (x86)/Diablo/d.exe" ""
check "isolate: Battle.net game" 0 'Diablo' isolate -y battlenet
expect "isolate (battlenet): own prefix has Battle.net + Diablo, not Other" bash -c 'p="$1/Games/diablo/drive_c/Program Files (x86)"; test -f "$p/Diablo/d.exe" && test -f "$p/Battle.net/b.exe" && test ! -e "$p/Other"' _ "${HOME}"
expect "isolate (battlenet): purged from the shared prefix" bash -c 'p="$1/Games/bnet/drive_c/Program Files (x86)"; test ! -e "$p/Diablo" && test -f "$p/Other/o.exe"' _ "${HOME}"
iso_check_common battlenet diablo
# --- EA App (the slug is renamed "<slug>-<name>")
iso_cleanup
g="${HOME}/Games/ea"
iso_mk "${g}/drive_c/Program Files/Electronic Arts/EA Desktop/e.exe"; iso_mk "${g}/drive_c/Program Files/EA Games/Mass Effect/m.exe"; iso_mk "${g}/drive_c/Program Files/EA Games/Other/o.exe"
iso_row "EA App" ea-store "${g}" ea-cfg "${g}/x.exe"; iso_row "Mass Effect" mass-effect "${g}" mass-111 "${g}/drive_c/Program Files/EA Games/Mass Effect/m.exe"
iso_yml mass-111 "${g}" "${g}/drive_c/Program Files/EA Games/Mass Effect/m.exe" ""
check "isolate: EA game" 0 'Mass Effect' isolate -y ea
expect "isolate (ea): own prefix named slug-name, with base + its folder" bash -c 'p="$1/Games/mass-effect-mass-effect/drive_c/Program Files"; test -f "$p/EA Games/Mass Effect/m.exe" && test -f "$p/Electronic Arts/EA Desktop/e.exe" && test ! -e "$p/EA Games/Other"' _ "${HOME}"
expect "isolate (ea): purged from the shared prefix" bash -c 'test ! -e "$1/Games/ea/drive_c/Program Files/EA Games/Mass Effect" && test -f "$1/Games/ea/drive_c/Program Files/EA Games/Other/o.exe"' _ "${HOME}"
iso_check_common ea mass-effect-mass-effect
# --- Ubisoft Connect (base = launcher folder minus games/ and data/, game folder + data/<id> from the launch args)
iso_cleanup
g="${HOME}/Games/ubi"; u="${g}/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
iso_mk "${u}/upc.exe"; iso_mk "${u}/games/Far Cry/fc.exe"; iso_mk "${u}/games/Other/o.exe"; iso_mk "${u}/data/123/save"; iso_mk "${u}/data/999/save"
iso_row "Ubisoft Connect" ubi-store "${g}" ubi-cfg "${g}/x.exe"; iso_row "Far Cry" far-cry "${g}" far-111 "${u}/upc.exe"
iso_yml far-111 "${g}" "${u}/upc.exe" "uplay://launch/123/0"
check "isolate: Ubisoft game" 0 'Far Cry' isolate -y ubisoft
expect "isolate (ubisoft): own prefix has launcher files, its game and its data/<id> only" bash -c 'p="$1/Games/far-cry/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"; test -f "$p/upc.exe" && test -f "$p/games/Far Cry/fc.exe" && test -f "$p/data/123/save" && test ! -e "$p/games/Other" && test ! -e "$p/data/999"' _ "${HOME}"
expect "isolate (ubisoft): purged from the shared prefix" bash -c 'p="$1/Games/ubi/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"; test ! -e "$p/games/Far Cry" && test ! -e "$p/data/123" && test -f "$p/games/Other/o.exe" && test -f "$p/data/999/save"' _ "${HOME}"
iso_check_common ubisoft far-cry
# --- Refusals leave everything untouched
iso_cleanup
g="${HOME}/Games/epic"
iso_mk "${g}/drive_c/Program Files/Epic Games/Launcher/launcher.exe"
iso_row "Epic Games Store" epic-store "${g}" epic-cfg "${g}/x.exe"; iso_row "Cool Game" cool-game "${g}" "../../etc/x" "${g}/x.exe"
check "isolate: configpath with a slash is refused" 1 '' isolate -y egs
expect "isolate: refusal leaves the Lutris row alone" bash -c '[ "$(sqlite3 "$1" "select directory from games where slug=\"cool-game\";")" = "$2/Games/epic" ]' _ "${iso_db}" "${HOME}"
check "isolate: unknown store argument" 1 'nvalid|not|unknown' isolate -y nosuchstore
iso_cleanup
# --- Prefix creation helpers (lib/zgu-prefix-common.sh), shared by exe-install and create-prefix
expect "prefix lib: slug, runner type, registry wait, YAML with and without exe" bash -c '
  source "$1/lib/zgu-prefix-common.sh"; d=$(mktemp -d); trap "rm -rf $d" EXIT
  [ "$(zgp_slugify "Été du Héros!")" = "ete-du-heros" ] || exit 1
  mkdir -p "$d/r/GE-X/bin" "$d/r/P"; : > "$d/r/GE-X/bin/wine"; chmod +x "$d/r/GE-X/bin/wine"; : > "$d/r/P/toolmanifest.vdf"
  [ "$(zgp_detect_runner_type "$d/r/GE-X")" = wine ] && [ "$(zgp_detect_runner_type "$d/r/P")" = proton ] || exit 1
  runner_dir="$d/r"; [ "$(zgp_list_usable_runners | sort | tr "\n" " ")" = "GE-X P " ] || exit 1
  touch "$d/user.reg" "$d/userdef.reg" "$d/system.reg"; zgp_wait_for_prefix "$d" || exit 1
  zgp_write_config_yml "$d/a.yml" "$d" slug Name GE-X || exit 1
  zgp_write_config_yml "$d/b.yml" "$d" slug Name GE-X "/x/setup.exe" || exit 1
  python3 -c "import sys,yaml; a=yaml.safe_load(open(sys.argv[1])); b=yaml.safe_load(open(sys.argv[2])); assert a[\"game\"][\"exe\"]==\"\" and b[\"game\"][\"exe\"]==\"/x/setup.exe\" and a[\"name\"]==\"Name\"" "$d/a.yml" "$d/b.yml"
' _ "${repo}"
expect "prefix lib: no prefix helper is defined anywhere else" bash -c '! grep -lE "^zgp_(detect_runner_type|list_usable_runners|find_umu_run|slugify|wait_for_prefix|write_config_yml)\(\) \{" "$1"/lib/*.sh | grep -v "zgu-prefix-common.sh"' _ "${repo}"
# create-prefix / exe-install end to end with a fake wineboot (creates the registry files)
wbdir="${HOME}/.local/share/lutris/runners/wine/GE-Test/bin"
printf '#!/bin/sh\nmkdir -p "$WINEPREFIX"; : > "$WINEPREFIX/user.reg"; : > "$WINEPREFIX/userdef.reg"; : > "$WINEPREFIX/system.reg"\nexit 0\n' > "${wbdir}/wineboot"; chmod +x "${wbdir}/wineboot"
check "create-prefix: prefix created" 0 'blank-demo' create-prefix -y -r GE-Test "Blank Demo"
expect "create-prefix: folder and Lutris YAML exist" bash -c 'test -f "$1/Games/blank-demo/user.reg" && grep -q "Blank Demo" "$1"/.config/lutris/games/blank-demo-*.yml' _ "${HOME}"
printf 'x' > "${HOME}/setup.exe"
check "exe-install: prefix created and installer run" 0 'setup' exe-install -y "${HOME}/setup.exe" -r GE-Test -f none
expect "exe-install: folder and Lutris YAML exist" bash -c 'test -f "$1/Games/setup/user.reg" && ls "$1"/.config/lutris/games/setup-*.yml >/dev/null' _ "${HOME}"
rm -rf "${HOME}/Games/blank-demo" "${HOME}/Games/setup" "${HOME}/.config/lutris/games/blank-demo-"* "${HOME}/.config/lutris/games/setup-"* "${HOME}/setup.exe" "${wbdir}/wineboot"
sqlite3 "${HOME}/.local/share/lutris/pga.db" "delete from games where slug in ('blank-demo','setup');"
# --- No function is copy-pasted between scripts: a name defined in two files of lib/ is only allowed
# for the per-script cancel handler and the tiny output wrappers (each script has its own).
expect "lib: no shell function defined in two different files (except the per-script handlers)" bash -c '
  dups=$(grep -hoE "^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{" "$1"/lib/*.sh | sort | uniq -d | grep -vE "^(ludis_cancel_cleanup|say|say_err)\(\)")
  [ -z "$dups" ] || { echo "$dups" >&2; exit 1; }' _ "${repo}"
# --- Lutris paths: one function (zgu_set_lutris_paths) gives every path of the Flatpak or native install
expect "lutris paths: flatpak" bash -c 'source "$1/lib/zgu-lutris-utils.sh"; HOME=/h zgu_set_lutris_paths flatpak && [ "$lutris_db" = /h/.var/app/net.lutris.Lutris/data/lutris/pga.db ] && [ "$lutris_config_dir" = /h/.var/app/net.lutris.Lutris/data/lutris/games ] && [ "$runner_dir" = /h/.var/app/net.lutris.Lutris/data/lutris/runners/wine ] && [ "$lutris_umu" = /h/.var/app/net.lutris.Lutris/data/lutris/runtime/umu/umu-run ] && [ "$version" = flatpak ] && [ "$games_dir" = /h/Games ]' _ "${repo}"
expect "lutris paths: native" bash -c 'source "$1/lib/zgu-lutris-utils.sh"; HOME=/h zgu_set_lutris_paths native && [ "$lutris_db" = /h/.local/share/lutris/pga.db ] && [ "$lutris_config_dir" = /h/.config/lutris/games ] && [ "$lutris_system_file" = /h/.config/lutris/system.yml ] && [ "$runner_dir" = /h/.local/share/lutris/runners/wine ] && [ "$version" = package ]' _ "${repo}"
expect "lutris paths: game_path of system.yml wins over ~/Games" bash -c 'mkdir -p "$2/.config/lutris"; printf "system:\n  game_path: /data/jeux\n" | sed "s/^system:$//" > "$2/.config/lutris/system.yml"; sed -i "s/^  game_path/game_path/" "$2/.config/lutris/system.yml"; source "$1/lib/zgu-lutris-utils.sh"; HOME="$2" zgu_set_lutris_paths native && [ "$games_dir" = /data/jeux ]' _ "${repo}" "${work}/lutrispaths"
expect "lutris paths: unknown version is refused" bash -c 'source "$1/lib/zgu-lutris-utils.sh"; ! zgu_set_lutris_paths bogus' _ "${repo}"

# --- sync-media (lutris.net API) with a fake curl: download, 404 = nothing to do, unreachable
smshim="${work}/smshim"; mkdir -p "${smshim}"
cat > "${smshim}/curl" <<'CURLEOF'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
case "$*" in
  *api/games/mario*) printf '{"banner_url":"http://x/b.jpg","icon":"http://x/i.png","coverart":"http://x/c.jpg"}' > "$out"; printf 200;;
  *api/games/zelda*) printf '404';;
  *http://x/*) printf 'IMG' > "$out";;
  *) exit 6;;
esac
CURLEOF
chmod +x "${smshim}/curl"
PATH="${smshim}:${PATH}" check "sync-media: downloads banner, cover and icon" 0 'mario' sync-media mario
expect "sync-media: 3 files written" bash -c 'for p in "$HOME"/.local/share/lutris/banners/mario.jpg "$HOME"/.local/share/lutris/coverart/mario.jpg "$HOME"/.local/share/icons/hicolor/128x128/apps/lutris_mario.png; do [ -s "$p" ] || exit 1; done'
PATH="${smshim}:${PATH}" check "sync-media: game not on lutris.net is not an error" 0 '.' sync-media zelda

# --- icon / splash / logo end to end with a fake curl (SteamGridDB search, download, convert)
e2e="${work}/e2eshim"; mkdir -p "${e2e}"
convert -size 4x4 xc:red "${work}/test.png" 2>/dev/null || magick -size 4x4 xc:red "${work}/test.png"
cat > "${e2e}/curl" <<CURLEOF
#!/bin/bash
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
case "\$*" in
  *autocomplete/a*) printf 200;;
  *autocomplete/Link*) echo '{"success":true,"data":[{"id":7,"name":"Link"}]}';;
  *heroes/game/7*) echo '{"success":true,"data":[{"url":"http://x/h.png"}]}';;
  *logos/game/7*) echo '{"success":true,"data":[{"url":"http://x/l.png"}]}';;
  *icons/game/7*) echo '{"success":true,"data":[{"url":"http://x/i.png"}]}';;
  *http://x/*) cp "${work}/test.png" "\$out";;
  *) echo '{}';;
esac
CURLEOF
chmod +x "${e2e}/curl"
sqlite3 "${HOME}/.local/share/lutris/pga.db" "insert into games(name,slug,runner,directory,configpath) values('Link','link','wine','${HOME}/Games/link','link-1');"
mkdir -p "${HOME}/Games/link"; printf 'game:\n  exe: /z.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/link-1.yml"
mkdir -p "${HOME}/.config/ludis"; echo testkey > "${HOME}/.config/ludis/steamgriddb.key"
for kind in icon splash logo; do
  PATH="${e2e}:${PATH}" check "${kind}: found on SteamGridDB, downloaded and converted" 0 'Link' "${kind}" link
done
expect "icon/splash/logo: the 3 images are in the ludis folder" bash -c 'find "$1/ludis" -name "icon.png" | grep -q . && find "$1/ludis" -name "splash.png" | grep -q . && find "$1/ludis" -name "logo.png" | grep -q .' _ "${HOME}/Games/link"

check "icon: unknown slug is refused" 1 'nosuch' icon nosuch
check "splash: --url needs a single game" 1 '' splash --url http://x/a.png mario zelda
check "logo: unknown slug is refused" 1 'nosuch' logo nosuch

# --- SteamGridDB functions: one copy (lib/zgu-sgdb.sh), working with a fake curl
sgshim="${work}/sgshim"; mkdir -p "${sgshim}"
cat > "${sgshim}/curl" <<'CURLEOF'
#!/bin/bash
case "$*" in
  *autocomplete/a*) printf '200';;
  *autocomplete/zelda*) echo '{"success":true,"data":[{"id":42,"name":"Zelda"}]}';;
  *icons/game/42*) echo '{"success":true,"data":[{"url":"http://x/i.png","thumb":"http://x/t.png"}]}';;
  *) echo '{}';;
esac
CURLEOF
chmod +x "${sgshim}/curl"
expect "sgdb lib: search, icons and key saving work (fake curl)" bash -c 'export PATH="$2:$PATH" XDG_CONFIG_HOME="$3"; t(){ :; }; source "$1/lib/zgu-sgdb.sh"; sgdb_key=k; [ "$(zgp_sgdb_search zelda)" = "$(printf "42\tZelda")" ] && zgp_sgdb_icons 42 | grep -q "http://x/i.png" && zgp_sgdb_save_key abc && [ "$(zgp_sgdb_read_key)" = abc ]' _ "${repo}" "${sgshim}" "${work}/sgcfg"
expect "sgdb lib: no sgdb function is defined anywhere else" bash -c '! grep -lE "^zgp_(sgdb_[a-z_]+|steam_find_appid)\(\) \{" "$1"/lib/*.sh | grep -v "zgu-sgdb.sh"' _ "${repo}"
check "lsfg status" 0 '"installed"' lsfg status
check "self-update: invalid argument" 1 'Invalid argument' self-update bogus
check "doctor: sees Lutris, the runner and the tools" 0 'Lutris \(native\) found.*GE-Test|1 Wine/Proton runner' doctor
check "doctor: ends with a summary" 0 'Everything needed is present|warning' doctor
expect "doctor: changes nothing (no new file in the fake home)" bash -c 'a=$(find "$1" -type f | wc -l); bash "$2" doctor >/dev/null 2>&1; [ "$a" = "$(find "$1" -type f | wc -l)" ]' _ "${HOME}" "${R}"
expect "doctor: fails (exit 1) when a required tool is missing" bash -c 'PATH="$3" "$BASH" "$2" doctor >/dev/null 2>&1; [ $? -eq 1 ]' _ "${HOME}" "${R}" "/nonexistent"
check "check: structured report" 0 '\[REPORT\] ok\|' check
check "info" 0 'Slug +: mario' info mario
check "info: unknown slug" 1 'no installed game' info nosuch
check "info: no slug" 1 'provide a slug' info

# --- Missing target: clear error and exit code 1, never a false success
for cmd in install pack pack-runner uninstall uninstall-runner install-runner shortcut; do
  check "${cmd}: missing target" 1 'nothing to do' "${cmd}"
done
check "uninstall -y without target" 1 'nothing to do' uninstall -y
check "install: file not found" 1 'not found' install -y /nonexistent.zgp
check "uninstall: unknown slug" 1 'not found' uninstall -y nosuch
check "uninstall-runner: unknown" 1 'could not be found' uninstall-runner -y nosuch

# --- Launcher and tools (Lutris YAML editing)
check "launcher on" 0 'enabled' launcher mario on
expect "launcher on: file created" test -f "${HOME}/Games/mario/ludis/launcher.yml"
check "launcher off" 0 'disabled' launcher mario off
# Exe inside drive_c: the Windows paths are computed as text, Wine (winepath) is NOT started.
mkdir -p "${HOME}/Games/mario/drive_c/Games/Mario/sub"
printf 'game:\n  exe: %s/Games/mario/drive_c/Games/Mario/sub/m.exe\n  prefix: %s/Games/mario\nwine:\n  version: GE-Test\n' "${HOME}" "${HOME}" > "${HOME}/.config/lutris/games/mario-1.yml"
rm -f "${HOME}/winepath-called"
for dir in "${HOME}/bin" "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin"; do
  mv "${dir}/winepath" "${dir}/winepath.real"
  printf '#!/bin/sh\ntouch "%s/winepath-called"\nexit 1\n' "${HOME}" > "${dir}/winepath"; chmod +x "${dir}/winepath"
done
rm -f "${HOME}/Games/mario/ludis/launcher.yml"
check "launcher on: exe in drive_c" 0 'enabled' launcher mario on
expect "launcher on: winepath not called" test ! -e "${HOME}/winepath-called"
expect "launcher on: Windows path computed" grep -qF 'C:\Games\Mario\sub\m.exe' "${HOME}/Games/mario/ludis/launcher.yml"
expect "launcher on: bat has the path" grep -qF 'start "" "C:\Games\Mario\sub\m.exe"' "${HOME}/Games/mario/drive_c/Games/Mario/lpm-launch.bat"
for dir in "${HOME}/bin" "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin"; do
  mv -f "${dir}/winepath.real" "${dir}/winepath"
done
check "launcher off (2)" 0 'disabled' launcher mario off
# Existing lpm-launcher.yml WITHOUT bat_path/original_exe (hand-written or restored from a .zgp):
# "on" keeps the entries and comments, and adds the two keys (otherwise the runtime writes a
# lpm-launch.bat that Lutris never runs and the picker choice is ignored).
mkdir -p "${HOME}/Games/mario/ludis"
printf 'title: T\nprompt: P\nentries:\n- label: One\n  workdir: C:\\Games\\Mario\n  exe: C:\\Games\\Mario\\one.exe\n- label: Two\n  workdir: C:\\Games\\Mario\n  exe: C:\\Games\\Mario\\two.exe\n# my comment\n' > "${HOME}/Games/mario/ludis/launcher.yml"
check "launcher on: existing yml without bat_path" 0 'enabled' launcher mario on
expect "existing yml: bat_path added" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/ludis/launcher.yml')); sys.exit(0 if d.get('bat_path')=='${HOME}/Games/mario/drive_c/Games/Mario/lpm-launch.bat' else 1)"
expect "existing yml: original_exe added" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/ludis/launcher.yml')); sys.exit(0 if str(d.get('original_exe','')).endswith('m.exe') else 1)"
expect "existing yml: entries kept" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/ludis/launcher.yml')); sys.exit(0 if [e['label'] for e in d['entries']]==['One','Two'] else 1)"
expect "existing yml: comment kept" grep -q '# my comment' "${HOME}/Games/mario/ludis/launcher.yml"
check "launcher on again: refused" 1 'already enabled' launcher mario on
expect "existing yml: original_exe still the real exe" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/ludis/launcher.yml')); sys.exit(0 if str(d.get('original_exe','')).endswith('m.exe') else 1)"
mkdir -p "${HOME}/Games/mario/splash"
echo img > "${HOME}/Games/mario/splash/splash.png"
mkdir -p "${HOME}/Games/mario/scripts"
echo trace > "${HOME}/Games/mario/scripts/lpm-winetrace.sh"
echo data > "${HOME}/Games/mario/drive_c/Games/Mario/game-data.txt"
expect "launcher on: bat and yml exist, NO relay" bash -c '[[ ! -e "$1/scripts/lpm-launcher.sh" && -f "$1/drive_c/Games/Mario/lpm-launch.bat" && -f "$1/ludis/launcher.yml" ]]' _ "${HOME}/Games/mario"
expect "launcher on: Lutris config has game.exe on the bat and NO prelaunch command" bash -c 'grep -q "lpm-launch.bat" "$1" && ! grep -q "prelaunch" "$1"' _ "${HOME}/.config/lutris/games/mario-1.yml"
check "launcher off (3)" 0 'disabled' launcher mario off
expect "launcher off: yml and bat deleted" bash -c '[[ ! -e "$1/scripts/lpm-launcher.sh" && ! -e "$1/drive_c/Games/Mario/lpm-launch.bat" && ! -e "$1/ludis/launcher.yml" && ! -e "$1/lpm-launch.bat" ]]' _ "${HOME}/Games/mario"
expect "launcher off: splash, loading-screen script and game files kept" bash -c '[[ -f "$1/splash/splash.png" && -f "$1/scripts/lpm-winetrace.sh" && -f "$1/drive_c/Games/Mario/game-data.txt" ]]' _ "${HOME}/Games/mario"
expect "launcher off: Lutris exe restored" grep -q 'm.exe' "${HOME}/.config/lutris/games/mario-1.yml"
check "launcher on after off: fresh yml" 0 'enabled' launcher mario on
expect "launcher on after off: only the default entry (old entries gone)" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/ludis/launcher.yml')); sys.exit(0 if len(d['entries'])==1 else 1)"
check "launcher off (4)" 0 'disabled' launcher mario off
# Runtime with a YAML WITHOUT bat_path (picker choice already made): the choice must reach the
# lpm-launch.bat of drive_c that Lutris runs, not only a file at the root of the game folder.
rt_game="${HOME}/Games/rtgame"
mkdir -p "${rt_game}/drive_c/Games/Rt"
printf '@echo off\r\nstart "" "C:\\Games\\Rt\\first.exe"\r\n' > "${rt_game}/drive_c/Games/Rt/lpm-launch.bat"
printf 'title: T\nprompt: P\nentries:\n- label: One\n  workdir: C:\\Games\\Rt\n  exe: C:\\Games\\Rt\\first.exe\n- label: Two\n  workdir: C:\\Games\\Rt\n  exe: C:\\Games\\Rt\\second.exe\n' > "${rt_game}/lpm-launcher.yml"
mkdir -p "${rt_game}/ludis"; printf 'Two' > "${rt_game}/ludis/.launcher-choice"
expect "runtime without bat_path: runs" bash "${repo}/lib/zgl-launcher-runtime.sh" "${rt_game}"
expect "runtime without bat_path: drive_c bat gets the choice" grep -q 'second.exe' "${rt_game}/drive_c/Games/Rt/lpm-launch.bat"
# Loading-screen subtitle: the title (line 3) never changes; line 4 = chosen label, empty if the
# label is exactly the game name.
rt_key=$(printf '%s' "${rt_game}" | sha256sum | cut -c1-24)
rt_ctrl="${TMPDIR:-/tmp}/lpm-launcher-ctrl-${rt_key}"
printf 'NONE\nIND_SHOW\nRt Game\n\n' > "${rt_ctrl}"
mkdir -p "${rt_game}/ludis"; printf 'Two' > "${rt_game}/ludis/.launcher-choice"
bash "${repo}/lib/zgl-launcher-runtime.sh" "${rt_game}"
expect "subtitle: title kept, label on line 4" bash -c '[[ "$(sed -n 3p "$1")" = "Rt Game" && "$(sed -n 4p "$1")" = "Two" ]]' _ "${rt_ctrl}"
printf 'NONE\nIND_SHOW\nOne\n\n' > "${rt_ctrl}"
mkdir -p "${rt_game}/ludis"; printf 'One' > "${rt_game}/ludis/.launcher-choice"
bash "${repo}/lib/zgl-launcher-runtime.sh" "${rt_game}"
expect "subtitle: label equal to the game name -> no subtitle" bash -c '[[ "$(sed -n 3p "$1")" = "One" && -z "$(sed -n 4p "$1")" ]]' _ "${rt_ctrl}"
printf 'NONE\nIND_SHOW\nOne Two\n\n' > "${rt_ctrl}"
mkdir -p "${rt_game}/ludis"; printf 'One' > "${rt_game}/ludis/.launcher-choice"
bash "${repo}/lib/zgl-launcher-runtime.sh" "${rt_game}"
expect "subtitle: similar but different name -> subtitle kept" bash -c '[[ "$(sed -n 4p "$1")" = "One" ]]' _ "${rt_ctrl}"
rm -f "${rt_ctrl}"
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/mario-1.yml"
rm -f "${HOME}/Games/mario/ludis/launcher.yml"
check "tools env set" 0 '' tools mario env set FOO bar
check "tools env list" 0 'FOO' tools mario env list
check "tools env set empty" 0 '' tools mario env set FOO ""
# Lutris-wide defaults (runners/wine.yml)
check "lutris-defaults: status" 0 'runner=.*' lutris-defaults status
check "lutris-defaults: winetricks defaults to the runner's" 0 '^runner$' lutris-defaults winetricks
check "lutris-defaults: winetricks system" 0 'winetricks of Lutris: system' lutris-defaults winetricks system
check "lutris-defaults: winetricks read back" 0 '^system$' lutris-defaults winetricks
check "lutris-defaults: winetricks rejects junk" 1 'Invalid value' lutris-defaults winetricks maybe
check "lutris-defaults: runner must be installed" 1 'not installed' lutris-defaults runner Nope-1.0
check "lutris-defaults: runner set" 0 'set to GE-Test' lutris-defaults runner GE-Test
check "lutris-defaults: runner read back" 0 '^GE-Test$' lutris-defaults runner
expect "lutris-defaults: runners/wine.yml is valid and holds both" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/.config/lutris/runners/wine.yml')); sys.exit(0 if d['wine']['version']=='GE-Test' and d['wine']['system_winetricks'] is True else 1)"
check "lutris-defaults: apply both at once" 0 'set to GE-Test' lutris-defaults apply winetricks=runner runner=GE-Test
check "lutris-defaults: apply wrote winetricks too" 0 '^runner$' lutris-defaults winetricks
check "lutris-defaults: unknown action" 1 'Unknown action' lutris-defaults bogus

# Launch options of a game (GameMode, Gamescope, resolution, Esync/Fsync, DXVK, system winetricks)
check "options: nothing set = default" 0 '^default$' tools mario gamemode status
check "options: gamemode off is an explicit false" 0 'gamemode set to off' tools mario gamemode off
expect "options: system.gamemode is false in the YAML" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml')); sys.exit(0 if d['system']['gamemode'] is False and d['game']['exe']=='/x.exe' else 1)"
check "options: gamemode status off" 0 '^off$' tools mario gamemode status
check "options: gamemode default removes the key" 0 'back to the Lutris default' tools mario gamemode default
check "options: esync off (wine section)" 0 'esync set to off' tools mario esync off
expect "options: wine.esync is false and the runner is kept" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml')); sys.exit(0 if d['wine']['esync'] is False and d['wine']['version']=='GE-Test' else 1)"
check "options: dxvk on" 0 'dxvk set to on' tools mario dxvk on
check "options: system winetricks on" 0 'system-winetricks set to on' tools mario system-winetricks on
check "options: gamescope output resolution" 0 'gamescope-output set to 1920x1080' tools mario gamescope-output 1920x1080
check "options: gamescope output rejects junk" 1 'Invalid value' tools mario gamescope-output 19x
check "options: gamescope fps" 0 'gamescope-fps set to 60' tools mario gamescope-fps 60
check "options: gamescope fps rejects 0" 1 'Invalid value' tools mario gamescope-fps 0
check "options: gamescope status" 0 '^default$' tools mario gamescope status
check "options: gamescope on warns when missing" 0 'no effect' tools mario gamescope on
check "options: resolution off is read back as off" 0 'resolution set to off' tools mario resolution off
check "options: resolution status off" 0 '^off$' tools mario resolution status
check "options: unknown action is refused" 1 'Invalid value' tools mario esync maybe
check "options: status lists every option" 0 'gamescope-fps=60' tools mario options status
check "options: status also shows esync" 0 'esync=off' tools mario options status
check "options: apply several at once" 0 'fsync set to off' tools mario options apply fsync=off esync=default gamescope-fps=default
check "options: apply leaves an unchanged value alone" 0 '^$' tools mario options apply fsync=off
check "options: apply rejects an unknown option" 1 'Invalid value' tools mario options apply bogus=on
expect "options: the YAML is still valid and complete" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml')); sys.exit(0 if d['wine']['fsync'] is False and 'esync' not in d['wine'] and d['wine']['dxvk'] is True and d['system']['gamescope_output_res']=='1920x1080' and 'gamescope_fps_limiter' not in d['system'] else 1)"

# MangoHud: Lutris option system.mangohud (on = true, off = key removed, status prints on/off)
check "tools mangohud status (default off)" 0 '^off$' tools mario mangohud status
check "tools mangohud on" 0 'MangoHud enabled' tools mario mangohud on
check "tools mangohud status (on)" 0 '^on$' tools mario mangohud
expect "tools mangohud: Lutris YAML has system.mangohud true and stays valid" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml')); sys.exit(0 if d['system']['mangohud'] is True and d['game']['exe']=='/x.exe' else 1)"
check "tools mangohud warns when MangoHud is not installed" 0 'has no effect|no effect' tools mario mangohud on
check "tools mangohud off" 0 'MangoHud disabled' tools mario mangohud off
check "tools mangohud status (off again)" 0 '^off$' tools mario mangohud status
expect "tools mangohud off: key removed" bash -c '! grep -q mangohud "$1"' _ "${HOME}/.config/lutris/games/mario-1.yml"
check "tools mangohud off when already off" 0 'MangoHud disabled' tools mario mangohud off
check "tools mangohud: invalid action" 1 'unknown MangoHud action' tools mario mangohud maybe

# FPS overlay of the in-game menu (ludis's own files, not the Lutris YAML)
check "tools overlay status (default)" 0 '^game=follow global=off$' tools mario overlay status
check "tools overlay off" 0 'off' tools mario overlay off
check "tools overlay status (game off)" 0 '^game=off global=off$' tools mario overlay
check "tools overlay global-on" 0 'on' tools mario overlay global-on
check "tools overlay status (global on)" 0 '^game=off global=on$' tools mario overlay status
check "tools overlay follow" 0 'follow' tools mario overlay follow
check "tools overlay global-off" 0 'off' tools mario overlay global-off
check "tools overlay status (back to default)" 0 '^game=follow global=off$' tools mario overlay status
check "tools overlay: invalid action" 1 'unknown overlay action' tools mario overlay maybe

# Gamepad: Lutris option system.antimicro_config -> profile in <prefix>/ludis/gamepad/
gp_yml="${HOME}/.config/lutris/games/mario-1.yml"
gp_prof="${HOME}/Games/mario/ludis/gamepad/lpm-gamepad.gamecontroller.amgp"
check "tools gamepad status (default off)" 0 '^off$' tools mario gamepad
check "tools gamepad on" 0 'Gamepad profile enabled' tools mario gamepad on
expect "tools gamepad on: profile created" test -f "${gp_prof}"
expect "tools gamepad on: option points to it, YAML valid" python3 -c "import sys,yaml; d=yaml.safe_load(open('${gp_yml}')); sys.exit(0 if d['system']['antimicro_config']=='${gp_prof}' and d['game']['exe']=='/x.exe' else 1)"
check "tools gamepad status (on)" 0 '^on$' tools mario gamepad status
printf 'MY SETTINGS' > "${gp_prof}"
check "tools gamepad on again" 0 'enabled' tools mario gamepad on
expect "tools gamepad: existing profile never overwritten" grep -q 'MY SETTINGS' "${gp_prof}"
check "tools gamepad off" 0 'disabled' tools mario gamepad off
expect "tools gamepad off: option removed, profile kept" bash -c '! grep -q antimicro_config "$1" && grep -q "MY SETTINGS" "$2"' _ "${gp_yml}" "${gp_prof}"
check "tools gamepad edit without AntiMicroX" 1 'does not seem to be installed' tools mario gamepad edit
printf 'game:\n  exe: /x.exe\nsystem:\n  antimicro_config: /home/me/mine.amgp\nwine:\n  version: GE-Test\n' > "${gp_yml}"
check "tools gamepad status (user's own profile)" 0 '^other$' tools mario gamepad status
check "tools gamepad on refuses to replace the user's profile" 1 'another AntiMicroX profile' tools mario gamepad on
check "tools gamepad off leaves the user's profile" 1 'another AntiMicroX profile' tools mario gamepad off
expect "tools gamepad: user's profile still referenced" grep -q 'mine.amgp' "${gp_yml}"
check "tools gamepad: invalid action" 1 'unknown gamepad action' tools mario gamepad maybe
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${gp_yml}"
rm -rf "${HOME}/Games/mario/ludis/gamepad"
# ready-made gamepad profiles
check "gamepad templates: the list has WASD and ZQSD versions" 0 'LPM-FPS-WASD' tools mario gamepad templates
check "gamepad templates: AZERTY version listed" 0 'LPM-FPS-ZQSD' tools mario gamepad templates
expect "gamepad templates: every shipped profile is valid XML" python3 -c "
import glob, sys, xml.dom.minidom as m
files = glob.glob('${repo}/lib/data/gamepad-LPM-*.amgp')
[m.parse(f) for f in files]
sys.exit(0 if len(files) >= 12 else 1)"
expect "gamepad templates: ZQSD uses Z and Q, WASD uses W and A" bash -c 'grep -q "<code>0x5a</code>" "$1/lib/data/gamepad-LPM-FPS-ZQSD.amgp" && grep -q "<code>0x51</code>" "$1/lib/data/gamepad-LPM-FPS-ZQSD.amgp" && grep -q "<code>0x57</code>" "$1/lib/data/gamepad-LPM-FPS-WASD.amgp" && ! grep -q "<code>0x5a</code>" "$1/lib/data/gamepad-LPM-FPS-WASD.amgp"' _ "${repo}"
check "gamepad template: unknown name refused" 1 'unknown gamepad template' tools mario gamepad template LPM-Nope
check "gamepad template: path tricks refused" 1 'unknown gamepad template' tools mario gamepad template ../../etc/passwd
check "gamepad template: apply" 0 'template LPM-FPS-ZQSD applied' tools mario gamepad template LPM-FPS-ZQSD
expect "gamepad template: copied into the prefix and enabled" bash -c 'cmp -s "$1/lib/data/gamepad-LPM-FPS-ZQSD.amgp" "$2" && grep -q "antimicro_config" "$3"' _ "${repo}" "${gp_prof}" "${gp_yml}"
echo '<!-- MY EDIT -->' >> "${gp_prof}"
check "gamepad template: another template keeps the edited profile as a backup" 0 'previous profile was kept' tools mario gamepad template LPM-Course-WASD
expect "gamepad template: the backup holds the edit, the profile is the new template" bash -c 'grep -q "MY EDIT" "$1".*.bak && cmp -s "$2/lib/data/gamepad-LPM-Course-WASD.amgp" "$1"' _ "${gp_prof}" "${repo}"
expect "gamepad template: the shipped model itself is untouched" bash -c '! grep -q "MY EDIT" "$1/lib/data/gamepad-LPM-FPS-ZQSD.amgp"' _ "${repo}"
printf 'game:\n  exe: /x.exe\nsystem:\n  antimicro_config: /home/me/mine.amgp\nwine:\n  version: GE-Test\n' > "${gp_yml}"
check "gamepad template: refuses when the game uses the user's own profile" 1 'another AntiMicroX profile' tools mario gamepad template LPM-FPS-WASD
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${gp_yml}"
rm -rf "${HOME}/Games/mario/ludis/gamepad"
expect "YAML still valid" python3 -c "import sys,yaml; yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml'))"

# --- Legacy launcher (format of ludis <= 0.9.5: relay + Lutris prelaunch command). Packages made then
# can be installed or launched years later: the orchestrator must convert them. DO NOT delete this
# test together with lib/zgl-launcher-legacy.sh.
lg="${HOME}/Games/mario"
mkdir -p "${lg}/scripts" "${lg}/drive_c/Games/Mario"
printf '#!/bin/sh\n' > "${lg}/scripts/lpm-launcher.sh"
echo trace > "${lg}/scripts/lpm-winetrace.sh"
lg_bat="${lg}/drive_c/Games/Mario/lpm-launch.bat"
printf '@echo off\r\nstart "" "C:\\Games\\Mario\\old.exe"\r\n' > "${lg_bat}"
printf 'game:\n  exe: %s\n  prefix: %s\nsystem:\n  prelaunch_command: %s/scripts/lpm-launcher.sh\n  prelaunch_wait: true\n# prelaunch_command: %s/scripts/lpm-launcher.sh  # lpm:hook-disabled\nwine:\n  version: GE-Test\n' "${lg_bat}" "${lg}" "${lg}" "${lg}" > "${HOME}/.config/lutris/games/mario-1.yml"
printf 'title: T\nprompt: P\nentries:\n- label: Only\n  workdir: C:\\Games\\Mario\n  exe: C:\\Games\\Mario\\new.exe\n' > "${lg}/lpm-launcher.yml"
touch "${lg}/.lpm-no-loadingscreen"
expect "legacy launcher: shortcut launch (orchestrator) converts the game" env DISPLAY=:99 bash "${repo}/lib/zgl-launcher-orchestrator.sh" 1 package
expect "legacy launcher: prelaunch command and its commented copy removed" bash -c '! grep -q "lpm-launcher.sh" "$1" && ! grep -q "^ *prelaunch_wait" "$1"' _ "${HOME}/.config/lutris/games/mario-1.yml"
expect "legacy launcher: relay deleted, loading-screen script kept" bash -c '[[ ! -e "$1/scripts/lpm-launcher.sh" && -f "$1/scripts/lpm-winetrace.sh" ]]' _ "${lg}"
expect "legacy launcher: bat written by the orchestrator with the entry" grep -q 'new.exe' "${lg_bat}"
expect "legacy launcher: bat_path aligned on game.exe" python3 -c "import sys,yaml; d=yaml.safe_load(open('${lg}/lpm-launcher.yml')); sys.exit(0 if d.get('bat_path')=='${lg_bat}' else 1)"
expect "legacy launcher: Lutris YAML still valid" python3 -c "import sys,yaml; yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml'))"
# A prelaunch command of the user is never touched
printf 'game:\n  exe: %s\nsystem:\n  prelaunch_command: /home/me/mine.sh\n  prelaunch_wait: true\n' "${lg_bat}" > "${HOME}/.config/lutris/games/mario-1.yml"
expect "legacy launcher: a user's own prelaunch command is left alone" bash -c 'bash "$1" "$2" "$3"; grep -q "mine.sh" "$2" && grep -q prelaunch_wait "$2"' _ "${repo}/lib/zgl-launcher-legacy.sh" "${HOME}/.config/lutris/games/mario-1.yml" "${lg}"
rm -f "${lg}/.lpm-no-loadingscreen" "${lg}/lpm-launcher.yml" "${lg_bat}" "${lg}/scripts/lpm-winetrace.sh"
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/mario-1.yml"

# --- The orchestrator reads the Lutris YAML AS YAML. Lutris/PyYAML fold a long "exe:" value on two lines
# (a game folder with spaces is enough); a line-based match then missed the launcher and the game
# started with the lpm-launch.bat of the PREVIOUS launch: no picker, the last entry.
fold_dir="${lg}/drive_c/Games/A folder name with spaces long enough to fold"
mkdir -p "${fold_dir}"
fold_bat="${fold_dir}/lpm-launch.bat"
printf '@echo off\r\nstart "" "C:\\Games\\old.exe"\r\n' > "${fold_bat}"
FOLD_BAT="${fold_bat}" FOLD_PREFIX="${lg}" python3 -c "
import os, yaml
d = {'game': {'exe': os.environ['FOLD_BAT'], 'prefix': os.environ['FOLD_PREFIX']}, 'wine': {'version': 'GE-Test'}}
open('${HOME}/.config/lutris/games/mario-1.yml', 'w').write(yaml.dump(d, sort_keys=False))
"
expect "folded exe: the fixture really is folded on two lines" bash -c '! grep -Eq "^[[:space:]]*exe:.*lpm-launch\.bat" "$1" && grep -q "lpm-launch.bat" "$1"' _ "${HOME}/.config/lutris/games/mario-1.yml"
printf 'title: T\nprompt: P\nentries:\n- label: Only\n  workdir: C:\\Games\\Mario\n  exe: C:\\Games\\Mario\\folded-new.exe\n' > "${lg}/lpm-launcher.yml"
touch "${lg}/.lpm-no-loadingscreen"
expect "folded exe: shortcut launch (orchestrator) still sees the launcher" env DISPLAY=:99 bash "${repo}/lib/zgl-launcher-orchestrator.sh" 1 package
expect "folded exe: lpm-launch.bat rewritten with the chosen entry" grep -q 'folded-new.exe' "${fold_bat}"
rm -rf "${fold_dir}" "${lg}/.lpm-no-loadingscreen" "${lg}/lpm-launcher.yml"
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/mario-1.yml"

# --- "off" without original_exe (hand-written file): fallback on the first entry
mkdir -p "${lg}/drive_c/Games/Mario"
printf 'title: T\nprompt: P\nentries:\n- label: Only\n  workdir: C:\\Games\\Mario\n  exe: C:\\Games\\Mario\\first.exe\n' > "${lg}/lpm-launcher.yml"
printf 'game:\n  exe: %s/drive_c/Games/Mario/lpm-launch.bat\n  prefix: %s\nwine:\n  version: GE-Test\n' "${lg}" "${lg}" > "${HOME}/.config/lutris/games/mario-1.yml"
check "launcher off without original_exe: fallback on the first entry" 0 'disabled' launcher mario off
expect "launcher off fallback: game.exe restored to the first entry" grep -q "drive_c/Games/Mario/first.exe" "${HOME}/.config/lutris/games/mario-1.yml"
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/mario-1.yml"

# --- Change a game's runner ("runner" tool): tested on zelda
mkdir -p "${HOME}/.local/share/lutris/runners/wine/GE-Other/files/bin"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/.local/share/lutris/runners/wine/GE-Other/files/bin/wine"
chmod +x "${HOME}/.local/share/lutris/runners/wine/GE-Other/files/bin/wine"
printf 'game:\n  exe: /y.exe\n# lpm:hook-disabled keep-me\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/zelda-1.yml"
check "runner: change" 0 "changed to 'GE-Other'" tools zelda runner GE-Other
expect "runner: info shows the new runner" bash -c 'bash "$1" info zelda </dev/null | grep -q "GE-Other"' _ "${R}"
expect "runner: YAML comment preserved" grep -q 'lpm:hook-disabled' "${HOME}/.config/lutris/games/zelda-1.yml"
check "runner: not installed" 1 'is not installed' tools zelda runner NoSuchRunner
check "runner: no name" 1 'name of an installed runner' tools zelda runner
check "runner: name with /" 1 'name of an installed runner' tools zelda runner ../x
check "runner: unknown slug" 1 'no installed game' tools nosuch runner GE-Other
mkdir -p "${HOME}/.local/share/lutris/runners/wine/GE-Temp/bin"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/.local/share/lutris/runners/wine/GE-Temp/bin/wine"; chmod +x "${HOME}/.local/share/lutris/runners/wine/GE-Temp/bin/wine"
check "runner: to a temporary runner" 0 "changed to 'GE-Temp'" tools zelda runner GE-Temp
rm -rf "${HOME}/.local/share/lutris/runners/wine/GE-Temp"
check "runner: other tools reject a vanished runner" 1 'no longer installed' tools zelda folder
check "runner: but changing runner still works" 0 "changed to 'GE-Test'" tools zelda runner GE-Test
check "runner: tools work again afterwards" 0 'saved' tools zelda env set RUNNER_OK 1
rm -rf "${HOME}/.local/share/lutris/runners/wine/GE-Other"

# --- VSync (per-game environment variables): tested on zelda, a YAML comment must survive
zelda_yml="${HOME}/.config/lutris/games/zelda-1.yml"
printf 'game:\n  exe: /y.exe\n# lpm:hook-disabled keep-me\nwine:\n  version: GE-Test\n' > "${zelda_yml}"
vsync_out() { bash "${R}" vsync "$@" </dev/null 2>&1; }
check "vsync status: no game" 0 '' vsync status
expect "vsync status: empty list" bash -c '[[ -z "$(bash "$1" vsync status </dev/null 2>&1)" ]]' _ "${R}"
check "vsync: initial state" 0 'd3d9=off' vsync zelda
check "vsync: explicit state" 0 'gl-mesa=off' vsync zelda status
check "vsync on d3d9" 0 'enabled' vsync zelda on d3d9
expect "vsync: d3d9 on, d3d11 off" bash -c 'o="$(bash "$1" vsync zelda </dev/null)"; grep -qx "d3d9=on" <<<"$o" && grep -qx "d3d11=off" <<<"$o"' _ "${R}"
check "vsync status: lists zelda" 0 '^zelda$' vsync status
expect "vsync status: not mario" bash -c '! bash "$1" vsync status </dev/null | grep -q mario' _ "${R}"
check "tools env: existing DXVK_CONFIG" 0 '' tools zelda env set DXVK_CONFIG "dxgi.hideAmdGpu = True"
check "vsync on (all)" 0 'enabled' vsync zelda on
expect "vsync: all 5 on" bash -c '[[ "$(bash "$1" vsync zelda </dev/null | grep -c "=on")" -eq 5 ]]' _ "${R}"
expect "vsync: DXVK_CONFIG merged, existing option preserved" bash -c 'o="$(bash "$1" tools zelda env list </dev/null)"; grep -q "^DXVK_CONFIG=.*hideAmdGpu = True" <<<"$o" && grep -q "^DXVK_CONFIG=.*dxgi.syncInterval = 0" <<<"$o" && grep -q "^DXVK_CONFIG=.*d3d9.presentInterval = 0" <<<"$o"' _ "${R}"
expect "vsync: other variables set" bash -c 'o="$(bash "$1" tools zelda env list </dev/null)"; grep -qx "VKD3D_SWAPCHAIN_PRESENT_MODE=IMMEDIATE" <<<"$o" && grep -qx "__GL_SYNC_TO_VBLANK=0" <<<"$o" && grep -qx "vblank_mode=0" <<<"$o"' _ "${R}"
check "vsync on: idempotent" 0 'enabled' vsync zelda on
expect "vsync on x2: DXVK_CONFIG without duplicate" bash -c '[[ "$(bash "$1" tools zelda env list </dev/null | grep "^DXVK_CONFIG=" | grep -o "dxgi.syncInterval" | wc -l)" -eq 1 ]]' _ "${R}"
check "vsync off d3d9" 0 'removed' vsync zelda off d3d9
expect "vsync off d3d9: d3d11 stays on" bash -c 'o="$(bash "$1" vsync zelda </dev/null)"; grep -qx "d3d9=off" <<<"$o" && grep -qx "d3d11=on" <<<"$o"' _ "${R}"
check "tools env: custom d3d12 value" 0 '' tools zelda env set VKD3D_SWAPCHAIN_PRESENT_MODE MAILBOX
check "vsync off (all)" 0 'removed' vsync zelda off
expect "vsync off: no setting left on" bash -c '! bash "$1" vsync zelda </dev/null | grep -q "=on"' _ "${R}"
expect "vsync off: DXVK_CONFIG keeps the non-VSync option" bash -c 'bash "$1" tools zelda env list </dev/null | grep -qx "DXVK_CONFIG=dxgi.hideAmdGpu = True"' _ "${R}"
expect "vsync off: custom value never touched" bash -c 'bash "$1" tools zelda env list </dev/null | grep -qx "VKD3D_SWAPCHAIN_PRESENT_MODE=MAILBOX"' _ "${R}"
check "tools env: remove DXVK_CONFIG" 0 '' tools zelda env unset DXVK_CONFIG
check "vsync on d3d11 only" 0 'enabled' vsync zelda on d3d11
check "vsync off d3d11: DXVK_CONFIG removed if empty" 0 'removed' vsync zelda off d3d11
expect "vsync: DXVK_CONFIG absent after removal" bash -c '! bash "$1" tools zelda env list </dev/null | grep -q "^DXVK_CONFIG="' _ "${R}"
expect "vsync: YAML comment preserved" grep -q 'lpm:hook-disabled keep-me' "${zelda_yml}"
expect "vsync: YAML still valid" python3 -c "import yaml; yaml.safe_load(open('${zelda_yml}'))"
check "vsync: unknown setting" 1 "unknown setting 'bogus'" vsync zelda on bogus
check "vsync: unknown action" 1 "unknown action" vsync zelda toggle
check "vsync: status with setting" 1 'Usage' vsync zelda status d3d9
check "vsync: unknown slug" 1 'no installed game' vsync nosuch on
check "vsync: no argument" 1 'Usage' vsync

# --- Shortcut
check "shortcut" 0 'Shortcut created' shortcut mario
expect "shortcut: .desktop created" test -f "${HOME}/.local/share/applications/net.lutris.mario.desktop"
check "shortcut: unknown slug" 1 'not found' shortcut nosuch

# --- Proton GAMEID insertion keeps the game YAML valid, even with "env: {}" (inline empty mapping)
mkdir -p "${HOME}/.local/share/lutris/runners/wine/ProtonTest" "${HOME}/gameid-desk"
: > "${HOME}/.local/share/lutris/runners/wine/ProtonTest/toolmanifest.vdf"
printf 'game:\n  exe: drive_c/x.bat\n  prefix: /p\nsystem:\n  env: {}\n  mangohud: false\nwine:\n  version: ProtonTest\n' > "${HOME}/.config/lutris/games/gameid-1.yml"
expect "GAMEID: written" bash -c 'source "$1/lib/zgu-desktop-utils.sh"; zgu_write_game_shortcut "G" gameid "$2" 42 "" false true "$2/x.bat" gameid-1 "$2/.config/lutris/games" "$2/.local/share/lutris/runners/wine" "$2/gameid-desk" >/dev/null 2>&1; grep -q "GAMEID: umu-42" "$2/.config/lutris/games/gameid-1.yml"' _ "${repo}" "${HOME}"
expect "GAMEID: YAML still valid" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["system"]["env"]["GAMEID"]=="umu-42" and d["system"]["mangohud"] is False' "${HOME}/.config/lutris/games/gameid-1.yml"

rm -rf "${HOME}/.local/share/lutris/runners/wine/ProtonTest" "${HOME}/gameid-desk"

# --- Launch-hook policy keeps the YAML valid when a hook value spans several lines (YAML tools
#     wrap long values) -- an orphan line made Lutris report "game has no executable"
hook_yml="${HOME}/hook-policy.yml"
hook_run() { bash -c 'source "$1/lib/zgu-desktop-utils.sh"; t() { echo "disabled by ludis"; }; zgu_apply_hook_policy "$2" "$3" broad' _ "${repo}" "${hook_yml}" "$1"; }
printf 'game:\n  exe: /y.exe\nsystem:\n  env:\n    GAMEID: umu-3\n  prefix_command: /a/scripts/lpm-winetrace.sh\n    /a/scripts/lpm-winetrace.log\nwine:\n  version: X\n' > "${hook_yml}"
hook_run false
expect "hook policy: wrapped value disabled, YAML valid, hook gone" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert "prefix_command" not in d["system"] and d["system"]["env"]["GAMEID"]=="umu-3" and d["wine"]["version"]=="X"' "${hook_yml}"
cp "${hook_yml}" "${hook_yml}.once"; hook_run false
expect "hook policy: disabling twice changes nothing" cmp -s "${hook_yml}" "${hook_yml}.once"
hook_run true
expect "hook policy: restore gives back the whole value" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["system"]["prefix_command"]=="/a/scripts/lpm-winetrace.sh /a/scripts/lpm-winetrace.log"' "${hook_yml}"
# File left broken by an older ludis: first line commented, second line orphan
printf 'game:\n  exe: /y.exe\nsystem:\n  env:\n    GAMEID: umu-3\n  # prefix_command: /a/x.sh  # lpm:hook-disabled (old)\n    /a/x.log\nwine:\n  version: X\n' > "${hook_yml}"
hook_run false
expect "hook policy: file broken by an older ludis is repaired" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert "prefix_command" not in d["system"] and d["wine"]["version"]=="X"' "${hook_yml}"
# A sibling key after a disabled hook is never swallowed
printf 'system:\n  env:\n    GAMEID: umu-3\n  # prefix_command: /a/x.sh  # lpm:hook-disabled (old)\n    FOO: bar\n' > "${hook_yml}"
hook_run false
expect "hook policy: sibling key after a disabled hook kept" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["system"]["env"]["FOO"]=="bar"' "${hook_yml}"
rm -f "${hook_yml}" "${hook_yml}.once"

# --- Runner download helper returns ONLY the file path (a message on stdout would corrupt it)
expect "download_cli: stdout is only the path" bash -c '
  exec 3>/dev/null
  t() { echo "Downloading $1..."; }
  declare -A release_asset_size
  curl() { while [ "$1" != "-o" ]; do shift; done; echo data > "$2"; }
  eval "$(sed -n "/^download_cli()/,/^}/p" "$1/lib/zgc-dependency-checker.sh")"
  out=$(download_cli http://x/y runnertest)
  [ -f "$out" ] && rm -f "$out"' _ "${repo}"

# --- Game window detection (loading screen): rules of zgl_trace_line_is_game_window
load_detection='eval "$(sed -n "/^WIN_SIZE_THRESHOLD=/,/^}/p" "$1/lib/zgl-launcher-orchestrator.sh")"'
# Real trace (GE-Proton, Bloodborne): the Wine taskbar "Shell_TrayWnd" (166x52, title bar) and a
# hidden launcher helper window "SDL_app" (7x33, title bar) come first; the first accepted line
# must be the real game window ("SDL_app" 1928x1114, from the second process)
expect "window detection: real trace -> the real game window, not the taskbar or the helper" bash -c "${load_detection}"'
  while IFS= read -r l; do
    if zgl_trace_line_is_game_window "$l"; then [[ "$l" == *"1928x1114"* ]]; exit; fi
  done < "$1/tests/fixtures/winetrace-ge-proton-launcher-then-game.log"
  exit 1' _ "${repo}"
# Synthetic lines (same format as the traces)
trace_line() { printf '0100:trace:win:WIN_CreateWindowEx L"" L"%s"->L"%s" ex=00000000 style=%s 0,0 %s parent=0000000000000000 menu=0 inst=0 params=0\n' "$1" "$1" "$2" "$3"; }
expect "window detection: big window accepted" bash -c "${load_detection}"'; zgl_trace_line_is_game_window "$2"' _ "${repo}" "$(trace_line Game 90000000 1280x720)"
expect "window detection: small window with a title bar accepted (Kirby 106x132)" bash -c "${load_detection}"'; zgl_trace_line_is_game_window "$2"' _ "${repo}" "$(trace_line GameMaker06 06ca0000 106x132)"
expect "window detection: tiny helper window with a title bar ignored (7x33)" bash -c "${load_detection}"'; ! zgl_trace_line_is_game_window "$2"' _ "${repo}" "$(trace_line SDL_app 06ca0000 7x33)"
expect "window detection: empty window with a title bar ignored" bash -c "${load_detection}"'; ! zgl_trace_line_is_game_window "$2"' _ "${repo}" "$(trace_line Whatever 00cf0000 0x0)"
expect "window detection: small window without a title bar ignored" bash -c "${load_detection}"'; ! zgl_trace_line_is_game_window "$2"' _ "${repo}" "$(trace_line Whatever 80000000 100x100)"
expect "window detection: Wine taskbar ignored" bash -c "${load_detection}"'; ! zgl_trace_line_is_game_window "$2"' _ "${repo}" "$(trace_line Shell_TrayWnd 00c80000 166x52)"
expect "window detection: Wine taskbar ignored even when big" bash -c "${load_detection}"'; ! zgl_trace_line_is_game_window "$2"' _ "${repo}" "$(trace_line Shell_TrayWnd 00c80000 1920x1080)"
expect "window detection: per-game ignored word (lpm-ignore-windows.txt)" bash -c 'd=$(mktemp -d); mkdir -p "${d}/ludis/settings"; printf "# helper\nbbbridge\n" > "${d}/ludis/settings/ignore-windows.txt"; game_dir="${d}"; source "$1/lib/zgu-ludis-paths.sh"; '"${load_detection}"'; rc=0; zgl_trace_line_is_game_window "$3" && rc=1; rm -rf "${d}"; exit "${rc}"' _ "${repo}" "${repo}" "$(trace_line bbbridge 16cf0000 1280x800)"

# --- Pack safety: links pointing outside the game folder or to themselves are never copied
mkdir -p "${HOME}/outside-secret" "${HOME}/Games/zelda/drive_c/Games/Z"
echo secret > "${HOME}/outside-secret/private.txt"
echo inner > "${HOME}/Games/zelda/drive_c/Games/Z/real.txt"
ln -s "${HOME}/outside-secret" "${HOME}/Games/zelda/drive_c/Games/Z/to-outside"
ln -s / "${HOME}/Games/zelda/drive_c/Games/Z/to-root"
ln -s . "${HOME}/Games/zelda/drive_c/Games/Z/pfx"
ln -s real.txt "${HOME}/Games/zelda/drive_c/Games/Z/inner-link"
echo "GE-Proton-test" > "${HOME}/Games/zelda/version"
check "pack safety" 0 '\[EXPORTED\]' pack -3 zelda
# Proton's "version" file would make Proton skip repairing the prefix whose runner links were removed
expect "pack: Proton version file not archived" bash -c '! zstd -dc "$1" | tar -t | grep -Eq "^(\./)?[^/]+/version$"' _ "${HOME}/Zelda.zgp"
expect "pack: Proton version file removed from the installed game" test ! -e "${HOME}/Games/zelda/version"
expect "pack safety: archive has no outside data" bash -c '! zstd -dc "$1" | tar -t | grep -q "private.txt"' _ "${HOME}/Zelda.zgp"
expect "pack safety: inner link became a real file" bash -c 'zstd -dc "$1" | tar -t | grep -q "Z/inner-link$"' _ "${HOME}/Zelda.zgp"
expect "pack safety: outside folder untouched" test -f "${HOME}/outside-secret/private.txt"
expect "pack safety: no temporary copy left" bash -c '[ -z "$(find "$1" -name "*.zgp-tmp")" ]' _ "${HOME}/Games/zelda"
rm -f "${HOME}/Zelda.zgp"

# --- Pack: ludis's own window-detection relay is not exported, a command of the user stays
printf 'game:\n  exe: /y.exe\nsystem:\n  prefix_command: %s/Games/zelda/scripts/lpm-winetrace.sh %s/Games/zelda/scripts/lpm-winetrace.log gamemoderun\nwine:\n  version: GE-Test\n' "${HOME}" "${HOME}" > "${HOME}/.config/lutris/games/zelda-1.yml"
check "pack: relay + user command" 0 '\[EXPORTED\]' pack -3 zelda
expect "pack: relay removed, user command kept" bash -c 'bsdtar -xOqf "$1" .lpm-config.yml | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); assert d[\"system\"][\"prefix_command\"]==\"gamemoderun\", d"' _ "${HOME}/Zelda.zgp"
# --- Pack: a pre-launch script of the game is copied into ludis/scripts, YAML points to the copy
mkdir -p "${HOME}/hooks"; printf '#!/bin/bash\necho hi\n' > "${HOME}/hooks/before.sh"
printf 'game:\n  exe: /y.exe\nsystem:\n  prelaunch_command: %s/hooks/before.sh\nwine:\n  version: GE-Test\n' "${HOME}" > "${HOME}/.config/lutris/games/zelda-1.yml"
rm -f "${HOME}/Zelda.zgp"
check "pack: game with a pre-launch script" 0 '\[EXPORTED\]' pack -3 zelda
expect "pack: script copied to ludis/scripts in the archive" bash -c 'zstd -dc "$1" | tar -t | grep -q "/ludis/scripts/before.sh$"' _ "${HOME}/Zelda.zgp"
expect "pack: YAML points to the copied script" bash -c 'bsdtar -xOqf "$1" .lpm-config.yml | grep -q "GAMEDIR\|ludis/scripts/before.sh"' _ "${HOME}/Zelda.zgp"
# Install: the script travels in the archive; without --allow-scripts the hook is neutralized,
# with it the hook points to the copy in the new ludis/scripts.
mkdir -p "${HOME}/hookdir"; cp "${HOME}/Zelda.zgp" "${HOME}/hookdir/Zelda.zgp"
# --list-hooks (used by the GUI confirmation): read-only list of the scripts of the archives.
check "install --list-hooks: game with a script" 0 'GAME.*Zelda.zgp' install -y --list-hooks "${HOME}/hookdir/Zelda.zgp"
check "install --list-hooks: lists the script key" 0 'HOOK.*prelaunch_command' install -y --list-hooks "${HOME}/hookdir/Zelda.zgp"
check "install --list-hooks: full path once installed, no GAMEDIR left" 0 "/Games/[^[:cntrl:]]*/ludis/scripts/before.sh" install -y --list-hooks "${HOME}/hookdir/Zelda.zgp"
check "uninstall zelda (hook test)" 0 '\[REMOVED\] zelda' uninstall -y zelda
check "install: archive with a script, no --allow-scripts" 0 '\[INSTALLED\] zelda' install -y "${HOME}/hookdir/Zelda.zgp"
expect "install: script restored in ludis/scripts" test -f "${HOME}/Games/zelda/ludis/scripts/before.sh"
expect "install: script hook neutralized by default" bash -c '! grep -hE "^[[:space:]]*prelaunch_command:" $1' _ "${HOME}/.config/lutris/games/zelda-*.yml"
check "uninstall zelda (hook test 2)" 0 '\[REMOVED\] zelda' uninstall -y zelda
check "install: archive with a script, --allow-scripts" 0 '\[INSTALLED\] zelda' install -y --allow-scripts "${HOME}/hookdir/Zelda.zgp"
expect "install: --allow-scripts keeps the hook on the copy" bash -c 'grep -hE "^[[:space:]]*prelaunch_command:.*/ludis/scripts/before.sh" $1' _ "${HOME}/.config/lutris/games/zelda-*.yml"
rm -rf "${HOME}/hookdir"
rm -f "${HOME}/Zelda.zgp"
rm -f "${HOME}/Zelda.zgp"
printf 'name: Old Name\ngame:\n  exe: /x.exe\nsystem:\n  prefix_command: %s/Games/mario/scripts/lpm-winetrace.sh %s/Games/mario/scripts/lpm-winetrace.log\nwine:\n  version: GE-Test\n' "${HOME}" "${HOME}" > "${HOME}/.config/lutris/games/mario-1.yml"

# --- Pack: the free space for the WHOLE batch is checked before anything is touched
pshim="${work}/pshim"; mkdir -p "${pshim}"
# 0 KiB free: the fixture games are only a few bytes big.
printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nx 100 100 0 100%% /\\n"\n' > "${pshim}/df"
chmod +x "${pshim}/df"
PATH="${pshim}:${PATH}" check "pack: not enough space for the batch is refused" 1 'not enough free disk space to export 2 game' pack -3 mario zelda
expect "pack: nothing created when the batch is refused" bash -c '[ ! -e "$1/Mario.zgp" ] && [ ! -e "$1/Zelda.zgp" ]' _ "${HOME}"
# Compression failing: "disk full" only when the disk really is (almost) full afterwards.
# Fake df: plenty of space for the first call (the batch check), none afterwards.
mkdir -p "${pshim}"
cat > "${pshim}/df" <<DFEOF
#!/bin/sh
n=\$(cat "${pshim}/df-calls" 2>/dev/null || echo 0); echo \$((n + 1)) > "${pshim}/df-calls"
if [ "\$n" -eq 0 ]; then free=999999999; else free=0; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nx 1 1 %s 1%% /\n' "\$free"
DFEOF
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "${pshim}/zstd"
chmod +x "${pshim}/df" "${pshim}/zstd"
PATH="${pshim}:${PATH}" check "pack: full disk during compression reported as such" 1 'disk is full while compressing' pack -3 zelda
expect "pack: unfinished archive removed" test ! -e "${HOME}/Zelda.zgp"
rm -f "${pshim}/df-calls" "${pshim}/df"
PATH="${pshim}:${PATH}" check "pack: other compression failure still reported as such" 1 'compression of .Zelda. failed' pack -3 zelda
rm -rf "${pshim}"

# --- Full round trip: pack, uninstall, reinstall
check "pack" 0 '\[EXPORTED\]' pack -3 mario
expect "pack: relay only -> no prefix_command exported" bash -c '! bsdtar -xOqf "$1" .lpm-config.yml | grep -q prefix_command' _ "${HOME}/Mario.zgp"
expect "pack: .zgp created" test -s "${HOME}/Mario.zgp"
expect "pack: the name in the archive is the one in Lutris' database (renamed game), not the stale YAML one" bash -c 'bsdtar -xOqf "$1" .lpm-config.yml | python3 -c "import sys,yaml; assert yaml.safe_load(sys.stdin)[\"name\"]==\"Mario\""' _ "${HOME}/Mario.zgp"
expect "pack: .lpm-config.yml is the first member of the archive" bash -c 'zstd -dc "$1" | head -c 100 | tr -d "\0" | grep -qx ".lpm-config.yml"' _ "${HOME}/Mario.zgp"
expect "pack: first-member YAML holds the exact size" bash -c 'bsdtar -xOqf "$1" .lpm-config.yml | python3 -c "import sys,yaml; assert yaml.safe_load(sys.stdin)[\"lpm_archive\"][\"size\"] > 0"' _ "${HOME}/Mario.zgp"
expect "pack: no .lpm-size and no zgp-game-config.yml left in the archive" bash -c '! zstd -dc "$1" | tar -t | grep -qE "(^|/)(\.lpm-size|zgp-game-config\.yml)$"' _ "${HOME}/Mario.zgp"
expect "pack: the prefix itself is untouched (no config file left in it)" bash -c '[ ! -e "$1/zgp-game-config.yml" ] && [ ! -e "$1/ludis/config.yml" ]' _ "${HOME}/Games/mario"
check "uninstall" 0 '\[REMOVED\] mario' uninstall -y mario
expect "uninstall: removed from the list" bash -c "! bash '${R}' list </dev/null | grep -q '^mario '"
expect "uninstall: folder deleted" test ! -e "${HOME}/Games/mario"
check "install" 0 '\[INSTALLED\] mario' install -y "${HOME}/Mario.zgp"
expect "install: first-member YAML is not extracted into the games folder" bash -c '[ ! -e "$1/.lpm-config.yml" ] && [ ! -e "$1/mario/.lpm-config.yml" ]' _ "${HOME}/Games"
check "list after reinstall" 0 'mario +Mario' list

# --- Game version number + replacing an installed game
cp "${HOME}/Mario.zgp" "${HOME}/Mario-orig.zgp"
check "game-version: none yet" 0 '^$' game-version mario
check "game-version: invalid value refused" 1 'invalid version' game-version mario 'bad;value'
check "game-version: set" 0 'set to: 2.0' game-version mario 2.0
check "game-version: read back" 0 '^2.0$' game-version mario
expect "game-version: stored in the prefix settings" test -s "${HOME}/Games/mario/ludis/settings/game-version"
check "install --list-existing: nothing for a game that is not installed" 0 '^$' install -y --list-existing /nonexistent.zgp
check "install --list-existing: archive without number, game installed (2.0)" 0 'EXISTS.Mario.Mario.zgp.mario.2.0.' install -y --list-existing "${HOME}/Mario.zgp"
rm -f "${HOME}/Mario.zgp"
check "pack with a version" 0 '\[EXPORTED\]' pack -3 mario
expect "pack: the version is in the file name" test -s "${HOME}/Mario (v2.0).zgp"
mv -f "${HOME}/Mario (v2.0).zgp" "${HOME}/Mario.zgp"
expect "pack: game_version written in the first-member YAML" bash -c 'bsdtar -xOqf "$1" .lpm-config.yml | python3 -c "import sys,yaml; assert yaml.safe_load(sys.stdin)[\"game_version\"]==\"2.0\""' _ "${HOME}/Mario.zgp"
check "install --list-versions: version of the archive, without extracting" 0 "VERSION.*Mario.zgp.2.0" install -y --list-versions "${HOME}/Mario.zgp"
check "list: version after the name" 0 'mario +Mario \(v2.0\)' list
check "list --sizes: size of each game" 0 'mario +Mario .v2.0. \[[0-9.]+[KMG]?i?B\]' list --sizes
check "list --sizes-raw: slug and bytes" 0 '^mario.[0-9]+$' list --sizes-raw
check "install --list-versions: size of the archive" 0 'Mario.zgp.2.0.[0-9]+$' install -y --list-versions "${HOME}/Mario.zgp"
check "rename: empty name refused" 1 'invalid name' rename mario ' '
check "rename: unknown game" 1 'not found' rename nosuch Foo
check "rename: ok" 0 "Renamed: 'Mario' -> 'Super Mario'" rename mario "Super Mario"
check "rename: list shows the new name" 0 'mario +Super Mario' list
check "rename: back" 0 'Renamed' rename mario Mario
check "game-version: clear" 0 'removed' game-version mario --clear
check "game-version: empty after clear" 0 '^$' game-version mario
check "install --list-existing: installed none / new 2.0" 0 'EXISTS.Mario.Mario.zgp.mario..2.0' install -y --list-existing "${HOME}/Mario.zgp"
check "install over an installed game, no terminal, no --replace: refused" 1 'already installed' install -y "${HOME}/Mario.zgp" </dev/null
expect "refused install changed nothing" test -d "${HOME}/Games/mario"
mkdir -p "${HOME}/Games/mario/drive_c/users/steamuser/Documents/Mario"; echo keepme > "${HOME}/Games/mario/drive_c/users/steamuser/Documents/Mario/slot.sav"
check "install --replace: uninstalls then installs" 0 'INSTALLED. mario' install -y --replace --save "${HOME}/Mario.zgp"
check "install --replace: shows the removal" 0 'mario' list
expect "install --replace: the saves were backed up before and put back after" bash -c '[ "$(cat "$1/Games/mario/drive_c/users/steamuser/Documents/Mario/slot.sav")" = keepme ] && [ "$(cat "$1/syncsaves/mario/current/Documents/Mario/slot.sav")" = keepme ]' _ "${HOME}"
expect "install --replace: version of the package kept" bash -c '[ "$(cat "$1/ludis/settings/game-version")" = "2.0" ]' _ "${HOME}/Games/mario"
expect "install: game_version never leaks into the Lutris YAML" bash -c '! grep -rq game_version "$1"' _ "${HOME}/.config/lutris/games" 
# Saves question: --no-save / no flag = nothing copied, --save = copied (default folder when none is set)
D="${HOME}/Games/mario/drive_c/users/steamuser/Documents/Mario"; SY="${HOME}/syncsaves/mario/current/Documents/Mario"
echo s2 > "${D}/slot2.sav"
check "install --replace --no-save: replaces" 0 'INSTALLED. mario' install -y --replace --no-save "${HOME}/Mario.zgp"
expect "install --replace --no-save: saves not copied" test ! -e "${SY}/slot2.sav"
mkdir -p "${D}"; echo s3 > "${D}/slot3.sav"
check "uninstall --save: backs up then removes" 0 '\[REMOVED\] mario' uninstall -y --save mario
expect "uninstall --save: saves are in the sync folder" test -e "${SY}/slot3.sav"
check "reinstall after uninstall --save" 0 'INSTALLED. mario' install -y "${HOME}/Mario.zgp"
mkdir -p "${D}"; echo s4 > "${D}/slot4.sav"
check "uninstall --no-save: removes" 0 '\[REMOVED\] mario' uninstall -y --no-save mario
expect "uninstall --no-save: saves not copied" test ! -e "${SY}/slot4.sav"
check "reinstall after uninstall --no-save" 0 'INSTALLED. mario' install -y "${HOME}/Mario.zgp"
mkdir -p "${D}"; echo s5 > "${D}/slot5.sav"
check "uninstall without flag and without terminal: removes" 0 '\[REMOVED\] mario' uninstall -y mario
expect "uninstall without flag and without terminal: nothing copied" test ! -e "${SY}/slot5.sav"
check "reinstall after uninstall without flag" 0 'INSTALLED. mario' install -y "${HOME}/Mario.zgp"
cp "${HOME}/.config/ludis/saves.conf" "${HOME}/saves.conf.keep"
check "saves dir none" 0 '' saves dir none
mkdir -p "${D}"; echo s6 > "${D}/slot6.sav"
check "uninstall --save without a sync folder: default folder created" 0 'Saves sync folder: .*Ludis-saves' uninstall -y --save mario
expect "uninstall --save without a sync folder: saves in Documents/Ludis-saves" test -e "${HOME}/Documents/Ludis-saves/mario/current/Documents/Mario/slot6.sav"
cp "${HOME}/saves.conf.keep" "${HOME}/.config/ludis/saves.conf"
check "reinstall after the default folder test" 0 'INSTALLED. mario' install -y "${HOME}/Mario.zgp"
mv -f "${HOME}/Mario-orig.zgp" "${HOME}/Mario.zgp"

# --- Packaging: the RPM spec must not contain a bare path line in %install (it would be run as a command)
expect "rpm spec: no bare path line in %install" bash -c '! sed -n "/^%install/,/^%files/p" "$1/packaging/rpm/ludis.spec" | grep -q "^/"' _ "${repo}"
expect "rpm spec: the lpm compatibility links are listed in %files" bash -c 'sed -n "/^%files/,/^%changelog/p" "$1/packaging/rpm/ludis.spec" | grep -qx "/usr/bin/lpm" && sed -n "/^%files/,/^%changelog/p" "$1/packaging/rpm/ludis.spec" | grep -qx "/usr/lib/lpm"' _ "${repo}"

# --- Install removes Proton's "version" file from archives made before the export did it
mkdir -p "${HOME}/old-archive"
zstd -dc "${HOME}/Mario.zgp" | tar -x -C "${HOME}/old-archive"
echo "GE-Proton-test" > "${HOME}/old-archive/mario/version"
# Previous archive format: the YAML sits INSIDE the prefix under its old name, no first member.
cp "${HOME}/old-archive/.lpm-config.yml" "${HOME}/old-archive/mario/zgp-game-config.yml"
python3 - "${HOME}/old-archive/mario/zgp-game-config.yml" <<'PYEOF'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p)) or {}
d.setdefault("system", {})["antimicro_config"] = "$GAMEDIR/lpm_gamepad/lpm-gamepad.gamecontroller.amgp"
yaml.dump(d, open(p, "w"), sort_keys=False)
PYEOF
# ... and with the relay of the old Ludis Launcher format (ludis <= 0.9.5)
mkdir -p "${HOME}/old-archive/mario/scripts"
printf '#!/bin/sh\n' > "${HOME}/old-archive/mario/scripts/lpm-launcher.sh"
# Every old-layout ludis file at the prefix root (they must all end up in ludis/ at install)
mkdir -p "${HOME}/old-archive/mario/extras/Manual" "${HOME}/old-archive/mario/splash" "${HOME}/old-archive/mario/lpm_gamepad"
echo m > "${HOME}/old-archive/mario/extras/Manual/readme.txt"; echo s > "${HOME}/old-archive/mario/splash/splash.png"
echo g > "${HOME}/old-archive/mario/lpm_gamepad/profile.amgp"; echo i > "${HOME}/old-archive/mario/icon"
echo w > "${HOME}/old-archive/mario/lpm-ignore-windows.txt"; : > "${HOME}/old-archive/mario/.lpm-no-loadingscreen"
printf 'title: T\nentries: []\n' > "${HOME}/old-archive/mario/lpm-launcher.yml"
printf '#!/bin/sh\n' > "${HOME}/old-archive/mario/scripts/hook.sh"
tar -C "${HOME}/old-archive" -cf - mario | zstd -q > "${HOME}/Mario-old.zgp"
check "uninstall before old archive" 0 '\[REMOVED\] mario' uninstall -y mario
check "install old archive" 0 '\[INSTALLED\] mario' install -y "${HOME}/Mario-old.zgp"
expect "install: Proton version file removed" test ! -e "${HOME}/Games/mario/version"
expect "migration: every old file moved into ludis/" bash -c 'g="$1"; test -f "$g/ludis/extras/Manual/readme.txt" && test -f "$g/ludis/images/splash/splash.png" && test -f "$g/ludis/gamepad/profile.amgp" && test -f "$g/ludis/images/icon" && test -f "$g/ludis/settings/ignore-windows.txt" && test -e "$g/ludis/settings/no-loadingscreen" && test -f "$g/ludis/launcher.yml" && test -f "$g/ludis/scripts/hook.sh"' _ "${HOME}/Games/mario"
expect "migration: Lutris YAML points to the moved gamepad profile" bash -c 'grep -hq "antimicro_config: .*/mario/ludis/gamepad/lpm-gamepad.gamecontroller.amgp" $1 && ! grep -hq "lpm_gamepad" $1' _ "${HOME}/.config/lutris/games/mario-*.yml"
expect "migration: absolute old paths in a Lutris YAML are rewritten (gamepad, scripts), others untouched" bash -c 'd=$(mktemp -d); printf "system:\n  antimicro_config: %s/g/lpm_gamepad/p.amgp\n  prelaunch_command: %s/g/scripts/h.sh\n  other: /x/lpm_gamepad/keep\n" "$d" "$d" > "$d/y.yml"; source "$1/lib/zgu-ludis-paths.sh"; zgu_ludis_fix_yml_paths "$d/g" "$d/y.yml"; grep -q "g/ludis/gamepad/p.amgp" "$d/y.yml" && grep -q "g/ludis/scripts/h.sh" "$d/y.yml" && grep -q "/x/lpm_gamepad/keep" "$d/y.yml"; rc=$?; rm -rf "$d"; exit $rc' _ "${repo}"
expect "rename: old <prefix>/lpm folder moves to ludis, YAML paths follow, existing files win" bash -c 'd=$(mktemp -d); mkdir -p "$d/g/lpm/scripts" "$d/g/ludis"; echo a > "$d/g/lpm/scripts/h.sh"; echo old > "$d/g/lpm/x"; echo new > "$d/g/ludis/x"; printf "system:\n  prelaunch_command: %s/g/lpm/scripts/h.sh\n  other: /z/lpm/keep\n  g: \$GAMEDIR/lpm/gamepad/p\n" "$d" > "$d/y.yml"; source "$1/lib/zgu-ludis-paths.sh"; zgu_ludis_adopt_old_dir "$d/g" "$d/y.yml"; [ -f "$d/g/ludis/scripts/h.sh" ] && [ "$(cat "$d/g/ludis/x")" = new ] && grep -q "g/ludis/scripts/h.sh" "$d/y.yml" && grep -q "/z/lpm/keep" "$d/y.yml" && grep -q "GAMEDIR/ludis/gamepad" "$d/y.yml"; rc=$?; rm -rf "$d"; exit $rc' _ "${repo}"
expect "rename: reads fall back to the old lpm folder until it is moved" bash -c 'd=$(mktemp -d); mkdir -p "$d/g/lpm/settings"; echo on > "$d/g/lpm/settings/overlay-fps"; source "$1/lib/zgu-ludis-paths.sh"; [ "$(zgu_overlay_fps_pergame "$d/g")" = on ]; rc=$?; rm -rf "$d"; exit $rc' _ "${repo}"
expect "rename: ~/.config/lpm and ~/.local/share/lpm move to ludis (log renamed)" bash -c 'd=$(mktemp -d); mkdir -p "$d/.config/lpm" "$d/.local/share/lpm"; echo k > "$d/.config/lpm/steamgriddb.key"; echo l > "$d/.local/share/lpm/lpm.log"; HOME="$d" XDG_CONFIG_HOME="$d/.config" bash -c "source \"$1/lib/zgu-log-utils.sh\""; [ -f "$d/.config/ludis/steamgriddb.key" ] && [ -f "$d/.local/share/ludis/ludis.log" ] && [ ! -e "$d/.config/lpm" ]; rc=$?; rm -rf "$d"; exit $rc' _ "${repo}"
expect "migration: nothing ludis-owned left at the prefix root" bash -c 'g="$1"; for f in extras splash lpm_gamepad icon lpm-ignore-windows.txt .lpm-no-loadingscreen lpm-launcher.yml scripts zgp-game-config.yml; do test ! -e "$g/$f" || { echo "left: $f"; exit 1; }; done' _ "${HOME}/Games/mario"

check "list after an old-format install (name read from the old YAML)" 0 'mario +Mario' list
expect "install: relay of the old Ludis Launcher format removed (legacy)" test ! -e "${HOME}/Games/mario/scripts/lpm-launcher.sh"
rm -rf "${HOME}/old-archive" "${HOME}/Mario-old.zgp"

# --- Install: disk space. A small .zgp is enough: the failures happen before/while extracting.
mkdir -p "${HOME}/spacegame" && head -c 20000 /dev/urandom > "${HOME}/spacegame/data.bin"
tar -C "${HOME}" -cf - spacegame | zstd -q > "${HOME}/Space.zgp"
rm -rf "${HOME}/spacegame"
shim="${work}/shim"; mkdir -p "${shim}"
real_bsdtar="$(command -v bsdtar)"
# (a) Not enough free space (fake df: 1 KiB free): refused BEFORE reading the archive at all.
printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nx 100 99 1 99%% /\\n"\n' > "${shim}/df"
printf '#!/bin/sh\necho called >> "%s/bsdtar-calls"\nexec %s "$@"\n' "${shim}" "${real_bsdtar}" > "${shim}/bsdtar"
chmod +x "${shim}/df" "${shim}/bsdtar"
rm -f "${shim}/bsdtar-calls"
PATH="${shim}:${PATH}" check "install: not enough free space is refused" 1 'not enough free disk space' install -y "${HOME}/Space.zgp"
cp "${HOME}/Space.zgp" "${HOME}/Space2.zgp"
PATH="${shim}:${PATH}" check "install: a batch is refused as a whole, before extracting" 1 'these 2 games' install -y "${HOME}/Space.zgp" "${HOME}/Space2.zgp"
expect "install: nothing read or extracted when refused" bash -c '[ ! -e "$1/bsdtar-calls" ] && [ -z "$(ls -A "$2" | grep zgp-extract)" ]' _ "${shim}" "${HOME}/Games"
rm -f "${shim}/df"
# (b) Extraction fails with "No space left": reported as a full disk, not a corrupted archive.
printf '#!/bin/sh\ncat >/dev/null\necho "$LC_MESSAGES" > "'"${shim}"'/lc-messages"\necho "x/y.bin: Write failed: No space left on device" >&2\nexit 1\n' > "${shim}/bsdtar"
PATH="${shim}:${PATH}" check "install: full disk reported as such" 1 'disk is full' install -y "${HOME}/Space.zgp"
expect "install: bsdtar messages forced to English" grep -qx C "${shim}/lc-messages"
# (c) Extraction fails for another reason: still reported as a corrupted archive.
printf '#!/bin/sh\ncat >/dev/null\necho "Truncated input" >&2\nexit 1\n' > "${shim}/bsdtar"
PATH="${shim}:${PATH}" check "install: other failure still reported as corrupted" 1 'corrupted or invalid' install -y "${HOME}/Space.zgp"
expect "install: temp extraction folder removed after a failure" bash -c '[ -z "$(ls -A "$1" | grep zgp-extract)" ]' _ "${HOME}/Games"
rm -f "${shim}/bsdtar"
# (d) Exact size: a tiny archive (compresses to almost nothing) that declares 2 MiB once extracted.
# 1000 KiB free: the archive's own size would pass, the exact size must be refused. An archive
# without ".lpm-size" falls back to the archive's size.
mkdir -p "${HOME}/exactgame" "${HOME}/exactmeta"
head -c 2097152 /dev/zero > "${HOME}/exactgame/zeros.bin"
printf 'name: Exact\nlpm_archive:\n  format: 2\n  size: 2097152\n' > "${HOME}/exactmeta/.lpm-config.yml"
tar -cf - -C "${HOME}/exactmeta" .lpm-config.yml -C "${HOME}" exactgame | zstd -q > "${HOME}/Exact.zgp"
printf 'size=2097152\n' > "${HOME}/exactmeta/.lpm-size"
tar -cf - -C "${HOME}/exactmeta" .lpm-size -C "${HOME}" exactgame | zstd -q > "${HOME}/ExactLegacy.zgp"
tar -cf - -C "${HOME}" exactgame | zstd -q > "${HOME}/ExactOld.zgp"
printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nx 100000 99000 1000 99%% /\\n"\n' > "${shim}/df"
chmod +x "${shim}/df"
PATH="${shim}:${PATH}" check "install: exact size refused (archive itself would fit)" 1 'at least 2\.0MiB' install -y "${HOME}/Exact.zgp"
expect "exact size: read from a new archive" bash -c 'source "$1/lib/zgu-cli-utils.sh"; [ "$(zgu_archive_exact_size "$2")" = "2097152" ]' _ "${work}/repo" "${HOME}/Exact.zgp"
expect "exact size: still read from the previous .lpm-size format" bash -c 'source "$1/lib/zgu-cli-utils.sh"; [ "$(zgu_archive_exact_size "$2")" = "2097152" ]' _ "${work}/repo" "${HOME}/ExactLegacy.zgp"
expect "exact size: absent from an old archive" bash -c 'source "$1/lib/zgu-cli-utils.sh"; ! zgu_archive_exact_size "$2" >/dev/null' _ "${work}/repo" "${HOME}/ExactOld.zgp"
rm -f "${shim}/df"
rm -rf "${HOME}/exactgame" "${HOME}/exactmeta" "${HOME}/Exact.zgp" "${HOME}/ExactLegacy.zgp" "${HOME}/ExactOld.zgp"
rm -rf "${shim}" "${HOME}/Space.zgp" "${HOME}/Space2.zgp"

# --- Completion: every documented command is offered (except advanced commands
#     intentionally absent from "ludis --help"), and options with values complete
hidden=" archives options lsfg-dll sgdb-images sgdb-key "
for page in "${repo}"/docs/commands/*.md; do
  cmd="$(basename "${page}" .md)"
  [[ "${hidden}" == *" ${cmd} "* ]] && continue
  expect "completion bash: ${cmd}" grep -qw -- "${cmd}" "${repo}/completions/ludis.bash"
  expect "completion zsh: ${cmd}" grep -qw -- "${cmd}" "${repo}/completions/_ludis"
done
printf '#!/bin/sh\nexec bash %s "$@"\n' "${R}" > "${HOME}/bin/ludis"; chmod +x "${HOME}/bin/ludis"
# shellcheck disable=SC1091
source "${repo}/completions/ludis.bash" 2>/dev/null
comp() { COMP_WORDS=("$@"); COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); COMPREPLY=(); _ludis 2>/dev/null; echo "${COMPREPLY[*]}"; }
expect "completion: -a offers win32/win64" bash -c '[[ "$1" == *win64* ]]' _ "$(comp ludis create-prefix -a "")"
expect "completion: -s offers the modes" bash -c '[[ "$1" == *desktop* ]]' _ "$(comp ludis shortcut -s "")"
expect "completion: --url for icon" bash -c '[[ "$1" == *--url* ]]' _ "$(comp ludis icon "--u")"
expect "completion: installed slugs" bash -c '[[ "$1" == *mario* ]]' _ "$(comp ludis uninstall "")"
expect "completion: tools offers the runner tool" bash -c '[[ "$1" == *runner* ]]' _ "$(comp ludis tools mario "")"
expect "completion: tools runner offers installed runners" bash -c '[[ "$1" == *GE-Test* ]]' _ "$(comp ludis tools mario runner "")"
expect "completion: vsync offers status and slugs" bash -c '[[ "$1" == *status* && "$1" == *mario* ]]' _ "$(comp ludis vsync "")"
expect "completion: vsync <slug> offers on/off" bash -c '[[ "$1" == *on* && "$1" == *off* ]]' _ "$(comp ludis vsync mario "")"
expect "completion: vsync on offers the settings" bash -c '[[ "$1" == *d3d9* && "$1" == *gl-mesa* ]]' _ "$(comp ludis vsync mario on "")"

# --- Gamepad shortcuts (Alt+Tab / F4 / Alt+Enter / F11 watcher), without a real gamepad
if python3 -c "import ctypes; ctypes.CDLL('libSDL2-2.0.so.0')" 2>/dev/null; then
  expect "gamepad: keys during the combo (X11 and Wayland)" python3 "${repo}/tests/gamepad_smoke.py"
else
  echo "(libSDL2 missing: gamepad test skipped)"
fi

# --- install.sh refuses to overwrite another program named "ludis" (tested only as root,
#     and only the refusal: it stops before copying anything, so nothing is touched)
if [[ "$(id -u)" -eq 0 ]]; then
  foreign_bin="${work}/foreign-bin"; mkdir -p "${foreign_bin}"
  printf '\177ELF other-program' > "${foreign_bin}/ludis"
  out="$(LUDIS_INSTALL_BIN_DIR="${foreign_bin}" bash "${repo}/install.sh" 2>&1)"; rc=$?
  expect "install.sh: refuses another program named ludis" bash -c '[[ "$1" -eq 1 && "$2" == *"is not Ludis"* && "$2" == *"Nothing was installed"* ]]' _ "${rc}" "${out}"
  expect "install.sh: the other \"ludis\" is intact" grep -q 'other-program' "${foreign_bin}/ludis"
else
  echo "(not root: install.sh refusal test skipped)"
fi

# --- The log records errors
check "log" 0 'ERROR' log

# --- Uninstalling a game and a runner
check "uninstall zelda" 0 '\[REMOVED\] zelda' uninstall -y zelda
# --- Runner install from a local .zgr: normal, then refused when the disk has no room
mkdir -p "${HOME}/zgrsrc/GE-Fake/bin"; echo x > "${HOME}/zgrsrc/GE-Fake/bin/wine"
tar -cf - -C "${HOME}/zgrsrc" GE-Fake | zstd -q > "${HOME}/GE-Fake.zgr"
pshim="${work}/pshim"; mkdir -p "${pshim}"
printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nx 100 100 0 100%% /\\n"\n' > "${pshim}/df"; chmod +x "${pshim}/df"
PATH="${pshim}:${PATH}" check "install-runner: not enough space is refused before extracting" 1 'not enough free disk space' install-runner -y "${HOME}/GE-Fake.zgr"
expect "install-runner: nothing extracted when refused" test ! -e "${HOME}/.local/share/lutris/runners/wine/GE-Fake"
rm -rf "${pshim}"
check "install-runner: local .zgr" 0 '\[INSTALLED\] GE-Fake' install-runner -y "${HOME}/GE-Fake.zgr"
expect "install-runner: runner files present" test -f "${HOME}/.local/share/lutris/runners/wine/GE-Fake/bin/wine"
rm -rf "${HOME}/.local/share/lutris/runners/wine/GE-Fake" "${HOME}/GE-Fake.zgr" "${HOME}/zgrsrc"
check "uninstall-runner" 0 '\[REMOVED\] GE-Test' uninstall-runner -y GE-Test
check "list-runner empty" 0 'No runner' list-runner


echo "CLI: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
