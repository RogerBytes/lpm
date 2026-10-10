#!/usr/bin/env bash
# CLI smoke test: runs the main "lpm" commands against a fake HOME (fake Lutris, demo
# database, fake Wine runner) and checks exit code + output.
# No GUI, no network, nothing touched outside the temp directory.
# Requires: bash, sqlite3, python3 + PyYAML, zstd/tar (like lpm itself).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp -r "${repo}" "${work}/repo"
chmod +x "${work}/repo/bin/lpm"
R="${work}/repo/bin/lpm"

export HOME="${work}/home"
export LANG=C LC_ALL=C LANGUAGE=en
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "${HOME}/bin" "${HOME}/.config/lutris/games" "${HOME}/.local/share/applications" \
  "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin" \
  "${HOME}/Games/mario/drive_c/windows/system32" "${HOME}/Games/zelda/drive_c/windows/system32"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/bin/lutris"; chmod +x "${HOME}/bin/lutris"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin/wine"
chmod +x "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin/wine"
# Fake wine/wineserver/winetricks first in PATH: if an lpm command ran them, the test would
# start a real Wine (writing into the fake prefix and skewing packaging).
for fake in wine wine64 wineserver winetricks umu-run; do
  printf '#!/bin/sh\nexit 0\n' > "${HOME}/bin/${fake}"; chmod +x "${HOME}/bin/${fake}"
done
# Fake winepath ("winepath -w /a/b" -> Z:\a\b): lpm calls it for the LPM Launcher, and the
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
# check "name" <expected code> "<regex expected in stdout+stderr, or empty>" <lpm arguments...>
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
check "version" 0 '^lpm v[0-9]' --version
check "unknown command" 1 'Unknown command' bogus
check "no argument: help, exit code 0" 0 'lpm vsync' 
check "list" 0 'mario +Mario' list
check "list (zelda)" 0 'zelda +Zelda' list
check "list-runner" 0 'GE-Test' list-runner
check "list-isolable" 0 'No isolable|Nothing' list-isolable
check "isolate without shared store" 0 'Nothing to isolate' isolate
check "sgdb-key get" 0 '"key"' sgdb-key get
check "lsfg status" 0 '"installed"' lsfg status
check "self-update: invalid argument" 1 'Invalid argument' self-update bogus
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
expect "launcher on: file created" test -f "${HOME}/Games/mario/lpm-launcher.yml"
check "launcher off" 0 'disabled' launcher mario off
# Exe inside drive_c: the Windows paths are computed as text, Wine (winepath) is NOT started.
mkdir -p "${HOME}/Games/mario/drive_c/Games/Mario/sub"
printf 'game:\n  exe: %s/Games/mario/drive_c/Games/Mario/sub/m.exe\n  prefix: %s/Games/mario\nwine:\n  version: GE-Test\n' "${HOME}" "${HOME}" > "${HOME}/.config/lutris/games/mario-1.yml"
rm -f "${HOME}/winepath-called"
for dir in "${HOME}/bin" "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin"; do
  mv "${dir}/winepath" "${dir}/winepath.real"
  printf '#!/bin/sh\ntouch "%s/winepath-called"\nexit 1\n' "${HOME}" > "${dir}/winepath"; chmod +x "${dir}/winepath"
done
rm -f "${HOME}/Games/mario/lpm-launcher.yml"
check "launcher on: exe in drive_c" 0 'enabled' launcher mario on
expect "launcher on: winepath not called" test ! -e "${HOME}/winepath-called"
expect "launcher on: Windows path computed" grep -qF 'C:\Games\Mario\sub\m.exe' "${HOME}/Games/mario/lpm-launcher.yml"
expect "launcher on: bat has the path" grep -qF 'start "" "C:\Games\Mario\sub\m.exe"' "${HOME}/Games/mario/drive_c/Games/Mario/lpm-launch.bat"
for dir in "${HOME}/bin" "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin"; do
  mv -f "${dir}/winepath.real" "${dir}/winepath"
