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
#   BTN_SOUTH ("A")                 -> Entrée, PUIS clic direct sur le bouton par défaut
#                                       de la boîte de dialogue (voir note "VALIDATION" ci-
#                                       dessous -- ce n'est PAS juste "Entrée")
#   BTN_EAST  ("B")                 -> Échap                (annuler/fermer)
#   BTN_WEST  ("X")                 -> Gauche puis Espace   (cocher/décocher une case radio/
#                                                             checklist -- voir note ci-dessous)
#   BTN_TL (gâchette gauche)        -> Maj+Tab              (champ précédent)
#   BTN_TR (gâchette droite)        -> Tab                  (champ suivant)
#
# Pourquoi "Gauche puis Espace" pour BTN_WEST : dans un zenity --radiolist/--checklist, la
# colonne case à cocher (tout à gauche) et la colonne texte ont chacune leur propre "focus
# cellule" au sein de la ligne survolée -- Haut/Bas ne déplacent que la ligne, pas cette
# cellule. Par défaut le focus cellule est sur la colonne texte, donc Espace seul ne coche
# rien tant qu'un clic souris n'a pas explicitement déplacé ce focus sur la colonne case (et
# il y reste ensuite). Envoyer Gauche avant Espace déplace ce focus sur la colonne case (la
# plus à gauche) à chaque pression, sans jamais dépendre d'un clic souris préalable -- sans
# risque : Gauche sur une colonne déjà la plus à gauche ne fait rien.
#
# ARMEMENT CLAVIER (tous boutons) -- découverte clé, vérifiée en test réel avec Harry :
# une zenity --radiolist/--checklist fraîchement affichée n'accepte AUCUNE interaction
# clavier sur sa liste (Espace/Entrée ne cochent/sélectionnent rien) tant qu'un vrai
# événement pointeur n'a pas eu lieu sur elle au moins une fois -- comportement de
# GtkTreeView, pas un bug de lpm ni du bridge. Un clic SIMULÉ (via AT-SPI, XTest) a le même
# effet qu'un clic réel (vérifié). Solution : à chaque nouvelle fenêtre zenity détectée
# (par pid, une fois chacune -- voir ARMED_PIDS/ensure_zenity_armed), le bridge simule un
# clic sur la cellule TEXTE (jamais la case à cocher) de la première ligne, avant tout
# traitement d'appui manette. Best-effort : si AT-SPI est indisponible, cette étape est
# simplement sautée (le pont reste utilisable pour Haut/Bas/Échap, mais Espace/Entrée ne
# fonctionneront pas tant qu'un clic réel n'aura pas eu lieu par ailleurs).
#
# VALIDATION (BTN_SOUTH / "A") -- pourquoi "Espace" + clic direct, pas juste "Entrée" :
# une fois la liste armée (voir ci-dessus), c'est "Espace" qui pose le point radio / coche
# la case sur la ligne survolée (vérifié en test réel -- "Entrée" seul seul seul n'a pas le
# même effet sur ce zenity). Mais quelle que soit la touche, elle ne fait jamais que ça :
# jamais transmise au bouton de validation de la fenêtre ("Valider"), sauf si le focus
# clavier y est explicitement (ce qui ne s'obtient normalement qu'en tabulant depuis la
# liste -- compter les Tab nécessaires est fragile, dépend du nombre/ordre des boutons de
# chaque écran). Solution retenue, testée fonctionnelle : après "Espace", on clique
# DIRECTEMENT sur le bouton de validation via AT-SPI, repéré par son libellé
# (CONFIRM_BUTTON_LABELS ci-dessous). L'état GTK IS_DEFAULT a été essayé en premier et
# écarté : testé en réel, aucun bouton ne le porte sur ce zenity (ni "Valider" ni
# "Annuler") -- abandonné pour le matching par libellé, moins "élégant" mais vérifié
# fonctionnel. Couvre pour l'instant les deux langues implémentées (FR "Valider", EN "OK"
# -- le libellé par défaut de zenity) ; ajouter un libellé dans CONFIRM_BUTTON_LABELS le
# jour où une langue supplémentaire est ajoutée au projet. Best-effort : si AT-SPI est
# indisponible ou ne trouve aucun bouton correspondant, on ne fait rien de plus (l'appui
# "Espace" seul reste envoyé, comme avant).
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
import time

