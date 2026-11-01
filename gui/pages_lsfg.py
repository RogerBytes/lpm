"""Page 'Frame generation' (lsfg-vk): reference DLL, Vulkan layer notice and per-game switch."""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from util import _run_on_main, json_result
from widgets_rows import pick_file
from widgets_select import GameMultiSelect


class LsfgPage:
    """Frame generation (lsfg-vk). An extra row above the game selector shows the
    lsfg-vk.dll reference DLL already configured (or lets the user pick it if not yet):
    "lpm lsfg ... on" needed it via a terminal prompt ("read -p", see zgl-lsfg-manager.sh)
    that can neither display nor receive anything from the GUI (no TTY) and failed
    silently (zgl-lsfg-dll.sh, a dedicated CLI command, replaces that prompt for this
    case).

    "vk_notice_row", at the very top, is separate from the DLL choice (text too long and
    always shown otherwise): it shows NOTHING when lsfg-vk (the Vulkan layer itself, not
    the reference DLL below) is already installed, and only a short warning otherwise --
    never both at once. Relies on "lpm lsfg status" (see zgl-lsfg-manager.sh,
    non-interactive query, never the interactive install flow reserved for
    "lpm lsfg <slug> on").

    "vk_install_btn", suffix of "vk_notice_row", offers here the installation already
    available via "System > Check dependencies", without duplicating that logic (all
    detection/installation stays in zgu-lsfg-utils.sh, queried via the non-interactive
    commands "lsfg install-info"/"lsfg install-flatpak", see zgl-lsfg-manager.sh)."""

    def __init__(self, window):
        self.window = window

    def build(self):
        self._add_vk_notice_row()
        self._add_dll_row()
        self._add_game_rows()
        self._wire_reset_and_run()
        return self.page

    def _add_vk_notice_row(self):
        self.page = CommandPage(t("gui.lsfg.page_title"), t("gui.lsfg.page_subtitle"))

        self.vk_notice_row = Adw.ActionRow(title=t("gui.lsfg.vk_required_notice"), visible=False)
        vk_install_btn = Gtk.Button(label=t("gui.lsfg.install_button"), valign=Gtk.Align.CENTER)
        self.vk_notice_row.add_suffix(vk_install_btn)
        self.page.add_row(self.vk_notice_row)

        vk_install_btn.connect("clicked", self.on_install_clicked)

    def _add_dll_row(self):
        self.dll_row = Adw.ActionRow(title=t("gui.lsfg.dll_title"))
        dll_browse_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER,
                                     tooltip_text=t("gui.lsfg.dll_browse_tooltip"))
        self.dll_row.add_suffix(dll_browse_btn)
        self.page.add_row(self.dll_row)

        # Tracks the current DLL path -- "Run" must NEVER be able to enable ("on" action) if
        # no reference DLL is configured, see on_run below. Otherwise "lpm lsfg ... on" hits
        # its own interactive prompt ("read -p" in zgp_lsfg_ensure_dll, see
        # zgl-lsfg-manager.sh), which fails silently from the GUI (no TTY). Not needed for
        # "off", which never touches the DLL.
        self.lsfg_dll_state = {"path": ""}

        dll_browse_btn.connect("clicked", lambda *_: self.browse_dll())

    def _add_game_rows(self):
        self.selector = GameMultiSelect()
        self.page.add_row(self.selector)
        self.state_row = Adw.ComboRow(title=t("gui.toggle_feature.action_title"))
        self.state_row.set_model(Gtk.StringList.new([
            t("gui.toggle_feature.action_enable"), t("gui.toggle_feature.action_disable"),
        ]))
        self.page.add_row(self.state_row)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields
        self.refresh_dll_row()
        self.refresh_vk_notice_row()

        self.page.run_button.connect("clicked", self.on_run)

    def refresh_vk_notice_row(self):
        def on_done(result: backend.CommandResult):
            data = json_result(result)
            installed = bool(data.get("installed"))

            def apply():
                self.vk_notice_row.set_visible(not installed)

            _run_on_main(apply)

        backend.run_lpm_async(["lsfg", "status"], on_done=on_done)

    # Optional "Install lsfg-vk" button, suffix of "vk_notice_row": visible only when
    # lsfg-vk is not installed (it disappears with its row, no separate "set_visible"
    # needed). On click, first queries "lpm lsfg install-info" (see zgl-lsfg-manager.sh) to
    # know whether Lutris runs as a Flatpak, WITHOUT installing anything before explicit
    # confirmation: Flatpak shows a confirmation window then really installs via "lsfg
    # install-flatpak" (reuses zgu_lsfg_install_flatpak_do on the bash side, no copy of
    # that logic); native shows the same link as "System > Check dependencies"
    # (zgu_lsfg_native_link_info), since no automatic install is possible then.
    def on_install_clicked(self, *_):
        backend.run_lpm_async(["lsfg", "install-info"], on_done=self._on_install_info)

    def _on_install_info(self, result: backend.CommandResult):
        data = json_result(result)
        if not data:
            _run_on_main(lambda: self.page.toast(t("gui.lsfg.install_info_failed")))
            return
        _run_on_main(self._show_install_dialog, data)

    def _show_install_dialog(self, data):
        if data.get("flatpak"):
            self._confirm_flatpak_install(str(data.get("runtime_version") or ""))
        else:
            self._show_native_install_link(str(data.get("link") or ""), str(data.get("link_label") or ""))

    def _confirm_flatpak_install(self, runtime_version):
        if not runtime_version:
            self.page.toast(t("gui.lsfg.install_runtime_unknown"))
            return
        dialog = Adw.AlertDialog(
            heading=t("gui.lsfg.install_flatpak_heading"),
            body=t("gui.lsfg.install_flatpak_body", runtime_version),
        )
        dialog.add_response("cancel", t("gui.lsfg.install_flatpak_cancel"))
        dialog.add_response("confirm", t("gui.lsfg.install_flatpak_confirm"))
        dialog.set_response_appearance("confirm", Adw.ResponseAppearance.SUGGESTED)

        def on_response(_dlg, response):
            if response == "confirm":
                self._install_flatpak_layer(runtime_version)

        dialog.connect("response", on_response)
        dialog.present(self.window)

    def _install_flatpak_layer(self, runtime_version):
        def on_install_done(install_result: backend.CommandResult):
            install_data = json_result(install_result)

            def apply_install():
                if install_data.get("ok"):
                    self.page.toast(t("gui.lsfg.install_success"))
                    self.refresh_vk_notice_row()
                else:
                    self.page.toast(t("gui.lsfg.install_failed"))

            _run_on_main(apply_install)

        backend.run_lpm_async(["lsfg", "install-flatpak", runtime_version], on_done=on_install_done)

    def _show_native_install_link(self, link, link_label):
        dialog = Adw.AlertDialog(
            heading=t("gui.lsfg.install_native_heading"),
            body=t("gui.lsfg.install_native_body"),
        )
        if link:
            link_btn = Gtk.LinkButton(uri=link, label=link_label or link,
                                       valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
            dialog.set_extra_child(link_btn)
        dialog.add_response("close", t("gui.lsfg.install_native_close"))
        dialog.present(self.window)

    def refresh_dll_row(self):
        def on_done(result: backend.CommandResult):
            data = json_result(result)
            path = str(data.get("path") or "")

            def apply():
                self.lsfg_dll_state["path"] = path
                self.dll_row.set_subtitle(path or t("gui.lsfg.dll_not_configured"))

            _run_on_main(apply)

        backend.run_lpm_async(["lsfg-dll", "get"], on_done=on_done)

    def browse_dll(self):
        def got(paths):
            if not paths:
                return

            def on_done(result: backend.CommandResult):
                def apply():
                    if result.returncode == 0:
                        self.refresh_dll_row()
                    else:
                        self.page.toast(t("gui.lsfg.dll_set_failed"))

                _run_on_main(apply)

            backend.run_lpm_async(["lsfg-dll", "set", paths[0]], on_done=on_done)

        pick_file(self.window, t("gui.lsfg.dll_dialog_title"), got,
                  filters=[(t("gui.lsfg.dll_filter_label"), ["*.dll", "*.DLL"])])

    # The enable/disable choice is reset too, see CommandPage.reset_selection. The DLL
    # row and the lsfg-vk warning are also refreshed (e.g. modified by hand in the
    # meantime, or lsfg-vk installed since the page opened).
    def reset_fields(self):
        self.selector.refresh()
        self.state_row.set_selected(0)
        self.refresh_dll_row()
        self.refresh_vk_notice_row()

    def on_run(self, *_):
        slugs = self.selector.selected_slugs()
        if not slugs:
            self.page.toast(t("gui.common.choose_one_game"))
            return
        action = "on" if self.state_row.get_selected() in (0, Gtk.INVALID_LIST_POSITION) else "off"
        if action == "on" and not self.lsfg_dll_state["path"]:
            self.page.toast(t("gui.lsfg.toast_dll_required"))
            return
        self.page.run_command(["lsfg", *slugs, action], t("gui.common.done"))
