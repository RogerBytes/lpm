"""Main window: sidebar, navigation, page construction."""

import os

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk, Pango  # noqa: E402

from i18n import t
from pages import CommandPages


# ---------------------------------------------------------------------------------------
class MainWindow(Adw.ApplicationWindow):
    # --- Sidebar categories (drill-down navigation, a single level deep, per the GNOME HIG
    #     navigation guideline): the root list shows only the 6 categories; clicking one
    #     replaces the sidebar content with its items (see _render_sidebar_category). The
    #     sidebar header is empty at the root; the category name + back button appear only
    #     inside a category, in THAT header (not the content bar's).
    #     Each category tuple is (id, label, icon, items) and each item is
    #     (cmd_id, label, icon); cmd_id remains the key used by BUILDER_NAMES, show_page()
    #     and open_install_for().
    # Built by a classmethod rather than a class-level literal: labels go through t(), and a
    # class-body value is evaluated ONCE at import, possibly before i18n._init() has detected
    # the locale. _CATEGORIES_CACHE stores the result (the locale does not change during a
    # session, as with the bash CLI).
    _CATEGORIES_CACHE: list | None = None

    @classmethod
    def _categories(cls) -> list:
        if cls._CATEGORIES_CACHE is None:
            cls._CATEGORIES_CACHE = [
                ("games", t("gui.category.games"), "applications-games-symbolic", [
                    # Order: "launcher" (loading screen / LPM Launcher), "shortcut"
                    # (launch settings) and "lsfg" (frame generation) come from the former
                    # "launch"/"Display" category, which was removed; these settings are
                    # per game like the other entries here.
                    ("install", t("gui.install.page_title"), "list-add-symbolic"),
                    # Dedicated icon (not the screen icon shared with lsfg below): LPM Launcher
                    # is an executable selection MENU, not a display setting.
                    # "view-grid-symbolic" is the standard GNOME application-launcher icon.
                    ("launcher", t("gui.launcher.page_title"), "view-grid-symbolic"),
                    ("shortcut", t("gui.shortcut.page_title"), "emblem-symbolic-link"),
                    # "images" (former "Visual"/"assets" category, merged here): icon/splash/
                    # logo are PER-GAME settings like the other entries, not a separate
                    # category. A single page/entry (see page_images) with checkable types.
                    ("images", t("gui.images.sidebar_label"), "image-x-generic-symbolic"),
                    ("lsfg", t("gui.lsfg.page_title"), "video-display-symbolic"),
                    ("tools", t("gui.sidebar.tools"), "applications-utilities-symbolic"),
                    ("vsync", t("gui.vsync.page_title"), "view-refresh-symbolic"),
                    ("exe-install", t("gui.exe_install.page_title"), "application-x-executable-symbolic"),
                    ("create-prefix", t("gui.create_prefix.sidebar_label"), "folder-new-symbolic"),
                    ("uninstall", t("gui.uninstall.page_title"), "user-trash-symbolic"),
                ]),
                ("backup", t("gui.category.backup"), "package-x-generic-symbolic", [
                    ("pack", t("gui.pack.page_title"), "package-x-generic-symbolic"),
                    ("isolate", t("gui.isolate.page_title"), "security-high-symbolic"),
                ]),
                ("runners", t("gui.category.runners"), "view-list-symbolic", [
                    ("download-runner", t("gui.download_runner.page_title"), "folder-download-symbolic"),
                    ("install-runner", t("gui.install_runner.page_title"), "list-add-symbolic"),
                    ("uninstall-runner", t("gui.uninstall_runner.page_title"), "user-trash-symbolic"),
                    ("pack-runner", t("gui.pack_runner.page_title"), "package-x-generic-symbolic"),
                ]),
                ("system", t("gui.category.system"), "preferences-system-symbolic", [
                    ("check", t("gui.check.page_title"), "emblem-ok-symbolic"),
                    ("lutris-version", t("gui.lutris_version.sidebar_label"), "preferences-system-symbolic"),
                    ("logs", t("gui.logs.page_title"), "text-x-generic-symbolic"),
                    ("killwine", t("gui.killwine.page_title"), "process-stop-symbolic"),
                ]),
            ]
        return cls._CATEGORIES_CACHE

    BUILDER_NAMES = {
        "home": "page_home",
        "install": "page_install",
        "uninstall": "page_uninstall",
        "create-prefix": "page_create_prefix",
        "exe-install": "page_exe_install",
        "shortcut": "page_shortcut",
        "images": "page_images",
        "tools": "page_tools",
        "vsync": "page_vsync",
        "launcher": "page_launcher",
        "lsfg": "page_lsfg",
        "pack": "page_pack",
        "isolate": "page_isolate",
        "download-runner": "page_download_runner",
        "install-runner": "page_install_runner",
        "uninstall-runner": "page_uninstall_runner",
        "pack-runner": "page_pack_runner",
        "check": "page_check",
        "lutris-version": "page_lutris_version",
        "logs": "page_logs",
        "killwine": "page_killwine",
    }

    def __init__(self, app: Adw.Application):
        super().__init__(application=app, title="lpm", default_width=980, default_height=680)

        self.pages = CommandPages(self)
        self._built_pages: dict[str, Gtk.Widget] = {}
        # Leaving a page for another (even without going through the category menu) also
        # resets it -- see show_page() below.
        self._current_page_id: str | None = None

        split_view = Adw.NavigationSplitView()
        sidebar_min_width = self._compute_min_sidebar_width()
        split_view.set_min_sidebar_width(sidebar_min_width)
        self.set_content(split_view)

        # --- Content bar (right, above the viewport): no fixed app brand here (the home page
        #     already shows it large). Only the name of the current function appears (set by
        #     show_page/open_install_for via set_title()), and nothing on the home page
        #     (label_by_id.get("home", "") already falls back to an empty string, "home" never
        #     being a category id, see _categories()).
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)

        content_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content_header = Adw.HeaderBar()
        # "flat": same reason as sidebar_header above -- removes the separator line between
        # this bar and the viewport; Gtk.ScrolledWindow (top_scroller, see CommandPage) still
        # shows its own "undershoot" scroll shadow whenever content remains to scroll, so the
        # visual cue is only contextual rather than permanent.
        content_header.add_css_class("flat")
        self.title_widget = Adw.WindowTitle()
        content_header.set_title_widget(self.title_widget)
        content_box.append(content_header)
        content_box.append(self.stack)
        content_page = Adw.NavigationPage(title="lpm", child=content_box)
        split_view.set_content(content_page)

        # --- Sidebar: EMPTY header by default (at the root) -- the category name and the
        #     back button (pack_start, hidden otherwise) appear only inside a category. Below,
        #     a single Gtk.ListBox whose content is rebuilt in place for the current level
        #     (categories, or a category's items); unlike an Adw.NavigationView, it never
        #     replaces the header, only shows/hides what it contains.
        sidebar_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        # show_start_title_buttons stays at its default (shown): with window buttons
        # configured on the left, they must stay here, above the category list (there is no
        # duplicate in the content bar). These buttons take space in the same left area as
        # the category name, which _compute_min_sidebar_width() accounts for.
        sidebar_header = Adw.HeaderBar(show_end_title_buttons=False)
        # "flat" removes the separator/shadow Adw.HeaderBar draws at its bottom edge, so the
        # whole left part (window bar + categories) reads as one continuous block.
        sidebar_header.add_css_class("flat")

        # CENTERED title widget (the real "title-widget" slot, not pack_start): shows the
        # category name inside a category, nothing at the root. It also explicitly replaces the
        # default title: without a title-widget, Adw.HeaderBar automatically shows the window
        # title ("lpm"), which must not appear in this header. Empty text at the root has the
        # same effect without swapping two different widgets.
        self.sidebar_category_label = Gtk.Label()
        self.sidebar_category_label.add_css_class("heading")
        # Safety net only: set_min_sidebar_width() above is computed so this never triggers
        # in practice (category names must not be shortened).
        self.sidebar_category_label.set_ellipsize(Pango.EllipsizeMode.END)
        sidebar_header.set_title_widget(self.sidebar_category_label)

        self.sidebar_back_button = Gtk.Button(
            icon_name="go-previous-symbolic", tooltip_text=t("gui.common.back_to_categories_tooltip")
        )
        # Frame forced by CSS (see _BACK_BUTTON_CSS, loaded in LpmApp.do_activate): removing
        # the "flat" class is not enough, most themes flatten all headerbar buttons.
        self.sidebar_back_button.add_css_class("lpm-back-button")
        self.sidebar_back_button.connect("clicked", lambda _b: self._on_back_to_categories())
        self.sidebar_back_button.set_visible(False)
        # pack_end, not pack_start: the back button is right-aligned in the bar, separated
        # from the category name (which stays on the left).
        sidebar_header.pack_end(self.sidebar_back_button)

        sidebar_box.append(sidebar_header)

        sidebar_scroller = Gtk.ScrolledWindow(vexpand=True)
        self.sidebar_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.sidebar_list.add_css_class("navigation-sidebar")
        sidebar_scroller.set_child(self.sidebar_list)
        sidebar_box.append(sidebar_scroller)

        sidebar_page = Adw.NavigationPage(title="lpm", child=sidebar_box)
        split_view.set_sidebar(sidebar_page)

        self._sidebar_mode = "root"
        self._sidebar_row_map: dict = {}

        def on_sidebar_row_activated(_listbox, row):
            if self._sidebar_mode == "root":
                cat_label, items = self._sidebar_row_map[row]
                self._render_sidebar_category(cat_label, items)
            else:
                cmd_id = self._sidebar_row_map.get(row)
                if cmd_id is None:
                    return
                self.show_page(cmd_id)
                # On narrow/mobile layouts, NavigationSplitView collapses sidebar+content into
                # one stack: the content must be pushed explicitly after choosing an item,
                # otherwise the view stays on the sidebar.
                content = self.get_content()
                if isinstance(content, Adw.NavigationSplitView):
                    content.set_show_content(True)

        self.sidebar_list.connect("row-activated", on_sidebar_row_activated)

        self._render_sidebar_root()
        # Neutral home page at launch (see page_home), rather than starting an action the
        # user did not ask for.
        self.show_page("home")

        # --- Minimum window size ---
        # set_size_request() on the window sets a floor (passed to the window manager)
        # without preventing growth; no maximum is set. Without it, the window could shrink
        # until the sidebar showed a single row and the content became unreadable.
        #
        # Minimum width = sidebar minimum width (sidebar_min_width, computed above so that no
        # category name is truncated) + a generous reserve for the content pane, which may
        # contain checklists with a "check all" button in the group header
        # (Adw.ExpanderRow.set_header_suffix) that needs a minimum width to avoid overlapping
        # the title.
        content_min_width_reserve = 750
        min_window_width = sidebar_min_width + content_min_width_reserve
        # Minimum height: enough to keep the header, a few content rows and the "Run" button
        # visible without scrolling right away. Fixed value (no page has an incompressible
        # content height comparable to the longest category name).
        min_window_height = 480
        self.set_size_request(min_window_width, min_window_height)

    def _compute_min_sidebar_width(self) -> int:
        """Minimum sidebar width computed from the longest category name (self._categories()),
        so that the label is never truncated by construction, and automatically follows
        category changes. Measured via Pango (create_pango_layout), reliable even before the
        window is mapped."""
        max_label_width = max(
            self.create_pango_layout(cat_label).get_pixel_size()[0]
            for _id, cat_label, _icon, _items in self._categories()
        )
        # Generous margins: the back button on the right (icon + theme padding, ~40px) and
        # the window buttons on the left next to the category name. Their exact width cannot
        # be known in advance (it varies with theme/icon set and number of configured
        # buttons), so a wide estimate (~110px, room for 3 buttons) is used, plus spacing and
        # a safety margin for font/theme variations (the label is measured with the default
        # font, which may differ from the real rendering with the "heading" CSS class).
        back_button_reserve = 40
        window_buttons_reserve = 110
        spacing_reserve = 24
        font_variance_margin = 40
        return (
            max_label_width
            + back_button_reserve
            + window_buttons_reserve
            + spacing_reserve
            + font_variance_margin
        )

    @staticmethod
    def _clear_listbox(listbox: Gtk.ListBox):
        child = listbox.get_first_child()
        while child is not None:
            next_child = child.get_next_sibling()
            listbox.remove(child)
            child = next_child

    def _render_sidebar_root(self):
        self._clear_listbox(self.sidebar_list)
        row_to_category: dict[Gtk.ListBoxRow, tuple] = {}
        for _cat_id, cat_label, cat_icon, items in self._categories():
            row = Adw.ActionRow(title=cat_label, activatable=True)
            row.add_prefix(Gtk.Image.new_from_icon_name(cat_icon))
            row.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
            self.sidebar_list.append(row)
            row_to_category[row] = (cat_label, items)
        self._sidebar_row_map = row_to_category
        self._sidebar_mode = "root"
        self.sidebar_category_label.set_label("")
        self.sidebar_back_button.set_visible(False)

    def _on_back_to_categories(self):
        # Back to the root list AND the home page: going "back" returns to the neutral
        # starting point instead of leaving the last page of the category just left.
        self._render_sidebar_root()
        self.show_page("home")
        # Returning to the category menu also clears any selection (checked file/game/runner
        # lists) on ALL already-built pages, since we cannot know which one will be reopened.
        # CommandPage.reset_selection is a no-op for pages without a list (e.g. page_home,
        # page_killwine).
        for page in self._built_pages.values():
            getattr(page, "reset_selection", lambda: None)()

    def _render_sidebar_category(self, cat_label: str, items: list[tuple[str, str, str]]):
        self._clear_listbox(self.sidebar_list)
        row_to_id: dict[Gtk.ListBoxRow, str] = {}
        for cmd_id, label, icon_name in items:
            row = Adw.ActionRow(title=label, activatable=True)
            row.add_prefix(Gtk.Image.new_from_icon_name(icon_name))
            self.sidebar_list.append(row)
            row_to_id[row] = cmd_id
        self._sidebar_row_map = row_to_id
        self._sidebar_mode = "category"
        self.sidebar_category_label.set_label(cat_label)
        self.sidebar_back_button.set_visible(True)

    def show_page(self, cmd_id: str):
        # Leaving a page for another resets it (not only a return to the category menu, see
        # _on_back_to_categories which resets ALL built pages) -- here only the page actually
        # left, and only if the page really changes (same cmd_id = no real navigation).
        if self._current_page_id is not None and self._current_page_id != cmd_id:
            previous = self._built_pages.get(self._current_page_id)
            if previous is not None:
                getattr(previous, "reset_selection", lambda: None)()

        if cmd_id not in self._built_pages:
            builder_name = self.BUILDER_NAMES[cmd_id]
            widget = getattr(self.pages, builder_name)()
            self.stack.add_named(widget, cmd_id)
            self._built_pages[cmd_id] = widget
        self.stack.set_visible_child_name(cmd_id)
        self._current_page_id = cmd_id
        label_by_id = {cid: label for _, _, _, items in self._categories() for cid, label, _ in items}
        self.title_widget.set_title(label_by_id.get(cmd_id, ""))

    def open_install_for(self, path: str):
        """Open the right install page directly (game or runner, depending on the extension)
        with "path" pre-filled. Replaces the former zenity-driven "click" mode (see bin/lpm,
        section 2: double-clicking a .zgp/.zgr now delegates here)."""
        extension = os.path.splitext(path)[1].lower()
        cmd_id = "install-runner" if extension == ".zgr" else "install"

        # Same reset of the page being left as in show_page() (see the comment there).
        if self._current_page_id is not None and self._current_page_id != cmd_id:
            previous = self._built_pages.get(self._current_page_id)
            if previous is not None:
                getattr(previous, "reset_selection", lambda: None)()

        # The target page may already exist in the stack (built via the sidebar or by a
        # previous open_install_for call). Gtk.Stack refuses a second child with the same name
        # (add_named), so remove the old one first, otherwise the new widget (with the new
        # file) is never displayed.
        old_widget = self._built_pages.get(cmd_id)
        if old_widget is not None:
            self.stack.remove(old_widget)

        if cmd_id == "install-runner":
            widget = self.pages.page_install_runner(initial_files=[path])
        else:
            widget = self.pages.page_install(initial_files=[path])
        self.stack.add_named(widget, cmd_id)
        self._built_pages[cmd_id] = widget
        self.stack.set_visible_child_name(cmd_id)
        self._current_page_id = cmd_id
        label_by_id = {cid: label for _, _, _, items in self._categories() for cid, label, _ in items}
        self.title_widget.set_title(label_by_id.get(cmd_id, ""))
