#!/usr/bin/env python3
# --- lpm launcher : fenêtre noire plein écran + image de splash + indicateur, avec vraie
# transparence ---
#
# Usage : zgu-launcher-blackscreen.py <control_file> [<indicator_text>] [<logo_png>]
#
# <control_file> est un fichier texte de QUATRE lignes que le script relit en boucle (toutes
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
#   Ligne 3 -- le titre (nom du jeu) -- voir <logo_png> ci-dessous : dessiné en haut de
#   l'écran UNIQUEMENT si aucun logo n'a été fourni (repli). Toujours affiché tout du long
#   dans ce cas -- y compris pendant IND_HIDE (le picker), puisqu'il reste vrai qu'on
#   s'apprête à lancer CE jeu même le temps d'un choix. Ligne absente ou vide : rien n'est
#   dessiné.
#   Ligne 4 -- le libellé de l'entrée choisie (LPM Launcher à plusieurs entrées) : dessiné
#   en bas-droite, juste au-dessus de l'indicateur (l'emplacement qu'occupait le titre
#   auparavant -- désormais réservé à ce libellé puisque le titre est monté en haut, voir
#   <logo_png>) -- n'apparaît qu'UNE FOIS le choix fait dans le picker (voir
#   zgl-launcher-orchestrator.sh), reste vide/absent tant qu'aucun choix n'a encore été
#   validé (jeu à une seule entrée, ou picker pas encore résolu).
#
# <logo_png> (3ème argument, optionnel, CLI -- PAS dans le fichier de contrôle : ne change
# jamais une fois le script lancé, contrairement aux 4 lignes ci-dessus) : logo transparent
# du jeu, dessiné en HAUT de l'écran, centré, EN PERMANENCE -- avant, pendant ET après le
# picker, jamais masqué ni redessiné ailleurs. Auparavant une fenêtre séparée
# (zgu-launcher-logo.py) tentait de rester "au-dessus" du picker via divers artifices
# (plein écran, indice de fenêtre, relève périodique) -- tous ont fini par casser soit
# l'affichage soit les interactions clavier/souris/manette avec le picker (voir l'historique
# des échanges). Constat qui a débloqué le problème : le picker (voir
# zgu-launcher-picker.py, toujours 900x680 centré à l'écran) ne recouvre JAMAIS cette zone du
# haut -- donc le logo n'a besoin d'AUCUNE fenêtre à part ni d'AUCUN mécanisme de calque, il
# suffit de le dessiner ici, dans CETTE fenêtre (comme l'était déjà le titre), qui elle ne
# change jamais de calque à cet endroit précis. Si absent (fichier introuvable ou argument
# vide), le titre (ligne 3 du fichier de contrôle) prend cette place à la place -- voir
# PICKER_BOX_HEIGHT plus bas, qui doit rester synchronisé avec
# zgu-launcher-picker.py:set_default_size, et TOP_TITLE_FONT_SIZE pour la taille agrandie du
# titre dans ce cas.
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
import time

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
LOGO_PATH = sys.argv[3] if len(sys.argv) > 3 else ""
POLL_MS = 150
SPIN_TICK_MS = 60

SPINNER_SIZE = 20
MARGIN_RIGHT = 28
MARGIN_BOTTOM = 24
TEXT_SPINNER_GAP = 10
FONT_SIZE = 16

# Libellé de l'entrée choisie (LPM Launcher, ligne 4) : plus au coin bas-droite -- déplacé
# dans la bande dédiée entre le logo et la bannière (voir LABEL_ZONE_HEIGHT plus bas et
# l'en-tête de fichier), centré horizontalement comme le logo/titre au-dessus de lui. Le
# coin bas-droite reste réservé exclusivement à l'indicateur de chargement.
ENTRY_LABEL_FONT_SIZE = 30

