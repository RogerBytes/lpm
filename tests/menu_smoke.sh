#!/usr/bin/env bash
# Tests of the in-game menu (lib/zgu-game-menu.py) in a throwaway Xvfb, driven with real key presses.
# xdotool is replaced (for the menu only) by a script that records the keys it is asked to send.
# Requires: xvfb, xdotool, dbus-run-session, python3 + PyGObject + GTK4 (Ubuntu 24.04: /usr/bin/python3.12).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/prefix"
real_xdotool="$(command -v xdotool || true)"
if [ -z "${real_xdotool}" ]; then echo "SKIP: xdotool not installed"; exit 0; fi
printf '#!/bin/sh\necho "$@" >> "%s/keys.log"\n' "${work}" > "${work}/bin/xdotool"
chmod +x "${work}/bin/xdotool"
py="${PYTHON:-/usr/bin/python3.12}"
[ -x "${py}" ] || py="$(command -v python3)"
export GTK_A11Y=none

# One scenario inside the Xvfb: $1 = expected keys, $2 = expected state (exited/running), rest = keys to press.
cat > "${work}/driver.sh" <<DRV
#!/bin/bash
rm -f "${work}/keys.log"
"${py}" "${repo}/lib/zgu-game-menu.py" x11 "${work}/prefix" >/dev/null 2>&1 &
pid=\$!
sleep 2
wid=\$("${real_xdotool}" search --name LPM | head -1)
[ -n "\${wid}" ] && "${real_xdotool}" windowfocus "\${wid}"
for k in "\$@"; do "${real_xdotool}" key "\${k}"; sleep 0.5; done
sleep 1.5
if kill -0 \${pid} 2>/dev/null; then echo "running"; kill \${pid}; else echo "exited"; fi
cat "${work}/keys.log" 2>/dev/null
DRV
chmod +x "${work}/driver.sh"

status=0
check() {  # name, expected output (state + keys, one per line), keys...
  local name="$1" want="$2"; shift 2
  local got
  got="$(PATH="${work}/bin:${PATH}" timeout -s KILL 60 xvfb-run -a dbus-run-session -- "${work}/driver.sh" "$@" 2>/dev/null | grep -vE 'dbus-daemon|^$')"
  if [ "${got}" = "${want}" ]; then echo "OK: ${name}"; else echo "FAILED: ${name}"; echo "  got:      ${got//$'\n'/ | }"; echo "  expected: ${want//$'\n'/ | }"; status=1; fi
}
check "menu: Window > Alt+Enter" $'exited\nkey alt+Return' Return Return
check "menu: Window > F11" $'exited\nkey F11' Return Down Return
check "menu: Quit > F4" $'exited\nkey F4' Down Return Return
check "menu: Quit > Esc" $'exited\nkey Escape' Down Return Down Return
check "menu: force quit asks a confirmation (No keeps the menu open)" "running" Down Return Down Down Return Down Return
check "menu: force quit > Yes closes the menu, no key sent" "exited" Down Return Down Down Return Return
check "menu: Escape goes back, then closes" "exited" Return Escape Escape
exit "${status}"
