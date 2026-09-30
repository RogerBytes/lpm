#!/usr/bin/env python3
# --- lpm launcher : combo manette "quitter le jeu" (Alt+F4), via SDL2, sans verrou exclusif ---
#
# Usage : zgu-gamepad-exit-watcher.py <x11|wayland>
#
# DÉLIBÉRÉMENT un script à part de zgu-gamepad-bridge.py (voir ce fichier) : celui-ci
# verrouille la manette en exclusivité (InputDevice.grab(), evdev brut) pour traduire ses
# appuis en touches clavier pendant le picker -- exactement ce qu'il NE FAUT PAS faire ici.
# Ce surveillant tourne PENDANT LE JEU, où la manette doit rester lisible normalement par le
# jeu lui-même ET par un outil de remapping comme AntiMicro tournant en parallèle. SDL2 lit
# la manette via le sous-système joystick/evdev du noyau SANS appel EVIOCGRAB -- plusieurs
# lecteurs non-exclusifs coexistent sans problème sous Linux, donc la compatibilité AntiMicro
# reste intacte.
#
# HISTORIQUE -- pourquoi SDL2 et pas de l'evdev brut (comme la toute première version de ce
# script) : la première implémentation lisait les codes bouton/axe evdev bruts, capturés en
# direct sur une 8BitDo SN30 Pro+ précise (L1=308, R1=309, clic stick gauche=312, clic stick
# droit=313, L2/R2=axes bruts 2/5) -- parce que les noms symboliques evdev standard
# (BTN_TL2, BTN_THUMBL...) ne correspondaient PAS aux boutons physiques attendus sur cette
# manette. Ça marchait, mais UNIQUEMENT pour ce modèle précis, dans ce mode de connexion
# précis : changer de manette aurait exigé de tout recapturer à la main. SDL2 règle ça par
# construction : sa base communautaire "gamecontrollerdb.txt" (bundlée ici, voir
# lib/data/gamecontrollerdb.txt) associe chaque manette connue -- identifiée par son GUID
# (vendor/product/version) -- à un layout standardisé fixe (boutons LEFTSHOULDER,
# RIGHTSHOULDER, LEFTSTICK, RIGHTSTICK, axes TRIGGERLEFT/TRIGGERRIGHT). Le combo ci-dessous
# devient donc valable sur toute manette que SDL2 sait reconnaître -- pas seulement celle
# testée -- sans capture manuelle par modèle. Vérifié : la base bundlée contient plusieurs
# entrées "8BitDo SN30 Pro Plus" côté Linux, correspondant exactement à ce qui avait été
# observé en direct (boutons numériques pour L1/R1/L3/R3, axes analogiques pour L2/R2).
#
# Combo surveillé : L1 + R1 + L2 + R2 + clic stick gauche (L3) + clic stick droit (R3),
# TOUS enfoncés/tirés en même temps -- voir l'échange qui a mené à ce choix (recherche faite
# sur les combos "reset" classiques -- Start+Select+L+R -- et les combos de cheat-codes
# connus -- L1+L2+R1 sur certains jeux PS2 -- pour choisir un geste qui ne recoupe aucun des
# deux : les 4 boutons d'épaule PLUS les 2 clics de stick en même temps n'a aucune trace
# connue d'utilisation réelle en jeu, et est physiquement peu naturel à faire par accident).
#
# Déclenchement : dès que les 6 sont TOUS enfoncés/tirés (scruté toutes les 50ms -- pas de
# maintien, pas de délai notable -- demandé explicitement), envoie Alt+F4 puis ce script se
# termine (usage unique). Pas de filet de sécurité "kill -9" du process -- demandé
# explicitement : Alt+F4 seul, volontairement moins brutal (le jeu reçoit une vraie demande
# de fermeture WM_CLOSE, peut sauvegarder avant de quitter, plutôt qu'être tué depuis
# l'extérieur).
#
# Fin de vie : ce script s'arrête tout seul dès qu'il a envoyé Alt+F4 une fois -- il n'y a
# aucun moyen fiable, depuis l'orchestrateur, de savoir quand une partie se termine
# normalement (zgl-launcher-orchestrator.sh passe la main à Lutris via "exec" et perd toute
# trace du process du jeu, voir ce fichier) : si le combo n'est jamais utilisé, ce
# surveillant continue de tourner même après avoir quitté le jeu -- SANS DANGER en soi
# (lecture passive, quasi aucun coût CPU, scrutation à intervalle) -- mais ça veut dire que
# le combo restera "armé" jusqu'au prochain lancement de jeu (qui tue l'instance précédente
# avant d'en relancer une neuve, voir l'appel "pkill" dans zgl-launcher-orchestrator.sh) -- si
# jamais ce geste précis est refait par accident sur le bureau entre deux jeux, Alt+F4 partira
# vers la fenêtre alors au premier plan. Accepté comme compromis : le combo est suffisamment
# improbable pour qu'un déclenchement hors-jeu reste très rare.
#
# DÉPENDANCE SYSTÈME : nécessite la bibliothèque partagée libSDL2 (paquet
# "libsdl2-2.0-0" sur Debian/Ubuntu, "sdl2" sur Arch, "SDL2" sur Fedora) -- PAS de paquet
# Python supplémentaire (pysdl2/PySDL2) : ce script parle directement à libSDL2 via ctypes,
# pour limiter la dépendance ajoutée au strict minimum (la bibliothèque seule, souvent déjà
# présente comme dépendance transitive d'autres jeux/applications Wine).

import sys
import os
import signal
import subprocess
import shutil
import time
import ctypes
import ctypes.util

if len(sys.argv) < 2 or sys.argv[1] not in ("x11", "wayland"):
    sys.stderr.write("Usage: zgu-gamepad-exit-watcher.py <x11|wayland>\n")
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