# Zone du haut (logo, ou titre en repli si pas de logo) -- voir l'en-tête de fichier.
# PICKER_BOX_HEIGHT doit rester en phase avec
# zgu-launcher-picker.py:set_default_size(900, 680) : c'est ce qui définissait la position
# fixe du haut du picker à l'écran (fenêtre centrée) -- gardé comme référence de taille pour
# la zone du logo, même si la bannière ne s'aligne plus sur cette limite (voir
# LABEL_ZONE_HEIGHT/BANNER_ZONE_TOP ci-dessous : la bannière descend maintenant sous une
# bande supplémentaire réservée au libellé du picker).
PICKER_BOX_HEIGHT = 680
TOP_ZONE_MAX_WIDTH_FRACTION = 0.29
TOP_ZONE_MIN_MARGIN = 24
LOGO_VERTICAL_OFFSET = 30  # décalé vers le bas par rapport au centre de sa zone
TOP_TITLE_FONT_SIZE = 42  # bien plus gros que l'ancien emplacement bas-droite (27px)
TOP_TITLE_BOTTOM_PADDING = 48  # remonté par rapport au bas de sa zone -- pas collé dessus

# Bande dédiée au libellé du picker, juste sous la zone du logo -- toujours réservée (vide
# tant qu'aucun choix n'a encore été fait), c'est elle qui pousse la bannière plus bas et la
# recentre dans l'espace qui lui reste (voir on_draw). Le libellé est collé vers le HAUT de
# cette bande (LABEL_ZONE_TOP_PADDING), pas centré dedans -- demandé explicitement.
LABEL_ZONE_HEIGHT = 90
LABEL_ZONE_TOP_PADDING = 16

# Curseur souris : masqué après ce délai d'inactivité (souris immobile), tant que l'écran
# noir est affiché (chargement OU picker -- constaté réel, l'utilisateur veut ça dans les
# deux cas). Réapparaît dès le moindre mouvement. Voir BlackWindow.on_motion/tick_cursor.
CURSOR_IDLE_S = 1.0

# Réduction volontaire de la largeur maximale d'une bannière (indépendante de la hauteur,
# elle-même toujours plafonnée à 100% -- voir on_draw) : une bannière qui occupait pile toute
# la largeur de l'écran touchait les deux bords, demandé en retour un peu de marge visuelle
# de chaque côté.
MAX_BANNER_WIDTH_FRACTION = 0.75
BANNER_VERTICAL_LIFT = 30  # remontée légère par rapport au centre de sa bande, pas replaquée en haut

is_wayland = (os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland") or bool(
    os.environ.get("WAYLAND_DISPLAY")
)

