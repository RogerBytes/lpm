#!/usr/bin/env python3
# --- lpm launcher: gamepad mouse (both sticks move the cursor), via SDL2 ---
#
# Usage: zgu-gamepad-mouse.py <x11|wayland> <prefix_folder>
#
# Started by zgu-gamepad-exit-watcher.py when the mouse mode is turned on (LPM menu, or
# L1+L2+R1+R2+R3 held then D-pad down) and stopped (SIGTERM) when it is turned off. It also
# stops by itself when the game is over (see zgu-prefix-watch.py).
#
# Both sticks move the cursor independently and their movements ADD UP: both going the same
# way = twice as fast, opposite ways cancel out.
#   A = left click   B = right click   Y = middle click   X = Enter   Start = Escape
#   L1 = wheel up    R1 = wheel down (repeats while held)
#
# Read through SDL2 without grabbing the pad, like the other watchers: the game still receives
# the same buttons. While the L1+R1+R3 + triggers "hold" of the window switch is pressed, the
# buttons below do nothing (L1/R1 would otherwise scroll).
#
# Events: XTest on X11, ydotool on Wayland (zgu_inject.py).

import fcntl
import math
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_common import (  # noqa: E402
    SDL_CONTROLLER_AXIS_LEFTX,
    SDL_CONTROLLER_AXIS_LEFTY,
    SDL_CONTROLLER_AXIS_RIGHTX,
    SDL_CONTROLLER_AXIS_RIGHTY,
    SDL_CONTROLLER_AXIS_TRIGGERLEFT,
    SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
    SDL_CONTROLLER_BUTTON_A,
    SDL_CONTROLLER_BUTTON_B,
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
    SDL_CONTROLLER_BUTTON_BACK,
    SDL_CONTROLLER_BUTTON_START,
    SDL_CONTROLLER_BUTTON_X,
    SDL_CONTROLLER_BUTTON_Y,
    init_sdl,
    load_menu_conf,
    load_sdl2,
    sync_controllers,
)
from zgu_inject import BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, Injector  # noqa: E402

DEADZONE = 0.20            # fraction of the stick travel ignored around the center
MAX_SPEED_PX_S = 900.0     # pixels per second, ONE stick fully pushed (times mouse_speed)
WHEEL_FIRST_REPEAT_S = 0.40
WHEEL_REPEAT_S = 0.12
KEY_ENTER, KEY_ESC = 28, 1


def stick_vector(x, y):
    """Stick position (-1..1 each) -> speed vector: dead zone, then a quadratic curve (fine control
    near the center, full speed at the edge). Returns (vx, vy) in -1..1."""
    magnitude = math.hypot(x, y)
    if magnitude < DEADZONE:
        return 0.0, 0.0
    scale = min(1.0, (magnitude - DEADZONE) / (1.0 - DEADZONE))
    factor = scale * scale / magnitude
    return x * factor, y * factor


def cursor_delta(sticks, seconds, speed):
    """Movement for this tick, in pixels (float). `sticks` = [(x, y), ...]: the vectors ADD UP."""
    vx = vy = 0.0
    for x, y in sticks:
        sx, sy = stick_vector(x, y)
        vx += sx
        vy += sy
    return vx * MAX_SPEED_PX_S * speed * seconds, vy * MAX_SPEED_PX_S * speed * seconds


