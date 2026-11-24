#!/usr/bin/env python3
# --- lpm launcher: opens the in-game LPM menu (gamepad combo or keyboard hotkey) ---
#
# Usage: zgu-gamepad-exit-watcher.py <x11|wayland> <prefix_folder>
#
# Historical name: this watcher used to be the "quit the game" combo. The combo now opens the
# LPM menu (lib/zgu-game-menu.py), whose "Quit the game" entry does what the combo used to do.
#
# Runs for the WHOLE game session (not single-use) and stops by itself once the game is over
# (no wineserver of the prefix any more, see zgu-prefix-watch.py).
#
# Gamepad: read through SDL2 WITHOUT EVIOCGRAB, so the game and remapping tools such as
# AntiMicro keep working. Default combo: L1 + R1 + L2 + R2 + L3 + R3 ALL pressed at once
# (chosen to avoid classic reset combos and cheat codes); configurable, see
# zgu_common.load_menu_conf (<XDG config>/lpm/menu.conf, one setting for every game). SDL2's
# bundled gamecontrollerdb gives every known pad the same standard layout.
#
# Keyboard (default Ctrl+Shift+M, same config file): read straight from /dev/input/event*
# (read-only, non-blocking), the only way that works on X11 AND Wayland (Wayland forbids global
# key capture). It needs read access to those files (usually group "input"); without it the
# keyboard hotkey is silently inactive and the gamepad combo keeps working.
#
# The menu is started once per trigger (rising edge) and never twice at the same time.
#
# Also here (same SDL reading): with the window-switch hold of zgu-gamepad-alttab-watcher.py
# (L1+L2+R1+R2+R3, no L3) pressed, D-pad UP opens the virtual keyboard (zgu-virtual-keyboard.py)
# and D-pad DOWN turns the gamepad mouse on / off (zgu-gamepad-mouse.py, a separate process that
# lives only while the mouse mode is on). The LPM menu asks for the same through a small command
# file (zgu_common.runtime_file("gamepad-cmd")).
#
# SYSTEM DEPENDENCY: the libSDL2 shared library ("libsdl2-2.0-0" on Debian/Ubuntu, "sdl2"
# on Arch, "SDL2" on Fedora). No extra Python package: libSDL2 is called through ctypes.

import sys
import os
import select
import signal
import struct
import subprocess
import time
# lib/ is the folder of this script: zgu_common.py sits next to it, whatever the way it is started.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_common import (
    close_keyboard_if_running,
    SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    SDL_CONTROLLER_BUTTON_DPAD_UP,
    SDL_CONTROLLER_AXIS_TRIGGERLEFT,
    SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_LEFTSTICK,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
    find_controllers,
    init_sdl,
    load_sdl2,
    load_menu_conf,
    parse_keyboard_hotkey,
    runtime_file,
)

if len(sys.argv) < 3 or sys.argv[1] not in ("x11", "wayland") or not sys.argv[2]:
    sys.stderr.write("Usage: zgu-gamepad-exit-watcher.py <x11|wayland> <prefix_folder>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]
PREFIX_DIR = os.path.realpath(sys.argv[2])

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

running = True

# Diagnostic log (the watcher runs detached, its output is discarded): what it found at start
# (keyboards opened or refused, gamepads), every trigger, and the menu's own errors.
LOG_PATH = os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share"),
    "lpm", "menu-watcher.log")


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        if os.path.getsize(LOG_PATH) > 200000:
            os.remove(LOG_PATH)
    except OSError:
        pass
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write("%s [%d] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), os.getpid(), message))
    except OSError:
        pass


def _load_prefix_watch():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "zgu_prefix_watch", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zgu-prefix-watch.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def handle_signal(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)



sdl = load_sdl2()
if sdl is None:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: libSDL2 not found "
        "(missing package: libsdl2-2.0-0 / sdl2 / SDL2)\n"
    )
    sys.exit(1)

