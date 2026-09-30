#!/usr/bin/env python3
# --- lpm launcher : combo manette "changer de fenêtre" (Alt+Tab), via SDL2 ---
#
# Usage : zgu-gamepad-alttab-watcher.py <x11|wayland>
#
# Frère de zgu-gamepad-exit-watcher.py (mêmes principes -- SDL2, pas de grab(), lecture non-
# exclusive compatible AntiMicro, voir ce fichier pour l'historique complet) mais avec une
# vie et un geste différents :
#
#   - PAS un script "coup unique" : contrairement au quit (une seule fois puis le process
#     se termine), celui-ci doit rester actif pendant TOUTE la session de jeu et peut se
#     déclencher autant de fois que voulu.
#   - Le geste est un MAINTIEN, pas un simple déclenchement : tant que le combo
#     L1+L2+R1+R2+clic R3 reste enfoncé/tiré, le D-pad Gauche/Droite fait défiler les
#     fenêtres (Maj+Tab / Tab) -- exactement comme maintenir Alt au clavier et appuyer sur
#     Tab plusieurs fois. Relâcher le combo relâche Alt et valide la sélection en cours.
#
# Combo DÉLIBÉRÉMENT différent (pas un sous-ensemble) du combo "quitter" de
# zgu-gamepad-exit-watcher.py (L1+L2+R1+R2+L3+R3) : L3 (clic stick gauche) n'entre jamais
# en jeu ici -- la direction se fait UNIQUEMENT au D-pad, jamais au stick gauche, pour que
# bouger le stick pendant le maintien ne puisse jamais compléter accidentellement le combo
# de fermeture (voir l'échange qui a mené à ce choix : la version envisagée au départ
# utilisait le stick gauche pour la direction, ce qui aurait rendu les deux combos quasi
# identiques -- un clic de stick involontaire pendant qu'on le pousse aurait alors aussi
# fermé le jeu par accident).
#
# DÉPENDANCE SYSTÈME : libSDL2, identique à zgu-gamepad-exit-watcher.py -- voir ce fichier.

import sys
import os
import signal
import subprocess
import shutil
import time
import ctypes
import ctypes.util

if len(sys.argv) < 2 or sys.argv[1] not in ("x11", "wayland"):
    sys.stderr.write("Usage: zgu-gamepad-alttab-watcher.py <x11|wayland>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GAMECONTROLLERDB_PATH = os.path.join(SCRIPT_DIR, "data", "gamecontrollerdb.txt")

running = True


def handle_signal(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


# --- Chargement de libSDL2 (identique à zgu-gamepad-exit-watcher.py) -----------------------
def _load_sdl2():
    names = []
    found = ctypes.util.find_library("SDL2")
    if found:
        names.append(found)
    names += ["libSDL2-2.0.so.0", "libSDL2-2.0.so", "SDL2"]
    for name in names:
        try:
            return ctypes.CDLL(name)
        except OSError:
            continue
    return None


sdl = _load_sdl2()
if sdl is None:
    sys.stderr.write(
        "zgu-gamepad-alttab-watcher: libSDL2 introuvable "
        "(paquet manquant : libsdl2-2.0-0 / sdl2 / SDL2)\n"
    )
    sys.exit(1)

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1")

SDL_INIT_JOYSTICK = 0x00000200
SDL_INIT_GAMECONTROLLER = 0x00002000
SDL_INIT_EVENTS = 0x00004000

sdl.SDL_Init.restype = ctypes.c_int
sdl.SDL_Init.argtypes = [ctypes.c_uint32]
sdl.SDL_Quit.restype = None
sdl.SDL_GetError.restype = ctypes.c_char_p
sdl.SDL_NumJoysticks.restype = ctypes.c_int
sdl.SDL_IsGameController.restype = ctypes.c_int
sdl.SDL_IsGameController.argtypes = [ctypes.c_int]
sdl.SDL_GameControllerOpen.restype = ctypes.c_void_p
sdl.SDL_GameControllerOpen.argtypes = [ctypes.c_int]
sdl.SDL_GameControllerClose.restype = None
sdl.SDL_GameControllerClose.argtypes = [ctypes.c_void_p]
sdl.SDL_GameControllerUpdate.restype = None
sdl.SDL_GameControllerGetButton.restype = ctypes.c_uint8
sdl.SDL_GameControllerGetButton.argtypes = [ctypes.c_void_p, ctypes.c_int]
sdl.SDL_GameControllerGetAxis.restype = ctypes.c_int16
sdl.SDL_GameControllerGetAxis.argtypes = [ctypes.c_void_p, ctypes.c_int]

_add_mappings_from_file = getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None)
if _add_mappings_from_file is not None:
    _add_mappings_from_file.restype = ctypes.c_int
    _add_mappings_from_file.argtypes = [ctypes.c_char_p]

if sdl.SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0:
    sys.stderr.write(
        "zgu-gamepad-alttab-watcher: SDL_Init a échoué (%s)\n"
        % sdl.SDL_GetError().decode("utf-8", "replace")
    )
    sys.exit(1)

if _add_mappings_from_file is not None and os.path.isfile(GAMECONTROLLERDB_PATH):
    _add_mappings_from_file(GAMECONTROLLERDB_PATH.encode("utf-8"))


def _resolve_xdotool():
    if shutil.which("xdotool"):
        return "xdotool"
    if os.access("/run/host/usr/bin/xdotool", os.X_OK):
        return "/run/host/usr/bin/xdotool"
    return None


XDOTOOL_BIN = _resolve_xdotool()

# Codes clavier Linux (linux/input-event-codes.h) pour ydotool -- KEY_LEFTALT=56,
# KEY_TAB=15, KEY_LEFTSHIFT=42.
YDOTOOL_ALT_DOWN = ["56:1"]
YDOTOOL_ALT_UP = ["56:0"]
YDOTOOL_TAB = ["15:1", "15:0"]
YDOTOOL_SHIFT_TAB = ["42:1", "15:1", "15:0", "42:0"]


def _run_best_effort(argv):
    try:
        subprocess.run(argv, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass  # best-effort, comme send_key() dans zgu-gamepad-bridge.py


def alt_down():
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "keydown", "alt"])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *YDOTOOL_ALT_DOWN])


