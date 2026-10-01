#!/usr/bin/env python3
"""
--- Interface graphique GTK4/Libadwaita pour lpm -- remplace entièrement Zenity ---

Architecture (voir discussion de conception) :
  1. Cette interface n'implémente AUCUNE logique métier elle-même : chaque écran se
     contente de rassembler les choix de l'utilisateur via des widgets GTK4 natifs, puis
     appelle "bin/lpm <commande> <args CLI>" en arrière-plan -- exactement les mêmes
     scripts de lib/ que ceux utilisés depuis un terminal, en mode CLI pur (jamais
     Zenity, voir le refactor CLI qui a précédé ce fichier).
  2. Le thème du bureau (clair/sombre, couleur d'accent) est suivi nativement par
     Libadwaita >= 1.4 lui-même (AdwStyleManager, lit org.gnome.desktop.interface) --
     aucun code à nous ici. Un pont CSS maison (theme_bridge.py) avait été tenté pour
     calquer aussi les couleurs exactes d'un thème GTK3 tiers (Mint-Y...), mais ça
     nécessite des propriétés CSS personnalisées (--window-bg-color, etc.) que le moteur
     CSS de GTK ne reconnaît que depuis la version 4.16 -- en-dessous (toute la plage
     4.10-4.15 visée par ce projet), ça ne fait qu'émettre des avertissements sans aucun
     effet. Retiré : testé en désactivant l'appel, le thème (changé en direct) continue
     de suivre exactement pareil -- confirme que c'était bien Libadwaita natif qui
     faisait déjà tout le travail.
  3. Toute commande est lancée dans un thread séparé (gui.backend.run_lpm_async) : le
     thread principal GTK ne doit jamais être bloqué en attendant qu'un script finisse.

Pré-requis système (à vérifier avant de lancer ce fichier) : Python 3.11+, PyGObject,
GTK4 >= 4.10 (pour Gtk.FileDialog), Libadwaita >= 1.4 (pour Adw.EntryRow/SwitchRow/
NavigationSplitView). Sur une distribution dont les dépôts sont plus anciens (ex: Mint 21,
basé sur Ubuntu 22.04), ces versions peuvent nécessiter un dépôt plus récent ou un flatpak
runtime -- à vérifier sur la machine cible avant le premier lancement.
"""

import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backend  # noqa: E402


APP_ID = "com.rogerbytes.lpm.gui"


def _run_on_main(fn, *args):
    GLib.idle_add(lambda: (fn(*args), False)[1])


# ---------------------------------------------------------------------------------------
# --- Petit widget réutilisable : zone de journal (sortie live d'une commande) ---
class LogView(Gtk.ScrolledWindow):
    def __init__(self):
        super().__init__()
        self.set_vexpand(True)
        self.set_min_content_height(140)
        self.textview = Gtk.TextView()
        self.textview.set_editable(False)
        self.textview.set_monospace(True)
        self.textview.set_cursor_visible(False)
        self.textview.set_top_margin(6)
        # "set_margin_start", pas "set_start_margin" -- TextView n'a que des marges
        # internes top/bottom/left/right (set_top_margin et consorts, utilisées ci-dessus
        # pour l'espacement du texte dans le buffer) ; pour un retrait du widget lui-même
        # côté "début" (logique, compatible RTL), c'est la méthode générique de Gtk.Widget.
        self.textview.set_margin_start(8)
        self.buffer = self.textview.get_buffer()
        self.set_child(self.textview)

    def clear(self):
        self.buffer.set_text("")

    def append_line(self, line: str):
        end = self.buffer.get_end_iter()
        self.buffer.insert(end, line + "\n")
        end = self.buffer.get_end_iter()
        self.textview.scroll_to_iter(end, 0.0, False, 0.0, 0.0)


