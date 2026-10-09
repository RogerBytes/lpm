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
        page = CommandPage(t("gui.logs.page_title"), t("gui.logs.page_subtitle"))
        page.run_button.set_visible(False)

        journal_row = Adw.ComboRow(title=t("gui.logs.journal_title"))
        journal_row.set_model(Gtk.StringList.new([
            t("gui.logs.journal_both"), t("gui.logs.journal_lpm"), t("gui.logs.journal_gui"),
        ]))
        page.add_row(journal_row)
        period_row = Adw.ComboRow(title=t("gui.logs.period_title"))
        period_row.set_model(Gtk.StringList.new([
            t("gui.logs.period_hour"), t("gui.logs.period_day"), t("gui.logs.period_week"), t("gui.logs.period_all"),
        ]))
        period_row.set_selected(1)
        page.add_row(period_row)
        search_row = Adw.EntryRow(title=t("gui.logs.search_title"))
        page.add_row(search_row)

        text_view = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                                 wrap_mode=Gtk.WrapMode.WORD_CHAR, top_margin=8, bottom_margin=8,
                                 left_margin=10, right_margin=10)
        scroller = Gtk.ScrolledWindow(min_content_height=320, hexpand=True)
        scroller.set_child(text_view)
        frame = Gtk.Frame()
        frame.set_child(scroller)
        page.add_row(frame)
        count_label = Gtk.Label(xalign=0, margin_top=4, margin_bottom=4)
        count_label.add_css_class("dim-label")
        page.add_row(count_label)

        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, halign=Gtk.Align.END)
        copy_btn = Gtk.Button(label=t("gui.logs.copy"))
        save_btn = Gtk.Button(label=t("gui.logs.save"))
        clear_btn = Gtk.Button(label=t("gui.logs.clear"))
        clear_btn.add_css_class("destructive-action")
        for b in (copy_btn, save_btn, clear_btn):
            buttons.append(b)
        page.add_row(buttons)

        periods = [3600, 86400, 7 * 86400, None]
        display_limit = 2000
        state = {"gen": 0, "export": "", "lines": 0, "timer": None}

        def selected():
            j = journal_row.get_selected()
            kinds = [("lpm", "gui"), ("lpm",), ("gui",)][j if j != Gtk.INVALID_LIST_POSITION else 0]
            p = period_row.get_selected()
            seconds = periods[p if p != Gtk.INVALID_LIST_POSITION else 1]
            return kinds, seconds, search_row.get_text().strip(), p

        def build(kinds, seconds, query, period_index):
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
                shown = lines[-display_limit:]
                shown_body = "\n".join(shown) if shown else t("gui.logs.empty")
                if len(shown) < len(lines):
                    shown_body = t("gui.logs.truncated", display_limit) + "\n" + shown_body
                shown_parts.append(f"--- {title} ---\n{shown_body}\n")
            return "\n".join(shown_parts), "".join(export_parts), total

        def apply(gen, result):
            if gen != state["gen"]:
                return
            shown, export, total = result
            state["export"], state["lines"] = export, total
            buf = text_view.get_buffer()
            buf.set_text(shown)
            count_label.set_label(t("gui.logs.count", total))
            GLib.idle_add(lambda: (text_view.scroll_to_iter(buf.get_end_iter(), 0.0, False, 0.0, 0.0), False)[1])

        def refresh(*_):
            state["gen"] += 1
            gen = state["gen"]
            args = selected()

            def worker():
                result = build(*args)
                _run_on_main(apply, gen, result)

            threading.Thread(target=worker, daemon=True).start()

        def refresh_debounced(*_):
            # Search: only 250 ms after the last keystroke (not one parse per letter).
            if state["timer"] is not None:
                GLib.source_remove(state["timer"])
            def fire():
                state["timer"] = None
                refresh()
                return False
            state["timer"] = GLib.timeout_add(250, fire)

        journal_row.connect("notify::selected", refresh)
        period_row.connect("notify::selected", refresh)
        search_row.connect("changed", refresh_debounced)

        def has_export() -> bool:
            if state["lines"] == 0:
                page.toast(t("gui.logs.nothing_to_export"))
                return False
            return True

        def on_copy(*_):
            if not has_export():
                return
            Gdk.Display.get_default().get_clipboard().set(state["export"])
            page.toast(t("gui.logs.copied"))

        def on_save(*_):
            if not has_export():
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
                        out.write(state["export"])
                    page.toast(t("gui.logs.saved", path))
                except OSError:
                    page.toast(t("gui.logs.save_failed"))

            dialog.save(self.window, None, done)

        def on_clear(*_):
            kinds, _s, _q, _p = selected()

            def do_clear():
                for kind in kinds:
                    _clear_log_files(kind)
                page.toast(t("gui.logs.cleared"))
                refresh()

            self._confirm_destructive(
                t("gui.logs.clear_heading"), t("gui.logs.clear_body"), t("gui.logs.clear_confirm"), do_clear
            )

        copy_btn.connect("clicked", on_copy)
        save_btn.connect("clicked", on_save)
        clear_btn.connect("clicked", on_clear)

        # Leaving the page / back to menu: filters reset to defaults (a filter change
        # re-triggers the read by itself), otherwise just re-read.
        def reset_fields():
            search_row.set_text("")
            journal_row.set_selected(0)
            period_row.set_selected(1)
            refresh()

        page.reset_selection = reset_fields
        refresh()
        return page

    def page_lutris_version(self):
        page = CommandPage(t("gui.lutris_version.page_title"))
        # Versions actually DETECTED ("lpm lutris-version status"), loaded when the page
        # opens: the choice only offers what is installed.
        info_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        page.add_row(info_box)
        choice_row = Adw.ComboRow(title=t("gui.lutris_version.choice_title"))
        page.add_row(choice_row)
        state = {"values": [], "gen": 0}
        labels = {"flatpak": t("lutris_version.label_flatpak"), "native": t("lutris_version.label_native")}

        def clear_info():
            child = info_box.get_first_child()
            while child is not None:
                nxt = child.get_next_sibling()
                info_box.remove(child)
                child = nxt

        def add_info(title, subtitle=None):
            info_box.append(Adw.ActionRow(title=_escape_markup(title), subtitle=_escape_markup(subtitle)))

        def apply_status(gen, result):
            if gen != state["gen"]:
                return
            clear_info()
            detected, saved = [], None
            for line in result.stdout.splitlines():
                if line.startswith("[LUTRIS] "):
                    kind, _, rest = line[len("[LUTRIS] "):].partition("|")
                    version, _, status = rest.partition("|")
                    detected.append((kind, version.strip(), status.strip()))
                elif line.startswith("[LUTRIS-SAVED] "):
                    saved = line[len("[LUTRIS-SAVED] "):].strip()
            if result.returncode != 0 or not detected:
                add_info(t("lutris_version.none_found"))
                choice_row.set_visible(False)
                page.run_button.set_sensitive(False)
                return
            for kind, version, status in detected:
                subtitle = version or t("lutris_version.status_unknown")
                if status:
                    subtitle += f" ({status})"
                add_info(labels.get(kind, kind), subtitle)
            if saved:
                add_info(t("gui.lutris_version.saved_choice", labels.get(saved, saved)))
            # Offered choices: the detected versions (only if at least two) + the reset
            # (only if a choice is saved). The value sent to the command is indexed separately
            # from the displayed label.
            values = [k for k, _, _ in detected] if len(detected) >= 2 else []
            shown = [labels.get(k, k) for k in values]
            if saved:
                values.append("reset")
                shown.append(t("gui.lutris_version.choice_reset_display"))
            state["values"] = values
            if not values:
                add_info(t("gui.lutris_version.only_one", labels.get(detected[0][0], detected[0][0])))
                choice_row.set_visible(False)
                page.run_button.set_sensitive(False)
                return
            choice_row.set_model(Gtk.StringList.new(shown))
            choice_row.set_selected(0)
            choice_row.set_visible(True)
            page.run_button.set_sensitive(True)

        def load():
            state["gen"] += 1
            gen = state["gen"]
            clear_info()
            add_info(t("gui.lutris_version.loading"))
            choice_row.set_visible(False)
            page.run_button.set_sensitive(False)
            backend.run_lpm_async(
                ["lutris-version", "status"],
                on_done=lambda result: _run_on_main(apply_status, gen, result),
            )

        load()
        page.reset_selection = load

        def on_run(*_):
            idx = choice_row.get_selected()
            if idx == Gtk.INVALID_LIST_POSITION or idx >= len(state["values"]):
                return
            page.run_command(["lutris-version", state["values"][idx]], t("gui.lutris_version.done"))

        page.run_button.connect("clicked", on_run)
        return page
