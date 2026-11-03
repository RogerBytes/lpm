# Drawing part of the loading-screen window (Cairo): background image, logo, title, entry
# label, loading indicator, gamepad help line and custom loading messages. Used as a mixin of
# ScreenWindow (zgu-launcher-screen.py).
import math
import time

import gi
gi.require_version("Gtk", "4.0")
import cairo

from zgu_screen_config import (
    BANNER_EXTRA_DOWN_FRACTION,
    BANNER_EXTRA_LIFT_NO_LABEL,
    LOGO_BANNER_GAP,
    SUBTITLE_BAND_HEIGHT,
    TOP_ZONE_MIN_MARGIN,
    BANNER_VERTICAL_LIFT,
    ENTRY_LABEL_FONT_SIZE,
    FONT_SIZE,
    HELP_ALTENTER_TEXT,
    HELP_ALTTAB_TEXT,
    HELP_F11_TEXT,
    HELP_F4_TEXT,
    HELP_FADE_S,
    HELP_FONT_SIZE,
    HELP_GAP,
    HELP_LINE_HEIGHT,
    HELP_MARGIN_LEFT,
    HELP_PERIOD_S,
    HELP_PILL_FONT_SIZE,
    HELP_PILL_HEIGHT,
    HELP_QUIT_TEXT,
    HELP_RESERVED_HEIGHT,
    HELP_RIGHT_RESERVED,
    INDICATOR_TEXT,
    LABEL_SHIFT_DOWN,
    LABEL_ZONE_TOP_PADDING,
    LOADING_MESSAGES,
    LOADING_MESSAGE_FONT_SIZE,
    LOADING_MESSAGE_LINE_HEIGHT,
    LOADING_MESSAGE_MAX_LINES,
    LOADING_MESSAGE_MAX_WIDTH_FRACTION,
    LOADING_MESSAGE_PERIOD_S,
    LOGO_EXTRA_DOWN,
    MARGIN_BOTTOM,
    MARGIN_RIGHT,
    MAX_BANNER_WIDTH_FRACTION,
    NO_LABEL,
    SPINNER_SIZE,
    TEXT_SPINNER_GAP,
    TOP_TITLE_BOTTOM_PADDING,
    TOP_TITLE_FONT_SIZE,
    entry_label_text,
    extend_help_sequence,
    gamepad_pads,
    help_sequence,
    help_start,
    message_start,
    picker_request_pending,
    show_indicator,
    spinner_angle,
    title_text,
    windows,
)




def draw_spinner(cr, cx, cy, radius, angle):
    """8 rotating fading spokes."""
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