# --- Chargement de libSDL2 -----------------------------------------------------------------
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
        "zgu-gamepad-exit-watcher: libSDL2 introuvable "
        "(paquet manquant : libsdl2-2.0-0 / sdl2 / SDL2)\n"
    )
    sys.exit(1)

# Pas de fenêtre ici, juste la lecture de manettes -- on force un pilote vidéo factice pour
# que SDL_Init ne tente jamais de toucher un serveur d'affichage (utile aussi si ce script
# démarrait sans variable DISPLAY/WAYLAND_DISPLAY joignable au moment précis où il se lance).
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
# La manette doit continuer à être lue même quand ce process n'a jamais eu le focus (il n'a
# pas de fenêtre du tout) -- comportement par défaut de SDL2 pour le sous-système manette
# sous Linux (lecture directe via joystick/evdev, pas liée au focus X11/Wayland), gardé
# explicite ici pour ne pas dépendre d'un défaut qui pourrait changer.
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
# SDL_GameControllerAddMappingsFromFile est optionnel : selon la distribution/version exacte
# de libSDL2, ce symbole n'est pas toujours exporté tel quel (constaté : absent de la
# libSDL2-2.0.so.0 2.30.0 d'Ubuntu, alors que toutes les fonctions ci-dessus le sont) --
# résolution défensive via getattr plutôt qu'un accès direct, pour ne jamais planter au
# démarrage si ce symbole précis manque. Dans ce cas on se contente de la base interne déjà
# embarquée dans la libSDL2 installée -- pas de couverture bundlée en plus, mais pas de
# plantage non plus.
_add_mappings_from_file = getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None)
if _add_mappings_from_file is not None:
    _add_mappings_from_file.restype = ctypes.c_int
    _add_mappings_from_file.argtypes = [ctypes.c_char_p]

if sdl.SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_Init a échoué (%s)\n"
        % sdl.SDL_GetError().decode("utf-8", "replace")
    )
    sys.exit(1)

# Charge la base communautaire bundlée -- donne à SDL2 le mapping standardisé pour un très
# grand nombre de manettes connues (dont la 8BitDo SN30 Pro+), plutôt que de dépendre
# uniquement de la base déjà embarquée dans la libSDL2 installée sur le système (variable
# selon la distribution/version). Absence du fichier ou du symbole : pas fatal, juste moins
# de couverture (repli sur la base interne de la libSDL2 installée).
if _add_mappings_from_file is not None and os.path.isfile(GAMECONTROLLERDB_PATH):
    _add_mappings_from_file(GAMECONTROLLERDB_PATH.encode("utf-8"))
elif _add_mappings_from_file is None:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_GameControllerAddMappingsFromFile indisponible dans "
        "cette libSDL2 -- base bundlée ignorée, repli sur la base interne de la lib installée.\n"
    )


def _resolve_xdotool():
    if shutil.which("xdotool"):
        return "xdotool"
    if os.access("/run/host/usr/bin/xdotool", os.X_OK):
        return "/run/host/usr/bin/xdotool"
    return None


XDOTOOL_BIN = _resolve_xdotool()

# Codes clavier Linux (linux/input-event-codes.h) pour ydotool -- KEY_LEFTALT=56, KEY_F4=62.
YDOTOOL_ALT_F4 = ["56:1", "62:1", "62:0", "56:0"]


def send_alt_f4():
    try:
        if SESSION_KIND == "x11" and XDOTOOL_BIN:
            subprocess.run([XDOTOOL_BIN, "key", "alt+F4"], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif shutil.which("ydotool"):
            subprocess.run(["ydotool", "key", *YDOTOOL_ALT_F4], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass  # best-effort, comme send_key() dans zgu-gamepad-bridge.py


# --- Boutons/axes standardisés SDL2 (SDL_GameControllerButton / SDL_GameControllerAxis,
# valeurs numériques fixes de l'API C -- voir SDL_gamecontroller.h) -- PLUS de codes bruts
# propres à une manette précise (voir historique en tête de fichier) : SDL2 traduit chaque
# manette reconnue vers ce layout fixe, quel que soit le modèle.
SDL_CONTROLLER_BUTTON_LEFTSTICK = 7        # clic stick gauche (L3)
SDL_CONTROLLER_BUTTON_RIGHTSTICK = 8       # clic stick droit (R3)
SDL_CONTROLLER_BUTTON_LEFTSHOULDER = 9     # L1
SDL_CONTROLLER_BUTTON_RIGHTSHOULDER = 10   # R1
SDL_CONTROLLER_AXIS_TRIGGERLEFT = 4        # L2 (analogique, 0..32767)
SDL_CONTROLLER_AXIS_TRIGGERRIGHT = 5       # R2 (analogique, 0..32767)

COMBO_BUTTONS = (
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_LEFTSTICK,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
)
COMBO_AXES = (SDL_CONTROLLER_AXIS_TRIGGERLEFT, SDL_CONTROLLER_AXIS_TRIGGERRIGHT)
AXIS_PULL_THRESHOLD = int(32767 * 0.9)  # gâchette "enfoncée" au-delà de 90% de sa course
POLL_INTERVAL_SECONDS = 0.05


def find_controllers():
    pads = []
    for i in range(sdl.SDL_NumJoysticks()):
        if sdl.SDL_IsGameController(i):
            handle = sdl.SDL_GameControllerOpen(i)
            if handle:
                pads.append(handle)
    return pads


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
    pads = find_controllers()
    if not pads:
        sdl.SDL_Quit()
        sys.exit(0)

    try:
        while running:
            sdl.SDL_GameControllerUpdate()
            if combo_complete(pads):
                send_alt_f4()
                return
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