def alt_up():
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "keyup", "alt"])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *YDOTOOL_ALT_UP])


def send_tab(reverse):
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "key", "shift+Tab" if reverse else "Tab"])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *(YDOTOOL_SHIFT_TAB if reverse else YDOTOOL_TAB)])


# --- Boutons/axes standardisés SDL2 (mêmes constantes que les autres watchers) ------------
SDL_CONTROLLER_BUTTON_LEFTSTICK = 7
SDL_CONTROLLER_BUTTON_RIGHTSTICK = 8         # clic stick droit (R3)
SDL_CONTROLLER_BUTTON_LEFTSHOULDER = 9       # L1
SDL_CONTROLLER_BUTTON_RIGHTSHOULDER = 10     # R1
SDL_CONTROLLER_BUTTON_DPAD_LEFT = 13
SDL_CONTROLLER_BUTTON_DPAD_RIGHT = 14
SDL_CONTROLLER_AXIS_TRIGGERLEFT = 4          # L2
SDL_CONTROLLER_AXIS_TRIGGERRIGHT = 5         # R2

# Maintien : L1 + R1 + clic R3 (boutons) + L2 + R2 (axes) -- volontairement SANS L3 (clic
# stick gauche), voir l'en-tête de fichier : la direction se fait au D-pad, jamais au stick
# gauche, pour ne jamais recouper le combo de fermeture de zgu-gamepad-exit-watcher.py.
HOLD_BUTTONS = (
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
)
HOLD_AXES = (SDL_CONTROLLER_AXIS_TRIGGERLEFT, SDL_CONTROLLER_AXIS_TRIGGERRIGHT)
AXIS_PULL_THRESHOLD = int(32767 * 0.9)
POLL_INTERVAL_SECONDS = 0.05


def find_controllers():
    pads = []
    for i in range(sdl.SDL_NumJoysticks()):
        if sdl.SDL_IsGameController(i):
            handle = sdl.SDL_GameControllerOpen(i)
            if handle:
                pads.append(handle)
    return pads


def hold_active(pads):
    for pad in pads:
        buttons_ok = all(sdl.SDL_GameControllerGetButton(pad, code) for code in HOLD_BUTTONS)
        axes_ok = all(
            sdl.SDL_GameControllerGetAxis(pad, code) >= AXIS_PULL_THRESHOLD for code in HOLD_AXES
        )
        if buttons_ok and axes_ok:
            return True
    return False


def dpad_direction(pads):
    """-1 (gauche), 1 (droite) ou 0 -- premier pad qui répond, jamais les deux à la fois."""
    for pad in pads:
        left = sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_LEFT)
        right = sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_RIGHT)
        if left and not right:
            return -1
        if right and not left:
            return 1
    return 0


def main():
    pads = find_controllers()
    if not pads:
        sdl.SDL_Quit()
        sys.exit(0)

    alt_is_held = False
    prev_dpad_dir = 0

    try:
        while running:
            sdl.SDL_GameControllerUpdate()
            active = hold_active(pads)

            if active and not alt_is_held:
                alt_down()
                alt_is_held = True
                prev_dpad_dir = 0  # repart de zéro à chaque nouveau maintien
            elif not active and alt_is_held:
                alt_up()
                alt_is_held = False
                prev_dpad_dir = 0

            if alt_is_held:
                direction = dpad_direction(pads)
                if direction != prev_dpad_dir and direction != 0:
                    send_tab(reverse=(direction < 0))
                prev_dpad_dir = direction

            time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        # Filet de sécurité : si on quitte (SIGTERM, jeu tué...) alors qu'Alt était encore
        # tenu enfoncé côté clavier virtuel, on le relâche -- sinon Alt resterait bloqué
        # "appuyé" pour le reste de la session desktop, ce qui casserait toute la navigation
        # clavier/souris ensuite. Pire bug possible ici, donc toujours couvert, même en
        # sortie anormale.
        if alt_is_held:
            alt_up()
        for pad in pads:
            try:
                sdl.SDL_GameControllerClose(pad)
            except Exception:
                pass
        sdl.SDL_Quit()


if __name__ == "__main__":
    main()