# État partagé (mutable via listes à un élément, lu/écrit depuis les callbacks GLib) --
# show_indicator/spinner_angle/title_text sont communs à toutes les fenêtres (un seul
# indicateur/titre "logique", même si physiquement dessiné sur chaque écran sous Wayland).
show_indicator = [True]
spinner_angle = [0.0]
title_text = [""]
entry_label_text = [""]


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

        # Logo (voir l'en-tête de fichier) : chargé une seule fois ici, taille/position
        # calculées une seule fois aussi (l'image ne change jamais en cours de route,
        # contrairement au fond/titre/libellé qui viennent du fichier de contrôle).
        self.logo_surface = None
        self.logo_draw_x = 0
        self.logo_draw_y = 0
        self.logo_draw_w = 0
        self.logo_draw_h = 0
        self.zone_top_y = max(0, (monitor_geom.height - PICKER_BOX_HEIGHT) / 2)

        if LOGO_PATH and os.path.isfile(LOGO_PATH):
            try:
                self.logo_surface = cairo.ImageSurface.create_from_png(LOGO_PATH)
            except Exception:
                self.logo_surface = None

        if self.logo_surface is not None:
            usable_h = max(0, self.zone_top_y - 2 * TOP_ZONE_MIN_MARGIN)
            img_w = self.logo_surface.get_width()
            img_h = self.logo_surface.get_height()
            max_w = monitor_geom.width * TOP_ZONE_MAX_WIDTH_FRACTION
            max_h = usable_h if usable_h > 0 else monitor_geom.height * 0.2
            # Pas de plafond à 100% ("min(1.0, ...)") : la case définit la taille
            # d'affichage, pas la résolution native de l'image -- un logo plus petit que la
            # case est agrandi pour la remplir, jamais l'inverse (voir l'échange qui a mené
            # à ce choix : la taille affichée doit être la même pour tous les logos, pas
            # dépendante de la résolution fournie par chacun).
            scale = min(max_w / img_w, max_h / img_h)
            self.logo_draw_w = img_w * scale
            self.logo_draw_h = img_h * scale
            self.logo_draw_x = (monitor_geom.width - self.logo_draw_w) / 2
            draw_y = (self.zone_top_y - self.logo_draw_h) / 2 + LOGO_VERTICAL_OFFSET
            max_draw_y = self.zone_top_y - self.logo_draw_h - TOP_ZONE_MIN_MARGIN
            self.logo_draw_y = max(TOP_ZONE_MIN_MARGIN, min(draw_y, max_draw_y))

        # Bande du libellé, puis bannière : tout ce qui est sous la zone du logo -- voir
        # LABEL_ZONE_HEIGHT plus haut.
        self.label_zone_top = self.zone_top_y
        self.label_zone_bottom = self.zone_top_y + LABEL_ZONE_HEIGHT
        self.banner_zone_top = self.label_zone_bottom
        self.banner_zone_height = max(0, monitor_geom.height - self.banner_zone_top)

        self.connect("draw", self.on_draw)

        # Curseur souris auto-masqué -- voir CURSOR_IDLE_S plus haut.
        self.add_events(Gdk.EventMask.POINTER_MOTION_MASK)
        self.connect("motion-notify-event", self.on_motion)
        self.last_motion_ts = time.monotonic()
        self.cursor_hidden = False
        self.blank_cursor = None  # créé à la volée (nécessite la fenêtre déjà réalisée)

    def on_motion(self, _widget, _event):
        self.last_motion_ts = time.monotonic()
        if self.cursor_hidden:
            self.show_cursor()
        return False

    def show_cursor(self):
        gdk_win = self.get_window()
        if gdk_win is not None:
            gdk_win.set_cursor(None)
        self.cursor_hidden = False

    def hide_cursor(self):
        gdk_win = self.get_window()
        if gdk_win is None:
            return
        if self.blank_cursor is None:
            self.blank_cursor = Gdk.Cursor.new_for_display(self.get_display(), Gdk.CursorType.BLANK_CURSOR)
        gdk_win.set_cursor(self.blank_cursor)
        self.cursor_hidden = True

    def maybe_hide_cursor_if_idle(self):
        if not self.cursor_hidden and (time.monotonic() - self.last_motion_ts) >= CURSOR_IDLE_S:
            self.hide_cursor()

    def on_draw(self, _widget, cr):
        win_alloc = self.get_allocation()

        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 1)
        cr.paint()
        if self.current_surface is not None and self.banner_zone_height > 0:
            cr.set_operator(cairo.OPERATOR_OVER)
            img_w = self.current_surface.get_width()
            img_h = self.current_surface.get_height()
            # Centrée dans la bande qui lui reste SOUS le logo et la bande du libellé (voir
            # banner_zone_top/banner_zone_height dans __init__), pas sur la fenêtre entière
            # -- c'est ce qui la fait descendre par rapport à avant. Toujours sans
            # l'agrandir au-delà de sa taille réelle. Largeur plafonnée à
            # MAX_BANNER_WIDTH_FRACTION de la fenêtre (jamais bord à bord), hauteur toujours
            # plafonnée à 100% -- voir la constante plus haut.
            scale = min(
                1.0,
                (win_alloc.width * MAX_BANNER_WIDTH_FRACTION) / img_w,
                self.banner_zone_height / img_h,
            )
            off_x = (win_alloc.width - img_w * scale) / 2
            off_y = self.banner_zone_top + (self.banner_zone_height - img_h * scale) / 2
            off_y = max(self.banner_zone_top, off_y - BANNER_VERTICAL_LIFT)
            cr.translate(off_x, off_y)
            cr.scale(scale, scale)
            cr.set_source_surface(self.current_surface, 0, 0)
            cr.paint()
            cr.identity_matrix()

        cr.set_operator(cairo.OPERATOR_OVER)
        indicator_bottom_y = win_alloc.height - MARGIN_BOTTOM - SPINNER_SIZE / 2

        # Coin bas-droite : réservé exclusivement à l'indicateur de chargement (voir
        # l'en-tête de fichier -- le libellé du picker et le titre n'y sont plus).
        if show_indicator[0] and INDICATOR_TEXT:
            self.draw_indicator(cr, indicator_bottom_y)

        # Bande dédiée, entre le logo et la bannière : le libellé de l'entrée choisie,
        # affiché seulement une fois présent (vide tant que le picker n'a pas encore
        # tranché) -- voir LABEL_ZONE_HEIGHT.
        if entry_label_text[0]:
            self.draw_entry_label(cr, win_alloc)

        # Zone du haut : le logo s'il a été fourni, sinon le titre en repli, agrandi --
        # dans les deux cas affiché EN PERMANENCE, y compris pendant IND_HIDE (le picker) et
        # jamais recouvert par lui (voir l'en-tête de fichier).
        if self.logo_surface is not None:
            self.draw_logo(cr)
        elif title_text[0]:
            self.draw_top_title(cr, win_alloc)

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

    def draw_entry_label(self, cr, win_alloc):
        """Libellé de l'entrée choisie -- bande dédiée entre le logo et la bannière, centré
        horizontalement mais collé vers le HAUT de cette bande (pas centré verticalement
        dedans -- voir LABEL_ZONE_HEIGHT/LABEL_ZONE_TOP_PADDING et l'en-tête de fichier)."""
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(ENTRY_LABEL_FONT_SIZE)
        extents = cr.text_extents(entry_label_text[0])

        label_x = (win_alloc.width - extents.width) / 2
        label_baseline_y = self.label_zone_top + LABEL_ZONE_TOP_PADDING + extents.height

        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(label_x, label_baseline_y)
        cr.show_text(entry_label_text[0])

    def draw_logo(self, cr):
        """Logo -- zone du haut, taille/position déjà calculées une fois dans __init__ (voir
        l'en-tête de fichier)."""
        cr.set_operator(cairo.OPERATOR_OVER)
        img_w = self.logo_surface.get_width()
        scale = self.logo_draw_w / img_w
        cr.save()
        cr.translate(self.logo_draw_x, self.logo_draw_y)
        cr.scale(scale, scale)
        cr.set_source_surface(self.logo_surface, 0, 0)
        cr.paint()
        cr.restore()

    def draw_top_title(self, cr, win_alloc):
        """Titre (nom du jeu) -- repli utilisé UNIQUEMENT quand aucun logo n'a été fourni,
        à la même place que celui-ci aurait occupée (voir l'en-tête de fichier) : centré
        horizontalement, mais collé vers le BAS de la zone (pas centré verticalement dedans)
        -- pour ne pas créer un grand vide entre lui et la bande du libellé juste en
        dessous."""
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(TOP_TITLE_FONT_SIZE)
        extents = cr.text_extents(title_text[0])

        title_x = (win_alloc.width - extents.width) / 2
        title_baseline_y = self.zone_top_y - TOP_TITLE_BOTTOM_PADDING

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
last_entry_label_state = None


def poll_control_file():
    global last_bg_state, last_indicator_state, last_title_state, last_entry_label_state
    try:
        with open(CONTROL_FILE, "r") as f:
            lines = f.read().splitlines()
    except Exception:
        return True  # fichier momentanément illisible : on réessaie au prochain tick

    bg_state = lines[0].strip() if len(lines) > 0 else "NONE"
    indicator_state = lines[1].strip() if len(lines) > 1 else "IND_SHOW"
    title_state = lines[2].strip() if len(lines) > 2 else ""
    entry_label_state = lines[3].strip() if len(lines) > 3 else ""

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

    if entry_label_state != last_entry_label_state:
        last_entry_label_state = entry_label_state
        entry_label_text[0] = entry_label_state
        for win in windows:
            win.queue_draw()

    return True


def tick_spinner():
    spinner_angle[0] += 0.35
    if show_indicator[0]:
        for win in windows:
            win.queue_draw()
    return True


def tick_cursor():
    for win in windows:
        win.maybe_hide_cursor_if_idle()
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
    GLib.timeout_add(200, tick_cursor)
    Gtk.main()


if __name__ == "__main__":
    main()
