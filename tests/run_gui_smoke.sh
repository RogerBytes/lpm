#!/usr/bin/env bash
# Runs tests/gui_smoke.py in a throwaway Xvfb, with a fake HOME, a fake "lutris" and a demo
# Lutris database. Requires: xvfb, dbus-run-session, python3 + PyGObject + GTK4 +
# libadwaita >= 1.5 (Ubuntu 24.04: /usr/bin/python3.12, packages gir1.2-gtk-4.0 gir1.2-adw-1).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp -r "${repo}" "${work}/repo"
chmod +x "${work}/repo/bin/lpm"
export HOME="${work}/home"
mkdir -p "${HOME}/bin" "${HOME}/.local/share/lutris/runners/wine/GE-Test" "${HOME}/.config/lutris/games" \
  "${HOME}/Games/mario" "${HOME}/Games/zelda" "${HOME}/.local/share/applications"
printf '#!/bin/sh\nexit 0\n' > "${HOME}/bin/lutris"; chmod +x "${HOME}/bin/lutris"
mkdir -p "${HOME}/.local/share/lutris/runners/wine/GE-Test/bin" "${HOME}/.local/share/lutris/runners/wine/GE-Other/bin"
for r in GE-Test GE-Other; do printf '#!/bin/sh\nexit 0\n' > "${HOME}/.local/share/lutris/runners/wine/${r}/bin/wine"; chmod +x "${HOME}/.local/share/lutris/runners/wine/${r}/bin/wine"; done
export PATH="${HOME}/bin:${PATH}"
sqlite3 "${HOME}/.local/share/lutris/pga.db" "create table games(id integer primary key,name text,slug text,runner text,directory text,configpath text,installer_slug text,parent_slug text,executable text,updated int,installed int,installed_at int);
insert into games(name,slug,runner,directory,configpath) values('Mario','mario','wine','${HOME}/Games/mario','mario-1'),('Zelda','zelda','wine','${HOME}/Games/zelda','zelda-1');"
printf 'game:\n  exe: /x.exe\nwine:\n  version: GE-Test\n' > "${HOME}/.config/lutris/games/mario-1.yml"
py="${PYTHON:-/usr/bin/python3.12}"
export GTK_A11Y=none
log="${work}/smoke.log"
status=0
xvfb-run -a dbus-run-session -- "${py}" "${work}/repo/tests/gui_smoke.py" >"${log}" 2>&1 || status=$?
grep -vE 'DRI3|dbus-daemon|^$' "${log}" || true
if [ "${status}" -ne 0 ]; then echo "FAILED: the test script exited with code ${status}" >&2; fi
# A traceback or critical GTK warning is a failure even if the script did not crash.
if grep -qE 'Traceback|-CRITICAL' "${log}"; then
  echo "FAILED: traceback or critical warning in the output" >&2
  exit 1
fi
exit "${status}"
