"""Pages: runner install, download, uninstall and export."""

import os

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

from i18n import t
from commandpage import CommandPage
from refresh import _RUNNER_LIST_WIDGETS
from widgets_rows import add_compression_rows, ask_keep_or_delete, pick_file, sibling_files
from widgets_select import FileMultiSelect, RemoteRunnerMultiSelect, RunnerMultiSelect


class InstallRunnerPage:
    def __init__(self, owner, initial_files):
        self.owner = owner
        self.window = owner.window
        self.initial_files = initial_files

    def build(self):
        self._add_file_selector()
        self._add_options()
        self._wire_reset_and_run()
        return self.page

    def _add_file_selector(self):
        self.page = CommandPage(t("gui.install_runner.page_title"), t("gui.install_runner.page_subtitle"))

        self.file_selector = FileMultiSelect(t("gui.install_runner.file_selector_title"))

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER,
                                 tooltip_text=t("gui.install_runner.choose_tooltip"))
        choose_btn.connect("clicked", lambda *_: self.choose())
        self.file_selector.add_suffix(choose_btn)
        self.page.add_row(self.file_selector)
        if self.initial_files:
            self._scan_and_set(list(self.initial_files))
        else:
            self.file_selector.set_paths([])

    def _add_options(self):
        self.ignore_hash_row = Adw.SwitchRow(title=t("gui.common.ignore_hash_title"))
        self.page.add_row(self.ignore_hash_row)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    def _scan_and_set(self, chosen_paths: list[str]):
        # Same principle as page_install() for .zgp: the other .zgr files in the same
        # folder are listed too, so they can be added at once with "check all".
        all_in_dir = sibling_files(chosen_paths, ".zgr")
        self.file_selector.set_paths(all_in_dir, checked_paths=chosen_paths)

    def choose(self):
        def got(paths):
            if paths:
                self._scan_and_set(paths)

        pick_file(self.window, t("gui.install_runner.choose_dialog_title"), got, [(".zgr", ["*.zgr"])], multiple=True)

    # The hash switch is reset too, see CommandPage.reset_selection. (Downloading from
    # the repository has its own page: page_download_runner.)
    def reset_fields(self):
        self.file_selector.set_paths([])
        self.ignore_hash_row.set_active(False)

    def on_run(self, *_):
        targets = self.file_selector.selected_paths()
        if not targets:
            self.page.toast(t("gui.install_runner.toast_need_target"))
            return
        args = ["install-runner", "-y"]
        if self.ignore_hash_row.get_active():
            args.append("--ignore-hash")
        args.extend(targets)
        self.page.run_command(args, t("gui.install_runner.done"), refresh="runners",
                         cancellable=True, cancel_toast=t("gui.install_runner.toast_cancelled"),
                         on_cancelled=self.owner._runner_install_cancel_handler(self.page))



