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
printf '#!/bin/sh\n[ "$1" = key ] && echo "$@" >> "%s/keys.log"\nexit 0\n' "${work}" > "${work}/bin/xdotool"
chmod +x "${work}/bin/xdotool"
py="${PYTHON:-/usr/bin/python3.12}"
[ -x "${py}" ] || py="$(command -v python3)"
export GTK_A11Y=none
export XDG_RUNTIME_DIR="${work}/run"
mkdir -p "${XDG_RUNTIME_DIR}"

# One scenario inside the Xvfb: $1 = expected keys, $2 = expected state (exited/running), rest = keys to press.
cat > "${work}/driver.sh" <<DRV
#!/bin/bash
rm -f "${work}/keys.log" "${work}"/run/lpm-gamepad-cmd-*
if [ -n "\${FAKE_GAME:-}" ]; then
  ln -sf /bin/sleep "${work}/wineserver"
  WINEPREFIX="${work}/prefix" "${work}/wineserver" "\${FAKE_GAME}" &
  sleep 0.5
fi
"${py}" "${repo}/lib/zgu-game-menu.py" x11 "${work}/prefix" >/dev/null 2>&1 &
pid=\$!
sleep 2
wid=\$("${real_xdotool}" search --name LPM | head -1)
[ -n "\${wid}" ] && "${real_xdotool}" windowfocus "\${wid}"
for k in "\$@"; do
  if [ "\${k}" = "click-corner" ]; then "${real_xdotool}" mousemove 5 5 click 1; else "${real_xdotool}" key "\${k}"; fi
  sleep 0.5
done
if [ -n "\${OTHER_WINDOW:-}" ]; then  # focus another window, as a click on the game would
  "${py}" -c "
import gi; gi.require_version('Gtk','4.0')
from gi.repository import Gtk, GLib
a = Gtk.Application(application_id='x.other')
a.connect('activate', lambda app: (Gtk.ApplicationWindow(application=app, title='OTHERWIN').present(), GLib.timeout_add(8000, app.quit)))
a.run([])" >/dev/null 2>&1 &
  sleep 1.5
  ow=\$("${real_xdotool}" search --name OTHERWIN | head -1)
  [ -n "\${ow}" ] && "${real_xdotool}" windowfocus "\${ow}"
fi
sleep "\${WAIT:-1.5}"
if kill -0 \${pid} 2>/dev/null; then echo "running"; kill \${pid}; else echo "exited"; fi
cat "${work}/keys.log" 2>/dev/null
[ -f "${work}/run/lpm-gamepad-cmd-\$(id -u)" ] && echo "cmd: \$(cat "${work}/run/lpm-gamepad-cmd-\$(id -u)")"
DRV
chmod +x "${work}/driver.sh"

status=0
check() {  # name, expected output (state + keys, one per line), keys... (env: FAKE_GAME, OTHER_WINDOW, WAIT)
  local name="$1" want="$2"; shift 2
  local got
  got="$(PATH="${work}/bin:${PATH}" timeout -s KILL 60 xvfb-run -a dbus-run-session -- "${work}/driver.sh" "$@" 2>/dev/null | grep -vE 'dbus-daemon|^$')"
  if [ "${got}" = "${want}" ]; then echo "OK: ${name}"; else echo "FAILED: ${name}"; echo "  got:      ${got//$'\n'/ | }"; echo "  expected: ${want//$'\n'/ | }"; status=1; fi
}
check "menu: Window > Alt+Enter" $'exited\nkey alt+Return' Return Return
check "menu: Window > F4 (alone)" $'exited\nkey F4' Return Down Return
check "menu: Window > F11" $'exited\nkey F11' Return Down Down Return
check "menu: Quit > Esc is sent and the menu closes" $'exited\nkey Escape' Down Down Down Return Return
check "menu: Quit > Alt+F4 asks a confirmation, then sends it" $'exited\nkey alt+F4' Down Down Down Return Down Return Return
check "menu: Alt+F4 > No keeps the menu open, nothing sent" "running" Down Down Down Return Down Return Down Return
check "menu: force quit asks a confirmation (No keeps the menu open)" "running" Down Down Down Return Down Down Return Down Return
check "menu: force quit > Yes closes the menu, no key sent" "exited" Down Down Down Return Down Down Return Return
check "menu: Gamepad mouse is a switch: asks the watcher to toggle it, menu stays open" $'running\ncmd: mouse-toggle' Down Down Return
FAKE_GAME=3 WAIT=9 check "menu: closes by itself once the game is gone" "exited" Down
OTHER_WINDOW=1 check "menu: closes when the focus goes elsewhere" "exited" Return
LPM_MENU_FORCE_VEIL=1 check "menu (fullscreen veil): Window > Alt+Enter" $'exited\nkey alt+Return' Return Return
LPM_MENU_FORCE_VEIL=1 check "menu (fullscreen veil): a click on the veil closes it" "exited" click-corner
check "menu: Escape goes back, then closes" "exited" Return Escape Escape
exit "${status}"
