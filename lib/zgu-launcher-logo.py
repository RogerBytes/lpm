#!/usr/bin/env python3
# --- lpm launcher : logo du jeu, toujours au premier plan (écran noir, picker, bannière) ---
#
# Usage : zgu-launcher-logo.py <logo_png> [<control_file>]
#
# Fenêtre séparée, DÉLIBÉRÉMENT distincte de zgu-launcher-blackscreen.py et de
# zgu-launcher-picker.py : ces deux-là s'échangent la place au premier plan pendant le
# lancement (le picker passe au-dessus du fond le temps du choix, voir
# zgl-launcher-orchestrator.sh et le "keep_above" togglé via IND_HIDE/IND_SHOW dans
# zgu-launcher-blackscreen.py) -- le logo, lui, doit rester visible EN PERMANENCE, par-dessus
# les DEUX, sans jamais redescendre, ET sans jamais clignoter/disparaître un instant.
#
# Ordre des calques voulu, du plus fort (0) au plus faible :
#   0. le logo (ce script)       -- toujours au sommet, jamais retouché
#   1. le picker OU la bannière/l'indicateur de chargement (écran noir) -- s'échangent la
#      place entre eux, jamais au-dessus du logo
# Deux essais précédents ont échoué à obtenir cet ordre de façon fiable :
#   - un simple "keep_above" sur une fenêtre normale : ne garantit aucun ordre RELATIF entre
#     plusieurs fenêtres qui sont toutes "above" -- dès que l'écran noir repasse
#     keep_above=True (IND_SHOW, picker refermé), il peut repasser devant le logo.
#   - un indice de type "DOCK" : pire, pas mieux -- l'écran noir et le picker sont mis en
#     plein écran natif (Gtk.Window.fullscreen()), et la plupart des gestionnaires de
#     fenêtres placent la couche "plein écran" AU-DESSUS de la couche "dock/panneau" (pensé
#     pour qu'un jeu ou une vidéo recouvre la barre des tâches) -- le logo disparaissait donc
#     ENTIÈREMENT derrière l'écran noir, constaté réel.
# Solution retenue : le logo est LUI AUSSI mis en plein écran natif (comme l'écran noir),
# donc dans la MÊME couche d'empilement qu'eux -- transparent partout sauf sur l'image du
# logo elle-même, dessinée à la position voulue par Cairo plutôt que déplacée en bougeant la
# fenêtre. Dans une même couche, l'ordre relatif ne dépend plus que de qui a été "relevé" le
# plus récemment : ce script surveille donc le MÊME fichier de contrôle que
# zgu-launcher-blackscreen.py (2ème argument, optionnel) et se relève (present()) à chaque
# changement d'état -- exactement au moment où l'écran noir fait lui aussi
# set_keep_above(True)/se relève (voir poll_control_file dans zgu-launcher-blackscreen.py),
# donc synchronisé avec lui plutôt qu'un sondage périodique indépendant qui laisserait un
# court instant où l'ordre est inversé.
#
# Position : centré horizontalement, et centré VERTICALEMENT entre le haut de l'écran et le
# haut de la zone où s'affichent ensuite le picker/la bannière -- cette zone a une position
# fixe (le picker est une fenêtre de taille fixe, toujours centrée à l'écran, voir
# PICKER_BOX_HEIGHT ci-dessous qui doit rester synchronisé avec
# zgu-launcher-picker.py:set_default_size), donc le logo garde la même place que le picker
# soit affiché ou non.
# Taille : celle de l'image PNG, plafonnée pour ne jamais dépasser une fraction raisonnable
# de l'écran NI déborder dans la zone du picker (un logo peut être fourni dans une résolution
# disproportionnée).

import sys
import os

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GLib
    import cairo