# ---------------------------------------------------------------------------------------
# --- Page de commande générique : un formulaire (haut) + un journal (bas) ---
class CommandPage(Gtk.Box):
    def __init__(self, title: str, subtitle: str = ""):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.toast_overlay = Adw.ToastOverlay()
        self.append(self.toast_overlay)

        paned = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
        paned.set_vexpand(True)
        self.toast_overlay.set_child(paned)

        top_scroller = Gtk.ScrolledWindow()
        top_scroller.set_vexpand(True)
        self.page = Adw.PreferencesPage()
        self.page.set_title(title)
        top_scroller.set_child(self.page)
        paned.set_start_child(top_scroller)
        paned.set_resize_start_child(True)

        self.group = Adw.PreferencesGroup(title=subtitle or None)
        self.page.add(self.group)

        self.log = LogView()
        paned.set_end_child(self.log)
        paned.set_resize_end_child(False)
        paned.set_position(420)

        self.run_button = Gtk.Button(label="Exécuter")
        self.run_button.add_css_class("suggested-action")
        self.run_button.add_css_class("pill")
        self.run_button.set_halign(Gtk.Align.END)
        self.run_button.set_margin_top(6)
        self.run_button.set_margin_end(6)
        self.run_button.set_margin_bottom(6)
        action_row_box = Gtk.Box(halign=Gtk.Align.END)
        action_row_box.append(self.run_button)
        self.page.add(self._wrap_action_group(action_row_box))

    @staticmethod
    def _wrap_action_group(box):
        group = Adw.PreferencesGroup()
        group.add(box)
        return group

    def add_row(self, row):
        self.group.add(row)

    def toast(self, text: str):
        self.toast_overlay.add_toast(Adw.Toast(title=text, timeout=4))

    def run_command(self, args: list[str], done_message: str | None = None):
        self.log.clear()
        self.run_button.set_sensitive(False)
        self.log.append_line("$ bin/lpm " + " ".join(args))

        def on_line(line: str):
            _run_on_main(self.log.append_line, line)

        def on_done(result: backend.CommandResult):
            def finish():
                self.run_button.set_sensitive(True)
                if result.stderr.strip():
                    for err_line in result.stderr.strip().splitlines():
                        self.log.append_line("! " + err_line)
                if result.returncode == 0:
                    self.toast(done_message or "Terminé.")
                else:
                    self.toast(f"Échec (code {result.returncode}) -- voir le journal.")

            _run_on_main(finish)

        backend.run_lpm_async(args, on_line=on_line, on_done=on_done)


# ---------------------------------------------------------------------------------------
# --- Sélecteur multi-jeux (coché/décoché), rempli depuis "lpm list" ---
class GameMultiSelect(Adw.ExpanderRow):
    def __init__(self, title: str = "Jeux concernés"):
        super().__init__(title=title)
        self.checks: dict[str, Gtk.CheckButton] = {}
        self._rows: list[Adw.ActionRow] = []
        self.refresh()

    def refresh(self):
        for row in self._rows:
            self.remove(row)
        self._rows.clear()
        self.checks.clear()

        entries = backend.list_games()
        for entry in entries:
            check = Gtk.CheckButton()
            action_row = Adw.ActionRow(title=entry.name, subtitle=entry.slug)
            action_row.add_prefix(check)
            action_row.set_activatable_widget(check)
            self.add_row(action_row)
            self._rows.append(action_row)
            self.checks[entry.slug] = check

    def selected_slugs(self) -> list[str]:
        return [slug for slug, chk in self.checks.items() if chk.get_active()]


class SingleGameCombo(Adw.ComboRow):
    def __init__(self, title: str = "Jeu"):
        super().__init__(title=title)
        self._slugs: list[str] = []
        self.refresh()

    def refresh(self):
        entries = backend.list_games()
        self._slugs = [e.slug for e in entries]
        model = Gtk.StringList.new([f"{e.name}  ({e.slug})" for e in entries])
        self.set_model(model)

    def selected_slug(self) -> str | None:
        idx = self.get_selected()
        if idx is None or idx == Gtk.INVALID_LIST_POSITION or idx >= len(self._slugs):
            return None
        return self._slugs[idx]


class RunnerCombo(Adw.ComboRow):
    def __init__(self, title: str = "Runner"):
        super().__init__(title=title)
        self._runners: list[str] = []
        self.refresh()

    def refresh(self):
        self._runners = backend.list_runners()
        self.set_model(Gtk.StringList.new(self._runners or ["(aucun runner installé)"]))

    def selected_runner(self) -> str | None:
        idx = self.get_selected()
        if idx is None or idx == Gtk.INVALID_LIST_POSITION or idx >= len(self._runners):
            return None
        return self._runners[idx]


