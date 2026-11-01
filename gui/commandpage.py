"""Generic command page: form, launching bin/lpm, reading the line protocol."""

import os
import re
import signal
from typing import Callable

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk, Pango  # noqa: E402

import backend
from i18n import t
from guilog import _GUI_LOGGER, show_log_dialog
from refresh import _refresh_game_lists, _refresh_runner_lists
from util import _run_on_main


# "[current/total] ..." pattern already present in the output of several lib/*.sh scripts
# (see uninstall_game.progress_cli, uninstall_runner.progress_cli, pack_runner.compressing_cli,
# install_game.progress_cli, install_runner.progress_cli in lang/*.lang), reused as is rather
# than inventing a GUI-specific format. It only says "which item out of how many"; it no
# longer drives the bar fill (see _update_item_progress).
_ITEM_LINE_RE = re.compile(r"^\[(\d+)/(\d+)\]")


# Current item name: text between the first and last apostrophe of the "[n/total] ... 'name'
# ..." line (the 5 progress_cli/compressing_cli messages quote the name, in every language).
# Absent -> only "n / total" is shown.
_ITEM_NAME_RE = re.compile(r"'(.+)'")


# "[PROGRESS] <pct>" pattern, emitted by zgp-game-installer.sh/zgr-runner-installer.sh during
# extraction (via "pv -n"): a 0-100 percentage for the CURRENT item only, never the whole
# batch. This percentage, not "[n/total]" above, drives the bar fill, so the bar follows the
# package being installed instead of jumping one step per finished package.
_PERCENT_LINE_RE = re.compile(r"^\[PROGRESS\]\s*(\d+)")


# "[STEP] <n> <total> <label>": current step of a multi-step command (lpm check);
# "[REPORT] <ok|warn|error>|<text>": one line of the final summary (see page_check).
_STEP_LINE_RE = re.compile(r"^\[STEP\]\s+(\d+)\s+(\d+)\s+(.*)$")


_REPORT_LINE_RE = re.compile(r"^\[REPORT\]\s+(ok|warn|error|runner)\|(.*)$")


