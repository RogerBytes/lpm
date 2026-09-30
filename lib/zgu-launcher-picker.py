#!/usr/bin/env python3
# --- lpm launcher : picker multi-entrées maison, avec Valider/Annuler EXPLICITES ---
#
# Usage : zgu-launcher-picker.py <titre> <prompt> <label_valider> <label_annuler>
#                                 <entree1> [<entree2> ...]
# Sur stdout : le libellé choisi, UNIQUEMENT en cas de validation.
# Code de sortie :
#   0 -- validé (stdout contient le libellé choisi)
#   2 -- annulé explicitement (Annuler/Échap/bouton B) -- rien sur stdout
#   1 -- erreur (GTK indisponible, fenêtre fermée sans état clair...) -- rien sur stdout
#
# Remplace "zenity --list" (voir l'échange qui a mené à ce choix) : Zenity impose ses
# propres boutons "OK"/"Annuler" (pas d'option pour les retirer) et sa propre barre de
# titre avec sa croix de fermeture -- aucune des deux ne peut être stylée ou retirée. Un
# Gtk.Window fait à la main permet de choisir précisément CE qui est proposé.
#
# Accessible par TROIS entrées, chacune capable à elle seule de valider OU d'annuler :
#   - Clavier : flèches Haut/Bas pour naviguer, Entrée pour valider, Échap pour annuler.
#   - Manette (voir zgu-gamepad-bridge.py -- KEY_MAP/BUTTON_KEY_MAP) : flèches/joystick
#     traduits en Haut/Bas, bouton A -> touche Entrée, bouton B -> touche Échap. Rien à
#     changer côté pont manette : il injecte déjà ces mêmes touches clavier, ce script
#     n'a qu'à les gérer comme n'importe quel appui clavier.
#   - Souris : clic pour sélectionner une ligne, double-clic pour valider directement
#     CETTE ligne (comme Entrée), et deux boutons visibles "Valider"/"Annuler" pour
#     quelqu'un qui n'a ni clavier ni manette sous la main -- Valider agit sur la ligne
#     actuellement sélectionnée (la première par défaut à l'ouverture).
#
# PAS de croix de fermeture (fenêtre non décorée, set_decorated(False)) -- fermer sans
# passer par Annuler prêterait à confusion sur ce qui a réellement été décidé. La requête
# de fermeture (Alt+F4, etc.) est donc traitée EXACTEMENT comme Annuler, jamais ignorée
# silencieusement (voir on_delete_event) : un utilisateur qui insiste pour fermer obtient
# le même résultat clair qu'avec le bouton Annuler, pas une fenêtre qui refuse de bouger.

import math
import sys
import time

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GLib
    import cairo
