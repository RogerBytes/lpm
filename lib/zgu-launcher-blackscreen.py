#!/usr/bin/env python3
# --- lpm launcher : fenêtre noire plein écran + image de splash + indicateur, avec vraie
# transparence ---
#
# Usage : zgu-launcher-blackscreen.py <control_file> [<indicator_text>]
#
# <control_file> est un fichier texte de TROIS lignes que le script relit en boucle (toutes
# les 150ms, même technique de sondage que zgu-focus-utils.sh) :
#   Ligne 1 -- le fond :
#     - "NONE"        : fond noir seul, rien par-dessus
#     - "<chemin>"     : fond noir + l'image PNG à ce chemin, centrée (canal alpha respecté
#                        via un visual RGBA -- transparent si un compositeur tourne, sinon
#                        dégradation automatique en noir plein, vérifié empiriquement, voir
#                        l'échange qui a mené à ce choix -- AUCUNE détection de compositeur
#                        n'est donc nécessaire ici, GTK/Cairo gère la dégradation tout seul)
#     - "STOP"        : le script se termine proprement (les lignes 2 et 3 sont ignorées)
#   Ligne 2 -- l'indicateur "chargement" (texte + spinner, bas-droite, jamais recouvert par
#   une bannière puisqu'ancré dans un coin) :
#     - "IND_SHOW"    : visible (état par défaut si la ligne est absente, pour compatibilité)
#     - "IND_HIDE"    : masqué -- utilisé par zgl-launcher-runtime.sh pendant que le picker
#                       multi-entrées est affiché par-dessus (on n'est plus "en train de
#                       charger", on attend un choix) ; le fond, lui, ne bouge jamais.
#   Ligne 3 -- le titre (nom du jeu, ou libellé de l'entrée choisie si le LPM Launcher a
#   plusieurs entrées actives) : dessiné juste au-dessus de l'indicateur, dans le même coin
#   bas-droite (jamais au même endroit qu'une bannière, quelle que soit sa taille), en plus
#   gros. Contrairement à l'indicateur, reste affiché tout du long -- y compris pendant
#   IND_HIDE (le picker) -- puisqu'il reste vrai qu'on s'apprête à lancer CE jeu/CETTE entrée
#   même le temps d'un choix. Ligne absente ou vide : rien n'est dessiné.
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
#
# Indicateur dessiné en Cairo pur (pas de Gtk.Spinner) -- délibéré : testé, ce widget ne
# s'affiche pas du tout dans un environnement minimal sans thème GTK complet (vérifié en
# amont). Un arc dessiné à la main ne dépend d'aucun thème, fonctionne identiquement
# partout, cohérent avec le rendu de l'image de fond déjà fait à la main juste au-dessus.

import math
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
    sys.stderr.write("Usage: zgu-launcher-blackscreen.py <control_file> [<indicator_text>]\n")
    sys.exit(1)

CONTROL_FILE = sys.argv[1]
INDICATOR_TEXT = sys.argv[2] if len(sys.argv) > 2 else ""
POLL_MS = 150
SPIN_TICK_MS = 60

SPINNER_SIZE = 20
MARGIN_RIGHT = 28
MARGIN_BOTTOM = 24
TEXT_SPINNER_GAP = 10
FONT_SIZE = 16

# Titre (nom du jeu / libellé d'entrée) : même coin, juste au-dessus de l'indicateur, plus
# gros -- voir l'en-tête de fichier.
TITLE_FONT_SIZE = 27
TITLE_INDICATOR_GAP = 14

# Réduction volontaire de la largeur maximale d'une bannière (indépendante de la hauteur,
# elle-même toujours plafonnée à 100% -- voir on_draw) : une bannière qui occupait pile toute
# la largeur de l'écran touchait les deux bords, demandé en retour un peu de marge visuelle
# de chaque côté.
MAX_BANNER_WIDTH_FRACTION = 0.5

is_wayland = (os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland") or bool(
    os.environ.get("WAYLAND_DISPLAY")
)

# État partagé (mutable via listes à un élément, lu/écrit depuis les callbacks GLib) --
# show_indicator/spinner_angle/title_text sont communs à toutes les fenêtres (un seul
# indicateur/titre "logique", même si physiquement dessiné sur chaque écran sous Wayland).
show_indicator = [True]
spinner_angle = [0.0]
title_text = [""]