class GamepadMouse:
    def __init__(self, sdl, injector, speed, tick_seconds):
        self.sdl = sdl
        self.inj = injector
        self.speed = speed
        self.tick = tick_seconds
        self.pads = []
        self.rest_x = self.rest_y = 0.0     # fractional pixels not sent yet
        self.down = {}                      # button code -> was pressed last tick
        self.wheel_next = {}                # wheel button -> time of the next repeat
        self.next_scan = 0.0
        self.next_kb_check = 0.0
        self.open_keyboard = None  # set by main(): starts the virtual keyboard
        self.kb_open = False

    def _btn(self, pad, code):
        return bool(self.sdl.SDL_GameControllerGetButton(pad, code))

    def _axis(self, pad, code):
        return self.sdl.SDL_GameControllerGetAxis(pad, code) / 32767.0

    def other_ui_open(self, now):
        """True while the virtual keyboard or the LPM menu runs (each holds a lock for its whole
        life): the mouse is suspended then, so simulated clicks cannot close them. Checked ten
        times a second at most."""
        if now >= self.next_kb_check:
            self.next_kb_check = now + 0.1
            base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
            self.kb_open = False
            for name in ("lpm-virtual-keyboard.lock-%d", "lpm-game-menu.lock-%d"):
                path = os.path.join(base, name % os.getuid())
                if not os.path.exists(path):
                    continue
                try:
                    with open(path, "r") as handle:
                        try:
                            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except OSError:
                            self.kb_open = True
                except OSError:
                    pass
        return self.kb_open

    def step(self, now):
        """One tick: read the pads, send the events."""
        if now >= self.next_scan:
            self.next_scan = now + 1.0
            sync_controllers(self.sdl, self.pads)
        if not self.pads:
            return
        self.sdl.SDL_GameControllerUpdate()
        sticks = []
        pressed = {}
        hold = False
        for pad in self.pads:
            sticks.append((self._axis(pad, SDL_CONTROLLER_AXIS_LEFTX), self._axis(pad, SDL_CONTROLLER_AXIS_LEFTY)))
            sticks.append((self._axis(pad, SDL_CONTROLLER_AXIS_RIGHTX), self._axis(pad, SDL_CONTROLLER_AXIS_RIGHTY)))
            for code in (SDL_CONTROLLER_BUTTON_A, SDL_CONTROLLER_BUTTON_B, SDL_CONTROLLER_BUTTON_X,
                         SDL_CONTROLLER_BUTTON_Y, SDL_CONTROLLER_BUTTON_START, SDL_CONTROLLER_BUTTON_BACK,
                         SDL_CONTROLLER_BUTTON_LEFTSHOULDER, SDL_CONTROLLER_BUTTON_RIGHTSHOULDER):
                pressed[code] = pressed.get(code, False) or self._btn(pad, code)
            if (self._btn(pad, SDL_CONTROLLER_BUTTON_LEFTSHOULDER) and self._btn(pad, SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)
                    and self._btn(pad, SDL_CONTROLLER_BUTTON_RIGHTSTICK)
                    and self._axis(pad, SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 0.9
                    and self._axis(pad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 0.9):
                hold = True
        pressed["L2"] = any(self._axis(pad, SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 0.5 for pad in self.pads)
        pressed["R2"] = any(self._axis(pad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 0.5 for pad in self.pads)
        if pressed[SDL_CONTROLLER_BUTTON_LEFTSHOULDER] and pressed[SDL_CONTROLLER_BUTTON_RIGHTSHOULDER]:
            hold = True  # L1 + R1 together are part of the LPM menu / window-switch combos: no click
        if self.other_ui_open(now):  # keyboard or menu open: it alone reacts
            self.release_all()
            self.rest_x = self.rest_y = 0.0
            self.down.update(pressed)  # a button still held when the keyboard closes is not a click
            return
        if hold:  # window-switch hold: no mouse action, and nothing stays pressed
            self.release_all()
            return

        dx, dy = cursor_delta(sticks, self.tick, self.speed)
        self.rest_x += dx
        self.rest_y += dy
        ix, iy = int(self.rest_x), int(self.rest_y)
        if ix or iy:
            self.rest_x -= ix
            self.rest_y -= iy
            self.inj.move(ix, iy)

        for mouse_button, was, now_down in ((BTN_LEFT,) + tuple(self.logical(d, BTN_LEFT) for d in (self.down, pressed)),
                                            (BTN_RIGHT,) + tuple(self.logical(d, BTN_RIGHT) for d in (self.down, pressed)),
                                            (BTN_MIDDLE,) + tuple(self.logical(d, BTN_MIDDLE) for d in (self.down, pressed))):
            if was != now_down:
                self.inj.button(mouse_button, now_down)
        if pressed[SDL_CONTROLLER_BUTTON_BACK] and not self.down.get(SDL_CONTROLLER_BUTTON_BACK, False) \
                and self.open_keyboard:
            self.open_keyboard()  # Select: shows the virtual keyboard (Select closes it, in the keyboard)
        for code, key in ((SDL_CONTROLLER_BUTTON_X, KEY_ENTER), (SDL_CONTROLLER_BUTTON_START, KEY_ESC)):
            if pressed[code] and not self.down.get(code, False):
                self.inj.tap([key])
        for code, direction in ((SDL_CONTROLLER_BUTTON_LEFTSHOULDER, -1), (SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, 1)):
            if pressed[code]:
                if not self.down.get(code, False):
                    self.inj.wheel(direction)
                    self.wheel_next[code] = now + WHEEL_FIRST_REPEAT_S
                elif now >= self.wheel_next.get(code, now + 1):
                    self.inj.wheel(direction)
                    self.wheel_next[code] = now + WHEEL_REPEAT_S
        self.down = dict(pressed)

    @staticmethod
    def logical(state, mouse_button):
        """Is this mouse button down, given the pad buttons: left = A or R2, right = B or L2, middle = Y."""
        if mouse_button == BTN_LEFT:
            return bool(state.get(SDL_CONTROLLER_BUTTON_A) or state.get("R2"))
        if mouse_button == BTN_RIGHT:
            return bool(state.get(SDL_CONTROLLER_BUTTON_B) or state.get("L2"))
        return bool(state.get(SDL_CONTROLLER_BUTTON_Y))

    def release_all(self):
        """Release any mouse button this process still holds down (also on exit)."""
        for mouse_button in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
            if self.logical(self.down, mouse_button):
                self.inj.button(mouse_button, False)
        self.down = {}


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("x11", "wayland") or not sys.argv[2]:
        sys.stderr.write("Usage: zgu-gamepad-mouse.py <x11|wayland> <prefix_folder>\n")
        return 1
    session_kind, prefix_dir = sys.argv[1], sys.argv[2]
    running = [True]

    def stop(_signum, _frame):
        running[0] = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    sdl = load_sdl2()
    if sdl is None or not init_sdl(sdl):
        sys.stderr.write("zgu-gamepad-mouse: SDL2 unavailable\n")
        return 1
    try:
        speed = max(0.1, min(5.0, float(load_menu_conf().get("mouse_speed", "1.0"))))
    except ValueError:
        speed = 1.0
    # ydotool starts a process per call: fewer, bigger steps on Wayland.
    tick = 0.016 if session_kind == "x11" else 0.04

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "zgu_prefix_watch", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zgu-prefix-watch.py"))
    watch_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(watch_module)
    game_watch = watch_module.GameEndWatch(prefix_dir)

    mouse = GamepadMouse(sdl, Injector(session_kind), speed, tick)

    def open_keyboard():
        import subprocess
        try:
            subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                            "zgu-virtual-keyboard.py"), session_kind, prefix_dir],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError:
            pass

    mouse.open_keyboard = open_keyboard
    try:
        while running[0] and not game_watch.game_ended():
            mouse.step(time.monotonic())
            time.sleep(tick)
    finally:
        mouse.release_all()
        sdl.SDL_Quit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