try:
    import evdev
    from evdev import InputDevice, ecodes
except Exception as exc:  # pragma: no cover - dépendance système absente
    sys.stderr.write("zgu-gamepad-bridge: python3-evdev indisponible (%s)\n" % exc)
    sys.exit(1)

# AT-SPI est utilisé uniquement pour le clic direct sur le bouton par défaut (BTN_SOUTH) --
# absence tolérée : le pont reste utilisable (Haut/Bas/Entrée brut/Échap/etc.), seule la
# validation "un seul bouton" perd son clic direct et retombe sur l'Entrée simple.
try:
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
except Exception:
    Atspi = None

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


# Libellés du bouton de validation reconnus, tous les langages actuellement gérés par le
# projet (voir note "VALIDATION" en tête de fichier) -- "OK" est le libellé par défaut de
# zenity quand bin/lpm ne le surcharge pas explicitement en anglais.
CONFIRM_BUTTON_LABELS = ("Valider", "OK")

# Délai (secondes) laissé à zenity/GTK pour traiter l'appui "Entrée" (poser le point radio
# / cocher la case) avant qu'on aille chercher et cliquer le bouton de validation --
# constaté en test réel : xdotool rend la main dès que le serveur X a reçu l'événement
# synthétique, pas une fois que l'appli l'a effectivement traité. Sans ce délai, le clic
# AT-SPI part trop tôt et voit "rien n'est sélectionné" (lpm se ferme au lieu d'ouvrir le
# sous-menu attendu). Valeur choisie généreuse mais imperceptible à l'usage.
CONFIRM_CLICK_DELAY = 0.08


def _find_table(acc):
    """Parcourt récursivement l'arbre AT-SPI et renvoie le premier accessible de rôle
    'table' (la liste --radiolist/--checklist), ou None. Best-effort."""
    try:
        if acc.get_role_name() == "table":
            return acc
    except Exception:
        pass
    try:
        n = acc.get_child_count()
    except Exception:
        return None
    for i in range(n):
        try:
            child = acc.get_child_at_index(i)
        except Exception:
            continue
        if child is None:
            continue
        found = _find_table(child)
        if found is not None:
            return found
    return None


# PIDs des fenêtres zenity déjà "armées" (voir note ARMEMENT CLAVIER en tête de fichier) --
# un seul clic d'armement par fenêtre, jamais répété une fois fait (inutile, et éviterait
# de re-cliquer sans arrêt sur la première ligne à chaque appui).
ARMED_PIDS = set()

# Index, dans les enfants du 'table' AT-SPI, de la cellule TEXTE (pas la case à cocher) de
# la première ligne -- structure constatée en test réel : 0=en-tête colonne "Choix",
# 1=en-tête colonne "Action", 2=case à cocher ligne 0, 3=texte ligne 0. On clique
# volontairement sur le texte, jamais la case, pour ne jamais cocher/sélectionner quoi que
# ce soit par accident en armant la fenêtre.
FIRST_ROW_TEXT_CELL_INDEX = 3