except Exception as exc:  # pragma: no cover - dépendance système absente
    sys.stderr.write("zgu-launcher-logo: GTK/PyGObject indisponible (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 2:
    sys.stderr.write("Usage: zgu-launcher-logo.py <logo_png> [<control_file>]\n")
    sys.exit(1)

LOGO_PATH = sys.argv[1]
CONTROL_FILE = sys.argv[2] if len(sys.argv) > 2 else ""
POLL_MS = 150  # même cadence que zgu-launcher-blackscreen.py -- voir l'en-tête de fichier

# Doit rester en phase avec zgu-launcher-picker.py:set_default_size(900, 680) -- c'est ce qui
# définit la position fixe du haut du picker à l'écran (fenêtre centrée), donc la "zone" par
# rapport à laquelle le logo se centre verticalement.
PICKER_BOX_HEIGHT = 680

MAX_WIDTH_FRACTION = 0.46
MIN_TOP_MARGIN = 24  # garde-fou si l'écran est petit ou le picker haut : jamais collé au bord

is_wayland = (os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland") or bool(
    os.environ.get("WAYLAND_DISPLAY")
)

windows = []


class LogoWindow(Gtk.Window):
    def __init__(self, monitor_geom, surface):
        super().__init__()
        self.surface = surface
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)  # jamais togglé -- voir l'en-tête de fichier
        self.set_app_paintable(True)
        self.set_accept_focus(False)
        self.set_can_focus(False)

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)

        self.move(monitor_geom.x, monitor_geom.y)
        self.resize(monitor_geom.width, monitor_geom.height)
        self.set_default_size(monitor_geom.width, monitor_geom.height)

        # Zone fixe au-dessus de laquelle le picker/la bannière apparaissent -- voir
        # PICKER_BOX_HEIGHT plus haut.
        zone_top_y = max(0, (monitor_geom.height - PICKER_BOX_HEIGHT) / 2)
        usable_h = max(0, zone_top_y - 2 * MIN_TOP_MARGIN)

        img_w, img_h = surface.get_width(), surface.get_height()
        max_w = monitor_geom.width * MAX_WIDTH_FRACTION
        max_h = usable_h if usable_h > 0 else monitor_geom.height * 0.2
        scale = min(1.0, max_w / img_w, max_h / img_h)
        self.draw_w = img_w * scale
        self.draw_h = img_h * scale

        # Position du logo À L'INTÉRIEUR de la fenêtre plein écran (dessin Cairo, pas
        # déplacement de fenêtre -- voir l'en-tête de fichier).
        self.draw_x = (monitor_geom.width - self.draw_w) / 2
        draw_y = (zone_top_y - self.draw_h) / 2
        self.draw_y = max(MIN_TOP_MARGIN, draw_y)

        self.connect("draw", self.on_draw)

    def on_draw(self, _widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)  # totalement transparent partout sauf le logo
        cr.paint()

        cr.set_operator(cairo.OPERATOR_OVER)
        img_w, img_h = self.surface.get_width(), self.surface.get_height()
        scale = self.draw_w / img_w
        cr.translate(self.draw_x, self.draw_y)
        cr.scale(scale, scale)
        cr.set_source_surface(self.surface, 0, 0)
        cr.paint()
        return False

    def reassert_above(self):
        self.set_keep_above(True)
        gdk_window = self.get_window()
        if gdk_window is not None:
            gdk_window.raise_()


def get_monitor_geometries():
    display = Gdk.Display.get_default()
    geoms = []
    n = display.get_n_monitors()
    primary_idx = 0
    for i in range(n):
        mon = display.get_monitor(i)
        if mon.is_primary():
            primary_idx = i
        geoms.append(mon.get_geometry())
    if is_wayland:
        return geoms  # même raisonnement multi-écran que zgu-launcher-blackscreen.py
    return [geoms[primary_idx]] if geoms else []


last_control_content = None


def poll_control_file():
    global last_control_content
    if not CONTROL_FILE:
        return False  # pas de fichier fourni : rien à surveiller, on arrête le sondage
    try:
        with open(CONTROL_FILE, "r") as f:
            content = f.read()
    except Exception:
        return True  # fichier momentanément illisible : on réessaie au prochain tick

    # Réagit à TOUT changement (pas seulement l'indicateur) : simple et sûr -- se relever
    # une fois de trop ne coûte rien, alors que rater le bon changement laisserait le logo
    # repasser derrière. Synchronisé sur la même cadence que
    # zgu-launcher-blackscreen.py:poll_control_file, donc pas de sondage "en plus" perçu
    # indépendamment de ses propres changements d'état.
    if content != last_control_content:
        last_control_content = content
        for win in windows:
            win.reassert_above()

    return True


def main():
    try:
        surface = cairo.ImageSurface.create_from_png(LOGO_PATH)
    except Exception as exc:
        sys.stderr.write("zgu-launcher-logo: image illisible (%s)\n" % exc)
        sys.exit(1)

    geoms = get_monitor_geometries()
    if not geoms:
        sys.stderr.write("zgu-launcher-logo: aucun écran détecté\n")
        sys.exit(1)

    for geom in geoms:
        win = LogoWindow(geom, surface)
        win.show_all()
        win.fullscreen()
        # Passage en plein écran = la fenêtre couvre maintenant TOUT l'écran, y compris les
        # zones transparentes où rien n'est dessiné -- sans ça, elle intercepte la souris sur
        # toute sa surface (constaté réel : plus moyen de cliquer/interagir avec le picker en
        # dessous, alors que le clavier fonctionnait puisque le focus, lui, reste bien exclu
        # via accept_focus/can_focus à False). "set_pass_through" laisse les évènements
        # souris traverser vers la fenêtre du dessous sur toute la fenêtre -- exactement ce
        # qu'il faut ici puisque le logo n'a de toute façon aucune interaction à proposer.
        gdk_win = win.get_window()
        if gdk_win is not None:
            gdk_win.set_pass_through(True)
        windows.append(win)

    if CONTROL_FILE:
        GLib.timeout_add(POLL_MS, poll_control_file)

    Gtk.main()


if __name__ == "__main__":
    main()
