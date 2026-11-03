"""Generic command page: form, launching bin/lpm, reading the line protocol."""

import os
import re
import signal
from typing import Callable

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
import operations
from i18n import t
from guilog import _GUI_LOGGER
from progresswindow import ProgressWindow
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

        self._build_action_group()

    def _build_action_group(self):
        self.run_button = Gtk.Button(label=t("gui.common.run"))
        self.run_button.add_css_class("suggested-action")
        self.run_button.add_css_class("pill")
        self.run_button.set_halign(Gtk.Align.END)
        self.run_button.set_margin_top(6)
        self.run_button.set_margin_end(6)
        self.run_button.set_margin_bottom(6)
        action_row_box = Gtk.Box(halign=Gtk.Align.END, spacing=6)
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

    def run_command(self, args: list[str], done_message: str | None = None, refresh: str | None = None,
                    cancellable: bool = False, on_cancelled: Callable[[list[str]], None] | None = None,
                    cancel_toast: str | None = None, cancel_group: bool = True, undoable: bool = False,
                    on_report: Callable[[list[tuple[str, str]], int, str], None] | None = None):
        """"refresh": None (default), "games" or "runners" -- whether this command changes
        the list of installed games or runners, so that all selectors built elsewhere are
        refreshed (see _refresh_game_lists/_refresh_runner_lists) after a successful run.
        Deliberately coarse (no partial refresh): a needless refresh costs only a few instant
        CLI calls like "lpm list"."""
        _CommandRun(self, args, done_message, refresh, cancellable, on_cancelled,
                    cancel_toast, cancel_group, on_report, undoable).start()


class _CommandRun:
    """One run of a bin/lpm command from a CommandPage. Its progress, cancel button and error
    live in an independent ProgressWindow, so the run goes on even if the main window is closed
    (the page is then no longer in a window: nothing of it is touched, see _page_alive)."""

    def __init__(self, page, args, done_message, refresh, cancellable, on_cancelled,
                 cancel_toast, cancel_group, on_report, undoable=False):
        self.page = page
        self.args = args
        self.done_message = done_message
        self.refresh = refresh
        self.cancellable = cancellable
        self.on_cancelled = on_cancelled
        self.cancel_toast = cancel_toast
        self.cancel_group = cancel_group
        self.on_report = on_report
        # undoable: what is already finished can be undone (installed games, exported archives)
        # -> the progress window asks "stop here" or "undo all" when something is finished.
        self.undoable = undoable
        self.cancel_choice: str | None = None  # "stop" or "undo" (None: no choice was asked)
        self.proc = None
        self.cancelled = False
        self.installed: list[str] = []
        self.report: list[tuple[str, str]] = []
        self.progress_window: ProgressWindow | None = None

    def start(self):
        page = self.page
        if operations.is_busy():
            page.toast(t("gui.op.already_running"))
            return
        operations.begin(self)
        page.run_button.set_sensitive(False)
        self.progress_window = ProgressWindow(page.page.get_title() or "lpm", self.cancellable, self._request_cancel,
                                              self._has_finished_items if self.undoable else None,
                                              parent=page.get_root())
        self.progress_window.start()
        self.progress_window.present()
        _GUI_LOGGER.info("$ bin/lpm " + " ".join(self.args))
        # Cancellation (cancellable=True): SIGTERM goes to the WHOLE process group (see
        # backend.run_lpm, new_session); the lib/ script cleans up the current game itself
        # (lpm_cancel_cleanup in zgp-game-installer.sh) and exits with 130.
        backend.run_lpm_async(self.args, on_line=self._on_line, on_done=self._on_done,
                              on_proc=self._on_proc, new_session=self.cancellable)

    def _on_proc(self, proc):
        self.proc = proc

    def _has_finished_items(self) -> bool:
        return bool(self.installed)

    def _request_cancel(self, choice: str | None = None):
        self.cancel_choice = choice
        proc = self.proc
        if proc is None or proc.poll() is not None:
            return
        self.cancelled = True
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
        window = self.progress_window
        step_match = _STEP_LINE_RE.match(stripped)
        if step_match:
            _run_on_main(window.set_step, t("gui.check.step_format", step_match.group(1),
                                            step_match.group(2), step_match.group(3)))
            return
        report_match = _REPORT_LINE_RE.match(stripped)
        if report_match:
            self.report.append((report_match.group(1), report_match.group(2)))
            return
        item_match = _ITEM_LINE_RE.match(stripped)
        if item_match:
            name_match = _ITEM_NAME_RE.search(stripped)
            _run_on_main(window.set_item, int(item_match.group(1)), int(item_match.group(2)),
                         name_match.group(1) if name_match else "")
            return
        percent_match = _PERCENT_LINE_RE.match(stripped)
        if percent_match:
            _run_on_main(window.set_percent, int(percent_match.group(1)))

    def _on_done(self, result: backend.CommandResult):
        for err_line in result.stderr.strip().splitlines():
            _GUI_LOGGER.info("! " + err_line)
        _run_on_main(self._finish, result)

    def _page_alive(self) -> bool:
        """False once the main window that held the page was closed."""
        return self.page.get_root() is not None

    def _refresh_lists(self):
        if not self._page_alive():
            return
        if self.refresh == "games":
            _refresh_game_lists()
        elif self.refresh == "runners":
            _refresh_runner_lists()

    def _notify_end(self, body: str):
        """Desktop notification for the end of ANY operation, except where the command's own
        script already sends one (see operations.COMMANDS_THAT_NOTIFY)."""
        if self.args and self.args[0] in operations.COMMANDS_THAT_NOTIFY:
            return
        operations.notify("lpm", body)

    def _finish(self, result: backend.CommandResult):
        page = self.page
        operations.end(self)
        alive = self._page_alive()
        if alive:
            page.run_button.set_sensitive(True)
        reported = False
        if self.on_report is not None and self.report and not self.cancelled and alive:
            self.on_report(list(self.report), result.returncode, result.stderr)
            reported = True
        if self.cancelled and result.returncode != 0:
            self.progress_window.finish()
            self._notify_end(self.cancel_toast or t("gui.install.toast_cancelled"))
            if alive and self.cancel_toast != "":
                page.toast(self.cancel_toast or t("gui.install.toast_cancelled"))
            self._refresh_lists()
            if self.on_cancelled is not None and (alive or self.cancel_choice):
                # The window's choice (stop / undo) answers the keep-or-delete question.
                operations.cancel_choice[0] = self.cancel_choice
                try:
                    self.on_cancelled(list(self.installed))
                finally:
                    operations.cancel_choice[0] = None
        elif result.returncode == 0:
            self.progress_window.finish()
            self._notify_end(self.done_message or t("gui.common.done"))
            if alive:
                page.toast(self.done_message or t("gui.common.done"))
                self._refresh_lists()
                # Reset the selection after a success only: after a failure the user will
                # likely retry with the same selection.
                page.reset_selection()
        elif reported:
            # The report dialog already tells what is wrong (lpm check).
            self.progress_window.finish()
        else:
            self.progress_window.show_error(t("gui.op.error_heading"),
                                   result.stderr.strip() or t("gui.common.command_failed", result.returncode))
