"""Pages: killwine, check, logs, Lutris version."""

import datetime
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gdk, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from guilog import _clear_log_files, _read_log_lines
from util import _escape_markup, _run_on_main


class LutrisVersionPage:
    def __init__(self, owner):
        self.owner = owner
        self.window = owner.window

    def build(self):
        self._add_rows()
        self._wire_load_and_run()
        return self.page

    def _add_rows(self):
        self.page = CommandPage(t("gui.lutris_version.page_title"))
        # Versions actually DETECTED ("lpm lutris-version status"), loaded when the page
        # opens: the choice only offers what is installed.
        self.info_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.page.add_row(self.info_box)
        self.choice_row = Adw.ComboRow(title=t("gui.lutris_version.choice_title"))
        self.page.add_row(self.choice_row)
        self.state = {"values": [], "gen": 0}
        self.labels = {"flatpak": t("lutris_version.label_flatpak"), "native": t("lutris_version.label_native")}

    def _wire_load_and_run(self):
        self.load()
        self.page.reset_selection = self.load

        self.page.run_button.connect("clicked", self.on_run)

    def clear_info(self):
        child = self.info_box.get_first_child()
        while child is not None:
            nxt = child.get_next_sibling()
            self.info_box.remove(child)
            child = nxt

    def add_info(self, title, subtitle=None):
        self.info_box.append(Adw.ActionRow(title=_escape_markup(title), subtitle=_escape_markup(subtitle)))

    def apply_status(self, gen, result):
        if gen != self.state["gen"]:
            return
        self.clear_info()
        detected, saved = [], None
        for line in result.stdout.splitlines():
            if line.startswith("[LUTRIS] "):
                kind, _, rest = line[len("[LUTRIS] "):].partition("|")
                version, _, status = rest.partition("|")
                detected.append((kind, version.strip(), status.strip()))
            elif line.startswith("[LUTRIS-SAVED] "):
                saved = line[len("[LUTRIS-SAVED] "):].strip()
        if result.returncode != 0 or not detected:
            self.add_info(t("lutris_version.none_found"))
            self.choice_row.set_visible(False)
            self.page.run_button.set_sensitive(False)
            return
        for kind, version, status in detected:
            subtitle = version or t("lutris_version.status_unknown")
            if status:
                subtitle += f" ({status})"
            self.add_info(self.labels.get(kind, kind), subtitle)
        if saved:
            self.add_info(t("gui.lutris_version.saved_choice", self.labels.get(saved, saved)))
        # Offered choices: the detected versions (only if at least two) + the reset
        # (only if a choice is saved). The value sent to the command is indexed separately
        # from the displayed label.
        values = [k for k, _, _ in detected] if len(detected) >= 2 else []
        shown = [self.labels.get(k, k) for k in values]
        if saved:
            values.append("reset")
            shown.append(t("gui.lutris_version.choice_reset_display"))
        self.state["values"] = values
        if not values:
            self.add_info(t("gui.lutris_version.only_one", self.labels.get(detected[0][0], detected[0][0])))
            self.choice_row.set_visible(False)
            self.page.run_button.set_sensitive(False)
            return
        self.choice_row.set_model(Gtk.StringList.new(shown))
        self.choice_row.set_selected(0)
        self.choice_row.set_visible(True)
        self.page.run_button.set_sensitive(True)

    def load(self):
        self.state["gen"] += 1
        gen = self.state["gen"]
        self.clear_info()
        self.add_info(t("gui.lutris_version.loading"))
        self.choice_row.set_visible(False)
        self.page.run_button.set_sensitive(False)
        backend.run_lpm_async(
            ["lutris-version", "status"],
            on_done=lambda result: _run_on_main(self.apply_status, gen, result),
        )

    def on_run(self, *_):
        idx = self.choice_row.get_selected()
        if idx == Gtk.INVALID_LIST_POSITION or idx >= len(self.state["values"]):
            return
        self.page.run_command(["lutris-version", self.state["values"][idx]], t("gui.lutris_version.done"))