def draw_spinner(cr, cx, cy, radius, angle):
    """8 rayons dégradés qui tournent, à la façon des spinners classiques -- dessiné à la
    main, aucune dépendance à un thème ou à une icône système."""
    n = 8
    cr.set_line_width(2.4)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    for i in range(n):
        a = angle + i * (2 * math.pi / n)
        alpha = (i + 1) / n
        cr.set_source_rgba(1, 1, 1, alpha)
        cr.move_to(cx + (radius - 3) * math.cos(a), cy + (radius - 3) * math.sin(a))
        cr.line_to(cx + radius * math.cos(a), cy + radius * math.sin(a))
        cr.stroke()


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
        win_alloc = self.get_allocation()

        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 1)
        cr.paint()
        if self.current_surface is not None:
            cr.set_operator(cairo.OPERATOR_OVER)
            img_w = self.current_surface.get_width()
            img_h = self.current_surface.get_height()
            # Centre l'image, sans l'agrandir au-delà de sa taille réelle (une image plus
            # petite que l'écran reste à sa taille -- seul le fond noir remplit l'écran).
            # Largeur plafonnée à MAX_BANNER_WIDTH_FRACTION de la fenêtre (jamais bord à
            # bord), hauteur toujours plafonnée à 100% -- voir la constante plus haut.
            scale = min(
                1.0,
                (win_alloc.width * MAX_BANNER_WIDTH_FRACTION) / img_w,
                win_alloc.height / img_h,
            )
            off_x = (win_alloc.width - img_w * scale) / 2
            off_y = (win_alloc.height - img_h * scale) / 2
            cr.translate(off_x, off_y)
            cr.scale(scale, scale)
            cr.set_source_surface(self.current_surface, 0, 0)
            cr.paint()
            cr.identity_matrix()

        cr.set_operator(cairo.OPERATOR_OVER)
        indicator_bottom_y = win_alloc.height - MARGIN_BOTTOM - SPINNER_SIZE / 2

        if show_indicator[0] and INDICATOR_TEXT:
            self.draw_indicator(cr, indicator_bottom_y)

        # Titre : toujours affiché tant qu'il y en a un, y compris quand l'indicateur est
        # masqué (IND_HIDE, pendant le picker) -- voir l'en-tête de fichier.
        if title_text[0]:
            self.draw_title(cr, indicator_bottom_y)

        return False

    def draw_indicator(self, cr, center_y):
        win_alloc = self.get_allocation()

        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(FONT_SIZE)
        extents = cr.text_extents(INDICATOR_TEXT)

        spinner_cx = win_alloc.width - MARGIN_RIGHT - SPINNER_SIZE / 2
        text_x = spinner_cx - SPINNER_SIZE / 2 - TEXT_SPINNER_GAP - extents.width

        cr.set_source_rgba(0.91, 0.91, 0.91, 1)
        cr.move_to(text_x, center_y + extents.height / 2)
        cr.show_text(INDICATOR_TEXT)

        draw_spinner(cr, spinner_cx, center_y, SPINNER_SIZE / 2 - 2, spinner_angle[0])

    def draw_title(self, cr, indicator_center_y):
        """Nom du jeu (ou libellé de l'entrée choisie) -- même coin bas-droite que
        l'indicateur, juste au-dessus, en plus gros. Aligné à droite sur la même marge que
        le spinner, jamais au même endroit qu'une bannière (voir MAX_BANNER_WIDTH_FRACTION
        et le centrage de l'image dans on_draw : le coin bas-droite n'est jamais couvert)."""
        win_alloc = self.get_allocation()

        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(TITLE_FONT_SIZE)
        extents = cr.text_extents(title_text[0])

        title_baseline_y = indicator_center_y - SPINNER_SIZE / 2 - TITLE_INDICATOR_GAP
        title_x = win_alloc.width - MARGIN_RIGHT - extents.width

        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(title_x, title_baseline_y)
        cr.show_text(title_text[0])

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
last_bg_state = None
last_indicator_state = None
last_title_state = None


def poll_control_file():
    global last_bg_state, last_indicator_state, last_title_state
    try:
        with open(CONTROL_FILE, "r") as f:
            lines = f.read().splitlines()
    except Exception:
        return True  # fichier momentanément illisible : on réessaie au prochain tick

    bg_state = lines[0].strip() if len(lines) > 0 else "NONE"
    indicator_state = lines[1].strip() if len(lines) > 1 else "IND_SHOW"
    title_state = lines[2].strip() if len(lines) > 2 else ""

    if bg_state == "STOP":
        Gtk.main_quit()
        return False

    if bg_state != last_bg_state:
        last_bg_state = bg_state
        for win in windows:
            if bg_state == "NONE" or not bg_state:
                win.clear_image()
            elif os.path.isfile(bg_state):
                win.set_image(bg_state)
            else:
                win.clear_image()

    if indicator_state != last_indicator_state:
        last_indicator_state = indicator_state
        show_indicator[0] = (indicator_state != "IND_HIDE")
        # IND_HIDE veut aussi dire "un picker est affiché par-dessus" (voir
        # zgl-launcher-orchestrator.sh) : le fond doit alors passer SOUS lui, sinon
        # keep_above (mis pour rester au-dessus du bureau/des autres fenêtres) le
        # recouvre aussi. Remis au-dessus dès IND_SHOW (picker refermé).
        for win in windows:
            win.set_keep_above(show_indicator[0])
            win.queue_draw()

    if title_state != last_title_state:
        last_title_state = title_state
        title_text[0] = title_state
        for win in windows:
            win.queue_draw()

    return True


def tick_spinner():
    spinner_angle[0] += 0.35
    if show_indicator[0]:
        for win in windows:
            win.queue_draw()
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
    GLib.timeout_add(SPIN_TICK_MS, tick_spinner)
    Gtk.main()


if __name__ == "__main__":
    main()
