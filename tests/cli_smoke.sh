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
    echo "ECHEC: ${name} (attendu rc=${want_rc} /${want_re}/, obtenu rc=${rc})" >&2
    sed 's/^/    | /' <<<"${out}" | head -8 >&2
  fi
}
# expect "name" <shell test command>
expect() {
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ECHEC: ${name}" >&2; fi
}

# --- General
check "version" 0 '^lpm v[0-9]' --version
check "commande inconnue" 1 'Unknown command' bogus
check "sans argument: aide, code 0" 0 'lpm vsync' 
check "list" 0 'mario +Mario' list
check "list (zelda)" 0 'zelda +Zelda' list
check "list-runner" 0 'GE-Test' list-runner
check "list-isolable" 0 'No isolable|Nothing' list-isolable
check "isolate sans store partagé" 0 'Nothing to isolate' isolate
check "sgdb-key get" 0 '"key"' sgdb-key get
check "lsfg status" 0 '"installed"' lsfg status
check "self-update: argument invalide" 1 'Invalid argument' self-update bogus
check "check: rapport structuré" 0 '\[REPORT\] ok\|' check
check "info" 0 'Slug +: mario' info mario
check "info: slug inconnu" 1 'no installed game' info nosuch
check "info: sans slug" 1 'provide a slug' info

# --- Missing target: clear error and exit code 1, never a false success
for cmd in install pack pack-runner uninstall uninstall-runner install-runner shortcut; do
  check "${cmd}: cible manquante" 1 'nothing to do' "${cmd}"
done
check "uninstall -y sans cible" 1 'nothing to do' uninstall -y
check "install: fichier introuvable" 1 'not found' install -y /nonexistent.zgp
check "uninstall: slug inconnu" 1 'not found' uninstall -y nosuch
check "uninstall-runner: inconnu" 1 'could not be found' uninstall-runner -y nosuch

# --- Launcher and tools (Lutris YAML editing)
check "launcher on" 0 'enabled' launcher mario on
expect "launcher on: fichier créé" test -f "${HOME}/Games/mario/lpm-launcher.yml"
check "launcher off" 0 'disabled' launcher mario off
check "tools env set" 0 '' tools mario env set FOO bar
check "tools env list" 0 'FOO' tools mario env list
check "tools env set vide" 0 '' tools mario env set FOO ""
expect "YAML toujours valide" python3 -c "import sys,yaml; yaml.safe_load(open('${HOME}/.config/lutris/games/mario-1.yml'))"

# --- Change a game's runner ("runner" tool): tested on zelda
mkdir -p "${HOME}/.local/share/lutris/runners/wine/GE-Other/files/bin"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/.local/share/lutris/runners/wine/GE-Other/files/bin/wine"
chmod +x "${HOME}/.local/share/lutris/runners/wine/GE-Other/files/bin/wine"
printf 'game:\n  exe: /y.exe\n# lpm:hook-disabled garde-moi\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/zelda-1.yml"
check "runner: changement" 0 "changed to 'GE-Other'" tools zelda runner GE-Other
expect "runner: info affiche le nouveau runner" bash -c 'bash "$1" info zelda </dev/null | grep -q "GE-Other"' _ "${R}"
expect "runner: commentaire YAML conservé" grep -q 'lpm:hook-disabled' "${HOME}/.config/lutris/games/zelda-1.yml"
check "runner: non installé" 1 'is not installed' tools zelda runner NoSuchRunner
check "runner: sans nom" 1 'name of an installed runner' tools zelda runner
check "runner: nom avec /" 1 'name of an installed runner' tools zelda runner ../x
check "runner: slug inconnu" 1 'no installed game' tools nosuch runner GE-Other
mkdir -p "${HOME}/.local/share/lutris/runners/wine/GE-Temp/bin"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/.local/share/lutris/runners/wine/GE-Temp/bin/wine"; chmod +x "${HOME}/.local/share/lutris/runners/wine/GE-Temp/bin/wine"
check "runner: vers un runner temporaire" 0 "changed to 'GE-Temp'" tools zelda runner GE-Temp
rm -rf "${HOME}/.local/share/lutris/runners/wine/GE-Temp"
check "runner: les autres outils refusent un runner disparu" 1 'no longer installed' tools zelda folder
check "runner: mais le changement de runner marche quand même" 0 "changed to 'GE-Test'" tools zelda runner GE-Test
check "runner: les outils refonctionnent ensuite" 0 'saved' tools zelda env set RUNNER_OK 1
rm -rf "${HOME}/.local/share/lutris/runners/wine/GE-Other"

