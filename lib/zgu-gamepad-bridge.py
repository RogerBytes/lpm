#!/usr/bin/env python3
# --- lpm launcher : pont manette -> clavier, via SDL2 (SANS verrou exclusif) ---
#
# Usage : zgu-gamepad-bridge.py <x11|wayland>
#
# HISTORIQUE -- pourquoi ce n'est PLUS de l'evdev+grab() : la version précédente ouvrait
# chaque manette en evdev brut et la verrouillait avec InputDevice.grab() (EVIOCGRAB), pour
# empêcher tout autre programme de recevoir ses événements pendant la navigation dans les
# menus lpm. Ça marchait, mais en s'appuyant sur les noms symboliques evdev (BTN_SOUTH,
# BTN_WEST, ABS_X...) -- qui ne correspondent pas forcément aux boutons physiques réels
# selon la manette (constaté en pratique sur une 8BitDo SN30 Pro+, voir l'historique de
# zgu-gamepad-exit-watcher.py). Décision explicite (demandée) : migrer vers SDL2, qui
# traduit chaque manette reconnue -- via sa base "gamecontrollerdb.txt", bundlée avec lpm,
# voir lib/data/ -- vers un layout standardisé fixe, valable sur un très grand nombre de
# modèles sans capture manuelle par matériel.
#
# COMPROMIS ACCEPTÉ (délibéré, pas un oubli) : SDL2 ne verrouille jamais un périphérique en
# exclusivité (EVIOCGRAB) -- il se contente de s'enregistrer comme UN lecteur de plus. Ce
# pont n'a donc plus d'exclusivité : un autre programme qui lirait la manette au niveau
# matériel en parallèle (AntiMicro, un frontend resté ouvert en arrière-plan...) continue
# de recevoir ses événements pendant que ce pont traduit les mêmes appuis en touches
# clavier pour la navigation des menus lpm. EVIOCGRAB et la traduction universelle
# multi-manette de SDL2 sont mutuellement exclusifs sur un même périphérique (une fois
# grabbé, plus aucun autre lecteur -- y compris une instance SDL2 -- ne reçoit quoi que ce
# soit) : il fallait choisir l'un des deux, la portabilité multi-manette a été choisie.
#
# PONT VERS LE CLAVIER : les boutons/axes standardisés SDL2 sont traduits en appuis clavier
# injectés dans la fenêtre ayant le focus, via xdotool (X11) ou ydotool (Wayland, jeu de
# touches plus limité -- voir KEY_MAP ci-dessous) -- Zenity navigue déjà nativement au
# clavier (--list, --checklist, --entry...), donc aucune logique de menu à réécrire ici,
# seulement une traduction d'événements. Le focus de la fenêtre Zenity elle-même est déjà
# assuré par zgu-focus-utils.sh (sourcé par le script bash appelant), pas le problème de ce
# script.
#
# Traductions manette -> clavier (boutons/axes standardisés SDL2) :
#   Stick gauche vertical / D-pad vertical   -> Haut / Bas      (déplacement dans une liste)
#   Stick gauche horizontal / D-pad horizontal -> Gauche / Droite (déplacement horizontal)
#   A                                        -> Entrée           (valider)
#   B                                        -> Échap             (annuler/fermer)
#   X                                        -> Gauche puis Espace (cocher/décocher une case
#                                                                    radio/checklist -- voir
#                                                                    note ci-dessous)
#   LEFTSHOULDER (L1)                        -> Maj+Tab           (champ précédent)
#   RIGHTSHOULDER (R1)                       -> Tab               (champ suivant)
#
# Pourquoi "Gauche puis Espace" pour X : dans un zenity --radiolist/--checklist, la colonne
# case à cocher (tout à gauche) et la colonne texte ont chacune leur propre "focus cellule"
# au sein de la ligne survolée -- Haut/Bas ne déplacent que la ligne, pas cette cellule. Par
# défaut le focus cellule est sur la colonne texte, donc Espace seul ne coche rien tant
# qu'un clic souris n'a pas explicitement déplacé ce focus sur la colonne case (et il y
# reste ensuite). Envoyer Gauche avant Espace déplace ce focus sur la colonne case (la plus
# à gauche) à chaque pression, sans jamais dépendre d'un clic souris préalable -- sans
# risque : Gauche sur une colonne déjà la plus à gauche ne fait rien.
#
# Détection des manettes : tout périphérique que SDL2 reconnaît comme "game controller"
# (SDL_IsGameController, via sa base de mappings). Un nouveau périphérique branché après le
# démarrage n'est PAS détecté à chaud (scan une seule fois au lancement) : limitation
# acceptée, le cas d'usage est "la manette est déjà branchée avant de lancer lpm ou le jeu",
# pas un branchement à chaud en cours de session.
#
# Arrêt : SIGTERM (envoyé par le script bash appelant) -- proprement, ferme les manettes
# ouvertes avant de quitter.
#
# DÉPENDANCE SYSTÈME : libSDL2 (paquet "libsdl2-2.0-0" sur Debian/Ubuntu, "sdl2" sur Arch,
# "SDL2" sur Fedora) -- même bibliothèque que zgu-gamepad-exit-watcher.py, pas de dépendance
# Python supplémentaire.

