"""Page: rename the display name of a game (Lutris database)."""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw  # noqa: E402

from i18n import t
from commandpage import CommandPage
from widgets_select import SingleGameSelect


class RenamePage:
    def __init__(self, window):
        self.window = window

    def build(self):
        self.page = CommandPage(t("gui.rename.page_title"))
        self.page.group.set_description(t("gui.rename.intro"))
        self.game_row = SingleGameSelect()
        self.page.add_row(self.game_row)
        self.name_row = Adw.EntryRow(title=t("gui.rename.entry_title"))
        self.page.add_row(self.name_row)
        self.page.reset_selection = self.game_row.refresh
        self.page.run_button.set_label(t("gui.rename.button"))
        self.page.run_button.connect("clicked", self.on_run)
        return self.page

    def on_run(self, *_):
        slug = self.game_row.selected_slug()
        name = self.name_row.get_text().strip()
        if not slug:
            self.page.toast(t("gui.common.choose_one_game"))
            return
        if not name:
            return
        self.page.run_command(["rename", slug, name], t("gui.rename.done"), refresh="games")
