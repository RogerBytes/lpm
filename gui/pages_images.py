"""Page 'Images': icon, splash and logo of games from SteamGridDB."""

from typing import Callable

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from sgdb import SgdbPickerWindow, SgdbTitleResolverWindow
from util import _run_on_main, json_result
from widgets_select import GameMultiSelect


class ImagesPage:
    """Merges the former separate "Icon"/"Splash"/"Logo" pages (three PER-GAME settings
    like the other pages of the "Games" category, not a category of their own): one
    multi-game selector + three switches (checked by default: fetch everything) to choose
    which image types to fetch via SteamGridDB. "Run" chains one CLI call per checked type
    (never in parallel, see run_step) and reports a single aggregated result at the end.
    It continues with the remaining types even if one fails, since a missing type (e.g.
    a logo not found on SteamGridDB for a given game) should not prevent fetching the
    others."""

    def __init__(self, window):
        self.window = window

    def build(self):
        self._add_key_rows()
        self._wire_key_row()
        self._add_game_and_type_rows()
        self._wire_reset_and_run()
        return self.page

    def _add_key_rows(self):
        self.page = CommandPage(t("gui.images.page_title"), t("gui.images.subtitle"))

        # SteamGridDB API key -- entered directly ON this page (never a separate window),
        # masked (asterisks) but still editable (Adw.PasswordEntryRow), persistent once filled
        # (see lib/zgl-sgdb-key.sh, same storage file as "lpm icon"/"splash"/"logo").
        # "show_apply_button" shows an explicit validation checkmark (in addition to Enter):
        # the key is (re)tested with a REAL API call and saved ONLY on this "apply" signal,
        # never on each keystroke.
        self.sgdb_key_row = Adw.PasswordEntryRow(title=t("gui.images.sgdb_key_title"), show_apply_button=True)
        self.page.add_row(self.sgdb_key_row)

        # Warning + direct link to the SteamGridDB key page.
        # Two triggers, and NEVER an API call outside them: verification must only happen
        # when a key is EDITED/ADDED, never on each page opening or reset.
        #   - no saved key (empty) -- known without any API call, simple read via
        #     "lpm sgdb-key get" (see refresh_sgdb_key_row);
        #   - an entry attempt was just rejected by "lpm sgdb-key set" (see
        #     on_sgdb_key_apply) -- that call tests the key against the API anyway in order
        #     to save it, so it is never an EXTRA check.
        # Hidden as soon as a saved key exists (whether it is still valid is no longer
        # rechecked until it is modified).
        self.sgdb_key_notice_row = Adw.ActionRow(title=t("gui.images.sgdb_key_invalid_notice"), visible=False)
        sgdb_key_link_btn = Gtk.LinkButton(
            uri="https://www.steamgriddb.com/profile/preferences/api",
            label=t("gui.images.sgdb_key_link_label"),
            valign=Gtk.Align.CENTER,
        )
        self.sgdb_key_notice_row.add_suffix(sgdb_key_link_btn)
        self.page.add_row(self.sgdb_key_notice_row)

    def _wire_key_row(self):
        self.sgdb_key_row.connect("apply", self.on_sgdb_key_apply)
        # On page opening (and on each reset): "sgdb_key_notice_row" reflects ONLY the
        # absence of a key (empty), found without any API call -- never a revalidation of
        # the saved key (see the comment above "sgdb_key_notice_row").
        self.refresh_sgdb_key_row(lambda: self.sgdb_key_notice_row.set_visible(not self.sgdb_key_row.get_text()))

    def _add_game_and_type_rows(self):
        self.selector = GameMultiSelect()
        self.page.add_row(self.selector)

        self.icon_row = Adw.SwitchRow(title=t("gui.images.toggle_icon"), active=True)
        self.page.add_row(self.icon_row)
        self.splash_row = Adw.SwitchRow(title=t("gui.images.toggle_splash"), active=True)
        self.page.add_row(self.splash_row)
        self.logo_row = Adw.SwitchRow(title=t("gui.images.toggle_logo"), active=True)
        self.page.add_row(self.logo_row)

        # "Automatic download" checkbox -- UNCHECKED by default. Checked: the first
        # SteamGridDB result is taken without a window ("lpm icon"/"splash"/"logo" directly --
        # run_step below). Unchecked (default): opens SgdbPickerWindow, which goes game by
        # game then type by type and lets the user choose the image in a thumbnail grid (see
        # lib/zgl-sgdb-images.sh for candidate retrieval).
        self.auto_download_row = Adw.SwitchRow(title=t("gui.images.auto_download_toggle"), active=False)
        self.page.add_row(self.auto_download_row)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    def refresh_sgdb_key_row(self, on_synced: Callable[[], None] | None = None):
        """Resync only the FIELD (simple read, "lpm sgdb-key get", never an API call) --
        NEVER touches "sgdb_key_notice_row" itself: its state is decided by the only two
        legitimate callers below (empty key found at opening, or failure of a "set" in
        on_sgdb_key_apply), never rebuilt from the key's presence/absence on each call --
        that would erase the warning shown after a failure as soon as the old (non-empty)
        key still in place is read back."""
        def on_done(result: backend.CommandResult):
            data = json_result(result)
            key = str(data.get("key") or "")

            def apply():
                self.sgdb_key_row.set_text(key)
                if on_synced is not None:
                    on_synced()

            _run_on_main(apply)

        backend.run_lpm_async(["sgdb-key", "get"], on_done=on_done)

    def on_sgdb_key_apply(self, *_):
        candidate = self.sgdb_key_row.get_text().strip()

        def on_done(result: backend.CommandResult):
            def apply():
                if result.returncode != 0:
                    self.page.toast(t("gui.images.sgdb_key_set_failed"))
                    self.sgdb_key_notice_row.set_visible(True)
                    self.refresh_sgdb_key_row()  # back to the field with the key still in place
                else:
                    self.sgdb_key_notice_row.set_visible(False)
                    self.refresh_sgdb_key_row()  # confirm the field with the accepted key

            _run_on_main(apply)

        backend.run_lpm_async(["sgdb-key", "set", candidate], on_done=on_done)

    def reset_fields(self):
        self.selector.refresh()
        self.icon_row.set_active(True)
        self.splash_row.set_active(True)
        self.logo_row.set_active(True)
        self.auto_download_row.set_active(False)
        self.refresh_sgdb_key_row(lambda: self.sgdb_key_notice_row.set_visible(not self.sgdb_key_row.get_text()))

    def on_run(self, *_):
        entries = self.selector.selected_entries()
        if not entries:
            self.page.toast(t("gui.common.choose_one_game"))
            return

        types = []
        if self.icon_row.get_active():
            types.append(("icon", t("gui.images.toggle_icon")))
        if self.splash_row.get_active():
            types.append(("splash", t("gui.images.toggle_splash")))
        if self.logo_row.get_active():
            types.append(("logo", t("gui.images.toggle_logo")))
        if not types:
            self.page.toast(t("gui.images.toast_choose_type"))
            return

        self._run_images(entries, types, self.auto_download_row.get_active())

    def _run_images(self, entries, types, auto_pick):
        """Phase A (title resolution -- SgdbTitleResolverWindow) then Phase B (image
        choice/download -- SgdbPickerWindow), in that order, for BOTH modes ("Automatic
        download" checked or not). Title disambiguation, when needed, must always happen
        first for all selected games, before any image choice or download, whether that is
        then automatic ("auto_pick=True" -- first image taken directly) or manual (thumbnail
        grid)."""
        self.page.run_button.set_sensitive(False)
        resolver = SgdbTitleResolverWindow(self.window, entries)
        resolver.start(lambda resolved, cancelled: self._on_titles_resolved(entries, types, auto_pick, resolved, cancelled))

    def _finish_images(self, failed_labels):
        """End of the whole run: one aggregated message, then the form goes back to its start."""
        self.page.run_button.set_sensitive(True)
        if failed_labels:
            self.page.toast(t("gui.images.toast_failed", ", ".join(failed_labels)))
        else:
            self.page.toast(t("gui.common.done"))
        self.reset_fields()

    def _on_titles_resolved(self, entries, types, auto_pick, resolved: dict[str, tuple[str, str]], cancelled: bool):
        if cancelled:
            # Nothing was downloaded yet (Phase B never started) -- not one failure per
            # game/type, a single generic marker, same principle as cancellation in Phase B
            # (see SgdbPickerWindow._on_close_request).
            self._finish_images([t("gui.sgdb_picker.cancelled_marker")])
            return
        image_queue, failed_labels = self._build_image_queue(entries, types, resolved)
        if not image_queue:
            self._finish_images(failed_labels)
            return
        picker = SgdbPickerWindow(self.window, image_queue, auto_pick=auto_pick)
        picker.start(lambda image_failed_labels: self._finish_images(failed_labels + image_failed_labels))

    @staticmethod
    def _build_image_queue(entries, types, resolved):
        """One queue item per (game, image type); the games whose title could not be resolved
        are reported as failed instead."""
        failed_labels = []
        image_queue = []
        for slug, name in entries:
            identity = resolved.get(slug)
            if identity is None:
                failed_labels += [f"{name} — {label}" for _command, label in types]
                continue
            game_id, game_name = identity
            for command, label in types:
                image_queue.append({
                    "type": command, "type_label": label, "slug": slug, "name": name,
                    "game_id": game_id, "game_name": game_name,
                })
        return image_queue, failed_labels