if not init_sdl(sdl):
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_Init failed (%s)\n"
        % sdl.SDL_GetError().decode("utf-8", "replace")
    )
    sys.exit(1)
elif getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None) is None:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_GameControllerAddMappingsFromFile unavailable in "
        "this libSDL2 -- bundled database ignored, falling back to the installed library's built-in one.\n"
    )



# --- SDL2 standardized buttons/axes (SDL_GameControllerButton / SDL_GameControllerAxis,
# fixed numeric values of the C API, see SDL_gamecontroller.h). SDL2 translates every
# recognized gamepad to this fixed layout, whatever the model.
BUTTON_NAMES = {
    "L1": SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    "R1": SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    "L3": SDL_CONTROLLER_BUTTON_LEFTSTICK,
    "R3": SDL_CONTROLLER_BUTTON_RIGHTSTICK,
}
AXIS_NAMES = {"L2": SDL_CONTROLLER_AXIS_TRIGGERLEFT, "R2": SDL_CONTROLLER_AXIS_TRIGGERRIGHT}
DEFAULT_COMBO = "L1,R1,L2,R2,L3,R3"


def parse_combo(text):
    """"L1,R1,L2,..." -> (button codes, axis codes). An unknown or empty list falls back to
    the default combo: a typo in the config must never leave the menu unreachable."""
    names = [n.strip().upper() for n in (text or "").split(",") if n.strip()]
    if not names or any(n not in BUTTON_NAMES and n not in AXIS_NAMES for n in names):
        names = DEFAULT_COMBO.split(",")
    return (tuple(BUTTON_NAMES[n] for n in names if n in BUTTON_NAMES),
            tuple(AXIS_NAMES[n] for n in names if n in AXIS_NAMES))


MENU_CONF = load_menu_conf()
COMBO_BUTTONS, COMBO_AXES = parse_combo(MENU_CONF["gamepad_combo"])
KEYBOARD_HOTKEY = parse_keyboard_hotkey(MENU_CONF["keyboard_hotkey"], resolve=True)
AXIS_PULL_THRESHOLD = int(32767 * 0.9)  # trigger counts as pressed beyond 90% of its travel
POLL_INTERVAL_SECONDS = 0.05
# Re-scan connected gamepads about once per second (not on every 50ms tick); see the
# comment in main() below.
RESCAN_INTERVAL_LOOPS = max(1, round(1.0 / POLL_INTERVAL_SECONDS))

MENU_SCRIPT = os.path.join(SCRIPT_DIR, "zgu-game-menu.py")


class MenuLauncher:
    """Starts the menu (separate GTK process), never twice at once."""

    def __init__(self):
        self.proc = None

    def is_open(self):
        if self.proc is not None and self.proc.poll() is not None:
            log("menu ended with code %s" % self.proc.returncode)
            self.proc = None
        return self.proc is not None

    def open(self, source):
        if self.is_open():
            return
        log("menu requested by %s: starting %s" % (source, MENU_SCRIPT))
        try:
            os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
            err = open(LOG_PATH, "a", encoding="utf-8")
        except OSError:
            err = subprocess.DEVNULL
        try:
            self.proc = subprocess.Popen(
                [sys.executable, MENU_SCRIPT, SESSION_KIND, PREFIX_DIR],
                stdin=subprocess.DEVNULL, stdout=err, stderr=err)
        except OSError as exc:
            log("menu start failed: %s" % exc)
            self.proc = None

    def close(self):
        if self.is_open():
            try:
                self.proc.terminate()
            except OSError:
                pass


KEYBOARD_SCRIPT = os.path.join(SCRIPT_DIR, "zgu-virtual-keyboard.py")
MOUSE_SCRIPT = os.path.join(SCRIPT_DIR, "zgu-gamepad-mouse.py")
TOAST_SCRIPT = os.path.join(SCRIPT_DIR, "zgu-toast.py")
CMD_FILE = runtime_file("gamepad-cmd")
MOUSE_STATE_FILE = runtime_file("gamepad-mouse")


