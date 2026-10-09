#!/usr/bin/env python3
"""Test of the gamepad watcher (lib/zgu-gamepad-alttab-watcher.py) WITHOUT a gamepad or real
SDL: the SDL object is replaced by a fake whose button state follows a scenario, and the
keyboard commands that would be sent (xdotool on X11, ydotool on Wayland) are recorded.

Run: python3 tests/gamepad_smoke.py   (only needs libSDL2 installed, like the script itself;
no gamepad, no display).
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "lib", "zgu-gamepad-alttab-watcher.py")

BTN = dict(BACK=4, L3=7, R3=8, L1=9, R1=10, UP=11, DOWN=12, LEFT=13, RIGHT=14)
AX_L2, AX_R2 = 4, 5
COMBO = ("L1", "R1", "R3")


def run(session, script):
    """script: list of (pressed buttons, trigger combo?) -- one item per tick."""
    sys.argv = ["zgu-gamepad-alttab-watcher.py", session]
    spec = importlib.util.spec_from_file_location("alttab_watcher_%s" % session, PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)

    state = {"tick": 0}

    class FakeSDL:
        def SDL_GameControllerUpdate(self): pass
        def SDL_NumJoysticks(self): return 1
        def SDL_IsGameController(self, i): return 1
        def SDL_GameControllerOpen(self, i): return 1
        def SDL_GameControllerClose(self, h): pass
        def SDL_Quit(self): pass

        def SDL_GameControllerGetButton(self, pad, code):
            pressed, _ = script[min(state["tick"], len(script) - 1)]
            return 1 if any(BTN[name] == code for name in pressed) else 0

        def SDL_GameControllerGetAxis(self, pad, code):
            _, triggers = script[min(state["tick"], len(script) - 1)]
            return 32767 if triggers else 0

    calls = []
    m.sdl = FakeSDL()
    m.XDOTOOL_BIN = "xdotool"
    m._run_best_effort = lambda argv: calls.append(" ".join(argv))
    m.shutil.which = lambda name: "/usr/bin/" + name if name in ("ydotool", "xdotool") else None
    m._find_antimicro_pids = lambda: []

    def fake_sleep(_):
        state["tick"] += 1
        if state["tick"] >= len(script):
            m.running = False

    m.time.sleep = fake_sleep
    m.main()
    return calls


def held(*names):
    return list(COMBO) + list(names), True


FREE = ([], False)
scenario = [
    (["BACK"], False),          # Select held BEFORE the combo: must trigger nothing
    held("BACK"),               # combo completed with Select already held: nothing either
    held(),                     # Select released
    held("UP"), held("UP"), held("UP"),   # long press on Up: fires once only
    held(),
    held("DOWN"), held(),
    held("BACK"), held(),
    held("LEFT"), held(),
    FREE,                       # combo released
    (["UP"], False),            # Up outside the combo: must send nothing
]

ok = True


def expect(label, got, want):
    global ok
    if got != want:
        ok = False
        print("ECHEC %s:\n   obtenu : %s\n   attendu: %s" % (label, got, want))
    else:
        print("OK: " + label)


x11 = run("x11", scenario)
expect("X11", x11, [
    "xdotool keydown alt",
    "xdotool key --clearmodifiers F4",
    "xdotool key Return",
    "xdotool key --clearmodifiers F11",
    "xdotool key shift+Tab",
    "xdotool keyup alt",
])

wl = run("wayland", scenario)
expect("Wayland", wl, [
    "ydotool key 56:1",
    "ydotool key 56:0 62:1 62:0 56:1",
    "ydotool key 28:1 28:0",
    "ydotool key 56:0 87:1 87:0 56:1",
    "ydotool key 42:1 15:1 15:0 42:0",
    "ydotool key 56:0",
])

sys.exit(0 if ok else 1)