import sys
import os
import signal
import subprocess
import shutil
import time
import ctypes
import ctypes.util

if len(sys.argv) < 2 or sys.argv[1] not in ("x11", "wayland"):
    sys.stderr.write("Usage: zgu-gamepad-bridge.py <x11|wayland>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GAMECONTROLLERDB_PATH = os.path.join(SCRIPT_DIR, "data", "gamecontrollerdb.txt")

AXIS_THRESHOLD = int(32767 * 0.5)  # même seuil (50% de la course) que l'ancienne version
POLL_INTERVAL_SECONDS = 0.02

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
        "zgu-gamepad-bridge: libSDL2 introuvable "
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

# Optionnel -- voir zgu-gamepad-exit-watcher.py : ce symbole n'est pas exporté par toutes
# les versions/distributions de libSDL2 (constaté absent sur Ubuntu 2.30.0). Résolution
# défensive, jamais fatale.
_add_mappings_from_file = getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None)
if _add_mappings_from_file is not None:
    _add_mappings_from_file.restype = ctypes.c_int
    _add_mappings_from_file.argtypes = [ctypes.c_char_p]

if sdl.SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0:
    sys.stderr.write(
        "zgu-gamepad-bridge: SDL_Init a échoué (%s)\n"
        % sdl.SDL_GetError().decode("utf-8", "replace")
    )
    sys.exit(1)

if _add_mappings_from_file is not None and os.path.isfile(GAMECONTROLLERDB_PATH):
    _add_mappings_from_file(GAMECONTROLLERDB_PATH.encode("utf-8"))


# --- Table de traduction touche logique -> commande xdotool / séquence ydotool ------------
KEY_MAP = {
    "Return":     {"xdotool": "Return",     "ydotool": ["28:1", "28:0"]},
    "Escape":     {"xdotool": "Escape",     "ydotool": ["1:1", "1:0"]},
    "space":      {"xdotool": "space",      "ydotool": ["57:1", "57:0"]},
    "Up":         {"xdotool": "Up",         "ydotool": ["103:1", "103:0"]},
    "Down":       {"xdotool": "Down",       "ydotool": ["108:1", "108:0"]},
    "Left":       {"xdotool": "Left",       "ydotool": ["105:1", "105:0"]},
    "Right":      {"xdotool": "Right",      "ydotool": ["106:1", "106:0"]},
    "Tab":        {"xdotool": "Tab",        "ydotool": ["15:1", "15:0"]},
    "shift+Tab":  {"xdotool": "shift+Tab",  "ydotool": ["42:1", "15:1", "15:0", "42:0"]},
}


def _resolve_xdotool():
    if shutil.which("xdotool"):
        return "xdotool"
    if os.access("/run/host/usr/bin/xdotool", os.X_OK):
        return "/run/host/usr/bin/xdotool"
    return None


XDOTOOL_BIN = _resolve_xdotool()