class DrawMixin:
    # --- Drawing (Gtk.DrawingArea.set_draw_func replaces GTK3's "draw" signal): "cr, width,
    # height" are provided directly, no need for "get_allocation()". ---
    def on_draw(self, _area, cr, width, height):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 1)
        cr.paint()
        help_visible = self.gamepad_help_visible()
        if not help_visible:
            help_start[0] = None  # next appearance: restart from black (visible fade-in)
        all_messages = self.wrapped_loading_messages(cr, width)
        # Room kept for the TALLEST message, ALWAYS (even while the picker hides the messages):
        # the banner and the logo never jump when a message appears or changes.
        message_reserved = (max(len(m) for m in all_messages) * LOADING_MESSAGE_LINE_HEIGHT + 12) if all_messages else 0
        messages = self.loading_messages_lines(cr, width)
        # The help line's room is ALWAYS reserved (placeholder): the banner never moves when it appears.
        banner = self._banner_geometry(self.current_surface, width, height, True, message_reserved)  # drawn
        if banner is not None:
            off_x, off_y, scale, _base_y = banner
            cr.set_operator(cairo.OPERATOR_OVER)
            cr.translate(off_x, off_y)
            cr.scale(scale, scale)
            cr.set_source_surface(self.current_surface, 0, 0)
            cr.paint()
            cr.identity_matrix()

        cr.set_operator(cairo.OPERATOR_OVER)
        indicator_bottom_y = height - MARGIN_BOTTOM - SPINNER_SIZE / 2

        if show_indicator[0] and INDICATOR_TEXT:
            self.draw_indicator(cr, indicator_bottom_y, width)

        if help_visible:
            self.draw_gamepad_help(cr, indicator_bottom_y, width)

        if messages:
            self.draw_loading_message(cr, messages, width, height)

        # Logo and entry label are anchored to where the banner will be (its size is known in
        # advance, see banner_probe), whatever it is showing: they never move, neither when the
        # banner appears after a choice nor when the help line or a message takes some room.
        anchor = self._banner_geometry(self.banner_probe or self.current_surface, width, height, True, message_reserved)
        if entry_label_text[0]:
            shown = self._banner_geometry(self.banner_probe or self.current_surface, width, height, True, message_reserved)
            self.draw_entry_label(cr, width, height, anchor, shown)

        if self.logo_surface is not None:
            self.draw_logo(cr, width, height, anchor)
        elif title_text[0]:
            self.draw_top_title(cr, width)

    def _banner_geometry(self, surface, width, height, help_visible, message_reserved):
        """(x, y, scale, base_y) of the banner (splash image), or None if there is none to
        draw. base_y is its top before the extra move down: the logo is anchored to it."""
        banner_zone_height = self.banner_zone_height - (HELP_RESERVED_HEIGHT if help_visible else 0) - message_reserved
        if surface is None or banner_zone_height <= 0:
            return None
        img_w = surface.get_width()
        img_h = surface.get_height()
        scale = min(
            1.0,
            (width * MAX_BANNER_WIDTH_FRACTION) / img_w,
            banner_zone_height / img_h,
        )
        off_x = (width - img_w * scale) / 2
        off_y = self.banner_zone_top + (banner_zone_height - img_h * scale) / 2
        extra_lift = BANNER_EXTRA_LIFT_NO_LABEL if NO_LABEL else 0
        off_y = max(self.banner_zone_top, off_y - BANNER_VERTICAL_LIFT - extra_lift)
        base_y = off_y
        if NO_LABEL:
            # Moved down, but never below the end of its zone (tall banner: moved less).
            zone_end = self.banner_zone_top + banner_zone_height
            off_y += max(0, min(height * BANNER_EXTRA_DOWN_FRACTION, zone_end - (off_y + img_h * scale)))
        return off_x, off_y, scale, base_y

    @staticmethod
    def _banner_band():
        """Free height between the logo and the banner: small gap, or the subtitle band on a
        launcher with a picker (kept even while no entry is chosen yet, so nothing jumps)."""
        return LOGO_BANNER_GAP if NO_LABEL else SUBTITLE_BAND_HEIGHT

    def gamepad_help_visible(self):
        if not gamepad_pads or not any((HELP_ALTTAB_TEXT, HELP_QUIT_TEXT, HELP_F4_TEXT,
                                         HELP_ALTENTER_TEXT, HELP_F11_TEXT)):
            return False
        # Wait until the picker is done (requested or shown on any screen).
        if picker_request_pending[0] or any(w.picker_visible for w in windows):
            return False
        return True

    @staticmethod
    def _help_text_baseline(cr, cy):
        """Baseline that vertically centers CAPITAL letters on `cy` for the current font size.
        Using the cap height (not the height of each string) keeps every text of the help line
        on the same axis as the buttons, whatever letters it contains (descenders, accents)."""
        ref = cr.text_extents("H")
        return cy - ref.y_bearing - ref.height / 2

    def _help_pill_width(self, cr, kind, label):
        if kind == "dpad":
            return 2 * HELP_PILL_HEIGHT + 4
        if kind in ("dpad_up", "dpad_down"):
            return HELP_PILL_HEIGHT
        cr.set_font_size(HELP_PILL_FONT_SIZE)
        text_w = cr.text_extents(label).width
        if kind in ("L3", "R3"):
            return HELP_PILL_HEIGHT + 2
        return max(34, text_w + 16)

    def _help_rounded_rect(self, cr, x, y, w, h, r):
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()

    def _help_draw_item(self, cr, kind, label, x, cy):
        """Draw an icon (button pill) starting at x, return its width."""
        w = self._help_pill_width(cr, kind, label)
        h = HELP_PILL_HEIGHT
        top = cy - h / 2
        cr.set_line_width(1.5)
        if kind in ("dpad", "dpad_up", "dpad_down"):
            # One or two square D-pad keys with an arrow: (dx, dy) = arrow direction.
            arrows = {"dpad": ((-1, 0), (1, 0)), "dpad_up": ((0, -1),), "dpad_down": ((0, 1),)}[kind]
            for i, (dx, dy) in enumerate(arrows):
                bx = x + i * (h + 4)
                self._help_rounded_rect(cr, bx, top, h, h, 5)
                cr.set_source_rgba(1, 1, 1, 0.10)
                cr.fill_preserve()
                cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
                cr.stroke()
                mx = bx + h / 2
                # Tip 4 px from the center along (dx, dy), base 3 px behind, +/-5 px wide.
                cr.move_to(mx + dx * 4, cy + dy * 4)
                cr.line_to(mx - dx * 3 - dy * 5, cy - dy * 3 + dx * 5)
                cr.line_to(mx - dx * 3 + dy * 5, cy - dy * 3 - dx * 5)
                cr.close_path()
                cr.fill()
            return w
        if kind in ("L3", "R3"):
            cr.new_sub_path()
            cr.arc(x + w / 2, cy, h / 2, 0, 2 * math.pi)
        elif kind in ("L2", "R2"):
            self._help_rounded_rect(cr, x, top, w, h, h / 2)
        else:
            self._help_rounded_rect(cr, x, top, w, h, 6)
        cr.set_source_rgba(1, 1, 1, 0.10)
        cr.fill_preserve()
        cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
        cr.stroke()
        cr.set_font_size(HELP_PILL_FONT_SIZE)
        ext = cr.text_extents(label)
        cr.move_to(x + (w - ext.width) / 2 - ext.x_bearing, self._help_text_baseline(cr, cy))
        cr.show_text(label)
        return w

    def _help_line_items(self, buttons, with_direction, text):
        """with_direction: False, True (left/right arrows), or the name of a key type to
        add after the "+" ("dpad_up", "dpad_down", "Select")."""
        items = [(b, b) for b in buttons]
        if with_direction:
            items.append(("plus", "+"))
            kind = "dpad" if with_direction is True else with_direction
            items.append((kind, "Select" if kind == "Select" else ""))
        return items, text

    def _help_line_width(self, cr, items, text):
        total = 0
        for kind, label in items:
            if kind == "plus":
                cr.set_font_size(HELP_FONT_SIZE)
                total += cr.text_extents("+").x_advance + HELP_GAP
            else:
                total += self._help_pill_width(cr, kind, label) + HELP_GAP
        cr.set_font_size(HELP_FONT_SIZE)
        total += 8 + cr.text_extents(text).x_advance
        return total

    def _help_lines(self):
        """Help lines (items, text) actually available, per the configured texts."""
        lines = []
        if HELP_ALTTAB_TEXT:
            lines.append(self._help_line_items(["L1", "L2", "R1", "R2", "R3"], True, HELP_ALTTAB_TEXT))
        hotkey = ["L1", "L2", "R1", "R2", "R3"]
        for text, kind in ((HELP_F4_TEXT, "dpad_up"), (HELP_ALTENTER_TEXT, "dpad_down"),
                           (HELP_F11_TEXT, "Select")):
            if text:
                lines.append(self._help_line_items(hotkey, kind, text))
        if HELP_QUIT_TEXT:
            quit_items, quit_text = self._help_line_items(hotkey, False, HELP_QUIT_TEXT)
            lines.append((quit_items + [("plus", "+"), ("L3", "L3")], quit_text))
        return lines

    @staticmethod
    def _help_line_alpha(k, count, current, u):
        """Fade in, full, fade out to black (nothing written), only then the next line. A
        single available line is always opaque."""
        if count == 1:
            return 1.0
        if k != current:
            return 0.0
        if u < HELP_FADE_S:
            return u / HELP_FADE_S
        if u < HELP_PERIOD_S - HELP_FADE_S:
            return 1.0
        return (HELP_PERIOD_S - u) / HELP_FADE_S

    def _help_draw_line(self, cr, items, text, x, cy):
        for kind, label in items:
            cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
            if kind == "plus":
                cr.set_font_size(HELP_FONT_SIZE)
                ext = cr.text_extents("+")
                cr.move_to(x, cy - ext.y_bearing - ext.height / 2)  # center of the "+" glyph itself
                cr.show_text("+")
                x += ext.x_advance + HELP_GAP
            else:
                x += self._help_draw_item(cr, kind, label, x, cy) + HELP_GAP
        cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
        cr.set_font_size(HELP_FONT_SIZE)
        cr.move_to(x + 8, self._help_text_baseline(cr, cy))
        cr.show_text(text)

    def draw_gamepad_help(self, cr, bottom_center_y, width):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        lines = self._help_lines()
        available = width - HELP_MARGIN_LEFT - HELP_RIGHT_RESERVED
        widest = max(self._help_line_width(cr, items, text) for items, text in lines)
        scale = min(1.0, available / widest) if widest > 0 else 1.0

        # Alpha of each line (one at a time, cross-fade) from the time elapsed since the help
        # first appeared. The order is random (see extend_help_sequence), restarted each
        # time the help reappears.
        now = time.monotonic()
        if help_start[0] is None:
            help_start[0] = now
            help_sequence.clear()
        elapsed = now - help_start[0]
        slot = int(elapsed // HELP_PERIOD_S)
        u = elapsed - slot * HELP_PERIOD_S
        extend_help_sequence(help_sequence, len(lines), slot)
        current = help_sequence[slot]

        for k, (items, text) in enumerate(lines):
            alpha = self._help_line_alpha(k, len(lines), current, u)
            if alpha <= 0:
                continue
            cr.save()
            cr.scale(scale, scale)
            cr.push_group()
            self._help_draw_line(cr, items, text, HELP_MARGIN_LEFT / scale, bottom_center_y / scale)
            cr.pop_group_to_source()
            cr.paint_with_alpha(alpha)
            cr.restore()

    def draw_indicator(self, cr, center_y, width):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(FONT_SIZE)
        extents = cr.text_extents(INDICATOR_TEXT)

        spinner_cx = width - MARGIN_RIGHT - SPINNER_SIZE / 2
        text_x = spinner_cx - SPINNER_SIZE / 2 - TEXT_SPINNER_GAP - extents.width

        cr.set_source_rgba(0.91, 0.91, 0.91, 1)
        cr.move_to(text_x, center_y + extents.height / 2)
        cr.show_text(INDICATOR_TEXT)

        draw_spinner(cr, spinner_cx, center_y, SPINNER_SIZE / 2 - 2, spinner_angle[0])

    def loading_messages_lines(self, cr, width):
        """Every message wrapped to the available width, as a list of lists of lines (empty if
        there is no message or if the picker is on screen). Needs no font set by the caller."""
        if not LOADING_MESSAGES or picker_request_pending[0] or any(w.picker_visible for w in windows):
            message_start[0] = None  # restart from black when the messages come back
            return []
        return self.wrapped_loading_messages(cr, width)

    def wrapped_loading_messages(self, cr, width):
        """Same lines as above, whether the messages are shown or not (for the reserved room)."""
        if not LOADING_MESSAGES:
            return []
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(LOADING_MESSAGE_FONT_SIZE)
        max_w = min(width * LOADING_MESSAGE_MAX_WIDTH_FRACTION, 1100)
        result = []
        for message in LOADING_MESSAGES:
            lines, current = [], ""
            for word in message.split(" "):
                candidate = (current + " " + word).strip()
                if current and cr.text_extents(candidate).x_advance > max_w:
                    lines.append(current)
                    current = word
                else:
                    current = candidate
            if current:
                lines.append(current)
            if len(lines) > LOADING_MESSAGE_MAX_LINES:
                lines = lines[:LOADING_MESSAGE_MAX_LINES]
                lines[-1] = lines[-1].rstrip(" .,;:") + "\u2026"
            result.append(lines)
        return result

    def draw_loading_message(self, cr, messages, width, height):
        """Draws the CURRENT message: fade in, full, fade out to black, then the next one."""
        now = time.monotonic()
        if message_start[0] is None:
            message_start[0] = now
        elapsed = now - message_start[0]
        slot = int(elapsed // LOADING_MESSAGE_PERIOD_S)
        u = elapsed - slot * LOADING_MESSAGE_PERIOD_S
        lines = messages[slot % len(messages)]
        if len(messages) == 1:
            alpha = 1.0
        elif u < HELP_FADE_S:
            alpha = u / HELP_FADE_S
        elif u < LOADING_MESSAGE_PERIOD_S - HELP_FADE_S:
            alpha = 1.0
        else:
            alpha = (LOADING_MESSAGE_PERIOD_S - u) / HELP_FADE_S
        if alpha <= 0:
            return
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(LOADING_MESSAGE_FONT_SIZE)
        cr.set_source_rgba(0.91, 0.91, 0.91, 0.95 * alpha)
        bottom = height - MARGIN_BOTTOM - (HELP_LINE_HEIGHT + 10)  # help line room always reserved
        first_baseline = bottom - (len(lines) - 1) * LOADING_MESSAGE_LINE_HEIGHT
        for i, line in enumerate(lines):
            ext = cr.text_extents(line)
            cr.move_to((width - ext.x_advance) / 2, first_baseline + i * LOADING_MESSAGE_LINE_HEIGHT)
            cr.show_text(line)

    def _logo_ink_bottom(self, width, height, anchor):
        """y of the lowest visible pixel of the logo (its PNG may have transparent padding)."""
        x, y, scale = self._logo_placement(width, height, anchor)
        pad = getattr(self, "_logo_pad_bottom", None)
        if pad is None:
            surf = self.logo_surface
            w, h = surf.get_width(), surf.get_height()
            data = surf.get_data()
            stride = surf.get_stride()
            pad = h
            for row in range(h - 1, -1, -1):
                if any(data[row * stride + 4 * c + 3] for c in range(0, w, 2)):
                    pad = h - 1 - row
                    break
            self._logo_pad_bottom = pad
        return y + (self.logo_surface.get_height() - pad) * scale

    def draw_entry_label(self, cr, width, height, anchor, shown):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(ENTRY_LABEL_FONT_SIZE)
        extents = cr.text_extents(entry_label_text[0])

        label_x = (width - extents.width) / 2
        if anchor is not None and shown is not None and self.logo_surface is not None:
            # Centered between the visible bottom of the logo and the top of the banner.
            top = self._logo_ink_bottom(width, height, anchor)
            mid = (top + shown[1]) / 2
            label_baseline_y = mid + extents.height / 2
        elif anchor is not None:
            label_baseline_y = anchor[3] - self._banner_band() / 2 + extents.height / 2
        else:
            label_baseline_y = self.label_zone_top + LABEL_ZONE_TOP_PADDING + LABEL_SHIFT_DOWN + self.block_extra_down + extents.height

        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(label_x, label_baseline_y)
        cr.show_text(entry_label_text[0])

    def _logo_placement(self, width, height, banner):
        """(x, y, scale) of the logo: right above the banner (then shrunk if the room above is
        too small), or the fixed position of the top zone while there is no banner."""
        img_w = self.logo_surface.get_width()
        img_h = self.logo_surface.get_height()
        scale = self.logo_draw_w / img_w
        if banner is not None:
            bottom = banner[3] - self._banner_band()
            room = bottom - TOP_ZONE_MIN_MARGIN
            if room > 0:
                scale = min(scale, room / img_h)
                return (width - img_w * scale) / 2, bottom - img_h * scale, scale
        shift = 0 if NO_LABEL else (LABEL_SHIFT_DOWN + LOGO_EXTRA_DOWN)
        return self.logo_draw_x, self.logo_draw_y + shift + self.block_extra_down, scale

    def draw_logo(self, cr, width, height, banner):
        x, y, scale = self._logo_placement(width, height, banner)
        if not NO_LABEL:
            # The logo never moves for the picker: it is the picker card that goes below it.
            self._fit_picker_card(height, y + self.logo_surface.get_height() * scale)
        cr.set_operator(cairo.OPERATOR_OVER)
        cr.save()
        cr.translate(x, y)
        cr.scale(scale, scale)
        cr.set_source_surface(self.logo_surface, 0, 0)
        cr.paint()
        cr.restore()

    def draw_top_title(self, cr, width):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(TOP_TITLE_FONT_SIZE)
        extents = cr.text_extents(title_text[0])

        title_x = (width - extents.width) / 2
        if self.title_centered:
            title_baseline_y = (self.title_zone_bottom + extents.height) / 2
        else:
            title_baseline_y = self.title_zone_bottom - TOP_TITLE_BOTTOM_PADDING

        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(title_x, title_baseline_y)
        cr.show_text(title_text[0])

    def set_image(self, path):
        try:
            self.current_surface = cairo.ImageSurface.create_from_png(path)
        except Exception:
            self.current_surface = None
        self.drawing_area.queue_draw()

    def clear_image(self):
        self.current_surface = None
        self.drawing_area.queue_draw()

    def queue_redraw(self):
        self.drawing_area.queue_draw()
