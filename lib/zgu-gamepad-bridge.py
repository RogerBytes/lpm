#!/usr/bin/env python3
# --- lpm launcher : pont manette -> clavier, avec verrou exclusif sur la manette ---
#
# Usage : zgu-gamepad-bridge.py <x11|wayland>
#
# (Renommé depuis zgu-launcher-gamepad-bridge.py : à l'origine spawné uniquement par
# l'orchestrateur de l'écran de chargement, ce pont est maintenant aussi démarré par
# bin/lpm pour toute la session interactive -- voir zgu-gamepad-nav-utils.sh -- donc son
# nom ne doit plus être spécifique au "launcher".)
#
# Deux rôles en un seul processus, indissociables (voir l'échange qui a mené à ce choix) :
#
#   1. VERROU EXCLUSIF : chaque manette détectée est ouverte en lecture directe via evdev
#      (/dev/input/event*) et verrouillée avec InputDevice.grab() (ioctl EVIOCGRAB du noyau
#      Linux) -- tant que ce processus tourne, AUCUN autre programme sur la machine (un
#      frontend façon Batocera qui lirait la manette au niveau matériel, par exemple) ne
#      reçoit ses événements, même si ce même frontend est resté ouvert en arrière-plan
#      derrière l'écran noir ou un des menus lpm. C'est délibérément evdev/EVIOCGRAB plutôt
#      que SDL2 : SDL2 ne s'enregistre que comme UN lecteur de plus du périphérique, sans
#      empêcher les autres -- EVIOCGRAB est le mécanisme noyau standard pour une exclusivité
#      réelle.
#
#   2. PONT VERS LE CLAVIER : les mêmes événements, une fois captés, sont traduits en
#      appuis clavier injectés dans la fenêtre ayant le focus, via xdotool (X11) ou ydotool
#      (Wayland, jeu de touches plus limité -- voir KEY_MAP ci-dessous) -- Zenity navigue
#      déjà nativement au clavier (--list, --checklist, --entry...), donc aucune logique de
#      menu à réécrire ici, seulement une traduction d'événements. Le focus de la fenêtre
#      Zenity elle-même est déjà assuré par zgu-focus-utils.sh (sourcé par le script bash
#      appelant), pas le problème de ce script.
#
# Traductions manette -> clavier :
#   Stick gauche / D-pad vertical   -> Haut / Bas          (déplacement dans une liste)
#   Stick gauche / D-pad horizontal -> Gauche / Droite      (déplacement horizontal, onglets)
#   BTN_SOUTH ("A")                 -> Entrée               (valider)
#   BTN_EAST  ("B")                 -> Échap                (annuler/fermer)
#   BTN_WEST  ("X")                 -> Espace               (cocher/décocher une checklist)
#   BTN_TL (gâchette gauche)        -> Maj+Tab              (champ précédent)
#   BTN_TR (gâchette droite)        -> Tab                  (champ suivant)
#
# Détection des manettes : tout périphérique evdev exposant BTN_SOUTH (bouton "A"/face sud,
# présent sur toutes les manettes standard, manettes Xbox/PlayStation/Switch Pro incluses)
# OU un stick gauche (ABS_X/ABS_Y) est considéré comme une manette. Un nouveau périphérique
# branché après le démarrage n'est PAS détecté à chaud (scan une seule fois au lancement) :
# limitation acceptée, le cas d'usage est "la manette est déjà branchée avant de lancer lpm
# ou le jeu", pas un branchement à chaud en cours de session.
#
# Arrêt : SIGTERM (envoyé par le script bash appelant) -- chaque manette est proprement
# dégrappée (ungrab) avant de quitter, jamais laissée verrouillée si ce script est tué
# brutalement d'une autre façon (SIGKILL) : filet de sécurité, le bash appelant ne doit
# normalement jamais avoir besoin d'un SIGKILL ici.

import sys
import signal
import subprocess
import shutil

try:
    import evdev
    from evdev import InputDevice, ecodes