done
check "launcher off (2)" 0 'disabled' launcher mario off
# Existing lpm-launcher.yml WITHOUT bat_path/original_exe (hand-written or restored from a .zgp):
# "on" keeps the entries and comments, and adds the two keys (otherwise the runtime writes a
# lpm-launch.bat that Lutris never runs and the picker choice is ignored).
printf 'title: T\nprompt: P\nentries:\n- label: One\n  workdir: C:\\Games\\Mario\n  exe: C:\\Games\\Mario\\one.exe\n- label: Two\n  workdir: C:\\Games\\Mario\n  exe: C:\\Games\\Mario\\two.exe\n# my comment\n' > "${HOME}/Games/mario/lpm-launcher.yml"
check "launcher on: existing yml without bat_path" 0 'enabled' launcher mario on
expect "existing yml: bat_path added" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/lpm-launcher.yml')); sys.exit(0 if d.get('bat_path')=='${HOME}/Games/mario/drive_c/Games/Mario/lpm-launch.bat' else 1)"
expect "existing yml: original_exe added" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/lpm-launcher.yml')); sys.exit(0 if str(d.get('original_exe','')).endswith('m.exe') else 1)"
expect "existing yml: entries kept" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/lpm-launcher.yml')); sys.exit(0 if [e['label'] for e in d['entries']]==['One','Two'] else 1)"
expect "existing yml: comment kept" grep -q '# my comment' "${HOME}/Games/mario/lpm-launcher.yml"
check "launcher on again: refused" 1 'already enabled' launcher mario on
expect "existing yml: original_exe still the real exe" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/lpm-launcher.yml')); sys.exit(0 if str(d.get('original_exe','')).endswith('m.exe') else 1)"
mkdir -p "${HOME}/Games/mario/splash"
echo img > "${HOME}/Games/mario/splash/splash.png"
echo trace > "${HOME}/Games/mario/scripts/lpm-winetrace.sh"
echo data > "${HOME}/Games/mario/drive_c/Games/Mario/game-data.txt"
expect "launcher on: relay and bat exist before off" bash -c '[[ -f "$1/scripts/lpm-launcher.sh" && -f "$1/drive_c/Games/Mario/lpm-launch.bat" && -f "$1/lpm-launcher.yml" ]]' _ "${HOME}/Games/mario"
check "launcher off (3)" 0 'disabled' launcher mario off
expect "launcher off: yml, relay and bat deleted" bash -c '[[ ! -e "$1/scripts/lpm-launcher.sh" && ! -e "$1/drive_c/Games/Mario/lpm-launch.bat" && ! -e "$1/lpm-launcher.yml" && ! -e "$1/lpm-launch.bat" ]]' _ "${HOME}/Games/mario"
expect "launcher off: splash, loading-screen script and game files kept" bash -c '[[ -f "$1/splash/splash.png" && -f "$1/scripts/lpm-winetrace.sh" && -f "$1/drive_c/Games/Mario/game-data.txt" ]]' _ "${HOME}/Games/mario"
expect "launcher off: Lutris exe restored" grep -q 'm.exe' "${HOME}/.config/lutris/games/mario-1.yml"
check "launcher on after off: fresh yml" 0 'enabled' launcher mario on
expect "launcher on after off: only the default entry (old entries gone)" python3 -c "import sys,yaml; d=yaml.safe_load(open('${HOME}/Games/mario/lpm-launcher.yml')); sys.exit(0 if len(d['entries'])==1 else 1)"
check "launcher off (4)" 0 'disabled' launcher mario off
# Runtime with a YAML WITHOUT bat_path (picker choice already made): the choice must reach the
# lpm-launch.bat of drive_c that Lutris runs, not only a file at the root of the game folder.
rt_game="${HOME}/Games/rtgame"
mkdir -p "${rt_game}/drive_c/Games/Rt"
printf '@echo off\r\nstart "" "C:\\Games\\Rt\\first.exe"\r\n' > "${rt_game}/drive_c/Games/Rt/lpm-launch.bat"
printf 'title: T\nprompt: P\nentries:\n- label: One\n  workdir: C:\\Games\\Rt\n  exe: C:\\Games\\Rt\\first.exe\n- label: Two\n  workdir: C:\\Games\\Rt\n  exe: C:\\Games\\Rt\\second.exe\n' > "${rt_game}/lpm-launcher.yml"
printf 'Two' > "${rt_game}/.lpm-launcher-choice"
expect "runtime without bat_path: runs" bash "${repo}/lib/zgl-launcher-runtime.sh" "${rt_game}"
expect "runtime without bat_path: drive_c bat gets the choice" grep -q 'second.exe' "${rt_game}/drive_c/Games/Rt/lpm-launch.bat"
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/mario-1.yml"
rm -f "${HOME}/Games/mario/lpm-launcher.yml"
check "tools env set" 0 '' tools mario env set FOO bar
check "tools env list" 0 'FOO' tools mario env list
check "tools env set empty" 0 '' tools mario env set FOO ""
expect "YAML still valid" python3 -c "import sys,yaml; yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml'))"

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
hook_run() { bash -c 'source "$1/lib/zgu-desktop-utils.sh"; t() { echo "disabled by lpm"; }; zgu_apply_hook_policy "$2" "$3" broad' _ "${repo}" "${hook_yml}" "$1"; }
printf 'game:\n  exe: /y.exe\nsystem:\n  env:\n    GAMEID: umu-3\n  prefix_command: /a/scripts/lpm-winetrace.sh\n    /a/scripts/lpm-winetrace.log\nwine:\n  version: X\n' > "${hook_yml}"
hook_run false
expect "hook policy: wrapped value disabled, YAML valid, hook gone" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert "prefix_command" not in d["system"] and d["system"]["env"]["GAMEID"]=="umu-3" and d["wine"]["version"]=="X"' "${hook_yml}"
cp "${hook_yml}" "${hook_yml}.once"; hook_run false
expect "hook policy: disabling twice changes nothing" cmp -s "${hook_yml}" "${hook_yml}.once"
hook_run true
expect "hook policy: restore gives back the whole value" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["system"]["prefix_command"]=="/a/scripts/lpm-winetrace.sh /a/scripts/lpm-winetrace.log"' "${hook_yml}"
# File left broken by an older lpm: first line commented, second line orphan
printf 'game:\n  exe: /y.exe\nsystem:\n  env:\n    GAMEID: umu-3\n  # prefix_command: /a/x.sh  # lpm:hook-disabled (old)\n    /a/x.log\nwine:\n  version: X\n' > "${hook_yml}"
hook_run false
expect "hook policy: file broken by an older lpm is repaired" python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert "prefix_command" not in d["system"] and d["wine"]["version"]=="X"' "${hook_yml}"
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

