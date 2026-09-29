#!/usr/bin/env python3
# --- lpm launcher : pont manette -> clavier, avec verrou exclusif sur la manette ---
#
# Usage : zgu-launcher-gamepad-bridge.py <x11|wayland>
#
# Deux rôles en un seul processus, indissociables (voir l'échange qui a mené à ce choix) :
#
#   1. VERROU EXCLUSIF : chaque manette détectée est ouverte en lecture directe via evdev
#      (/dev/input/event*) et verrouillée avec InputDevice.grab() (ioctl EVIOCGRAB du noyau
#      Linux) -- tant que ce processus tourne, AUCUN autre programme sur la machine (un
#      frontend façon Batocera qui lirait la manette au niveau matériel, par exemple) ne
#      reçoit ses événements, même si ce même frontend est resté ouvert en arrière-plan
#      derrière l'écran noir. C'est délibérément evdev/EVIOCGRAB plutôt que SDL2 : SDL2 ne
#      s'enregistre que comme UN lecteur de plus du périphérique, sans empêcher les autres
#      -- EVIOCGRAB est le mécanisme noyau standard pour une exclusivité réelle.
#
#   2. PONT VERS LE CLAVIER : les mêmes événements, une fois captés, sont traduits en
#      appuis clavier (Haut/Bas/Entrée) injectés dans la fenêtre ayant le focus, via xdotool
#      (X11) ou ydotool (Wayland) -- Zenity (--list) navigue déjà nativement au clavier,
#      donc aucune logique de menu à réécrire ici, seulement une traduction d'événements.
#      Le focus de la fenêtre Zenity elle-même est déjà assuré par zgu-focus-utils.sh
#      (sourcé par le script bash appelant), pas le problème de ce script.
#
# Détection des manettes : tout périphérique evdev exposant BTN_SOUTH (bouton "A"/face sud,
# présent sur toutes les manettes standard, manettes Xbox/PlayStation/Switch Pro incluses)
# OU un stick gauche (ABS_X/ABS_Y) est considéré comme une manette. Un nouveau périphérique
# branché après le démarrage n'est PAS détecté à chaud (scan une seule fois au lancement) :
# limitation acceptée, le cas d'usage est "la manette est déjà branchée avant de lancer le
# jeu", pas un branchement à chaud pendant l'affichage du picker.
#
# Arrêt : SIGTERM (envoyé par le script bash appelant une fois le splash terminé) -- chaque
# manette est proprement dégrappée (ungrab) avant de quitter, jamais laissée verrouillée si
# ce script est tué brutalement d'une autre façon (SIGKILL) : filet de sécurité, le bash
# appelant ne doit normalement jamais avoir besoin d'un SIGKILL ici.

import sys
import signal
import subprocess
import shutil

try:
    import evdev
    from evdev import InputDevice, ecodes
except Exception as exc:  # pragma: no cover - dépendance système absente
    sys.stderr.write("zgu-launcher-gamepad-bridge: python3-evdev indisponible (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 2 or sys.argv[1] not in ("x11", "wayland"):
    sys.stderr.write("Usage: zgu-launcher-gamepad-bridge.py <x11|wayland>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]

AXIS_THRESHOLD = 0.5  # fraction de l'amplitude min/max avant de considérer l'axe "poussé"

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
    try:
        if SESSION_KIND == "x11" and shutil.which("xdotool"):
            subprocess.run(["xdotool", "key", key_name], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif shutil.which("ydotool"):
            ydotool_key = {"Up": "103:1", "Down": "108:1", "Return": "28:1"}.get(key_name)
            if ydotool_key:
                subprocess.run(["ydotool", "key", ydotool_key], check=False,
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
        for code in (ecodes.ABS_Y, ecodes.ABS_HAT0Y):
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
                        if event.code == ecodes.BTN_SOUTH or event.code == ecodes.BTN_A:
                            send_key("Return")
                    elif event.type == ecodes.EV_ABS and event.code in (ecodes.ABS_Y, ecodes.ABS_HAT0Y):
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
                            send_key("Up" if direction < 0 else "Down")
                        last_axis_dir[key] = direction
            except (OSError, BlockingIOError):
                continue

    release_all()


if __name__ == "__main__":
    main()