def ensure_zenity_armed():
    """Simule un clic (AT-SPI) sur la cellule texte de la première ligne de la fenêtre
    zenity actuellement affichée, une seule fois par fenêtre (par pid), pour débloquer les
    interactions clavier (Espace/Entrée) sur sa liste -- voir note ARMEMENT CLAVIER en
    tête de fichier. Best-effort total : ne fait rien si AT-SPI est indisponible, si
    aucune appli zenity n'est trouvée, ou sur toute erreur."""
    if Atspi is None:
        return
    try:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if app is None:
                continue
            name = (app.get_name() or "").lower()
            if "zenity" not in name:
                continue
            try:
                pid = app.get_process_id()
            except Exception:
                pid = None
            if pid is not None and pid in ARMED_PIDS:
                return
            table = _find_table(app)
            if table is None:
                return
            try:
                if table.get_child_count() <= FIRST_ROW_TEXT_CELL_INDEX:
                    return
                cell = table.get_child_at_index(FIRST_ROW_TEXT_CELL_INDEX)
            except Exception:
                return
            if cell is None:
                return
            try:
                ext = cell.get_extents(Atspi.CoordType.SCREEN)
                x = ext.x + ext.width // 2
                y = ext.y + ext.height // 2
                # DEUX clics, pas un seul : sur une checklist, un clic sur une ligne coche
                # ou décoche sa case QUELLE QUE SOIT la colonne cliquée (constaté par
                # Harry, prémisse acquise -- pas seulement la colonne case comme supposé
                # au départ). Cliquer une seule fois changerait donc l'état initial d'une
                # case par accident. Deux clics sur le même point ramènent cet état à son
                # point de départ (coché->décoché->coché ou l'inverse). Le délai entre les
                # deux (au-delà du délai de détection du double-clic de GTK, ~400ms) est
                # volontaire : un vrai double-clic sur une ligne zenity valide directement
                # la fenêtre (comme Entrée), ce qu'on veut éviter à tout prix ici -- deux
                # clics simples espacés n'ont pas cet effet.
                Atspi.generate_mouse_event(x, y, "b1c")
                time.sleep(0.45)
                Atspi.generate_mouse_event(x, y, "b1c")
                sys.stderr.write(f"[DEBUG] double clic d'armement envoyé sur {cell.get_name()!r} ({x},{y}), pid={pid}\n")
            except Exception as exc:
                sys.stderr.write(f"[DEBUG] échec du clic d'armement: {exc}\n")
                return
            if pid is not None:
                ARMED_PIDS.add(pid)
            return
    except Exception:
        pass  # best-effort : jamais fatal pour le pont


def _find_confirm_button(acc):
    """Parcourt récursivement l'arbre AT-SPI d'un accessible et renvoie le premier
    'push button' dont le libellé correspond à CONFIRM_BUTTON_LABELS, ou None.
    Best-effort : toute erreur d'un noeud est ignorée, jamais fatale."""
    try:
        if acc.get_role_name() == "push button" and acc.get_name() in CONFIRM_BUTTON_LABELS:
            return acc
    except Exception:
        pass
    try:
        n = acc.get_child_count()
    except Exception:
        return None
    for i in range(n):
        try:
            child = acc.get_child_at_index(i)
        except Exception:
            continue
        if child is None:
            continue
        found = _find_confirm_button(child)
        if found is not None:
            return found
    return None


def click_default_zenity_button():
    """Cherche la fenêtre zenity actuellement affichée et clique directement sur son
    bouton de validation (repéré par libellé, voir CONFIRM_BUTTON_LABELS), sans dépendre
    du focus clavier ni de l'ordre/nombre de boutons. Best-effort total : ne fait rien si
    AT-SPI est indisponible, si aucune appli zenity n'est trouvée, ou sur toute erreur."""
    if Atspi is None:
        sys.stderr.write("[DEBUG] click_default_zenity_button: Atspi est None (import échoué)\n")
        return
    time.sleep(CONFIRM_CLICK_DELAY)
    try:
        desktop = Atspi.get_desktop(0)
        n = desktop.get_child_count()
        sys.stderr.write(f"[DEBUG] {n} application(s) trouvée(s) sur le bureau AT-SPI\n")
        zenity_found = False
        for i in range(n):
            app = desktop.get_child_at_index(i)
            if app is None:
                continue
            name = (app.get_name() or "").lower()
            if "zenity" not in name:
                continue
            zenity_found = True
            button = _find_confirm_button(app)
            if button is not None:
                sys.stderr.write(f"[DEBUG] bouton trouvé: {button.get_name()!r} -> clic\n")
                try:
                    button.do_action(0)
                    sys.stderr.write("[DEBUG] do_action(0) exécuté sans exception\n")
                except Exception as exc:
                    sys.stderr.write(f"[DEBUG] do_action a levé une exception: {exc}\n")
                return
            else:
                sys.stderr.write("[DEBUG] appli zenity trouvée mais aucun bouton correspondant à CONFIRM_BUTTON_LABELS\n")
        if not zenity_found:
            sys.stderr.write("[DEBUG] aucune application 'zenity' trouvée via AT-SPI\n")
    except Exception as exc:
        sys.stderr.write(f"[DEBUG] exception dans click_default_zenity_button: {exc}\n")


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
BTN_PREV_FIELD = resolve_button_code("BTN_TL")
BTN_NEXT_FIELD = resolve_button_code("BTN_TR")