# --- Pack: lpm's own window-detection relay is not exported, a command of the user stays
printf 'game:\n  exe: /y.exe\nsystem:\n  prefix_command: %s/Games/zelda/scripts/lpm-winetrace.sh %s/Games/zelda/scripts/lpm-winetrace.log gamemoderun\nwine:\n  version: GE-Test\n' "${HOME}" "${HOME}" > "${HOME}/.config/lutris/games/zelda-1.yml"
check "pack: relay + user command" 0 '\[EXPORTED\]' pack -3 zelda
expect "pack: relay removed, user command kept" bash -c 'zstd -dc "$1" | tar -xO "$(zstd -dc "$1" | tar -t | grep -m1 "zgp-game-config.yml$")" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); assert d[\"system\"][\"prefix_command\"]==\"gamemoderun\", d"' _ "${HOME}/Zelda.zgp"
rm -f "${HOME}/Zelda.zgp"
printf 'game:\n  exe: /x.exe\nsystem:\n  prefix_command: %s/Games/mario/scripts/lpm-winetrace.sh %s/Games/mario/scripts/lpm-winetrace.log\nwine:\n  version: GE-Test\n' "${HOME}" "${HOME}" > "${HOME}/.config/lutris/games/mario-1.yml"

# --- Full round trip: pack, uninstall, reinstall
check "pack" 0 '\[EXPORTED\]' pack -3 mario
expect "pack: relay only -> no prefix_command exported" bash -c '! zstd -dc "$1" | tar -xO "$(zstd -dc "$1" | tar -t | grep -m1 "zgp-game-config.yml$")" | grep -q prefix_command' _ "${HOME}/Mario.zgp"
expect "pack: .zgp created" test -s "${HOME}/Mario.zgp"
check "uninstall" 0 '\[REMOVED\] mario' uninstall -y mario
expect "uninstall: removed from the list" bash -c "! bash '${R}' list </dev/null | grep -q '^mario '"
expect "uninstall: folder deleted" test ! -e "${HOME}/Games/mario"
check "install" 0 '\[INSTALLED\] mario' install -y "${HOME}/Mario.zgp"
check "list after reinstall" 0 'mario +Mario' list

# --- Install removes Proton's "version" file from archives made before the export did it
mkdir -p "${HOME}/old-archive"
zstd -dc "${HOME}/Mario.zgp" | tar -x -C "${HOME}/old-archive"
echo "GE-Proton-test" > "${HOME}/old-archive/mario/version"
tar -C "${HOME}/old-archive" -cf - mario | zstd -q > "${HOME}/Mario-old.zgp"
check "uninstall before old archive" 0 '\[REMOVED\] mario' uninstall -y mario
check "install old archive" 0 '\[INSTALLED\] mario' install -y "${HOME}/Mario-old.zgp"
expect "install: Proton version file removed" test ! -e "${HOME}/Games/mario/version"
rm -rf "${HOME}/old-archive" "${HOME}/Mario-old.zgp"