def start_detached(script):
    """Starts one of the GUI helpers (own session, output to the diagnostic log)."""
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        err = open(LOG_PATH, "a", encoding="utf-8")
    except OSError:
        err = subprocess.DEVNULL
    try:
        return subprocess.Popen([sys.executable, script, SESSION_KIND, PREFIX_DIR],
                                stdin=subprocess.DEVNULL, stdout=err, stderr=err, start_new_session=True)
    except OSError as exc:
        log("cannot start %s: %s" % (os.path.basename(script), exc))
        return None


def show_toast(on):
    """Brief notice (top right) that the gamepad mouse was turned on / off."""
    label = os.environ.get("LPM_MENU_MOUSE", "").strip() or "Gamepad mouse"
    state = (os.environ.get("LPM_MENU_ON", "").strip() or "on") if on else (os.environ.get("LPM_MENU_OFF", "").strip() or "off")
    try:
        subprocess.Popen([sys.executable, TOAST_SCRIPT, SESSION_KIND, "%s: %s" % (label, state)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError as exc:
        log("cannot show the notice: %s" % exc)


class MouseMode:
    """The gamepad mouse: a separate process that lives only while the mode is on."""

    def __init__(self):
        self.proc = None

    def is_on(self):
        if self.proc is not None and self.proc.poll() is not None:
            log("gamepad mouse ended with code %s" % self.proc.returncode)
            self.proc = None
            self._state(False)
        return self.proc is not None

    @staticmethod
    def _state(on):
        try:
            if on:
                open(MOUSE_STATE_FILE, "w").close()
            elif os.path.exists(MOUSE_STATE_FILE):
                os.remove(MOUSE_STATE_FILE)
        except OSError:
            pass

    def toggle(self):
        if self.is_on():
            self.stop()
            return
        self.proc = start_detached(MOUSE_SCRIPT)
        if self.proc is not None:
            log("gamepad mouse ON")
            self._state(True)
            show_toast(True)

    def stop(self):
        if self.proc is not None:
            log("gamepad mouse OFF")
            show_toast(False)
            try:
                self.proc.terminate()
            except OSError:
                pass
            self.proc = None
        self._state(False)


def take_command():
    """Command left by the LPM menu in CMD_FILE (one word), or "" ."""
    try:
        with open(CMD_FILE, encoding="utf-8") as f:
            command = f.read().strip()
        os.remove(CMD_FILE)
        return command
    except OSError:
        return ""


def window_hold_active(sdl_, pads):
    """The window-switch hold of zgu-gamepad-alttab-watcher.py: L1 + R1 + R3 + L2 + R2, WITHOUT L3."""
    for pad in pads:
        if (sdl_.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_LEFTSHOULDER)
                and sdl_.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)
                and sdl_.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_RIGHTSTICK)
                and not sdl_.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_LEFTSTICK)
                and sdl_.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_TRIGGERLEFT) >= AXIS_PULL_THRESHOLD
                and sdl_.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) >= AXIS_PULL_THRESHOLD):
            return pad
    return None