# --- VSync (per-game environment variables): tested on zelda, a YAML comment must survive
zelda_yml="${HOME}/.config/lutris/games/zelda-1.yml"
printf 'game:\n  exe: /y.exe\n# lpm:hook-disabled garde-moi\nwine:\n  version: GE-Test\n' > "${zelda_yml}"
vsync_out() { bash "${R}" vsync "$@" </dev/null 2>&1; }
check "vsync status: aucun jeu" 0 '' vsync status
expect "vsync status: liste vide" bash -c '[[ -z "$(bash "$1" vsync status </dev/null 2>&1)" ]]' _ "${R}"
check "vsync: état initial" 0 'd3d9=off' vsync zelda
check "vsync: état explicite" 0 'gl-mesa=off' vsync zelda status
check "vsync on d3d9" 0 'enabled' vsync zelda on d3d9
expect "vsync: d3d9 actif, d3d11 inactif" bash -c 'o="$(bash "$1" vsync zelda </dev/null)"; grep -qx "d3d9=on" <<<"$o" && grep -qx "d3d11=off" <<<"$o"' _ "${R}"
check "vsync status: liste zelda" 0 '^zelda$' vsync status
expect "vsync status: pas mario" bash -c '! bash "$1" vsync status </dev/null | grep -q mario' _ "${R}"
check "tools env: DXVK_CONFIG existant" 0 '' tools zelda env set DXVK_CONFIG "dxgi.hideAmdGpu = True"
check "vsync on (tout)" 0 'enabled' vsync zelda on
expect "vsync: les 5 actifs" bash -c '[[ "$(bash "$1" vsync zelda </dev/null | grep -c "=on")" -eq 5 ]]' _ "${R}"
expect "vsync: DXVK_CONFIG fusionné, option existante conservée" bash -c 'o="$(bash "$1" tools zelda env list </dev/null)"; grep -q "^DXVK_CONFIG=.*hideAmdGpu = True" <<<"$o" && grep -q "^DXVK_CONFIG=.*dxgi.syncInterval = 0" <<<"$o" && grep -q "^DXVK_CONFIG=.*d3d9.presentInterval = 0" <<<"$o"' _ "${R}"
expect "vsync: autres variables posées" bash -c 'o="$(bash "$1" tools zelda env list </dev/null)"; grep -qx "VKD3D_SWAPCHAIN_PRESENT_MODE=IMMEDIATE" <<<"$o" && grep -qx "__GL_SYNC_TO_VBLANK=0" <<<"$o" && grep -qx "vblank_mode=0" <<<"$o"' _ "${R}"
check "vsync on: idempotent" 0 'enabled' vsync zelda on
expect "vsync on x2: DXVK_CONFIG sans doublon" bash -c '[[ "$(bash "$1" tools zelda env list </dev/null | grep "^DXVK_CONFIG=" | grep -o "dxgi.syncInterval" | wc -l)" -eq 1 ]]' _ "${R}"
check "vsync off d3d9" 0 'removed' vsync zelda off d3d9
expect "vsync off d3d9: d3d11 reste actif" bash -c 'o="$(bash "$1" vsync zelda </dev/null)"; grep -qx "d3d9=off" <<<"$o" && grep -qx "d3d11=on" <<<"$o"' _ "${R}"
check "tools env: valeur personnalisée d3d12" 0 '' tools zelda env set VKD3D_SWAPCHAIN_PRESENT_MODE MAILBOX
check "vsync off (tout)" 0 'removed' vsync zelda off
expect "vsync off: plus aucun réglage actif" bash -c '! bash "$1" vsync zelda </dev/null | grep -q "=on"' _ "${R}"
expect "vsync off: DXVK_CONFIG garde l'option non VSync" bash -c 'bash "$1" tools zelda env list </dev/null | grep -qx "DXVK_CONFIG=dxgi.hideAmdGpu = True"' _ "${R}"
expect "vsync off: valeur personnalisée jamais touchée" bash -c 'bash "$1" tools zelda env list </dev/null | grep -qx "VKD3D_SWAPCHAIN_PRESENT_MODE=MAILBOX"' _ "${R}"
check "tools env: retire DXVK_CONFIG" 0 '' tools zelda env unset DXVK_CONFIG
check "vsync on d3d11 seul" 0 'enabled' vsync zelda on d3d11
check "vsync off d3d11: DXVK_CONFIG supprimée si vide" 0 'removed' vsync zelda off d3d11
expect "vsync: DXVK_CONFIG absente après retrait" bash -c '! bash "$1" tools zelda env list </dev/null | grep -q "^DXVK_CONFIG="' _ "${R}"
expect "vsync: commentaire YAML conservé" grep -q 'lpm:hook-disabled garde-moi' "${zelda_yml}"
expect "vsync: YAML toujours valide" python3 -c "import yaml; yaml.safe_load(open('${zelda_yml}'))"
check "vsync: réglage inconnu" 1 "unknown setting 'bogus'" vsync zelda on bogus
check "vsync: action inconnue" 1 "unknown action" vsync zelda toggle
check "vsync: status avec réglage" 1 'Usage' vsync zelda status d3d9
check "vsync: slug inconnu" 1 'no installed game' vsync nosuch on
check "vsync: sans argument" 1 'Usage' vsync

# --- Shortcut
check "shortcut" 0 'Shortcut created' shortcut mario
expect "shortcut: .desktop créé" test -f "${HOME}/.local/share/applications/net.lutris.mario.desktop"
check "shortcut: slug inconnu" 1 'not found' shortcut nosuch