# ---------------------------------------------------------------------------------------
# --- Generic command page: a form, nothing else in the viewport ---
class CommandPage(Gtk.Box):
    def __init__(self, title: str, subtitle: str = ""):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        # Reset by each page_* that builds a selector (files/games/runners); no-op by
        # default for pages without a list (e.g. page_home, page_killwine). Called after a
        # successful command (see run_command) and from MainWindow._on_back_to_categories(),
        # so a list never shows a selection left over from a previous session.
        self.reset_selection = lambda: None
        self.toast_overlay = Adw.ToastOverlay()
        self.append(self.toast_overlay)

        top_scroller = Gtk.ScrolledWindow()
        top_scroller.set_vexpand(True)
        self.page = Adw.PreferencesPage()
        self.page.set_title(title)
        top_scroller.set_child(self.page)
        self.toast_overlay.set_child(top_scroller)

        self.group = Adw.PreferencesGroup(title=subtitle or None)
        self.page.add(self.group)

        self._build_progress_group()
        self._build_action_group()

    def _build_progress_group(self):
        # Progress bar: hidden while no command runs (see run_command). Pulsing by default,
        # since nothing is known until a "[n/total]" line arrives (see _ITEM_LINE_RE); once
        # received, the text shows "which item out of how many" and the fill advances only on
        # "[PROGRESS] <pct>" lines (the real progress of the current item).
        self._pulse_source_id: int | None = None
        self.progress_bar = Gtk.ProgressBar()
        self.progress_bar.set_show_text(True)
        self.progress_bar.set_hexpand(True)
        self.progress_bar.set_visible(False)
        self.page.add(self._wrap_action_group(self.progress_bar))

    def _build_action_group(self):
        self.run_button = Gtk.Button(label=t("gui.common.run"))
        self.run_button.add_css_class("suggested-action")
        self.run_button.add_css_class("pill")
        self.run_button.set_halign(Gtk.Align.END)
        self.run_button.set_margin_top(6)
        self.run_button.set_margin_end(6)
        self.run_button.set_margin_bottom(6)
        action_row_box = Gtk.Box(halign=Gtk.Align.END, spacing=6)
        # "Cancel" button: hidden except during a command run with cancellable=True.
        self.cancel_button = Gtk.Button(label=t("gui.install.cancel_button"))
        self.cancel_button.add_css_class("destructive-action")
        self.cancel_button.add_css_class("pill")
        self.cancel_button.set_margin_top(6)
        self.cancel_button.set_margin_bottom(6)
        self.cancel_button.set_visible(False)
        action_row_box.append(self.cancel_button)
        action_row_box.append(self.run_button)
        # Kept so an immediate-effect page (page_vsync) can hide the "Run" button.
        self.action_group = self._wrap_action_group(action_row_box)
        self.page.add(self.action_group)

    @staticmethod
    def _wrap_action_group(box):
        group = Adw.PreferencesGroup()
        group.add(box)
        return group

    def add_row(self, row):
        self.group.add(row)

    def toast(self, text: str):
        self.toast_overlay.add_toast(Adw.Toast(title=text, timeout=4))

    def toast_failure(self, code, detail=""):
        """Failure message with a "View log" button that opens lpm-gui.log in the GUI
        (the message mentions that file, which must be readable without leaving the app).
        detail = last error line printed by the command (already translated), if any."""
        if detail:
            if len(detail) > 220:
                detail = detail[:217] + "..."
            title = t("gui.common.command_failed_detail", code, detail)
        else:
            title = t("gui.common.command_failed", code)
        toast = Adw.Toast(title=title, timeout=15,
                          button_label=t("gui.common.view_log"))
        toast.connect("button-clicked", lambda *_: show_log_dialog(self.get_root()))
        self.toast_overlay.add_toast(toast)

    # --- Progress bar (see run_command) ---
    def _pulse_tick(self) -> bool:
        self.progress_bar.pulse()
        return True  # True = GLib.timeout_add keeps calling this, indefinitely

    def _stop_pulsing(self):
        if self._pulse_source_id is not None:
            GLib.source_remove(self._pulse_source_id)
            self._pulse_source_id = None

    def _start_progress(self):
        self._step_text = ""
        self.progress_bar.set_fraction(0.0)
        self.progress_bar.set_text(None)
        self.progress_bar.set_visible(True)
        self._stop_pulsing()
        self._pulse_source_id = GLib.timeout_add(150, self._pulse_tick)

    def _update_step(self, text: str):
        """Current step of a multi-step command ("[STEP]"): bar text, pulsing until a real
        percentage is known. Kept so it can prefix the step's "n / total - name" lines
        (see _update_item_progress)."""
        self._step_text = text
        self.progress_bar.set_text(text)
        self.progress_bar.set_fraction(0.0)
        self._stop_pulsing()
        self._pulse_source_id = GLib.timeout_add(150, self._pulse_tick)

    def _update_item_progress(self, current: int, total: int, name: str = ""):
        # "[n/total]" = a new item starts: update the text ("which item out of how many").
        # Its internal progress is not known yet (not every command emits "[PROGRESS] <pct>",
        # see _update_item_percent), so go back to pulsing rather than freezing at 0%:
        # uninstall/pack (no "[PROGRESS]") pulse for each item, while install/install-runner
        # switch to a real fraction at the first "[PROGRESS]" line for THAT item.
        item_text = f"{current} / {total} \u2013 {name}" if name else f"{current} / {total}"
        step_text = getattr(self, "_step_text", "")
        self.progress_bar.set_text(f"{step_text} : {item_text}" if step_text else item_text)
        self.progress_bar.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        self.progress_bar.set_fraction(0.0)
        self._stop_pulsing()
        self._pulse_source_id = GLib.timeout_add(150, self._pulse_tick)

    def _update_item_percent(self, pct: int):
        # "[PROGRESS] <pct>" = REAL progress (0-100) of the CURRENT item being installed
        # (see "pv -n" in zgp-game-installer.sh/zgr-runner-installer.sh). Never touches the
        # "n / total" text (see _update_item_progress); only the bar fill.
        self._stop_pulsing()
        self.progress_bar.set_fraction(max(0.0, min(1.0, pct / 100.0)))

    def _finish_progress(self):
        self._stop_pulsing()
        self.progress_bar.set_visible(False)

    def run_command(self, args: list[str], done_message: str | None = None, refresh: str | None = None,
                    cancellable: bool = False, on_cancelled: Callable[[list[str]], None] | None = None,
                    cancel_toast: str | None = None, cancel_group: bool = True,
                    on_report: Callable[[list[tuple[str, str]], int, str], None] | None = None):
        """"refresh": None (default), "games" or "runners" -- whether this command changes
        the list of installed games or runners, so that all selectors built elsewhere are
        refreshed (see _refresh_game_lists/_refresh_runner_lists) after a successful run.
        Deliberately coarse (no partial refresh): a needless refresh costs only a few instant
        CLI calls like "lpm list"."""
        _CommandRun(self, args, done_message, refresh, cancellable, on_cancelled,
                    cancel_toast, cancel_group, on_report).start()