def pick_file(window, title: str, callback, filters: list[tuple[str, list[str]]] | None = None, multiple: bool = False):
    """Ouvre un Gtk.FileDialog natif (jamais "zenity --file-selection"). callback reçoit
    une liste de chemins (vide si annulé)."""
    dialog = Gtk.FileDialog(title=title)
    if filters:
        store = Gio.ListStore.new(Gtk.FileFilter)
        for label, patterns in filters:
            f = Gtk.FileFilter()
            f.set_name(label)
            for p in patterns:
                f.add_pattern(p)
            store.append(f)
        dialog.set_filters(store)

    def on_result(dlg, res):
        try:
            if multiple:
                files = dlg.open_multiple_finish(res)
                paths = [files.get_item(i).get_path() for i in range(files.get_n_items())]
            else:
                f = dlg.open_finish(res)
                paths = [f.get_path()] if f else []
        except GLib.Error:
            paths = []
        callback(paths)

    if multiple:
        dialog.open_multiple(window, None, on_result)
    else:
        dialog.open(window, None, on_result)


def pick_folder(window, title: str, callback):
    dialog = Gtk.FileDialog(title=title)

    def on_result(dlg, res):
        try:
            f = dlg.select_folder_finish(res)
            path = f.get_path() if f else None
        except GLib.Error:
            path = None
        callback(path)

    dialog.select_folder(window, None, on_result)


