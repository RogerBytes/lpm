#!/usr/bin/env python3
# --- lpm launcher : fenêtre noire plein écran + image de splash, avec vraie transparence ---
#
# Usage : zgu-launcher-blackscreen.py <control_file>
#
# <control_file> est un fichier texte que le script relit en boucle (toutes les 150ms,
# même technique de sondage que zgu-focus-utils.sh) pour savoir quoi afficher :
#   - "NONE"        : fond noir seul, rien par-dessus (état de départ, pendant le picker)
#   - "<chemin>"     : fond noir + l'image PNG à ce chemin, centrée (canal alpha respecté
#                      via un visual RGBA -- transparent si un compositeur tourne, sinon
#                      dégradation automatique en noir plein, vérifié empiriquement, voir
#                      l'échange qui a mené à ce choix -- AUCUNE détection de compositeur
#                      n'est donc nécessaire ici, GTK/Cairo gère la dégradation tout seul)
#   - "STOP"        : le script se termine proprement
#
# Écran couvert : sous X11, seulement l'écran physique marqué "primaire" (Gdk.Display /
# get_monitor, propriété is_primary()) -- les écrans secondaires restent inchangés. Sous
# Wayland, un compositeur peut refuser de placer une fenêtre sur un écran précis : plutôt
# que de deviner, une fenêtre plein écran est ouverte sur CHAQUE écran détecté (identique
# sur tous), ce qui couvre le cas dans tous les environnements sans dépendre d'une API de
# placement non garantie -- accepté comme compromis (voir discussion : quelques secondes
# de noir sur un deuxième écran, le temps du chargement, n'est pas gênant).
#
# Robustesse : le fichier de contrôle peut disparaître ou devenir illisible entre deux
# lectures (nettoyage concurrent) -- traité comme "ne rien changer", jamais comme une
# erreur fatale.

import sys
import os

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GLib
    import cairo
except Exception as exc:  # pragma: no cover - dépendance système absente
    sys.stderr.write("zgu-launcher-blackscreen: GTK/PyGObject indisponible (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 2:
    sys.stderr.write("Usage: zgu-launcher-blackscreen.py <control_file>\n")
    sys.exit(1)

CONTROL_FILE = sys.argv[1]
POLL_MS = 150

is_wayland = (os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland") or bool(
    os.environ.get("WAYLAND_DISPLAY")
)


class BlackWindow(Gtk.Window):
    def __init__(self, monitor_geom):
        super().__init__()
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_app_paintable(True)
        self.current_surface = None

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)

        self.move(monitor_geom.x, monitor_geom.y)
        self.resize(monitor_geom.width, monitor_geom.height)
        self.set_default_size(monitor_geom.width, monitor_geom.height)

        self.connect("draw", self.on_draw)

    def on_draw(self, _widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 1)
        cr.paint()
        if self.current_surface is not None:
            cr.set_operator(cairo.OPERATOR_OVER)
            win_alloc = self.get_allocation()
            img_w = self.current_surface.get_width()
            img_h = self.current_surface.get_height()
            # Centre l'image, sans l'agrandir au-delà de sa taille réelle (une image plus
            # petite que l'écran reste à sa taille -- seul le fond noir remplit l'écran).
            scale = min(1.0, win_alloc.width / img_w, win_alloc.height / img_h)
            off_x = (win_alloc.width - img_w * scale) / 2
            off_y = (win_alloc.height - img_h * scale) / 2
            cr.translate(off_x, off_y)
            cr.scale(scale, scale)
            cr.set_source_surface(self.current_surface, 0, 0)
            cr.paint()
        return False

    def set_image(self, path):
        try:
            self.current_surface = cairo.ImageSurface.create_from_png(path)
        except Exception:
            self.current_surface = None
        self.queue_draw()

    def clear_image(self):
        self.current_surface = None
        self.queue_draw()


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
        return geoms  # tous les écrans, voir en-tête de fichier
    return [geoms[primary_idx]] if geoms else []


windows = []
last_state = None


def poll_control_file():
    global last_state
    try:
        with open(CONTROL_FILE, "r") as f:
            state = f.read().strip()
    except Exception:
        return True  # fichier momentanément illisible : on réessaie au prochain tick

    if state == last_state:
        return True
    last_state = state

    if state == "STOP":
        Gtk.main_quit()
        return False

    for win in windows:
        if state == "NONE" or not state:
            win.clear_image()
        elif os.path.isfile(state):
            win.set_image(state)
        else:
            win.clear_image()

    return True


def main():
    geoms = get_monitor_geometries()
    if not geoms:
        sys.stderr.write("zgu-launcher-blackscreen: aucun écran détecté\n")
        sys.exit(1)

    for geom in geoms:
        win = BlackWindow(geom)
        win.show_all()
        win.fullscreen()
        windows.append(win)

    GLib.timeout_add(POLL_MS, poll_control_file)
    Gtk.main()


if __name__ == "__main__":
    main()