class LogsPage:
    def __init__(self, owner):
        self.owner = owner
        self.window = owner.window

    def build_page(self):
        self._add_filter_rows()
        self._add_log_view()
        self._add_buttons()
        self._init_state()
        self._wire_filters()
        self._wire_buttons()
        self._wire_reset()
        return self.page

    def _add_filter_rows(self):
        self.page = CommandPage(t("gui.logs.page_title"), t("gui.logs.page_subtitle"))
        self.page.run_button.set_visible(False)

        self.journal_row = Adw.ComboRow(title=t("gui.logs.journal_title"))
        self.journal_row.set_model(Gtk.StringList.new([
            t("gui.logs.journal_both"), t("gui.logs.journal_lpm"), t("gui.logs.journal_gui"),
        ]))
        self.page.add_row(self.journal_row)
        self.period_row = Adw.ComboRow(title=t("gui.logs.period_title"))
        self.period_row.set_model(Gtk.StringList.new([
            t("gui.logs.period_hour"), t("gui.logs.period_day"), t("gui.logs.period_week"), t("gui.logs.period_all"),
        ]))
        self.period_row.set_selected(1)
        self.page.add_row(self.period_row)
        self.search_row = Adw.EntryRow(title=t("gui.logs.search_title"))
        self.page.add_row(self.search_row)

    def _add_log_view(self):
        self.text_view = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                                 wrap_mode=Gtk.WrapMode.WORD_CHAR, top_margin=8, bottom_margin=8,
                                 left_margin=10, right_margin=10)
        scroller = Gtk.ScrolledWindow(min_content_height=320, hexpand=True)
        scroller.set_child(self.text_view)
        frame = Gtk.Frame()
        frame.set_child(scroller)
        self.page.add_row(frame)
        self.count_label = Gtk.Label(xalign=0, margin_top=4, margin_bottom=4)
        self.count_label.add_css_class("dim-label")
        self.page.add_row(self.count_label)

    def _add_buttons(self):
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, halign=Gtk.Align.END)
        self.copy_btn = Gtk.Button(label=t("gui.logs.copy"))
        self.save_btn = Gtk.Button(label=t("gui.logs.save"))
        self.clear_btn = Gtk.Button(label=t("gui.logs.clear"))
        self.clear_btn.add_css_class("destructive-action")
        for b in (self.copy_btn, self.save_btn, self.clear_btn):
            buttons.append(b)
        self.page.add_row(buttons)

    def _init_state(self):
        self.periods = [3600, 86400, 7 * 86400, None]
        self.display_limit = 2000
        self.state = {"gen": 0, "export": "", "lines": 0, "timer": None}

    def _wire_filters(self):
        self.journal_row.connect("notify::selected", self.refresh)
        self.period_row.connect("notify::selected", self.refresh)
        self.search_row.connect("changed", self.refresh_debounced)

    def _wire_buttons(self):
        self.copy_btn.connect("clicked", self.on_copy)
        self.save_btn.connect("clicked", self.on_save)
        self.clear_btn.connect("clicked", self.on_clear)

    def _wire_reset(self):
        self.page.reset_selection = self.reset_fields
        self.refresh()

    def selected(self):
        j = self.journal_row.get_selected()
        kinds = [("lpm", "gui"), ("lpm",), ("gui",)][j if j != Gtk.INVALID_LIST_POSITION else 0]
        p = self.period_row.get_selected()
        seconds = self.periods[p if p != Gtk.INVALID_LIST_POSITION else 1]
        return kinds, seconds, self.search_row.get_text().strip(), p

    def build(self, kinds, seconds, query, period_index):
        """Off the GTK thread: reads the files, returns (displayed text, exported text, line count)."""
        cutoff = None
        if seconds is not None:
            cutoff = datetime.datetime.now().astimezone() - datetime.timedelta(seconds=seconds)
        titles = {"lpm": t("gui.logs.section_lpm"), "gui": t("gui.logs.section_gui")}
        sections, total = [], 0
        for kind in kinds:
            lines = _read_log_lines(kind, cutoff, query)
            total += len(lines)
            sections.append((titles[kind], lines))
        period_label = [t("gui.logs.period_hour"), t("gui.logs.period_day"),
                        t("gui.logs.period_week"), t("gui.logs.period_all")][period_index]
        header = (
            t("gui.logs.export_header", backend.get_lpm_version(),
              datetime.datetime.now().strftime("%Y-%m-%d %H:%M")) + "\n"
            + t("gui.logs.export_filters", period_label, query or t("gui.logs.no_filter")) + "\n"
        )
        export_parts, shown_parts = [header], []
        for title, lines in sections:
            body = "\n".join(lines) if lines else t("gui.logs.empty")
            export_parts.append(f"\n--- {title} ---\n{body}\n")
            shown = lines[-self.display_limit:]
            shown_body = "\n".join(shown) if shown else t("gui.logs.empty")
            if len(shown) < len(lines):
                shown_body = t("gui.logs.truncated", self.display_limit) + "\n" + shown_body
            shown_parts.append(f"--- {title} ---\n{shown_body}\n")
        return "\n".join(shown_parts), "".join(export_parts), total

    def apply(self, gen, result):
        if gen != self.state["gen"]:
            return
        shown, export, total = result
        self.state["export"], self.state["lines"] = export, total
        buf = self.text_view.get_buffer()
        buf.set_text(shown)
        self.count_label.set_label(t("gui.logs.count", total))
        GLib.idle_add(lambda: (self.text_view.scroll_to_iter(buf.get_end_iter(), 0.0, False, 0.0, 0.0), False)[1])

    def refresh(self, *_):
        self.state["gen"] += 1
        gen = self.state["gen"]
        args = self.selected()

        def worker():
            result = self.build(*args)
            _run_on_main(self.apply, gen, result)

        threading.Thread(target=worker, daemon=True).start()

    def refresh_debounced(self, *_):
        # Search: only 250 ms after the last keystroke (not one parse per letter).
        if self.state["timer"] is not None:
            GLib.source_remove(self.state["timer"])
        def fire():
            self.state["timer"] = None
            self.refresh()
            return False
        self.state["timer"] = GLib.timeout_add(250, fire)

    def has_export(self) -> bool:
        if self.state["lines"] == 0:
            self.page.toast(t("gui.logs.nothing_to_export"))
            return False
        return True

    def on_copy(self, *_):
        if not self.has_export():
            return
        Gdk.Display.get_default().get_clipboard().set(self.state["export"])
        self.page.toast(t("gui.logs.copied"))

    def on_save(self, *_):
        if not self.has_export():
            return
        dialog = Gtk.FileDialog(title=t("gui.logs.save_dialog_title"))
        dialog.set_initial_name("lpm-logs-" + datetime.datetime.now().strftime("%Y%m%d-%H%M") + ".txt")

        def done(dlg, res):
            try:
                f = dlg.save_finish(res)
            except GLib.Error:
                return  # cancelled
            path = f.get_path() if f else None
            if not path:
                return
            try:
                with open(path, "w", encoding="utf-8") as out:
                    out.write(self.state["export"])
                self.page.toast(t("gui.logs.saved", path))
            except OSError:
                self.page.toast(t("gui.logs.save_failed"))

        dialog.save(self.window, None, done)

    def on_clear(self, *_):
        kinds, _s, _q, _p = self.selected()

        def do_clear():
            for kind in kinds:
                _clear_log_files(kind)
            self.page.toast(t("gui.logs.cleared"))
            self.refresh()

        self.owner._confirm_destructive(
            t("gui.logs.clear_heading"), t("gui.logs.clear_body"), t("gui.logs.clear_confirm"), do_clear
        )

    # Leaving the page / back to menu: filters reset to defaults (a filter change
    # re-triggers the read by itself), otherwise just re-read.
    def reset_fields(self):
        self.search_row.set_text("")
        self.journal_row.set_selected(0)
        self.period_row.set_selected(1)
        self.refresh()



