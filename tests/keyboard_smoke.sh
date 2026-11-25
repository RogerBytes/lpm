#!/bin/bash
# Virtual keyboard: gamepad navigation, shift (short press), shift lock (Y held), injected keys.
# Needs Xvfb, python3 with GTK4 (PYTHON=...) and SDL2.
cd "$(dirname "$0")/.." || exit 1
PYTHON="${PYTHON:-python3}"
"${PYTHON}" -c "import gi, sys; sys.path.insert(0, 'lib'); import zgu_common; sys.exit(0 if zgu_common.load_sdl2() else 1)" 2>/dev/null || { echo "SKIP: keyboard test (GTK4 or SDL2 missing)"; exit 0; }
work="$(mktemp -d)"; trap 'kill ${xpid} 2>/dev/null; rm -rf "${work}"' EXIT
Xvfb :98 -screen 0 1280x720x24 >/dev/null 2>&1 & xpid=$!; sleep 1
export DISPLAY=:98 GTK_A11Y=none XDG_RUNTIME_DIR="${work}" LUDIS_INJECT_LOG="${work}/inject.log" LUDIS_TEST_PREFIX="${work}"
# up, right -> letter key; Y held (lock) A; Y short (unlock) A; Y short (one capital) A; A
EVENTS="[(11,2500,150),(14,3000,150),(3,3500,900),(0,5000,150),(3,5500,150),(0,6000,150),(3,6500,150),(0,7000,150),(0,7600,150)]"
timeout 30 "${PYTHON}" tests/keyboard_pad.py lib/zgu-virtual-keyboard.py "${EVENTS}" >/dev/null 2>&1
expected=$'tap 42 16\ntap 16\ntap 42 16\ntap 16'
if [ "$(cat "${work}/inject.log" 2>/dev/null)" = "${expected}" ]; then echo "OK: keyboard: shift, shift lock and keys"; else echo "FAIL: keyboard"; cat "${work}/inject.log"; exit 1; fi
