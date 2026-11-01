# Picker part of the loading-screen window: the card that lists the executables, its
# keyboard / gamepad / mouse handling and the row-title marquee. Used as a mixin of ScreenWindow
# (zgu-launcher-screen.py).
import time

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Gdk, GLib, Pango

from zgu_screen_config import (
    BLOCK_EXTRA_DOWN_FRACTION,
    ENTRY_FONT_SIZE_PX,
    MARQUEE_END_PAUSE_S,
    MARQUEE_SPEED_PX_S,
    MARQUEE_START_DELAY_S,
    MARQUEE_TICK_MS,
    NO_LABEL,
    PICKER_BOX_WIDTH,
    PICKER_CARD_HEIGHT,
    PICKER_RESULT_FILE,
    PICKER_VERTICAL_OFFSET,
)




def _entry_markup(text):
    escaped = GLib.markup_escape_text(text)
    pango_units = int(round(ENTRY_FONT_SIZE_PX * 0.75 * 1024))  # px (96dpi) -> pt*1024
    return '<span size="%d" foreground="#ffffff">%s</span>' % (pango_units, escaped)



class PickerMixin:
    # --- Picker construction (same as zgu-launcher-picker.py, as a widget rather than a
    # separate window -- see file header) ---
    def _build_picker_card(self):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.add_css_class("lpm-picker-card")
        card.set_halign(Gtk.Align.CENTER)
        card.set_valign(Gtk.Align.CENTER)
        # The card is centered: moving it down by N takes a margin 2N bigger. Same N as the
        # logo/label block (BLOCK_EXTRA_DOWN_FRACTION), so the card never covers the logo.
        extra_down = 0 if NO_LABEL else self.monitor_geom.height * BLOCK_EXTRA_DOWN_FRACTION
        card.set_margin_top(PICKER_VERTICAL_OFFSET + int(2 * extra_down))
        card.set_size_request(PICKER_BOX_WIDTH, PICKER_CARD_HEIGHT)

        self.picker_title_label = Gtk.Label(xalign=0, visible=False)
        self.picker_title_label.add_css_class("lpm-picker-title")
        card.append(self.picker_title_label)

        self.picker_prompt_label = Gtk.Label(xalign=0, visible=False, wrap=True)
        self.picker_prompt_label.add_css_class("lpm-picker-prompt")
        card.append(self.picker_prompt_label)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_overlay_scrolling(False)
        scroll.set_vexpand(True)
        scroll_overlay = Gtk.Overlay()
        scroll_overlay.set_vexpand(True)
        scroll_overlay.set_child(scroll)
        self.picker_scroll = scroll
        adj = scroll.get_vadjustment()
        adj.connect("changed", self._update_picker_fade)
        card.append(scroll_overlay)

        self.picker_listbox = Gtk.ListBox()
        self.picker_listbox.set_selection_mode(Gtk.SelectionMode.BROWSE)
        self.picker_listbox.connect("row-selected", self._on_row_selected)
        # "row-activated" is NOT connected -- a click (single or double) only selects,
        # never validates directly.
        listbox_key_ctrl = Gtk.EventControllerKey()
        listbox_key_ctrl.connect("key-pressed", self.on_listbox_key_pressed)
        self.picker_listbox.add_controller(listbox_key_ctrl)
        scroll.set_child(self.picker_listbox)

        button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        button_box.set_halign(Gtk.Align.END)
        button_box.set_margin_top(22)
        button_box.set_size_request(-1, 44)

        self.picker_cancel_button = Gtk.Button()
        self.picker_cancel_icon = self._make_pad_icon("B", "lpm-pad-icon-b")
        self.picker_cancel_text = Gtk.Label()
        cancel_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        cancel_box.append(self.picker_cancel_icon)
        cancel_box.append(self.picker_cancel_text)
        self.picker_cancel_button.set_child(cancel_box)
        self.picker_cancel_button.add_css_class("lpm-picker-button")
        self.picker_cancel_button.add_css_class("lpm-picker-cancel-button")
        self.picker_cancel_button.connect("clicked", self.on_picker_cancel_clicked)
        button_box.append(self.picker_cancel_button)

        # "lpm-picker-validate-button" (our own colors, not "suggested-action", an Adwaita/
        # theme semantic class that would make the button depend on the desktop
        # environment): fixed dark theme, white text, green Validate button, fully
        # independent of the system theme or its absence (Linux without a desktop).
        self.picker_validate_button = Gtk.Button()
        self.picker_validate_icon = self._make_pad_icon("A", "lpm-pad-icon-a")
        self.picker_validate_text = Gtk.Label()
        validate_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        validate_box.append(self.picker_validate_icon)
        validate_box.append(self.picker_validate_text)
        self.picker_validate_button.set_child(validate_box)
        self.picker_validate_button.add_css_class("lpm-picker-button")
        self.picker_validate_button.add_css_class("lpm-picker-validate-button")
        self.picker_validate_button.connect("clicked", self.on_picker_validate_clicked)
        button_box.append(self.picker_validate_button)

        card.append(button_box)
        return card

    def _make_pad_icon(self, letter, css_class):
        icon = Gtk.Label(label=letter)
        icon.add_css_class("lpm-pad-icon")
        icon.add_css_class(css_class)
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_valign(Gtk.Align.CENTER)
        icon.set_visible(False)
        return icon

    def _update_picker_fade(self, *_args):
        adj = self.picker_scroll.get_vadjustment()
        # With a scrollbar, the rows stop before it so the selection's right rounding shows.
        scrollable = adj.get_upper() > adj.get_page_size() + 1
        if scrollable != self.picker_scrollable:
            self.picker_scrollable = scrollable
            self.picker_listbox.set_margin_end(26 if scrollable else 0)

    def set_pad_mode(self, on):
        """Gamepad mode: the buttons show a green "A" / red "B" icon and the gamepad texts;
        otherwise the plain Launch / Cancel texts. Called on any gamepad input (on) and on
        any keyboard or mouse input (off)."""
        if on == self.pad_mode:
            return
        self.pad_mode = on
        for button in (self.picker_validate_button, self.picker_cancel_button):
            if on:
                button.add_css_class("lpm-pad-flat")
            else:
                button.remove_css_class("lpm-pad-flat")
            button.set_can_target(not on)
            button.set_focusable(not on)
        self.picker_validate_icon.set_visible(on)
        self.picker_cancel_icon.set_visible(on)
        self.picker_validate_text.set_label(self.pad_validate_label if on else self.validate_label)
        self.picker_cancel_text.set_label(self.pad_cancel_label if on else self.cancel_label)

    def show_picker(self, title, prompt, validate_label, cancel_label, pad_validate_label, pad_cancel_label, entries):
        # The picker shows ONLY the list and the two buttons: the title and prompt lines
        # (still received in the request file) are never displayed.
        self.picker_title_label.set_visible(False)
        self.picker_prompt_label.set_visible(False)
        self.validate_label = validate_label
        self.cancel_label = cancel_label
        self.pad_validate_label = pad_validate_label
        self.pad_cancel_label = pad_cancel_label
        self.pad_mode = None
        self.set_pad_mode(False)

        while True:
            row = self.picker_listbox.get_row_at_index(0)
            if row is None:
                break
            self.picker_listbox.remove(row)

        first_row = None
        for entry in entries:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(xalign=0)
            # A long entry is cut with "..." instead of widening the whole card (the card
            # used to grow to the widest entry).
            label.set_ellipsize(Pango.EllipsizeMode.END)
            label.set_markup(_entry_markup(entry))
            row.set_child(label)
            row.lpm_label = label
            row.lpm_scroller = None
            self.picker_listbox.append(row)
            if first_row is None:
                first_row = row

        if first_row is not None:
            self.picker_listbox.select_row(first_row)

        self.picker_visible = True
        self.picker_card.set_visible(True)
        GLib.idle_add(self._update_picker_fade)
        GLib.idle_add(self._on_row_selected)
        self.picker_listbox.grab_focus()

    # --- Marquee of the selected entry (see MARQUEE_* above) ---
    def _marquee_stop(self):
        if self.marquee_source:
            GLib.source_remove(self.marquee_source)
            self.marquee_source = 0
        row = self.marquee_row
        self.marquee_row = None
        if row is not None and row.lpm_scroller is not None:
            row.lpm_scroller.set_child(None)
            row.lpm_label.set_ellipsize(Pango.EllipsizeMode.END)
            row.set_child(row.lpm_label)
            row.lpm_scroller = None

    def _on_row_selected(self, *_args):
        self._marquee_stop()
        if self.marquee_pending:
            GLib.source_remove(self.marquee_pending)
            self.marquee_pending = 0
        if not self.picker_visible:
            return
        row = self.picker_listbox.get_selected_row()
        if row is None:
            return
        self.marquee_pending = GLib.timeout_add(int(MARQUEE_START_DELAY_S * 1000), self._marquee_begin, row)

    def _marquee_begin(self, row):
        self.marquee_pending = 0
        if (not self.picker_visible or row is not self.picker_listbox.get_selected_row()
                or self.marquee_row is not None):
            return False
        label = row.lpm_label
        if not label.get_layout().is_ellipsized():
            return False
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.EXTERNAL, Gtk.PolicyType.NEVER)
        scroller.set_can_target(False)
        row.set_child(None)
        label.set_ellipsize(Pango.EllipsizeMode.NONE)
        scroller.set_child(label)
        row.set_child(scroller)
        row.lpm_scroller = scroller
        self.marquee_row = row
        self.marquee_state = {"phase": "wait_start", "t0": time.monotonic(), "x": 0.0}
        self.marquee_source = GLib.timeout_add(MARQUEE_TICK_MS, self._marquee_tick)
        return False

    def _marquee_tick(self):
        row = self.marquee_row
        if row is None or row.lpm_scroller is None:
            self.marquee_source = 0
            return False
        adj = row.lpm_scroller.get_hadjustment()
        end_x = max(0.0, adj.get_upper() - adj.get_page_size())
        st = self.marquee_state
        now = time.monotonic()
        if st["phase"] == "wait_start":
            if now - st["t0"] >= 0.3:
                st["phase"], st["last"] = "run", now
        elif st["phase"] == "run":
            st["x"] = min(end_x, st["x"] + MARQUEE_SPEED_PX_S * (now - st["last"]))
            st["last"] = now
            adj.set_value(st["x"])
            if st["x"] >= end_x:
                st["phase"], st["t0"] = "wait_end", now
        elif st["phase"] == "wait_end":
            if now - st["t0"] >= MARQUEE_END_PAUSE_S:
                st["phase"], st["last"] = "back", now
        elif st["phase"] == "back":
            # Back the other way (no jump): left, then right, and so on.
            st["x"] = max(0.0, st["x"] - MARQUEE_SPEED_PX_S * (now - st["last"]))
            st["last"] = now
            adj.set_value(st["x"])
            if st["x"] <= 0.0:
                st["phase"], st["t0"] = "wait_home", now
        elif st["phase"] == "wait_home":
            # Same pause back at the start as at the far end.
            if now - st["t0"] >= MARQUEE_END_PAUSE_S:
                st["phase"], st["last"] = "run", now
        return True

    def hide_picker(self):
        self._marquee_stop()
        if self.marquee_pending:
            GLib.source_remove(self.marquee_pending)
            self.marquee_pending = 0
        self.picker_visible = False
        self.picker_card.set_visible(False)

    def _write_picker_result(self, ok, label=""):
        try:
            with open(PICKER_RESULT_FILE, "w") as f:
                if ok:
                    f.write("OK\n" + label + "\n")
                else:
                    f.write("CANCEL\n")
        except OSError:
            pass
        self.hide_picker()

    def on_picker_validate_clicked(self, _button):
        self._validate_selected_row()

    def on_picker_cancel_clicked(self, _button):
        self._write_picker_result(False)

    def _validate_selected_row(self):
        row = self.picker_listbox.get_selected_row()
        if row is None:
            return
        # "get_text()", NEVER "get_label()" -- "get_label()" would return the raw Pango
        # markup ("<span size=...>...</span>"); "get_text()" returns the displayed text
        # with the markup stripped.
        label_widget = row.lpm_label
        self._write_picker_result(True, label_widget.get_text())

    # --- Gamepad navigation (see init_gamepad()/tick_gamepad() above): direct actions
    # on our own widgets, never a key injected from outside. ---
    def gamepad_move_selection(self, delta):
        self.set_pad_mode(True)
        row = self.picker_listbox.get_selected_row()
        idx = row.get_index() if row is not None else -1
        new_row = self.picker_listbox.get_row_at_index(idx + delta)
        if new_row is not None:
            self.picker_listbox.select_row(new_row)
            new_row.grab_focus()

    def gamepad_validate(self):
        self.set_pad_mode(True)
        if not self.cursor_hidden:
            self.hide_cursor()
        self._validate_selected_row()

    def gamepad_cancel(self):
        self.set_pad_mode(True)
        if not self.cursor_hidden:
            self.hide_cursor()
        self._write_picker_result(False)

    def on_listbox_key_pressed(self, _ctrl, keyval, _keycode, _state):
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            if not self.cursor_hidden:
                self.hide_cursor()
            self._validate_selected_row()
            return True
        return False

    def on_key_pressed(self, _ctrl, keyval, _keycode, _state):
        if self.picker_visible:
            self.set_pad_mode(False)
        if self.picker_visible and not self.cursor_hidden:
            self.hide_cursor()
        if keyval == Gdk.KEY_Escape and self.picker_visible:
            self._write_picker_result(False)
            return True
        return False