class RunnerPages:
    # --- Runners ---
    def page_install_runner(self, initial_files: list[str] | None = None):
        return InstallRunnerPage(self, initial_files).build()

    def _runner_install_cancel_handler(self, page):
        """on_cancelled for runner download/install: the current runner is cleaned up by the
        script; if runners from this batch are already finished, offer to delete them too
        (ONLY those). Default: keep them."""
        def on_cancelled(installed):
            if not installed:
                return
            ask_keep_or_delete(
                self.window,
                t("gui.install_runner.cancel_dialog_heading"),
                t("gui.install_runner.cancel_dialog_body", len(installed),
                  "\n".join(f"\u2022 {n}" for n in installed)),
                lambda: page.run_command(
                    ["uninstall-runner", "-y", *installed], t("gui.install_runner.toast_cancel_deleted"),
                    refresh="runners"),
            )
        return on_cancelled

    def _export_cancel_handler(self, page):
        """on_cancelled for exports (.zgp / .zgr): the current archive is deleted by the
        script; archives already finished in the batch are offered for deletion (with their
        hash files). Default: keep them."""
        def delete_exported(paths):
            for path in paths:
                if not path.endswith((".zgp", ".zgr")):
                    continue
                sidecar = os.path.join(os.path.dirname(path), "hash", os.path.basename(path) + ".sha256")
                for target in (path, sidecar):
                    try:
                        os.remove(target)
                    except OSError:
                        pass
            page.toast(t("gui.pack.toast_cancel_deleted"))

        def on_cancelled(exported_paths):
            if not exported_paths:
                return
            ask_keep_or_delete(
                self.window,
                t("gui.pack.cancel_dialog_heading"),
                t("gui.pack.cancel_dialog_body", len(exported_paths),
                  "\n".join(f"\u2022 {os.path.basename(p)}" for p in exported_paths)),
                lambda: delete_exported(exported_paths),
            )
        return on_cancelled

    def page_download_runner(self):
        page = CommandPage(t("gui.download_runner.page_title"), t("gui.download_runner.page_subtitle"))
        selector = RemoteRunnerMultiSelect()
        page.add_row(selector)
        # No "ignore hash" switch here: a downloaded runner is ALWAYS verified against the
        # SHA-256 digest provided by GitHub (see zgr-runner-installer.sh) and nothing can
        # disable it; the switch would only apply to local .zgr files.
        # After a successful install (refresh="runners") or a return to the menu, the list is
        # reloaded: just-installed runners are greyed out as "already installed".
        _RUNNER_LIST_WIDGETS.append(selector)
        page.reset_selection = selector.refresh

        def on_run(*_):
            selected = selector.selected_names()
            if not selected:
                page.toast(t("gui.download_runner.toast_choose"))
                return
            page.run_command(
                ["install-runner", "-y", *selected], t("gui.download_runner.done"), refresh="runners",
                cancellable=True, cancel_toast=t("gui.install_runner.toast_cancelled"),
                on_cancelled=self._runner_install_cancel_handler(page),
            )

        page.run_button.connect("clicked", on_run)
        return page

    def page_uninstall_runner(self):
        page = CommandPage(t("gui.uninstall_runner.page_title"))
        selector = RunnerMultiSelect()
        page.add_row(selector)
        # Back to menu / successful command: reload the list and uncheck everything (see
        # CommandPage.reset_selection).
        page.reset_selection = selector.refresh

        def on_run(*_):
            selected = selector.selected_names()
            if not selected:
                page.toast(t("gui.uninstall_runner.toast_choose_runner"))
                return
            self._confirm_destructive(
                t("gui.uninstall_runner.confirm_heading", len(selected)),
                t("gui.uninstall_runner.confirm_body"),
                t("gui.uninstall_runner.confirm_button"),
                lambda: page.run_command(
                    ["uninstall-runner", "-y", *selected], t("gui.uninstall_runner.done"), refresh="runners",
                    cancellable=True, cancel_group=False, cancel_toast="",
                    on_cancelled=lambda removed: page.toast(t("gui.uninstall_runner.toast_cancelled", len(removed))),
                ),
            )

        page.run_button.connect("clicked", on_run)
        return page

    def page_pack_runner(self):
        page = CommandPage(t("gui.pack_runner.page_title"))
        selector = RunnerMultiSelect()
        page.add_row(selector)

        level_row, hash_row = add_compression_rows(page)

        # Back to menu / successful command: list reloaded, level and switch reset.
        def reset_fields():
            selector.refresh()
            level_row.set_value(3)
            hash_row.set_active(False)

        page.reset_selection = reset_fields

        def on_run(*_):
            selected = selector.selected_names()
            if not selected:
                page.toast(t("gui.pack.toast_choose_item"))
                return
            args = ["pack-runner", f"-{int(level_row.get_value())}"]
            if hash_row.get_active():
                args.append("--hash")
            args.extend(selected)
            page.run_command(args, t("gui.pack.done"), cancellable=True,
                             cancel_toast=t("gui.pack.toast_cancelled"),
                             on_cancelled=self._export_cancel_handler(page))

        page.run_button.connect("clicked", on_run)
        return page