def send_key(key_name):
    mapping = KEY_MAP.get(key_name)
    if mapping is None:
        return
    try:
        if SESSION_KIND == "x11" and XDOTOOL_BIN:
            subprocess.run([XDOTOOL_BIN, "key", mapping["xdotool"]], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif shutil.which("ydotool"):
            subprocess.run(["ydotool", "key", *mapping["ydotool"]], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass  # best-effort : un appui manqué ne doit jamais faire planter le pont


# --- Boutons/axes standardisés SDL2 (valeurs numériques fixes de l'API C, voir
# SDL_gamecontroller.h -- mêmes constantes que zgu-gamepad-exit-watcher.py) ---
SDL_CONTROLLER_BUTTON_A = 0
SDL_CONTROLLER_BUTTON_B = 1
SDL_CONTROLLER_BUTTON_X = 2
SDL_CONTROLLER_BUTTON_LEFTSHOULDER = 9
SDL_CONTROLLER_BUTTON_RIGHTSHOULDER = 10
SDL_CONTROLLER_BUTTON_DPAD_UP = 11
SDL_CONTROLLER_BUTTON_DPAD_DOWN = 12
SDL_CONTROLLER_BUTTON_DPAD_LEFT = 13
SDL_CONTROLLER_BUTTON_DPAD_RIGHT = 14
SDL_CONTROLLER_AXIS_LEFTX = 0
SDL_CONTROLLER_AXIS_LEFTY = 1

# Chaque bouton associe une SÉQUENCE de touches (une liste, envoyées dans l'ordre) --
# nécessaire pour X (voir note plus haut : Gauche doit précéder Espace à chaque pression).
BUTTON_KEY_MAP = {
    SDL_CONTROLLER_BUTTON_A: ["Return"],
    SDL_CONTROLLER_BUTTON_B: ["Escape"],
    SDL_CONTROLLER_BUTTON_X: ["Left", "space"],
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER: ["shift+Tab"],
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER: ["Tab"],
}

# D-pad ET stick gauche partagent les mêmes touches logiques -- chacun est suivi
# indépendamment (clé "dpad_y"/"stick_y"/etc.) pour ne pas mélanger leurs fronts montants.
DPAD_BUTTON_KEYS = {
    "y": (SDL_CONTROLLER_BUTTON_DPAD_UP, SDL_CONTROLLER_BUTTON_DPAD_DOWN, "Up", "Down"),
    "x": (SDL_CONTROLLER_BUTTON_DPAD_LEFT, SDL_CONTROLLER_BUTTON_DPAD_RIGHT, "Left", "Right"),
}
STICK_AXIS_KEYS = {
    "y": (SDL_CONTROLLER_AXIS_LEFTY, "Up", "Down"),
    "x": (SDL_CONTROLLER_AXIS_LEFTX, "Left", "Right"),
}


def find_controllers():
    pads = []
    for i in range(sdl.SDL_NumJoysticks()):
        if sdl.SDL_IsGameController(i):
            handle = sdl.SDL_GameControllerOpen(i)
            if handle:
                pads.append(handle)
    return pads


def main():
    pads = find_controllers()
    if not pads:
        # Pas de manette reconnue : rien à traduire, sortie silencieuse (le clavier/la
        # souris continuent de fonctionner normalement sans ce script).
        sdl.SDL_Quit()
        sys.exit(0)

    prev_buttons = {pad: {code: 0 for code in BUTTON_KEY_MAP} for pad in pads}
    prev_dpad_dir = {pad: {"x": 0, "y": 0} for pad in pads}
    prev_stick_dir = {pad: {"x": 0, "y": 0} for pad in pads}

    try:
        while running:
            sdl.SDL_GameControllerUpdate()

            for pad in pads:
                # Boutons simples (front montant uniquement, comme event.value == 1 avant).
                for code, key_sequence in BUTTON_KEY_MAP.items():
                    value = sdl.SDL_GameControllerGetButton(pad, code)
                    if value and not prev_buttons[pad][code]:
                        for key_name in key_sequence:
                            send_key(key_name)
                    prev_buttons[pad][code] = value

                # D-pad (boutons dédiés, mais mêmes touches logiques que le stick).
                for axis_name, (neg_code, pos_code, neg_key, pos_key) in DPAD_BUTTON_KEYS.items():
                    neg = sdl.SDL_GameControllerGetButton(pad, neg_code)
                    pos = sdl.SDL_GameControllerGetButton(pad, pos_code)
                    direction = -1 if neg else (1 if pos else 0)
                    if direction != prev_dpad_dir[pad][axis_name] and direction != 0:
                        send_key(neg_key if direction < 0 else pos_key)
                    prev_dpad_dir[pad][axis_name] = direction

                # Stick gauche (axe analogique, seuillé comme avant -- 50% de la course).
                for axis_name, (axis_code, neg_key, pos_key) in STICK_AXIS_KEYS.items():
                    value = sdl.SDL_GameControllerGetAxis(pad, axis_code)
                    if value <= -AXIS_THRESHOLD:
                        direction = -1
                    elif value >= AXIS_THRESHOLD:
                        direction = 1
                    else:
                        direction = 0
                    if direction != prev_stick_dir[pad][axis_name] and direction != 0:
                        send_key(neg_key if direction < 0 else pos_key)
                    prev_stick_dir[pad][axis_name] = direction

            time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        for pad in pads:
            try:
                sdl.SDL_GameControllerClose(pad)
            except Exception:
                pass
        sdl.SDL_Quit()


if __name__ == "__main__":
    main()