except Exception as exc:  # pragma: no cover - dépendance système absente
    sys.stderr.write("zgu-launcher-picker: GTK/PyGObject indisponible (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 6:
    sys.stderr.write(
        "Usage: zgu-launcher-picker.py <titre> <prompt> <label_valider> <label_annuler> "
        "<entree1> [<entree2> ...]\n"
    )
    sys.exit(1)

TITLE = sys.argv[1]
PROMPT = sys.argv[2]
VALIDATE_LABEL = sys.argv[3]
CANCEL_LABEL = sys.argv[4]
ENTRIES = sys.argv[5:]

BG_COLOR = (0x1a / 255, 0x1a / 255, 0x1a / 255)
BORDER_COLOR = (0x2f / 255, 0x2f / 255, 0x2f / 255)
BORDER_WIDTH = 2
CORNER_RADIUS = 10

# Taille (en px) des libellés de choix dans la liste -- appliquée via balisage Pango
# directement sur le texte (span size=...), PAS via le CSS GTK : constaté réel, le CSS
# ("listbox row { font-size: ... }") ne s'appliquait pas du tout, même à 100px, très
# probablement à cause d'un gtk.css utilisateur (priorité USER, au-dessus de la priorité
# APPLICATION de notre CssProvider) qui écrase le "font-size" de "label"/"row" pour TOUTES
# les applications GTK de la machine. Le balisage Pango, lui, s'applique directement sur
# les attributs de rendu du texte -- il gagne quoi qu'il arrive, indépendamment de tout
# CSS concurrent.
ENTRY_FONT_SIZE_PX = 25

# Décalage vertical vers le bas par rapport au centre exact de l'écran -- demandé pour
# laisser un peu plus d'air au-dessus du picker (là où logo/titre s'affichent, voir
# zgu-launcher-blackscreen.py). "Gtk.WindowPosition.CENTER_ALWAYS" ne permet pas de décalage
# -- remplacé par un centrage manuel (move() explicite, voir PickerWindow.__init__) avec cet
# écart ajouté.
PICKER_VERTICAL_OFFSET = 50


# Curseur souris auto-masqué après ce délai d'inactivité (souris immobile) -- même
# comportement que zgu-launcher-blackscreen.py, voir ce fichier pour le détail. Ici, EN
# PLUS : masqué INSTANTANÉMENT dès un appui clavier/manette (voir on_key_press/
# on_listbox_key_press), puisque cette fenêtre reçoit bien le focus clavier -- contrairement
# à l'écran noir, qui ne peut compter que sur le délai.
CURSOR_IDLE_S = 1.0


def _entry_markup(text):
    escaped = GLib.markup_escape_text(text)
    pango_units = int(round(ENTRY_FONT_SIZE_PX * 0.75 * 1024))  # px (96dpi) -> pt*1024
    return '<span size="%d">%s</span>' % (pango_units, escaped)

CSS = b"""
.lpm-picker-title {
    color: #ffffff;
    font-weight: bold;
    font-size: 24px;
}
.lpm-picker-prompt {
    color: #cccccc;
    font-size: 20px;
}
listbox {
    background-color: #1a1a1a;
}
listbox row {
    padding: 8px 14px;
    color: #e0e0e0;
    font-size: 100px;
}
listbox row label {
    font-size: 100px;
}
listbox row:selected {
    background-color: #3a6ea5;
    color: #ffffff;
}
.lpm-picker-button {
    font-size: 20px;
}
"""


class PickerWindow(Gtk.Window):
    def __init__(self):
        super().__init__()
        self.selected = None
        self.cancelled = False

        self.set_decorated(False)  # pas de barre de titre -- donc pas de croix de fermeture
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_app_paintable(True)

        # Visual RGBA -- nécessaire pour que les coins arrondis (border-radius CSS) soient
        # réellement transparents au lieu de rester carrés en dessous (même technique que
        # BlackWindow dans zgu-launcher-blackscreen.py) : sans ça, la fenêtre X11 reste un
        # rectangle plein, le CSS ne fait que dessiner PAR-DESSUS.
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)
        self.set_keep_above(True)  # toujours au-dessus, y compris de l'écran noir/splash

        win_w, win_h = 900, 680
        self.set_default_size(win_w, win_h)

        # Centrage manuel plutôt que CENTER_ALWAYS -- voir PICKER_VERTICAL_OFFSET plus haut :
        # centré horizontalement, mais décalé vers le bas verticalement par rapport au centre
        # exact de l'écran.
        self.set_position(Gtk.WindowPosition.NONE)
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() if display is not None else None
        if monitor is None and display is not None and display.get_n_monitors() > 0:
            monitor = display.get_monitor(0)
        if monitor is not None:
            geom = monitor.get_geometry()
            pos_x = geom.x + int((geom.width - win_w) / 2)
            pos_y = geom.y + int((geom.height - win_h) / 2) + PICKER_VERTICAL_OFFSET
            self.move(pos_x, pos_y)

        self.get_style_context().add_class("lpm-picker")

        self.connect("delete-event", self.on_delete_event)
        # Échap : géré au niveau de la FENÊTRE, quel que soit le widget qui a le focus --
        # annuler doit marcher de partout.
        self.connect("key-press-event", self.on_key_press)

        # Curseur souris auto-masqué -- voir CURSOR_IDLE_S plus haut.
        self.add_events(Gdk.EventMask.POINTER_MOTION_MASK)
        self.connect("motion-notify-event", self.on_motion)
        self.last_motion_ts = time.monotonic()
        self.cursor_hidden = False
        self.blank_cursor = None
        # Fond + bordure dessinés à la main (voir la constante BG_COLOR/BORDER_COLOR plus
        # haut) : "app_paintable" désactive le rendu CSS automatique du fond de la fenêtre,
        # donc "background-color"/"border" en CSS ne s'appliquaient plus du tout une fois
        # le visual RGBA en place -- remplacé par un vrai rectangle arrondi en Cairo, qui
        # lui respecte le visual RGBA (coins réellement transparents, pas juste dessinés
        # par-dessus un rectangle plein).
        self.connect("draw", self.on_draw_background)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(16)
        self.add(box)

        if TITLE:
            title_label = Gtk.Label(label=TITLE, xalign=0)
            title_label.get_style_context().add_class("lpm-picker-title")
            box.pack_start(title_label, False, False, 0)

        if PROMPT:
            prompt_label = Gtk.Label(label=PROMPT, xalign=0)
            prompt_label.get_style_context().add_class("lpm-picker-prompt")
            prompt_label.set_line_wrap(True)
            box.pack_start(prompt_label, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        box.pack_start(scroll, True, True, 0)

        self.listbox = Gtk.ListBox()
        self.listbox.set_selection_mode(Gtk.SelectionMode.BROWSE)
        # PAS de "row-activated" connecté ici volontairement : ce signal se déclenche
        # aussi bien sur un double-clic souris QUE sur Entrée clavier -- or la souris ne
        # doit PAS pouvoir valider par un clic (simple ou double), seulement sélectionner
        # (comportement par défaut de BROWSE) puis passer par le bouton Valider. Entrée et
        # le bouton A restent gérés séparément dans on_key_press, indépendamment de ce
        # signal -- voir plus bas.
        #
        # Entrée/KP_Enter : géré ICI, sur la liste SPÉCIFIQUEMENT (pas sur la fenêtre
        # entière) -- pour que, si le focus est sur le bouton Valider ou Annuler (Tab), ce
        # soit CE bouton qui réagisse à Entrée normalement, pas la ligne sélectionnée dans
        # la liste par-dessus. Le bouton A de la manette envoie "Return" (voir
        # zgu-gamepad-bridge.py) et arrive ici de la même façon tant que la liste a le
        # focus, ce qui est le cas par défaut à l'ouverture (voir grab_focus() plus bas).
        self.listbox.connect("key-press-event", self.on_listbox_key_press)
        scroll.add(self.listbox)

        first_row = None
        for entry in ENTRIES:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(xalign=0)
            label.set_markup(_entry_markup(entry))  # taille forcée via Pango, voir plus haut
            row.add(label)
            self.listbox.add(row)
            if first_row is None:
                first_row = row

        # Barre de boutons -- pour la souris seule, sans clavier ni manette. Annuler à
        # gauche, Valider à droite (mis en avant, "suggested-action" -- c'est l'action la
        # plus probable une fois une ligne déjà sélectionnée par défaut).
        button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        button_box.set_halign(Gtk.Align.END)

        cancel_button = Gtk.Button(label=CANCEL_LABEL)
        cancel_button.get_style_context().add_class("lpm-picker-button")
        cancel_button.connect("clicked", self.on_cancel_clicked)
        button_box.pack_start(cancel_button, False, False, 0)

        validate_button = Gtk.Button(label=VALIDATE_LABEL)
        validate_button.get_style_context().add_class("suggested-action")
        validate_button.get_style_context().add_class("lpm-picker-button")
        validate_button.connect("clicked", self.on_validate_clicked)
        button_box.pack_start(validate_button, False, False, 0)

        box.pack_start(button_box, False, False, 0)

        self.show_all()

        # Une ligne pré-sélectionnée dès l'ouverture (la première) : Entrée/bouton A/le
        # bouton Valider peuvent confirmer directement, sans premier appui "à vide".
        if first_row is not None:
            self.listbox.select_row(first_row)
        self.listbox.grab_focus()

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

    def on_draw_background(self, widget, cr):
        alloc = widget.get_allocation()
        w, h = alloc.width, alloc.height
        half = BORDER_WIDTH / 2.0

        cr.save()
        cr.set_operator(cairo.OPERATOR_SOURCE)
        self._rounded_rect_path(cr, half, half, w - BORDER_WIDTH, h - BORDER_WIDTH, CORNER_RADIUS)
        cr.set_source_rgba(*BG_COLOR, 1)
        cr.fill_preserve()
        cr.set_source_rgba(*BORDER_COLOR, 1)
        cr.set_line_width(BORDER_WIDTH)
        cr.stroke()
        cr.restore()
        return False  # laisse les widgets enfants se dessiner par-dessus normalement

    @staticmethod
    def _rounded_rect_path(cr, x, y, width, height, radius):
        cr.new_sub_path()
        cr.arc(x + width - radius, y + radius, radius, -math.pi / 2, 0)
        cr.arc(x + width - radius, y + height - radius, radius, 0, math.pi / 2)
        cr.arc(x + radius, y + height - radius, radius, math.pi / 2, math.pi)
        cr.arc(x + radius, y + radius, radius, math.pi, 3 * math.pi / 2)
        cr.close_path()

    def on_delete_event(self, _widget, _event):
        # Pas de croix (non décoré), mais une requête de fermeture (Alt+F4...) reste
        # possible -- traitée EXACTEMENT comme Annuler, jamais ignorée en silence (voir
        # l'en-tête de fichier) : le résultat doit toujours être clair pour l'appelant.
        self.cancelled = True
        Gtk.main_quit()
        return True

    def on_key_press(self, _widget, event):
        # Tout appui clavier/manette (les deux arrivent ici de la même façon, la manette
        # n'étant qu'un injecteur de touches -- voir zgu-gamepad-bridge.py) masque le
        # curseur IMMÉDIATEMENT, sans attendre le délai d'inactivité -- voir CURSOR_IDLE_S.
        if not self.cursor_hidden:
            self.hide_cursor()
        if event.keyval == Gdk.KEY_Escape:
            self.cancelled = True
            Gtk.main_quit()
            return True
        return False

    def on_listbox_key_press(self, _widget, event):
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self._validate_row(self.listbox.get_selected_row())
            return True
        return False

    def on_validate_clicked(self, _button):
        row = self.listbox.get_selected_row()
        self._validate_row(row)

    def on_cancel_clicked(self, _button):
        self.cancelled = True
        Gtk.main_quit()

    def _validate_row(self, row):
        if row is None:
            return
        label_widget = row.get_child()
        self.selected = label_widget.get_text()
        Gtk.main_quit()


def main():
    style_provider = Gtk.CssProvider()
    style_provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(),
        style_provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    )

    win = PickerWindow()
    GLib.timeout_add(200, lambda: (win.maybe_hide_cursor_if_idle(), True)[1])
    Gtk.main()

    if win.cancelled:
        sys.exit(2)
    if win.selected:
        print(win.selected)
        sys.exit(0)
    sys.exit(1)


if __name__ == "__main__":
    main()
