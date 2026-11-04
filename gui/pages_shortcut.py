"""Page 'Shortcut': menu/desktop shortcuts and loading screen of games."""

from i18n import t
from commandpage import CommandPage
from widgets_rows import add_shortcut_rows
from widgets_select import GameMultiSelect


class ShortcutPage:
    def __init__(self, window):
        self.window = window

    def build(self):
        self._add_rows()
        self._wire_reset_and_run()
        return self.page

    def _add_rows(self):
        self.page = CommandPage(t("gui.shortcut.page_title"))
        self.selector = GameMultiSelect()
        self.page.add_row(self.selector)

        # Same shortcut settings as the install page (see add_shortcut_rows): "no shortcut"
        # is a consistent state, the loading screen is then hidden.
        self.menu_shortcut_row, self.desktop_shortcut_row, self.desktop_path_row, self.loadingscreen_row = \
            add_shortcut_rows(self.page, self.window)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    # Going back to the category menu, changing page, or a successful run resets
    # everything, see CommandPage.reset_selection.
    def reset_fields(self):
        self.selector.refresh()
        self.menu_shortcut_row.set_active(True)
        self.desktop_shortcut_row.set_active(True)
        self.loadingscreen_row.set_active(True)
        self.desktop_path_row.reset()

    def on_run(self, *_):
        slugs = self.selector.selected_slugs()
        if not slugs:
            self.page.toast(t("gui.shortcut.toast_choose_game"))
            return
        menu_on = self.menu_shortcut_row.get_active()
        desktop_on = self.desktop_shortcut_row.get_active()
        if menu_on and desktop_on:
            mode = "both"
        elif menu_on:
            mode = "menu"
        elif desktop_on:
            mode = "desktop"
        else:
            mode = "none"
        args = ["shortcut", f"--shortcut={mode}"]
        if (menu_on or desktop_on) and not self.loadingscreen_row.get_active():
            args.append("--no-loadingscreen")
        if desktop_on:
            desktop_path = self.desktop_path_row.value()
            if desktop_path:
                args.append(f"--desktop-dir={desktop_path}")
        args.extend(slugs)
        self.page.run_command(args, t("gui.shortcut.done"))
