"""Page: version number of a game (free text, kept in the game's settings, written into the .zgp
at export, shown when another package of the game is installed over it)."""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from util import _run_on_main
from widgets_select import SingleGameSelect


class VersionPage:
    def __init__(self, window):
        self.window = window
        self.state = {"gen": 0}

    def build(self):
        self.page = CommandPage(t("gui.game_version.page_title"))
        self.page.group.set_description(t("gui.game_version.intro"))
        self.game_row = SingleGameSelect()
        self.page.add_row(self.game_row)
        self.version_row = Adw.EntryRow(title=t("gui.game_version.entry_title"))
        self.version_row.set_sensitive(False)
        self.page.add_row(self.version_row)
        clear = Gtk.Button(label=t("gui.game_version.clear"), valign=Gtk.Align.CENTER)
        clear.connect("clicked", self.on_clear)
        self.version_row.add_suffix(clear)
        self.game_row.connect_changed(self.load)
        self.page.reset_selection = self.game_row.refresh
        self.page.run_button.set_label(t("gui.game_version.save"))
        self.page.run_button.connect("clicked", self.on_save)
        return self.page

    def load(self):
        self.state["gen"] += 1
        gen = self.state["gen"]
        slug = self.game_row.selected_slug()
        self.version_row.set_text("")
        self.version_row.set_sensitive(bool(slug))
        if not slug:
            return

        def done(result):
            def apply():
                if gen == self.state["gen"] and result.returncode == 0:
                    self.version_row.set_text(result.stdout.strip())
            _run_on_main(apply)

        backend.run_ludis_async(["game-version", slug], on_done=done)

    def _run(self, extra, done_msg):
        slug = self.game_row.selected_slug()
        if not slug:
            self.page.toast(t("gui.common.choose_one_game"))
            return
        self.page.run_command(["game-version", slug, *extra], done_msg, refresh=None)

    def on_save(self, *_):
        value = self.version_row.get_text().strip()
        if not value:
            self._run(["--clear"], t("gui.game_version.cleared"))
        else:
            self._run([value], t("gui.game_version.saved"))

    def on_clear(self, *_):
        self.version_row.set_text("")
        self._run(["--clear"], t("gui.game_version.cleared"))