class KeyboardHotkey:
    """Reads the keyboards through /dev/input/event* (see file header). Devices come from
    /proc/bus/input/devices (a "kbd" handler and key repeat = a real keyboard); an unreadable
    device is skipped, so with no access this simply never triggers."""

    EVENT = struct.Struct("llHHi")  # struct input_event (64-bit Linux)
    EV_KEY = 1

    def __init__(self, hotkey):
        self.hotkey = hotkey
        self.fds = {}
        self.down = set()
        self.next_scan = 0.0
        self.refused = set()
        self.logged_codes = set()
        self.reported_none = False

    def _event_paths(self):
        paths = []
        try:
            with open("/proc/bus/input/devices", encoding="utf-8", errors="replace") as f:
                blocks = f.read().split("\n\n")
        except OSError:
            return paths
        for block in blocks:
            handlers = ev = ""
            for line in block.splitlines():
                if line.startswith("H: Handlers="):
                    handlers = line.split("=", 1)[1]
                elif line.startswith("B: EV="):
                    ev = line.split("=", 1)[1].strip()
            try:
                ev_bits = int(ev, 16)
            except ValueError:
                continue
            if "kbd" in handlers.split() and ev_bits & (1 << 20):  # EV_REP: has key repeat
                for word in handlers.split():
                    if word.startswith("event"):
                        paths.append("/dev/input/" + word)
        return paths

    def rescan(self):
        wanted = set(self._event_paths())
        for path in list(self.fds):
            if path not in wanted:
                self._drop(path)
        for path in wanted - set(self.fds):
            try:
                self.fds[path] = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                log("keyboard opened: %s" % path)
            except OSError as exc:
                if path not in self.refused:
                    self.refused.add(path)
                    log("keyboard NOT readable: %s (%s)" % (path, exc))
        if not wanted and not self.reported_none:
            self.reported_none = True
            log("no keyboard found in /proc/bus/input/devices")

    def _drop(self, path):
        fd = self.fds.pop(path, None)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

    def close(self):
        for path in list(self.fds):
            self._drop(path)

    def _mods_down(self):
        return all(any(c in self.down for c in pair) for pair in self.hotkey[0])

    def _hotkey_down(self):
        mods, key = self.hotkey
        return key in self.down and all(any(c in self.down for c in pair) for pair in mods)

    def poll(self, timeout):
        """Waits up to `timeout` seconds for key events; True on the rising edge of the hotkey."""
        now = time.monotonic()
        if now >= self.next_scan:
            self.next_scan = now + 2.0
            self.rescan()
        if not self.fds:
            time.sleep(timeout)
            return False
        triggered = False
        try:
            ready, _, _ = select.select(list(self.fds.values()), [], [], timeout)
        except (OSError, ValueError):
            self.next_scan = 0.0
            return False
        for fd in ready:
            try:
                data = os.read(fd, self.EVENT.size * 64)
            except BlockingIOError:
                continue
            except OSError:
                self.next_scan = 0.0  # device unplugged: rescan
                continue
            for off in range(0, len(data) - self.EVENT.size + 1, self.EVENT.size):
                _s, _u, etype, code, value = self.EVENT.unpack_from(data, off)
                if etype == self.EV_KEY:
                    was_down = self._hotkey_down()
                    if value:
                        self.down.add(code)
                    else:
                        self.down.discard(code)
                    if self._hotkey_down() and not was_down:
                        triggered = True  # rising edge, event by event
                    elif value == 1 and code not in self.logged_codes and self._mods_down():
                        # Diagnostic: the modifiers are down but this is not the hotkey's key
                        # (typically a keyboard layout whose key codes differ).
                        self.logged_codes.add(code)
                        log("modifiers down + key code %d pressed (hotkey expects code %d)" % (code, self.hotkey[1]))
        return triggered


def count_available_controllers():
    """Count the gamepads SDL2 recognizes WITHOUT opening them, only to detect a change
    before calling find_controllers(sdl) again (see main())."""
    return sum(1 for i in range(sdl.SDL_NumJoysticks()) if sdl.SDL_IsGameController(i))


def combo_complete(pads):
    for pad in pads:
        buttons_ok = all(
            sdl.SDL_GameControllerGetButton(pad, code) for code in COMBO_BUTTONS
        )
        axes_ok = all(
            sdl.SDL_GameControllerGetAxis(pad, code) >= AXIS_PULL_THRESHOLD
            for code in COMBO_AXES
        )
        if buttons_ok and axes_ok:
            return True
    return False