# --- Completion: every documented command is offered (except advanced commands
#     intentionally absent from "lpm --help"), and options with values complete
hidden=" archives options lsfg-dll sgdb-images sgdb-key "
for page in "${repo}"/docs/commands/*.md; do
  cmd="$(basename "${page}" .md)"
  [[ "${hidden}" == *" ${cmd} "* ]] && continue
  expect "completion bash: ${cmd}" grep -qw -- "${cmd}" "${repo}/completions/lpm.bash"
  expect "completion zsh: ${cmd}" grep -qw -- "${cmd}" "${repo}/completions/_lpm"
done
printf '#!/bin/sh\nexec bash %s "$@"\n' "${R}" > "${HOME}/bin/lpm"; chmod +x "${HOME}/bin/lpm"
# shellcheck disable=SC1091
source "${repo}/completions/lpm.bash" 2>/dev/null
comp() { COMP_WORDS=("$@"); COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); COMPREPLY=(); _lpm 2>/dev/null; echo "${COMPREPLY[*]}"; }
expect "completion: -a offers win32/win64" bash -c '[[ "$1" == *win64* ]]' _ "$(comp lpm create-prefix -a "")"
expect "completion: -s offers the modes" bash -c '[[ "$1" == *desktop* ]]' _ "$(comp lpm shortcut -s "")"
expect "completion: --url for icon" bash -c '[[ "$1" == *--url* ]]' _ "$(comp lpm icon "--u")"
expect "completion: installed slugs" bash -c '[[ "$1" == *mario* ]]' _ "$(comp lpm uninstall "")"
expect "completion: tools offers the runner tool" bash -c '[[ "$1" == *runner* ]]' _ "$(comp lpm tools mario "")"
expect "completion: tools runner offers installed runners" bash -c '[[ "$1" == *GE-Test* ]]' _ "$(comp lpm tools mario runner "")"
expect "completion: vsync offers status and slugs" bash -c '[[ "$1" == *status* && "$1" == *mario* ]]' _ "$(comp lpm vsync "")"
expect "completion: vsync <slug> offers on/off" bash -c '[[ "$1" == *on* && "$1" == *off* ]]' _ "$(comp lpm vsync mario "")"
expect "completion: vsync on offers the settings" bash -c '[[ "$1" == *d3d9* && "$1" == *gl-mesa* ]]' _ "$(comp lpm vsync mario on "")"

# --- Gamepad shortcuts (Alt+Tab / F4 / Alt+Enter / F11 watcher), without a real gamepad
if python3 -c "import ctypes; ctypes.CDLL('libSDL2-2.0.so.0')" 2>/dev/null; then
  expect "gamepad: keys during the combo (X11 and Wayland)" python3 "${repo}/tests/gamepad_smoke.py"
else
  echo "(libSDL2 missing: gamepad test skipped)"
fi

# --- install.sh refuses to overwrite another program named "lpm" (tested only as root,
#     and only the refusal: it stops before copying anything, so nothing is touched)
if [[ "$(id -u)" -eq 0 ]]; then
  foreign_bin="${work}/foreign-bin"; mkdir -p "${foreign_bin}"
  printf '\177ELF other-program' > "${foreign_bin}/lpm"
  out="$(LPM_INSTALL_BIN_DIR="${foreign_bin}" bash "${repo}/install.sh" 2>&1)"; rc=$?
  expect "install.sh: refuses another program named lpm" bash -c '[[ "$1" -eq 1 && "$2" == *"is not Ludis Prefix Manager"* && "$2" == *"Nothing was installed"* ]]' _ "${rc}" "${out}"
  expect "install.sh: the other \"lpm\" is intact" grep -q 'other-program' "${foreign_bin}/lpm"
else
  echo "(not root: install.sh refusal test skipped)"
fi

# --- The log records errors
check "log" 0 'ERROR' log

# --- Uninstalling a game and a runner
check "uninstall zelda" 0 '\[REMOVED\] zelda' uninstall -y zelda
check "uninstall-runner" 0 '\[REMOVED\] GE-Test' uninstall-runner -y GE-Test
check "list-runner empty" 0 'No runner' list-runner

echo "CLI: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