# BUG CORRIGÉ : resolve_button_code() ne renvoie qu'UN SEUL code (le premier nom
# existant), donc "BTN_WEST" (toujours défini par evdev) l'emportait systématiquement et
# "BTN_C" n'était jamais retenu même en le passant en argument -- alors que certaines
# manettes (constaté par Harry sur une 8BitDo SN30 Pro+) remontent leur bouton face ouest
# ("X") comme BTN_C (306) plutôt que BTN_WEST (308), héritage de la nomenclature evdev des
# manettes Sega Genesis à 6 boutons, réutilisée par certains pilotes/modes génériques.
# Cette fois on collecte TOUS les codes candidats qui existent réellement sur cette
# version d'evdev, et on les mappe TOUS vers la même action -- BTN_WEST/BTN_X pour les
# manettes standard, BTN_C en plus pour celles qui l'utilisent à la place.
BTN_CHECK_CODES = {
    code for code in (
        getattr(ecodes, "BTN_WEST", None),
        getattr(ecodes, "BTN_X", None),
        getattr(ecodes, "BTN_C", None),
    )
    if code is not None
}

# Chaque bouton associe une SÉQUENCE de touches (une liste, envoyées dans l'ordre) plutôt
# qu'une touche unique -- nécessaire pour le bouton "check" (voir note plus haut : Gauche
# doit précéder Espace à chaque pression, pour ne jamais dépendre d'un focus déjà en place).
BUTTON_KEY_MAP = {}
if BTN_CONFIRM is not None:
    # "space" et non "Return" : vérifié en test réel, c'est Espace qui pose le point radio
    # / coche la case une fois la liste armée (voir note ARMEMENT CLAVIER) -- "Return" seul
    # n'a pas cet effet sur ce zenity.
    BUTTON_KEY_MAP[BTN_CONFIRM] = ["space"]
if BTN_CANCEL is not None:
    BUTTON_KEY_MAP[BTN_CANCEL] = ["Escape"]
for _code in BTN_CHECK_CODES:
    BUTTON_KEY_MAP[_code] = ["Left", "space"]
if BTN_PREV_FIELD is not None:
    BUTTON_KEY_MAP[BTN_PREV_FIELD] = ["shift+Tab"]
if BTN_NEXT_FIELD is not None:
    BUTTON_KEY_MAP[BTN_NEXT_FIELD] = ["Tab"]

# Actions supplémentaires à exécuter après la séquence de touches d'un bouton -- seul
# BTN_CONFIRM en a besoin pour l'instant (voir note "VALIDATION" en tête de fichier).
BUTTON_EXTRA_ACTION = {}
if BTN_CONFIRM is not None:
    BUTTON_EXTRA_ACTION[BTN_CONFIRM] = click_default_zenity_button

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
        # Vérifié à chaque tour de boucle (~5x/seconde, indépendamment des appuis manette)
        # plutôt que sur le premier appui de bouton : sinon, si l'utilisateur a déjà navigué
        # avec les flèches avant ce premier appui, le clic d'armement (sur la 1ère ligne)
        # annulerait sa navigation. Ici, une nouvelle fenêtre est armée quasi immédiatement
        # après son apparition, bien avant qu'une navigation ait pu avoir lieu.
        ensure_zenity_armed()
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
                        sys.stderr.write(f"[DEBUG] bouton pressé, code={event.code}"
                                          f" (BTN_CONFIRM={BTN_CONFIRM}, BTN_CANCEL={BTN_CANCEL},"
                                          f" BTN_CHECK_CODES={sorted(BTN_CHECK_CODES)})\n")
                        key_sequence = BUTTON_KEY_MAP.get(event.code)
                        if key_sequence is not None:
                            sys.stderr.write(f"[DEBUG] séquence de touches envoyée: {key_sequence}\n")
                            for key_name in key_sequence:
                                send_key(key_name)
                        else:
                            sys.stderr.write("[DEBUG] code non reconnu dans BUTTON_KEY_MAP -- aucune touche envoyée\n")
                        extra_action = BUTTON_EXTRA_ACTION.get(event.code)
                        if extra_action is not None:
                            extra_action()
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