class _CommandRun:
    """One run of a bin/lpm command from a CommandPage: progress, cancellation, result."""

    def __init__(self, page, args, done_message, refresh, cancellable, on_cancelled,
                 cancel_toast, cancel_group, on_report):
        self.page = page
        self.args = args
        self.done_message = done_message
        self.refresh = refresh
        self.cancellable = cancellable
        self.on_cancelled = on_cancelled
        self.cancel_toast = cancel_toast
        self.cancel_group = cancel_group
        self.on_report = on_report
        self.proc = None
        self.cancelled = False
        self.installed: list[str] = []
        self.report: list[tuple[str, str]] = []
        self.cancel_handler_id = None

    def start(self):
        page = self.page
        page.run_button.set_sensitive(False)
        _run_on_main(page._start_progress)
        _GUI_LOGGER.info("$ bin/lpm " + " ".join(self.args))
        # Cancellation (cancellable=True): SIGTERM goes to the WHOLE process group (see
        # backend.run_lpm, new_session); the lib/ script cleans up the current game itself
        # (lpm_cancel_cleanup in zgp-game-installer.sh) and exits with 130.
        if self.cancellable:
            page.cancel_button.set_sensitive(True)
            page.cancel_button.set_visible(True)
            self.cancel_handler_id = page.cancel_button.connect("clicked", self._request_cancel)
        backend.run_lpm_async(self.args, on_line=self._on_line, on_done=self._on_done,
                              on_proc=self._on_proc, new_session=self.cancellable)

    def _on_proc(self, proc):
        self.proc = proc

    def _request_cancel(self, *_):
        proc = self.proc
        if proc is None or proc.poll() is not None:
            return
        self.cancelled = True
        self.page.cancel_button.set_sensitive(False)
        try:
            if self.cancel_group:
                os.killpg(proc.pid, signal.SIGTERM)
            else:
                # Uninstalls: SIGTERM to the script ONLY (not its children), which finishes
                # the current item then stops, never leaving a half-deleted folder.
                os.kill(proc.pid, signal.SIGTERM)
        except OSError:
            pass

    def _on_line(self, line: str):
        # Called from the background thread (see backend.run_lpm_async): GTK widgets are only
        # touched via _run_on_main; the logger is thread-safe.
        _GUI_LOGGER.info(line)
        stripped = line.strip()
        # "[INSTALLED] <slug>" / "[EXPORTED] <.zgp path>" / "[REMOVED] ...": batch items
        # already done, offered for deletion on cancellation.
        for done_prefix in ("[INSTALLED] ", "[EXPORTED] ", "[REMOVED] "):
            if stripped.startswith(done_prefix):
                self.installed.append(stripped[len(done_prefix):])
                return
        self._on_progress_line(stripped)

    def _on_progress_line(self, stripped: str):
        page = self.page
        step_match = _STEP_LINE_RE.match(stripped)
        if step_match:
            _run_on_main(page._update_step, t("gui.check.step_format", step_match.group(1),
                                              step_match.group(2), step_match.group(3)))
            return
        report_match = _REPORT_LINE_RE.match(stripped)
        if report_match:
            self.report.append((report_match.group(1), report_match.group(2)))
            return
        item_match = _ITEM_LINE_RE.match(stripped)
        if item_match:
            name_match = _ITEM_NAME_RE.search(stripped)
            _run_on_main(page._update_item_progress, int(item_match.group(1)), int(item_match.group(2)),
                         name_match.group(1) if name_match else "")
            return
        percent_match = _PERCENT_LINE_RE.match(stripped)
        if percent_match:
            _run_on_main(page._update_item_percent, int(percent_match.group(1)))

    def _on_done(self, result: backend.CommandResult):
        for err_line in result.stderr.strip().splitlines():
            _GUI_LOGGER.info("! " + err_line)
        _run_on_main(self._finish, result)

    def _refresh_lists(self):
        if self.refresh == "games":
            _refresh_game_lists()
        elif self.refresh == "runners":
            _refresh_runner_lists()

    def _finish(self, result: backend.CommandResult):
        page = self.page
        page.run_button.set_sensitive(True)
        page._finish_progress()
        if self.cancel_handler_id is not None:
            page.cancel_button.disconnect(self.cancel_handler_id)
            page.cancel_button.set_visible(False)
        if self.on_report is not None and self.report and not self.cancelled:
            self.on_report(list(self.report), result.returncode, result.stderr)
        if self.cancelled and result.returncode != 0:
            if self.cancel_toast != "":
                page.toast(self.cancel_toast or t("gui.install.toast_cancelled"))
            self._refresh_lists()
            if self.on_cancelled is not None:
                self.on_cancelled(list(self.installed))
        elif result.returncode == 0:
            page.toast(self.done_message or t("gui.common.done"))
            self._refresh_lists()
            # Reset the selection after a success only: after a failure the user will
            # likely retry with the same selection.
            page.reset_selection()
        else:
            err_lines = [ln.strip() for ln in result.stderr.splitlines() if ln.strip()]
            page.toast_failure(result.returncode, err_lines[-1] if err_lines else "")