class SystemPages:
    def page_killwine(self):
        page = CommandPage(t("gui.killwine.page_title"), t("gui.killwine.page_subtitle"))
        warn_row = Adw.ActionRow(title=t("gui.killwine.warn_title"))
        page.add_row(warn_row)

        def on_run(*_):
            def confirmed():
                page.run_command(["killwine", "-y"], t("gui.killwine.done"))

            dialog = Adw.AlertDialog(
                heading=t("gui.killwine.confirm_heading"),
                body=t("gui.killwine.confirm_body"),
            )
            dialog.add_response("cancel", t("gui.killwine.confirm_cancel"))
            dialog.add_response("confirm", t("gui.killwine.confirm_confirm"))
            dialog.set_response_appearance("confirm", Adw.ResponseAppearance.DESTRUCTIVE)

            def on_response(_dlg, response):
                if response == "confirm":
                    confirmed()

            dialog.connect("response", on_response)
            dialog.present(self.window)

        page.run_button.connect("clicked", on_run)
        return page

    def page_check(self):
        page = CommandPage(t("gui.check.page_title"))

        def show_report(entries, returncode, _stderr):
            # Final summary: one line per check (ok, needs attention, error).
            icons = {"ok": "\u2714", "warn": "\u26A0", "error": "\u2716"}
            has_issue = any(kind != "ok" for kind, _ in entries) or returncode != 0

            def entry_text(kind, text):
                # "runner" = runner not found in the repository ("<name>|<games>"): GUI-specific phrasing.
                if kind == "runner":
                    runner_name, _sep, games = text.partition("|")
                    return t("gui.check.report_runner_unresolved", runner_name, games)
                return text

            dialog = Adw.AlertDialog(
                heading=t("gui.check.report_heading_issues" if has_issue else "gui.check.report_heading_ok"),
            )
            label = Gtk.Label(
                label="\n".join(f"{icons['error' if kind == 'runner' else kind]}  {entry_text(kind, text)}"
                                for kind, text in entries),
                xalign=0, wrap=True, selectable=True, margin_top=6, margin_bottom=6,
            )
            scrolled = Gtk.ScrolledWindow(min_content_height=120, max_content_height=320,
                                          propagate_natural_height=True,
                                          hscrollbar_policy=Gtk.PolicyType.NEVER)
            scrolled.set_child(label)
            dialog.set_extra_child(scrolled)
            dialog.add_response("close", t("gui.check.report_close"))
            dialog.set_default_response("close")
            dialog.set_close_response("close")
            dialog.present(self.window)

        def on_run(*_):
            page.run_command(["check", "-y"], t("gui.check.done"), on_report=show_report)

        page.run_button.connect("clicked", on_run)
        return page

    def page_logs(self):
        return LogsPage(self).build_page()

    def page_lutris_version(self):
        return LutrisVersionPage(self).build()