except Exception as exc:  # pragma: no cover - dépendance système absente
    sys.stderr.write("zgu-gamepad-bridge: python3-evdev indisponible (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 2 or sys.argv[1] not in ("x11", "wayland"):
    sys.stderr.write("Usage: zgu-gamepad-bridge.py <x11|wayland>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]

AXIS_THRESHOLD = 0.5  # fraction de l'amplitude min/max avant de considérer l'axe "poussé"

# --- Table de traduction touche logique -> commande xdotool / séquence ydotool ---
# ydotool ne prend pas de noms de touches symboliques : il faut ses propres codes clavier
# Linux (linux/input-event-codes.h), envoyés comme "code:etat" (1=pressé, 0=relâché) --
# jeu volontairement restreint à ce qui est réellement utile ici (pas de couverture
# complète du clavier, ydotool + Wayland restent le chemin "best effort" du projet).
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

grabbed_devices = []
running = True


def find_gamepads():
    pads = []
    for path in evdev.list_devices():
        try:
            dev = InputDevice(path)
            caps = dev.capabilities()
            keys = caps.get(ecodes.EV_KEY, [])
            abs_axes = [a for a, _ in caps.get(ecodes.EV_ABS, [])]
            if ecodes.BTN_SOUTH in keys or (ecodes.ABS_X in abs_axes and ecodes.ABS_Y in abs_axes):
                pads.append(dev)
            else:
                dev.close()
        except Exception:
            continue
    return pads


def send_key(key_name):
    mapping = KEY_MAP.get(key_name)
    if mapping is None:
        return
    try:
        if SESSION_KIND == "x11" and shutil.which("xdotool"):
            subprocess.run(["xdotool", "key", mapping["xdotool"]], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif shutil.which("ydotool"):
            subprocess.run(["ydotool", "key", *mapping["ydotool"]], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass  # best-effort : un appui manqué ne doit jamais faire planter le pont


def release_all():
    for dev in grabbed_devices:
        try:
            dev.ungrab()
        except Exception:
            pass
        try:
            dev.close()
        except Exception:
            pass


def handle_signal(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def axis_range(dev, code):
    info = dev.absinfo(code)
    return info.min, info.max


# --- Boutons face -> touche logique : plusieurs noms evdev possibles par bouton (alias
# selon le pilote/la manette), on prend le premier disponible et on retombe sur None si
# aucun n'existe sur cette version d'evdev (défensif, jamais rencontré en pratique). ---
def resolve_button_code(*names):
    for name in names:
        code = getattr(ecodes, name, None)
        if code is not None:
            return code
    return None


BTN_CONFIRM = resolve_button_code("BTN_SOUTH", "BTN_A")
BTN_CANCEL = resolve_button_code("BTN_EAST", "BTN_B")
BTN_CHECK = resolve_button_code("BTN_WEST", "BTN_X")
BTN_PREV_FIELD = resolve_button_code("BTN_TL")
BTN_NEXT_FIELD = resolve_button_code("BTN_TR")

BUTTON_KEY_MAP = {}
if BTN_CONFIRM is not None:
    BUTTON_KEY_MAP[BTN_CONFIRM] = "Return"
if BTN_CANCEL is not None:
    BUTTON_KEY_MAP[BTN_CANCEL] = "Escape"
if BTN_CHECK is not None:
    BUTTON_KEY_MAP[BTN_CHECK] = "space"
if BTN_PREV_FIELD is not None:
    BUTTON_KEY_MAP[BTN_PREV_FIELD] = "shift+Tab"
if BTN_NEXT_FIELD is not None:
    BUTTON_KEY_MAP[BTN_NEXT_FIELD] = "Tab"

# --- Axes -> paire (touche négative, touche positive) ---
AXIS_KEY_MAP = {
    ecodes.ABS_Y: ("Up", "Down"),
    ecodes.ABS_HAT0Y: ("Up", "Down"),
    ecodes.ABS_X: ("Left", "Right"),
    ecodes.ABS_HAT0X: ("Left", "Right"),
}


def main():
    pads = find_gamepads()
    if not pads:
        # Pas de manette détectée : rien à verrouiller ni à traduire, sortie silencieuse
        # (le clavier/la souris continuent de fonctionner normalement sans ce script).
        sys.exit(0)

    for dev in pads:
        try:
            dev.grab()
            grabbed_devices.append(dev)
        except Exception:
            pass  # déjà verrouillée par un autre processus, ou permissions insuffisantes

    if not grabbed_devices:
        sys.exit(0)

    axis_ranges = {}
    for dev in grabbed_devices:
        for code in AXIS_KEY_MAP:
            try:
                axis_ranges[(dev.path, code)] = axis_range(dev, code)
            except Exception:
                pass

    last_axis_dir = {}

    import select
    device_map = {dev.fd: dev for dev in grabbed_devices}

    while running:
        try:
            r, _, _ = select.select(device_map.keys(), [], [], 0.2)
        except (OSError, ValueError):
            break

        for fd in r:
            dev = device_map.get(fd)
            if dev is None:
                continue
            try:
                for event in dev.read():
                    if event.type == ecodes.EV_KEY and event.value == 1:
                        key_name = BUTTON_KEY_MAP.get(event.code)
                        if key_name is not None:
                            send_key(key_name)
                    elif event.type == ecodes.EV_ABS and event.code in AXIS_KEY_MAP:
                        key = (dev.path, event.code)
                        lo, hi = axis_ranges.get(key, (-32768, 32767))
                        span = (hi - lo) or 1
                        normalized = (event.value - lo) / span * 2 - 1  # -1..1
                        direction = 0
                        if normalized < -AXIS_THRESHOLD:
                            direction = -1
                        elif normalized > AXIS_THRESHOLD:
                            direction = 1
                        if direction != last_axis_dir.get(key, 0) and direction != 0:
                            neg_key, pos_key = AXIS_KEY_MAP[event.code]
                            send_key(neg_key if direction < 0 else pos_key)
                        last_axis_dir[key] = direction
            except (OSError, BlockingIOError):
                continue

    release_all()


if __name__ == "__main__":
    main()