# ---------------------------------------------------------------------------------------
# --- Construction de chaque écran de commande ---
class CommandPages:
    def __init__(self, window: "MainWindow"):
        self.window = window

    # --- Jeux ---
    def page_install(self, initial_files: list[str] | None = None):
        page = CommandPage("Installer un jeu", "Paquet(s) .zgp")
        self._selected_files: list[str] = list(initial_files or [])

        path_row = Adw.ActionRow(
            title="Fichier(s) .zgp",
            subtitle=", ".join(os.path.basename(p) for p in self._selected_files) or "Aucun sélectionné",
        )

        def choose():
            def got(paths):
                self._selected_files = paths
                path_row.set_subtitle(", ".join(os.path.basename(p) for p in paths) or "Aucun sélectionné")

            pick_file(self.window, "Choisir un ou plusieurs .zgp", got, [(".zgp", ["*.zgp"])], multiple=True)

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)
        choose_btn.connect("clicked", lambda *_: choose())
        path_row.add_suffix(choose_btn)
        page.add_row(path_row)

        allow_scripts_row = Adw.SwitchRow(title="Autoriser les scripts automatiques",
                                           subtitle="Hooks prelaunch/postexit détectés dans le paquet (désactivé = retirés par sécurité)")
        page.add_row(allow_scripts_row)

        ignore_hash_row = Adw.SwitchRow(title="Ignorer la vérification de hash")
        page.add_row(ignore_hash_row)

        def on_run(*_):
            if not self._selected_files:
                page.toast("Choisis au moins un fichier .zgp.")
                return
            args = ["install", "-y"]
            if allow_scripts_row.get_active():
                args.append("--allow-scripts")
            if ignore_hash_row.get_active():
                args.append("--ignore-hash")
            args.extend(self._selected_files)
            page.run_command(args, "Installation terminée.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_uninstall(self):
        page = CommandPage("Désinstaller un jeu")
        selector = GameMultiSelect()
        page.add_row(selector)

        def on_run(*_):
            slugs = selector.selected_slugs()
            if not slugs:
                page.toast("Sélectionne au moins un jeu.")
                return
            page.run_command(["uninstall", "-y", *slugs], "Désinstallation terminée.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_create_prefix(self):
        page = CommandPage("Créer un/des wineprefix(es) vierge(s)")
        names_row = Adw.EntryRow(title="Noms (séparés par des virgules)")
        page.add_row(names_row)
        runner_row = RunnerCombo()
        page.add_row(runner_row)
        arch_row = Adw.ComboRow(title="Architecture")
        arch_row.set_model(Gtk.StringList.new(["win64", "win32"]))
        page.add_row(arch_row)

        def on_run(*_):
            raw = names_row.get_text().strip()
            if not raw:
                page.toast("Indique au moins un nom.")
                return
            names = [n.strip() for n in raw.split(",") if n.strip()]
            runner = runner_row.selected_runner()
            arch_idx = arch_row.get_selected()
            arch = "win64" if arch_idx in (0, Gtk.INVALID_LIST_POSITION) else "win32"
            args = ["create-prefix", "-y"]
            if runner:
                args.extend(["-r", runner])
            args.extend(["-a", arch, *names])
            page.run_command(args, "Préfixe(s) créé(s).")

        page.run_button.connect("clicked", on_run)
        return page

    def page_exe_install(self):
        page = CommandPage("Installer un .exe hors catalogue")
        self._exe_path = ""
        path_row = Adw.ActionRow(title="Exécutable (.exe)", subtitle="Aucun sélectionné")

        def choose():
            def got(paths):
                if paths:
                    self._exe_path = paths[0]
                    path_row.set_subtitle(self._exe_path)

            pick_file(self.window, "Choisir l'exécutable", got, [(".exe", ["*.exe"])])

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)
        choose_btn.connect("clicked", lambda *_: choose())
        path_row.add_suffix(choose_btn)
        page.add_row(path_row)

        name_row = Adw.EntryRow(title="Nom affiché du jeu")
        page.add_row(name_row)
        slug_row = Adw.EntryRow(title="Slug personnalisé (optionnel)")
        page.add_row(slug_row)
        runner_row = RunnerCombo()
        page.add_row(runner_row)
        arch_row = Adw.ComboRow(title="Architecture")
        arch_row.set_model(Gtk.StringList.new(["win64", "win32"]))
        page.add_row(arch_row)
        final_exe_row = Adw.EntryRow(title="Exécutable final à lancer (optionnel)")
        page.add_row(final_exe_row)

        def on_run(*_):
            if not self._exe_path or not name_row.get_text().strip():
                page.toast("Choisis un .exe et donne un nom.")
                return
            target = f"{self._exe_path}|{name_row.get_text().strip()}"
            if slug_row.get_text().strip():
                target += f"|{slug_row.get_text().strip()}"
            runner = runner_row.selected_runner()
            arch = "win64" if arch_row.get_selected() in (0, Gtk.INVALID_LIST_POSITION) else "win32"
            args = ["exe-install", "-y", target]
            if runner:
                args.extend(["-r", runner])
            args.extend(["-a", arch])
            if final_exe_row.get_text().strip():
                args.extend(["-f", final_exe_row.get_text().strip()])
            page.run_command(args, "Installation terminée.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_shortcut(self):
        page = CommandPage("(Re)générer des raccourcis")
        selector = GameMultiSelect()
        page.add_row(selector)
        all_row = Adw.SwitchRow(title="Tous les jeux Wine installés")
        page.add_row(all_row)

        def on_run(*_):
            if all_row.get_active():
                page.run_command(["shortcut", "--all"], "Raccourcis régénérés.")
                return
            slugs = selector.selected_slugs()
            if not slugs:
                page.toast("Sélectionne au moins un jeu, ou coche \"tous\".")
                return
            page.run_command(["shortcut", *slugs], "Raccourcis régénérés.")

        page.run_button.connect("clicked", on_run)
        return page

    def _page_image_fetch(self, command: str, title: str):
        page = CommandPage(title, "Récupère une image via SteamGridDB (clé API demandée une seule fois)")
        selector = GameMultiSelect()
        page.add_row(selector)

        def on_run(*_):
            slugs = selector.selected_slugs()
            if not slugs:
                page.toast("Sélectionne au moins un jeu.")
                return
            page.run_command([command, *slugs], "Terminé.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_icon(self):
        return self._page_image_fetch("icon", "Icône de jeu")

    def page_splash(self):
        return self._page_image_fetch("splash", "Image de chargement (splash)")

    def page_logo(self):
        return self._page_image_fetch("logo", "Logo de jeu")

    def page_tools(self):
        page = CommandPage("Outils Wine pour un jeu")
        game_row = SingleGameCombo()
        page.add_row(game_row)

        tools = ["winetricks", "regedit", "winecfg", "console", "exe", "folder", "favorite"]
        tool_row = Adw.ComboRow(title="Outil")
        tool_row.set_model(Gtk.StringList.new(tools))
        page.add_row(tool_row)

        self._tools_path = ""
        path_row = Adw.ActionRow(title="Chemin (exe ou dossier favori)", subtitle="Si nécessaire pour l'outil choisi")

        def choose_exe():
            def got(paths):
                if paths:
                    self._tools_path = paths[0]
                    path_row.set_subtitle(self._tools_path)

            pick_file(self.window, "Choisir l'exécutable", got)

        def choose_folder():
            def got(path):
                if path:
                    self._tools_path = path
                    path_row.set_subtitle(self._tools_path)

            pick_folder(self.window, "Choisir le dossier favori", got)

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)

        def on_choose_clicked(*_):
            idx = tool_row.get_selected()
            if idx == 4:  # exe
                choose_exe()
            elif idx == 6:  # favorite
                choose_folder()

        choose_btn.connect("clicked", on_choose_clicked)
        path_row.add_suffix(choose_btn)
        page.add_row(path_row)

        def on_run(*_):
            slug = game_row.selected_slug()
            if not slug:
                page.toast("Choisis un jeu.")
                return
            tool = tools[tool_row.get_selected()] if tool_row.get_selected() != Gtk.INVALID_LIST_POSITION else tools[0]
            args = ["tools", slug, tool]
            if tool in ("exe", "favorite") and self._tools_path:
                args.append(self._tools_path)
            page.run_command(args, "Lancé.")

        page.run_button.connect("clicked", on_run)
        return page

    def _page_toggle_feature(self, command: str, title: str, subtitle: str = ""):
        page = CommandPage(title, subtitle)
        selector = GameMultiSelect()
        page.add_row(selector)
        state_row = Adw.ComboRow(title="Action")
        state_row.set_model(Gtk.StringList.new(["Activer", "Désactiver"]))
        page.add_row(state_row)

        def on_run(*_):
            slugs = selector.selected_slugs()
            if not slugs:
                page.toast("Sélectionne au moins un jeu.")
                return
            action = "on" if state_row.get_selected() in (0, Gtk.INVALID_LIST_POSITION) else "off"
            page.run_command([command, *slugs, action], "Terminé.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_launcher(self):
        return self._page_toggle_feature("launcher", "Écran de chargement (LPM Launcher)")

    def page_lsfg(self):
        return self._page_toggle_feature(
            "lsfg", "Génération de frames (lsfg-vk)",
            "Le DLL de référence et l'installation de lsfg-vk doivent déjà avoir été configurés une première fois (voir Réglages).",
        )

    # --- Runners ---
    def page_install_runner(self, initial_files: list[str] | None = None):
        page = CommandPage("Installer un runner", "Paquet(s) .zgr local(aux), ou nom(s) distant(s) GitHub")
        self._runner_files: list[str] = list(initial_files or [])
        path_row = Adw.ActionRow(
            title="Fichier(s) .zgr",
            subtitle=", ".join(os.path.basename(p) for p in self._runner_files) or "Aucun sélectionné",
        )

        def choose():
            def got(paths):
                self._runner_files = paths
                path_row.set_subtitle(", ".join(os.path.basename(p) for p in paths) or "Aucun sélectionné")

            pick_file(self.window, "Choisir un ou plusieurs .zgr", got, [(".zgr", ["*.zgr"])], multiple=True)

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)
        choose_btn.connect("clicked", lambda *_: choose())
        path_row.add_suffix(choose_btn)
        page.add_row(path_row)

        remote_row = Adw.EntryRow(title="Ou nom(s) distant(s) (séparés par des virgules)")
        page.add_row(remote_row)
        ignore_hash_row = Adw.SwitchRow(title="Ignorer la vérification de hash")
        page.add_row(ignore_hash_row)

        def on_run(*_):
            targets = list(self._runner_files)
            remote_raw = remote_row.get_text().strip()
            if remote_raw:
                targets.extend(n.strip() for n in remote_raw.split(",") if n.strip())
            if not targets:
                page.toast("Choisis un .zgr local ou donne un nom distant.")
                return
            args = ["install-runner", "-y"]
            if ignore_hash_row.get_active():
                args.append("--ignore-hash")
            args.extend(targets)
            page.run_command(args, "Runner(s) installé(s).")

        page.run_button.connect("clicked", on_run)
        return page

    def page_uninstall_runner(self):
        page = CommandPage("Désinstaller un runner")
        listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        checks: dict[str, Gtk.CheckButton] = {}
        for runner in backend.list_runners():
            check = Gtk.CheckButton()
            row = Adw.ActionRow(title=runner)
            row.add_prefix(check)
            row.set_activatable_widget(check)
            listbox.append(row)
            checks[runner] = check
        group = Adw.PreferencesGroup(title="Runners installés")
        group.add(listbox)
        page.page.add(group)

        def on_run(*_):
            selected = [r for r, c in checks.items() if c.get_active()]
            if not selected:
                page.toast("Sélectionne au moins un runner.")
                return
            page.run_command(["uninstall-runner", "-y", *selected], "Runner(s) supprimé(s).")

        page.run_button.connect("clicked", on_run)
        return page

    def _page_pack(self, command: str, title: str, items_label: str, list_fn):
        page = CommandPage(title)
        listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        checks: dict[str, Gtk.CheckButton] = {}
        for item in list_fn():
            name = item.name if hasattr(item, "name") else item
            key = item.slug if hasattr(item, "slug") else item
            check = Gtk.CheckButton()
            row = Adw.ActionRow(title=name, subtitle=key if hasattr(item, "slug") else None)
            row.add_prefix(check)
            row.set_activatable_widget(check)
            listbox.append(row)
            checks[key] = check
        group = Adw.PreferencesGroup(title=items_label)
        group.add(listbox)
        page.page.add(group)

        level_row = Adw.SpinRow.new_with_range(1, 22, 1)
        level_row.set_title("Niveau de compression (zstd)")
        level_row.set_value(3)
        page.add_row(level_row)
        hash_row = Adw.SwitchRow(title="Générer un fichier de hash (.sha256)")
        page.add_row(hash_row)

        def on_run(*_):
            selected = [k for k, c in checks.items() if c.get_active()]
            if not selected:
                page.toast("Sélectionne au moins un élément.")
                return
            level = int(level_row.get_value())
            args = [command, f"-{level}"]
            if hash_row.get_active():
                args.append("--hash")
            args.extend(selected)
            page.run_command(args, "Archive(s) créée(s).")

        page.run_button.connect("clicked", on_run)
        return page

    def page_pack(self):
        return self._page_pack("pack", "Exporter un jeu (.zgp)", "Jeux installés", backend.list_games)

    def page_pack_runner(self):
        return self._page_pack("pack-runner", "Exporter un runner (.zgr)", "Runners installés", backend.list_runners)

    def page_isolate(self):
        page = CommandPage("Isoler un store partagé", "Sépare chaque jeu d'un giga-préfixe (Epic/EA/Ubisoft/Battle.net) en son propre préfixe")
        entries = backend.list_isolable()
        by_store: dict[str, list[backend.IsolableEntry]] = {}
        for e in entries:
            by_store.setdefault(e.store_label, []).append(e)

        store_row = Adw.ComboRow(title="Store à isoler")
        store_labels = list(by_store.keys())
        store_row.set_model(Gtk.StringList.new(store_labels or ["(aucun store détecté)"]))
        page.add_row(store_row)

        def on_run(*_):
            idx = store_row.get_selected()
            if not store_labels or idx == Gtk.INVALID_LIST_POSITION or idx >= len(store_labels):
                page.toast("Aucun store à isoler.")
                return
            label = store_labels[idx]
            representative_slug = by_store[label][0].slug
            page.run_command(["isolate", "-y", representative_slug], f"Store « {label} » isolé.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_killwine(self):
        page = CommandPage("Tuer tous les processus Wine", "Action destructive : ferme immédiatement tous les jeux Wine/Proton en cours")
        warn_row = Adw.ActionRow(title="⚠️ Ferme TOUS les jeux Wine/Proton en cours d'exécution, sans sauvegarde")
        page.add_row(warn_row)

        def on_run(*_):
            def confirmed():
                page.run_command(["killwine", "-y"], "Processus Wine terminés.")

            dialog = Adw.AlertDialog(
                heading="Confirmer",
                body="Fermer tous les jeux Wine/Proton en cours maintenant ?",
            )
            dialog.add_response("cancel", "Annuler")
            dialog.add_response("confirm", "Fermer tout")
            dialog.set_response_appearance("confirm", Adw.ResponseAppearance.DESTRUCTIVE)

            def on_response(_dlg, response):
                if response == "confirm":
                    confirmed()

            dialog.connect("response", on_response)
            dialog.present(self.window)

        page.run_button.connect("clicked", on_run)
        return page

    def page_check(self):
        page = CommandPage("Vérifier les dépendances")

        def on_run(*_):
            page.run_command(["check", "-y"], "Vérification terminée.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_lutris_version(self):
        page = CommandPage("Choix Flatpak / natif de Lutris")
        choice_row = Adw.ComboRow(title="Version à utiliser")
        choice_row.set_model(Gtk.StringList.new(["flatpak", "native", "reset (redemander au prochain besoin)"]))
        page.add_row(choice_row)

        def on_run(*_):
            idx = choice_row.get_selected()
            value = ["flatpak", "native", "reset"][idx if idx != Gtk.INVALID_LIST_POSITION else 0]
            page.run_command(["lutris-version", value], "Préférence enregistrée.")

        page.run_button.connect("clicked", on_run)
        return page

    def page_settings(self):
        page = CommandPage("Réglages", "Clé SteamGridDB et DLL lsfg-vk (demandées une seule fois par les scripts CLI)")
        info_row = Adw.ActionRow(
            title="Ces deux réglages restent gérés par les scripts eux-mêmes",
            subtitle=(
                "La clé SteamGridDB (lpm icon/splash/logo) et le DLL lsfg-vk (lpm lsfg) sont "
                "redemandés automatiquement, UNE SEULE FOIS chacun, la première fois que tu "
                "utilises ces fonctions -- mais uniquement depuis un vrai terminal (ce sont des "
                "saisies de texte libre, pas encore de simples confirmations). Lance une fois "
                "« lpm icon <jeu> » et « lpm lsfg <jeu> on » dans un terminal pour les configurer, "
                "ensuite cette interface graphique les réutilisera sans redemander."
            ),
        )
        page.add_row(info_row)
        page.run_button.set_visible(False)
        return page


# ---------------------------------------------------------------------------------------
class MainWindow(Adw.ApplicationWindow):
    SECTIONS = [
        ("Jeux", [
            ("install", "Installer un jeu", "list-add-symbolic"),
            ("uninstall", "Désinstaller un jeu", "user-trash-symbolic"),
            ("create-prefix", "Créer un préfixe vierge", "folder-new-symbolic"),
            ("exe-install", "Installer un .exe hors catalogue", "application-x-executable-symbolic"),
            ("shortcut", "(Re)générer des raccourcis", "emblem-symbolic-link"),
            ("icon", "Récupérer une icône", "image-x-generic-symbolic"),
            ("splash", "Récupérer une image de chargement", "image-x-generic-symbolic"),
            ("logo", "Récupérer un logo", "image-x-generic-symbolic"),
            ("tools", "Outils Wine", "applications-utilities-symbolic"),
            ("launcher", "Écran de chargement (LPM Launcher)", "video-display-symbolic"),
            ("lsfg", "Génération de frames (lsfg-vk)", "video-display-symbolic"),
            ("pack", "Exporter un jeu (.zgp)", "package-x-generic-symbolic"),
            ("isolate", "Isoler un store partagé", "security-high-symbolic"),
        ]),
        ("Runners", [
            ("install-runner", "Installer un runner", "list-add-symbolic"),
            ("uninstall-runner", "Désinstaller un runner", "user-trash-symbolic"),
            ("pack-runner", "Exporter un runner (.zgr)", "package-x-generic-symbolic"),
        ]),
        ("Système", [
            ("check", "Vérifier les dépendances", "emblem-ok-symbolic"),
            ("lutris-version", "Flatpak / natif de Lutris", "preferences-system-symbolic"),
            ("killwine", "Tuer tous les processus Wine", "process-stop-symbolic"),
            ("settings", "Réglages", "preferences-other-symbolic"),
        ]),
    ]

    BUILDER_NAMES = {
        "install": "page_install",
        "uninstall": "page_uninstall",
        "create-prefix": "page_create_prefix",
        "exe-install": "page_exe_install",
        "shortcut": "page_shortcut",
        "icon": "page_icon",
        "splash": "page_splash",
        "logo": "page_logo",
        "tools": "page_tools",
        "launcher": "page_launcher",
        "lsfg": "page_lsfg",
        "pack": "page_pack",
        "isolate": "page_isolate",
        "install-runner": "page_install_runner",
        "uninstall-runner": "page_uninstall_runner",
        "pack-runner": "page_pack_runner",
        "check": "page_check",
        "lutris-version": "page_lutris_version",
        "killwine": "page_killwine",
        "settings": "page_settings",
    }

    def __init__(self, app: Adw.Application):
        super().__init__(application=app, title="lpm", default_width=980, default_height=680)

        self.pages = CommandPages(self)
        self._built_pages: dict[str, Gtk.Widget] = {}

        split_view = Adw.NavigationSplitView()
        self.set_content(split_view)

        sidebar_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        sidebar_header = Adw.HeaderBar(show_end_title_buttons=False)
        sidebar_header.set_title_widget(Adw.WindowTitle(title="lpm", subtitle="Ludis Package Manager"))
        sidebar_box.append(sidebar_header)

        sidebar_scroller = Gtk.ScrolledWindow(vexpand=True)
        sidebar_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        sidebar_list.add_css_class("navigation-sidebar")
        sidebar_scroller.set_child(sidebar_list)
        sidebar_box.append(sidebar_scroller)

        sidebar_page = Adw.NavigationPage(title="lpm", child=sidebar_box)
        split_view.set_sidebar(sidebar_page)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)

        content_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content_header = Adw.HeaderBar()
        self.title_widget = Adw.WindowTitle(title="lpm")
        content_header.set_title_widget(self.title_widget)
        content_box.append(content_header)
        content_box.append(self.stack)
        content_page = Adw.NavigationPage(title="lpm", child=content_box)
        split_view.set_content(content_page)

        row_to_id: dict[Gtk.ListBoxRow, str] = {}
        for section_title, items in self.SECTIONS:
            header = Gtk.Label(label=section_title, xalign=0)
            header.add_css_class("heading")
            header.set_margin_top(10)
            header.set_margin_start(12)
            header.set_margin_bottom(2)
            sidebar_list.append(header)
            for cmd_id, label, icon_name in items:
                row = Adw.ActionRow(title=label)
                row.add_prefix(Gtk.Image.new_from_icon_name(icon_name))
                sidebar_list.append(row)
                row_to_id[row] = cmd_id

        def on_row_selected(_listbox, row):
            if row is None:
                return
            cmd_id = row_to_id.get(row)
            if cmd_id is None:
                return
            self.show_page(cmd_id)

        sidebar_list.connect("row-selected", on_row_selected)

        # Sélectionne la première vraie ligne (pas un en-tête de section) au démarrage.
        first_row = next((r for r in row_to_id), None)
        if first_row is not None:
            sidebar_list.select_row(first_row)

    def show_page(self, cmd_id: str):
        if cmd_id not in self._built_pages:
            builder_name = self.BUILDER_NAMES[cmd_id]
            widget = getattr(self.pages, builder_name)()
            self.stack.add_named(widget, cmd_id)
            self._built_pages[cmd_id] = widget
        self.stack.set_visible_child_name(cmd_id)
        label_by_id = {cid: label for _, items in self.SECTIONS for cid, label, _ in items}
        self.title_widget.set_title(label_by_id.get(cmd_id, "lpm"))

    def open_install_for(self, path: str):
        """Ouvre directement la page d'installation adéquate (jeu ou runner, selon
        l'extension) avec "path" déjà pré-rempli -- remplace entièrement l'ancien mode
        "click" piloté par zenity (voir bin/lpm, section 2 : double-clic sur un .zgp/.zgr
        délègue maintenant ici plutôt qu'à lib/zgp-game-installer.sh en mode "click")."""
        extension = os.path.splitext(path)[1].lower()
        if extension == ".zgr":
            cmd_id = "install-runner"
            widget = self.pages.page_install_runner(initial_files=[path])
        else:
            cmd_id = "install"
            widget = self.pages.page_install(initial_files=[path])
        self.stack.add_named(widget, cmd_id)
        self._built_pages[cmd_id] = widget
        self.stack.set_visible_child_name(cmd_id)
        label_by_id = {cid: label for _, items in self.SECTIONS for cid, label, _ in items}
        self.title_widget.set_title(label_by_id.get(cmd_id, "lpm"))


class LpmApp(Adw.Application):
    def __init__(self, preselect_file: str | None = None):
        super().__init__(application_id=APP_ID)
        # Fichier .zgp/.zgr à pré-remplir dans la page d'installation dès l'ouverture
        # (double-clic / association de fichier, voir bin/lpm section 2) -- consommé une
        # seule fois, lors de la toute première activation.
        self._preselect_file = preselect_file

    def do_activate(self):
        win = self.props.active_window
        if not win:
            win = MainWindow(self)
        if self._preselect_file:
            win.open_install_for(self._preselect_file)
            self._preselect_file = None
        win.present()


def main():
    # Argument optionnel unique : chemin d'un .zgp/.zgr à pré-remplir (voir bin/lpm,
    # section 2 -- double-clic/association de fichier). On le retire de argv avant de le
    # passer à Gio/GLib pour que GApplication ne tente pas de l'interpréter lui-même comme
    # un fichier à "ouvrir" (ce qui exigerait de déclarer Gio.ApplicationFlags.HANDLES_OPEN
    # et d'implémenter do_open, inutile ici puisqu'on gère ça nous-mêmes).
    preselect_file = None
    extra_args = sys.argv[1:]
    if extra_args and os.path.isfile(extra_args[0]):
        preselect_file = extra_args[0]

    app = LpmApp(preselect_file=preselect_file)
    return app.run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
