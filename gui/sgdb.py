"""SteamGridDB windows (title resolution, image selection)."""

import shutil
from typing import Callable

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
from i18n import t
from guilog import _GUI_LOGGER
from util import _escape_markup, _run_on_main, json_result

def _make_loading_box():
    """Shared "loading" box (spinner + text) for both windows. Returns (box, label)."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER,
                  halign=Gtk.Align.CENTER, spacing=12)
    box.append(Gtk.Spinner(spinning=True, width_request=32, height_request=32))
    label = Gtk.Label(label="")
    box.append(label)
    return box, label


def _make_bottom_bar(on_cancel, on_skip, on_next):
    """Bottom bar shared by both windows: Cancel on the left, Skip and Next on the right.
    Returns (bar, cancel button, skip button, next button)."""
    bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8,
                  margin_top=10, margin_bottom=10, margin_start=12, margin_end=12)
    cancel_btn = Gtk.Button(label=t("gui.sgdb_picker.btn_cancel"))
    cancel_btn.connect("clicked", lambda *_: on_cancel())
    bar.append(cancel_btn)

    bar.append(Gtk.Box(hexpand=True))

    skip_btn = Gtk.Button(label=t("gui.sgdb_picker.btn_skip"))
    skip_btn.connect("clicked", lambda *_: on_skip())
    bar.append(skip_btn)

    next_btn = Gtk.Button(label=t("gui.sgdb_picker.btn_next"))
    next_btn.add_css_class("suggested-action")
    next_btn.connect("clicked", lambda *_: on_next())
    bar.append(next_btn)
    return bar, cancel_btn, skip_btn, next_btn


def _make_toolbar_view(header, stack, bottom_bar):
    """Window content: header, page stack, separator, bottom bar."""
    content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    content.append(stack)
    content.append(Gtk.Separator())
    content.append(bottom_bar)
    toolbar_view = Adw.ToolbarView()
    toolbar_view.add_top_bar(header)
    toolbar_view.set_content(content)
    return toolbar_view



class SgdbTitleResolverWindow(Adw.Window):
    """Phase A of SteamGridDB image selection (icon/splash/logo): resolves the IDENTITY of
    each selected game (which exact game on SteamGridDB) BEFORE any image choice or download.
    Title disambiguation, the only choice that remains necessary (whether the rest is
    automatic or manual), always happens FIRST for all selected games, never mixed with image
    choices. Shared by both page_images modes ("Automatic download" checked or not): Phase B
    (SgdbPickerWindow) receives each game's identity and does no further search.

    Relies on "lpm sgdb-images title <slug>" (lib/zgl-sgdb-images.sh, type "title": same
    SteamGridDB search as icon/splash/logo but WITHOUT fetching any image/thumbnail; one
    identity per slug is enough, however many types are checked). Never interactive on the
    bash side (same non-interactive JSON protocol as the other "sgdb-images" calls):
    disambiguation, when needed, is shown HERE, never as a "read -p" in the script, which
    would receive closed input.

    Walks "queue" (list of (slug, name)) slug by slug; silent (just a "Searching..." spinner)
    for an unambiguous slug, and shows the list of matching games only when SteamGridDB
    returns several results for that name.

    "on_finished(resolved, cancelled)" is called once at the end:
      - "resolved": dict slug -> (game_id, game_name) for each successfully resolved slug.
        A slug missing from it (not found on SteamGridDB, no valid key, etc., or "Skip" on
        disambiguation) failed -- the caller must count ALL its checked types as failures
        and never attempt Phase B for that slug.
      - "cancelled" (bool): True if "Cancel" (button or close) interrupted the phase before
        the end -- the caller must abandon all processing (no Phase B), with a single generic
        failure marker, not one failure per type/game not yet processed."""

    def __init__(self, parent_window, queue: list[tuple[str, str]]):
        super().__init__(
            title=t("gui.sgdb_picker.title_window_title"),
            modal=True,
            transient_for=parent_window,
            default_width=520,
            default_height=420,
        )
        self._queue = queue  # [(slug, name), ...]
        self._index = -1
        self._matches: list[dict] = []
        self._resolved: dict[str, tuple[str, str]] = {}
        self._on_finished: Callable[[dict[str, tuple[str, str]], bool], None] | None = None
        self._closed = False
        self._cancelled = False

        self._window_title = Adw.WindowTitle(title=t("gui.sgdb_picker.title_window_title"))
        header = Adw.HeaderBar(title_widget=self._window_title, show_end_title_buttons=True)

        self._stack = Gtk.Stack(vexpand=True, transition_type=Gtk.StackTransitionType.CROSSFADE)

        loading_box, self._loading_label = _make_loading_box()
        self._stack.add_named(loading_box, "loading")

        self._game_listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self._game_listbox.connect("row-selected", self._on_game_row_selected)
        game_scroller = Gtk.ScrolledWindow(child=self._game_listbox, vexpand=True)
        self._stack.add_named(game_scroller, "choice")

        bottom_bar, self._cancel_btn, self._skip_btn, self._next_btn = _make_bottom_bar(
            self.close, self._advance, self._on_next)

        self.set_content(_make_toolbar_view(header, self._stack, bottom_bar))

        self.connect("close-request", self._on_close_request)

    def start(self, on_finished: Callable[[dict[str, tuple[str, str]], bool], None]):
        self._on_finished = on_finished
        self.present()
        self._advance()

    def _advance(self):
        self._index += 1
        if self._index >= len(self._queue):
            self._finish()
            return
        self._start_current_item()

    def _current_item(self) -> tuple[str, str]:
        return self._queue[self._index]

    def _start_current_item(self):
        slug, name = self._current_item()
        self._skip_btn.set_sensitive(False)
        self._next_btn.set_sensitive(False)
        self._window_title.set_subtitle(
            t("gui.sgdb_picker.title_progress", self._index + 1, len(self._queue), name)
        )
        self._loading_label.set_text(t("gui.sgdb_picker.loading", name))
        self._stack.set_visible_child_name("loading")
        backend.run_lpm_async(
            ["sgdb-images", "title", slug],
            on_done=lambda result: _run_on_main(self._on_title_result, slug, result),
        )

    def _on_title_result(self, slug: str, result: backend.CommandResult):
        if self._closed:
            return
        data = json_result(result)

        if data.get("need_game_choice"):
            self._show_choice(data.get("matches", []))
            return

        if not data.get("error") and data.get("game_id"):
            self._resolved[slug] = (str(data["game_id"]), str(data.get("game_name", "")))
        # Error (invalid key, game not found, missing slug...): this slug simply stays
        # absent from "_resolved", see the class docstring.
        self._advance()

    def _show_choice(self, matches: list[dict]):
        self._matches = matches
        for row in list(self._game_listbox):
            self._game_listbox.remove(row)
        for match in matches:
            row = Adw.ActionRow(title=_escape_markup(str(match.get("name", ""))))
            self._game_listbox.append(row)
        self._stack.set_visible_child_name("choice")
        self._skip_btn.set_sensitive(True)
        self._next_btn.set_sensitive(False)

    def _on_game_row_selected(self, _listbox, row):
        self._next_btn.set_sensitive(row is not None)

    def _on_next(self):
        row = self._game_listbox.get_selected_row()
        idx = row.get_index() if row is not None else -1
        if idx < 0 or idx >= len(self._matches):
            return
        slug, _name = self._current_item()
        match = self._matches[idx]
        # The name/id chosen in the list are what a second "sgdb-images title <slug> <id>
        # <name>" call would return, so that call is not needed.
        self._resolved[slug] = (str(match.get("id", "")), str(match.get("name", "")))
        self._advance()

    def _on_close_request(self, *_args):
        self._cancelled = True
        self._finish()
        return False

    def _finish(self):
        if self._closed:
            return
        self._closed = True
        callback = self._on_finished
        self._on_finished = None
        self.destroy()
        if callback is not None:
            callback(self._resolved, self._cancelled)


class SgdbPickerWindow(Adw.Window):
    """Phase B of SteamGridDB image selection (icon/splash/logo), for both page_images
    modes -- manual (grid of thumbnails to pick from) or automatic (first image taken
    directly, "auto_pick=True"). Each game's identity (game_id/game_name) is already
    resolved by SgdbTitleResolverWindow (Phase A) and carried by each "queue" item, so this
    window does no title search or disambiguation, only fetches image candidates (see "lpm
    sgdb-images", lib/zgl-sgdb-images.sh) and then downloads/applies the image via "lpm
    icon/splash/logo <slug> --url <url>".

    Downloads must NEVER block the following choices: as soon as an image is chosen ("Next"
    in manual mode, or automatically when candidates arrive in "auto_pick" mode), the
    download starts in the background (_launch_download, reusing all the existing
    download/convert/apply/shortcut-regeneration code) and the window IMMEDIATELY advances to
    the next item. Several downloads may run at once (no file conflict possible: a slug
    writes <prefix>/icon for the icon and <game>/splash/{splash,logo}.png for splash/logo,
    never the same file). The window closes and shows the final result only once ALL items
    are processed AND ALL in-flight downloads are done (see "_pending_downloads"/
    "_all_choices_done" and _maybe_finish_after_downloads), so it never closes on a
    partial result.

    Thumbnail ratios and cropping (square+COVER icon, wide+COVER splash, wide+CONTAIN logo,
    never cropped) are done by ImageMagick in lib/zgl-sgdb-images.sh, NOT here: GTK's
    "set_size_request" only sets a minimum, so a source thumbnail larger than the wanted box
    would still grow its "natural" size as seen by GTK (and, the FlowBox being homogeneous,
    the whole row with it) -- see the comment in _show_image_choice.

    "on_finished(failed_labels)" is called once, when the window closes (queue exhausted, or
    "Cancel"/manual close). "failed_labels" lists the "<game name> — <type>" for which no
    image could be applied, in the same format page_images._run_images uses for the failure
    toast."""

    _THUMB_BOX = {
        "icon": (112, 112),
        "splash": (186, 60),
        "logo": (170, 96),
    }
    _THUMB_FIT = {
        "icon": Gtk.ContentFit.COVER,
        "splash": Gtk.ContentFit.COVER,
        "logo": Gtk.ContentFit.CONTAIN,
    }

    def __init__(self, parent_window, queue: list[dict], auto_pick: bool = False):
        super().__init__(
            title=t("gui.sgdb_picker.window_title"),
            modal=True,
            transient_for=parent_window,
            default_width=620,
            default_height=560,
        )
        self._queue = queue
        # "auto_pick" ("Automatic download" checked, see page_images): no grid is shown, the
        # first candidate image is taken directly (see _on_images_result). "Skip"/"Next" are
        # useless then (nothing to choose), so they are hidden rather than just disabled.
        self._auto_pick = auto_pick
        self._index = -1
        self._stage = ""  # "image_choice" or "finishing"
        self._chosen_url = ""
        self._current_thumb_dir = ""
        self._image_urls: list[str] = []
        self._failed_labels: list[str] = []
        self._on_finished: Callable[[list[str]], None] | None = None
        self._closed = False
        # Downloads launched in the background AS SOON AS each choice is made (never waiting
        # during the following choices, even with several in flight) -- see _launch_download.
        # "_all_choices_done" becomes True when the choice queue is exhausted; the window
        # closes only once THAT and "_pending_downloads" == 0 (see _maybe_finish_after_downloads).
        self._pending_downloads = 0
        self._all_choices_done = False
        self._finished_naturally = False

        self._window_title = Adw.WindowTitle(title=t("gui.sgdb_picker.window_title"))
        header = Adw.HeaderBar(title_widget=self._window_title, show_end_title_buttons=True)

        self._stack = Gtk.Stack(vexpand=True, transition_type=Gtk.StackTransitionType.CROSSFADE)

        loading_box, self._loading_label = _make_loading_box()
        self._stack.add_named(loading_box, "loading")

        self._flowbox = Gtk.FlowBox(
            selection_mode=Gtk.SelectionMode.SINGLE,
            homogeneous=True,
            max_children_per_line=5,
            row_spacing=10,
            column_spacing=10,
            valign=Gtk.Align.START,
            margin_top=12, margin_bottom=12, margin_start=12, margin_end=12,
        )
        self._flowbox.connect("selected-children-changed", self._on_image_selection_changed)
        image_scroller = Gtk.ScrolledWindow(child=self._flowbox, vexpand=True)
        self._stack.add_named(image_scroller, "image_choice")

        bottom_bar, self._cancel_btn, self._skip_btn, self._next_btn = _make_bottom_bar(
            self.close, self._on_skip, self._on_next)
        self._skip_btn.set_visible(not auto_pick)
        self._next_btn.set_visible(not auto_pick)

        self.set_content(_make_toolbar_view(header, self._stack, bottom_bar))

        self.connect("close-request", self._on_close_request)

    def start(self, on_finished: Callable[[list[str]], None]):
        self._on_finished = on_finished
        self.present()
        self._advance()

    # --- Queue navigation ---

    def _advance(self):
        """Advance to the next item of the CHOICE queue (cleaning up the previous step) --
        never blocked by a running download, see _launch_download. Once the queue is
        exhausted, waits before closing only if downloads are still in flight (see
        _maybe_finish_after_downloads)."""
        self._cleanup_current_thumb_dir()
        self._index += 1
        if self._index >= len(self._queue):
            self._all_choices_done = True
            self._maybe_finish_after_downloads()
            return
        self._start_current_item()

    def _current_item(self) -> dict:
        return self._queue[self._index]

    def _start_current_item(self):
        item = self._current_item()
        self._stage = "loading"
        self._chosen_url = ""
        self._skip_btn.set_sensitive(False)
        self._next_btn.set_sensitive(False)
        self._window_title.set_subtitle(
            t("gui.sgdb_picker.progress", self._index + 1, len(self._queue), item["name"], item["type_label"])
        )
        self._loading_label.set_text(t("gui.sgdb_picker.loading", item["name"]))
        self._stack.set_visible_child_name("loading")
        # The game's identity is already resolved (Phase A, see SgdbTitleResolverWindow):
        # no search or disambiguation to redo here, only fetch the image candidates for
        # this specific type.
        self._request_images(item, item["game_id"], item["game_name"])

    def _request_images(self, item: dict, game_id: str, game_name: str):
        args = ["sgdb-images", item["type"], item["slug"], game_id, game_name or ""]
        backend.run_lpm_async(args, on_done=lambda result: _run_on_main(self._on_images_result, item, result))

    def _on_images_result(self, item: dict, result: backend.CommandResult):
        if self._closed:
            return
        data = json_result(result)

        if data.get("error") or not data.get("images"):
            self._record_failure(item)
            self._advance()
            return

        self._current_thumb_dir = str(data.get("thumb_dir", ""))
        images = data.get("images", [])

        if self._auto_pick:
            # No grid to show: the first candidate image (already the best found by
            # lib/zgl-sgdb-images.sh, see its comment) is taken directly, like the former
            # "lpm icon/splash/logo" without "--url". In automatic mode the only remaining
            # choice is the game identity (Phase A), never the image.
            first_url = str((images[0] if images else {}).get("url", ""))
            self._cleanup_current_thumb_dir()
            if not first_url:
                self._record_failure(item)
                self._advance()
                return
            self._launch_download(item, first_url)
            self._advance()
            return

        self._show_image_choice(item, images)

    def _show_image_choice(self, item: dict, images: list[dict]):
        self._stage = "image_choice"
        for child in list(self._flowbox):
            self._flowbox.remove(child)
        self._image_urls = []

        box_w, box_h = self._THUMB_BOX.get(item["type"], (112, 112))
        content_fit = self._THUMB_FIT.get(item["type"], Gtk.ContentFit.COVER)

        for image in images:
            thumb_path = str(image.get("thumb_path", ""))
            url = str(image.get("url", ""))
            if not thumb_path or not url:
                continue
            picture = Gtk.Picture.new_for_filename(thumb_path)
            picture.set_content_fit(content_fit)
            picture.set_size_request(box_w, box_h)
            # "halign/valign=CENTER" (instead of the default FILL): otherwise the FlowBoxChild
            # stretches the Picture to fill the whole cell -- which may be larger than the
            # box requested above -- and distorts the crop (non-square icon, logo cropped on
            # the sides). With CENTER, the Picture keeps exactly its requested size.
            picture.set_halign(Gtk.Align.CENTER)
            picture.set_valign(Gtk.Align.CENTER)
            picture.add_css_class("card")
            self._flowbox.append(picture)
            self._image_urls.append(url)
        self._stack.set_visible_child_name("image_choice")
        self._skip_btn.set_sensitive(True)
        self._next_btn.set_sensitive(False)

    def _on_image_selection_changed(self, _flowbox):
        selected = self._flowbox.get_selected_children()
        if not selected:
            self._chosen_url = ""
            self._next_btn.set_sensitive(False)
            return
        idx = selected[0].get_index()
        if 0 <= idx < len(self._image_urls):
            self._chosen_url = self._image_urls[idx]
            self._next_btn.set_sensitive(True)

    def _on_next(self):
        item = self._current_item()
        if self._stage == "image_choice":
            if not self._chosen_url:
                return
            # Start the download right away, IN THE BACKGROUND, then advance to the next
            # choice without waiting for it -- see the class docstring. No need to store the
            # URL on "item": the _launch_download closure already captures it.
            self._launch_download(item, self._chosen_url)
            self._advance()

    def _on_skip(self):
        self._advance()

    # --- Background downloads (one per choice, never waiting on each other) ---

    def _launch_download(self, item: dict, url: str):
        self._pending_downloads += 1
        _GUI_LOGGER.info("$ bin/lpm " + " ".join([item["type"], item["slug"], "--url", url]))

        def on_done(result: backend.CommandResult):
            def apply():
                if result.returncode != 0:
                    self._record_failure(item)
                self._pending_downloads -= 1
                self._maybe_finish_after_downloads()
            _run_on_main(apply)

        backend.run_lpm_async([item["type"], item["slug"], "--url", url], on_done=on_done)

    def _maybe_finish_after_downloads(self):
        """Called after each choice (queue exhausted) and after each download that ends. It
        only concludes (close + final result) when BOTH conditions hold: no more choices to
        make AND no download in flight. Before that, while still in the choice queue, there
        is nothing to show here (the "loading" view displayed during a choice --
        disambiguation, search -- has nothing to do with a download). Once the queue is
        exhausted but downloads are still running, shows a dedicated waiting state."""
        if not self._all_choices_done:
            return
        if self._pending_downloads > 0:
            if self._stage != "finishing":
                self._stage = "finishing"
                self._skip_btn.set_sensitive(False)
                self._next_btn.set_sensitive(False)
                self._cancel_btn.set_sensitive(False)  # downloads in flight: no clean cancellation possible anymore
                self._window_title.set_subtitle("")
                self._loading_label.set_text(t("gui.sgdb_picker.finishing_downloads"))
                self._stack.set_visible_child_name("loading")
            return
        self._finished_naturally = True
        self._finish()

    def _record_failure(self, item: dict):
        self._failed_labels.append(f"{item['name']} — {item['type_label']}")

    def _cleanup_current_thumb_dir(self):
        if self._current_thumb_dir:
            shutil.rmtree(self._current_thumb_dir, ignore_errors=True)
            self._current_thumb_dir = ""

    def _on_close_request(self, *_args):
        # Manual close ("Cancel" or window cross) before the NATURAL end of the choice phase
        # AND of all in-flight downloads (_finished_naturally, set by
        # _maybe_finish_after_downloads once both conditions hold): items not yet processed
        # never count as failures (never attempted), but page_images' final toast must not
        # show "Done" as if the whole batch had been processed -- see the marker added here.
        if not self._finished_naturally and not self._failed_labels:
            self._failed_labels.append(t("gui.sgdb_picker.cancelled_marker"))
        self._finish()
        return False

    def _finish(self):
        if self._closed:
            return
        self._closed = True
        self._cleanup_current_thumb_dir()
        callback = self._on_finished
        self._on_finished = None
        self.destroy()
        if callback is not None:
            callback(self._failed_labels)