def main():
    # "pads" must not be detected only once at startup: if no gamepad is ready at that
    # instant (Bluetooth still reconnecting, wireless dongle negotiating, game launching
    # faster than the pad), exiting would leave the combo unreachable for the whole session.
    # Reading is passive and nearly free (see file header), so keep running and re-scan
    # periodically (RESCAN_INTERVAL_LOOPS, ~1x/s). This also covers a pad that disconnects
    # and reconnects mid-game. The comparison is deliberately simple (number of recognized
    # gamepads, not a per-GUID match); enough since lpm assumes one player/one gamepad.
    pads = find_controllers(sdl)
    loops_since_rescan = 0
    game_watch = _load_prefix_watch().GameEndWatch(PREFIX_DIR)
    menu = MenuLauncher()
    log("hotkey key code on this keyboard layout: %s" % (KEYBOARD_HOTKEY[1] if KEYBOARD_HOTKEY else "disabled"))
    log("start: session=%s prefix=%s gamepads=%d combo=%s hotkey=%s python=%s" % (
        SESSION_KIND, PREFIX_DIR, len(pads), MENU_CONF["gamepad_combo"], MENU_CONF["keyboard_hotkey"],
        sys.executable))
    keyboard = KeyboardHotkey(KEYBOARD_HOTKEY) if KEYBOARD_HOTKEY else None
    combo_was_down = True  # a combo already held at start must be released first
    mouse = MouseMode()
    take_command()  # drop a command left by a previous session
    mouse._state(False)
    prev_up = prev_down = True  # D-pad directions held at start do nothing

    try:
        while running:
            if game_watch.game_ended():
                log("game ended, stopping")
                return
            sdl.SDL_GameControllerUpdate()

            loops_since_rescan += 1
            if loops_since_rescan >= RESCAN_INTERVAL_LOOPS:
                loops_since_rescan = 0
                if count_available_controllers() != len(pads):
                    for pad in pads:
                        try:
                            sdl.SDL_GameControllerClose(pad)
                        except Exception:
                            pass
                    pads = find_controllers(sdl)

            hold_pad = window_hold_active(sdl, pads) if pads else None
            if hold_pad is not None:
                up = bool(sdl.SDL_GameControllerGetButton(hold_pad, SDL_CONTROLLER_BUTTON_DPAD_UP))
                down = bool(sdl.SDL_GameControllerGetButton(hold_pad, SDL_CONTROLLER_BUTTON_DPAD_DOWN))
                if down and not prev_down:  # down: the keyboard appears at the bottom of the screen
                    if close_keyboard_if_running():
                        log("virtual keyboard closed by gamepad")
                    else:
                        log("virtual keyboard requested by gamepad")
                        start_detached(KEYBOARD_SCRIPT)
                if up and not prev_up:
                    mouse.toggle()
                prev_up, prev_down = up, down
            else:
                prev_up = prev_down = True  # outside the hold: a direction held when it starts is ignored
            command = take_command()
            if command == "mouse-toggle":
                mouse.toggle()
            mouse.is_on()  # notices a mouse process that ended by itself

            combo_down = bool(pads) and combo_complete(pads)
            if combo_down and not combo_was_down:
                menu.open("gamepad combo")
            combo_was_down = combo_down

            if keyboard is not None:
                if keyboard.poll(POLL_INTERVAL_SECONDS):
                    if close_keyboard_if_running():  # the virtual keyboard is open: the hotkey closes it
                        log("virtual keyboard closed by the keyboard hotkey")
                    else:
                        menu.open("keyboard hotkey")
            else:
                time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        mouse.stop()
        for leftover in (CMD_FILE, runtime_file("overlay-armed"), runtime_file("overlay-visible")):
            try:
                os.remove(leftover)  # nothing of this game session must stay for the next one
            except OSError:
                pass
        menu.close()
        if keyboard is not None:
            keyboard.close()
        for pad in pads:
            try:
                sdl.SDL_GameControllerClose(pad)
            except Exception:
                pass
        sdl.SDL_Quit()


if __name__ == "__main__":
    main()