# --- Full round trip: pack, uninstall, reinstall
check "pack" 0 '\[EXPORTED\]' pack -3 mario
expect "pack: .zgp créé" test -s "${HOME}/Mario.zgp"
check "uninstall" 0 '\[REMOVED\] mario' uninstall -y mario
expect "uninstall: retiré de la liste" bash -c "! bash '${R}' list </dev/null | grep -q '^mario '"
expect "uninstall: dossier supprimé" test ! -e "${HOME}/Games/mario"
check "install" 0 '\[INSTALLED\] mario' install -y "${HOME}/Mario.zgp"
check "list après réinstallation" 0 'mario +Mario' list

# --- Completion: every documented command is offered (except advanced commands
#     intentionally absent from "lpm --help"), and options with values complete
hidden=" archives options lsfg-dll sgdb-images sgdb-key "
for page in "${repo}"/docs/commands/*.md; do
  cmd="$(basename "${page}" .md)"
  [[ "${hidden}" == *" ${cmd} "* ]] && continue
  expect "complétion bash: ${cmd}" grep -qw -- "${cmd}" "${repo}/completions/lpm.bash"
  expect "complétion zsh: ${cmd}" grep -qw -- "${cmd}" "${repo}/completions/_lpm"
done
printf '#!/bin/sh\nexec bash %s "$@"\n' "${R}" > "${HOME}/bin/lpm"; chmod +x "${HOME}/bin/lpm"
# shellcheck disable=SC1091
source "${repo}/completions/lpm.bash" 2>/dev/null
comp() { COMP_WORDS=("$@"); COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); COMPREPLY=(); _lpm 2>/dev/null; echo "${COMPREPLY[*]}"; }
expect "complétion: -a propose win32/win64" bash -c '[[ "$1" == *win64* ]]' _ "$(comp lpm create-prefix -a "")"
expect "complétion: -s propose les modes" bash -c '[[ "$1" == *desktop* ]]' _ "$(comp lpm shortcut -s "")"
expect "complétion: --url pour icon" bash -c '[[ "$1" == *--url* ]]' _ "$(comp lpm icon "--u")"
expect "complétion: slugs installés" bash -c '[[ "$1" == *mario* ]]' _ "$(comp lpm uninstall "")"
expect "complétion: tools propose l'outil runner" bash -c '[[ "$1" == *runner* ]]' _ "$(comp lpm tools mario "")"
expect "complétion: tools runner propose les runners installés" bash -c '[[ "$1" == *GE-Test* ]]' _ "$(comp lpm tools mario runner "")"
expect "complétion: vsync propose status et les slugs" bash -c '[[ "$1" == *status* && "$1" == *mario* ]]' _ "$(comp lpm vsync "")"
expect "complétion: vsync <slug> propose on/off" bash -c '[[ "$1" == *on* && "$1" == *off* ]]' _ "$(comp lpm vsync mario "")"
expect "complétion: vsync on propose les réglages" bash -c '[[ "$1" == *d3d9* && "$1" == *gl-mesa* ]]' _ "$(comp lpm vsync mario on "")"

# --- Gamepad shortcuts (Alt+Tab / F4 / Alt+Enter / F11 watcher), without a real gamepad
if python3 -c "import ctypes; ctypes.CDLL('libSDL2-2.0.so.0')" 2>/dev/null; then
  expect "manette: touches pendant le combo (X11 et Wayland)" python3 "${repo}/tests/gamepad_smoke.py"
else
  echo "(libSDL2 absente : test manette ignoré)"
fi

# --- install.sh refuses to overwrite another program named "lpm" (tested only as root,
#     and only the refusal: it stops before copying anything, so nothing is touched)
if [[ "$(id -u)" -eq 0 ]]; then
  foreign_bin="${work}/foreign-bin"; mkdir -p "${foreign_bin}"
  printf '\177ELF autre-programme' > "${foreign_bin}/lpm"
  out="$(LPM_INSTALL_BIN_DIR="${foreign_bin}" bash "${repo}/install.sh" 2>&1)"; rc=$?
  expect "install.sh: refuse un autre « lpm »" bash -c '[[ "$1" -eq 1 && "$2" == *"pas Ludis Prefix Manager"* && "$2" == *"Rien n'"'"'a été installé"* ]]' _ "${rc}" "${out}"
  expect "install.sh: l'autre « lpm » est intact" grep -q 'autre-programme' "${foreign_bin}/lpm"
else
  echo "(pas root : test du refus d'install.sh ignoré)"
fi

# --- The log records errors
check "log" 0 'ERREUR|ERROR' log

# --- Uninstalling a game and a runner
check "uninstall zelda" 0 '\[REMOVED\] zelda' uninstall -y zelda
check "uninstall-runner" 0 '\[REMOVED\] GE-Test' uninstall-runner -y GE-Test
check "list-runner vide" 0 'No runner' list-runner

echo "CLI: ${pass} ok, ${fail} échec(s)"
[[ "${fail}" -eq 0 ]]
