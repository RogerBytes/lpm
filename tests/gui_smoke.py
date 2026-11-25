#!/usr/bin/env python3
"""Smoke test for the GTK4 interface (no real display: run via tests/run_gui_smoke.sh).

Builds the main window, shows EVERY sidebar page (running all page constructors), lets the
GTK loop run briefly (async list loading via the CLI), then returns to the menu. Fails on any
Python traceback raised in a GTK callback (captured via sys.excepthook / stderr) or any
broken import.
"""
import os
import sys
import time
import traceback

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import GLib  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "gui"))

errors = []


def _hook(exc_type, exc, tb):
    errors.append("".join(traceback.format_exception(exc_type, exc, tb)))


sys.excepthook = _hook

import ludis_gtk  # noqa: E402


def pump(seconds):
    ctx = GLib.MainContext.default()
    end = time.time() + seconds
    while time.time() < end:
        while ctx.pending():
            ctx.iteration(False)
        time.sleep(0.01)


app = ludis_gtk.LudisApp()
app.register(None)
app.activate()
pump(0.5)
win = app.props.active_window
assert win is not None, "no window created"

page_ids = list(ludis_gtk.MainWindow.BUILDER_NAMES)
ok = []
for page_id in page_ids:
    try:
        win.show_page(page_id)
        pump(0.6)
        ok.append(page_id)
    except Exception:
        errors.append("page %s:\n%s" % (page_id, traceback.format_exc()))

try:
    win._on_back_to_categories()
    pump(0.3)
except Exception:
    errors.append("back to menu:\n" + traceback.format_exc())

import sgdb  # noqa: E402

for label, make in (("SGDB titles window", lambda: sgdb.SgdbTitleResolverWindow(win, [("mario", "Mario")])),
                    ("SGDB images window", lambda: sgdb.SgdbPickerWindow(win, []))):
    try:
        w = make()
        w.present()
        pump(0.3)
        w.destroy()
        print("OK:", label)
    except Exception:
        errors.append("%s:\n%s" % (label, traceback.format_exc()))

import types  # noqa: E402
import i18n  # noqa: E402
import widgets_select  # noqa: E402

try:
    fs = widgets_select.FileMultiSelect("Test")
    assert fs.get_title() == "Test" or fs.get_title(), "empty title"
    fs.set_paths(["/a/x.zgp", "/a/y.zgp", "/a/z.zgp"], checked_paths=["/a/y.zgp"])
    assert fs.selected_paths() == ["/a/y.zgp"], fs.selected_paths()
    assert not fs.select_all_check.get_active()
    fs.select_all_check.set_active(True)
    assert len(fs.selected_paths()) == 3, fs.selected_paths()
    fs.set_paths([])
    assert fs.selected_paths() == []
    rr = widgets_select.RemoteRunnerMultiSelect()
    pump(0.2)
    # The widget starts a real network request when created; with network access its answer
    # lands in the list. Invalidate it (late answers are dropped) and start from an empty list.
    rr._gen += 1
    rr._clear()
    res = types.SimpleNamespace(returncode=0, stdout="GE-1\nGE-2" + i18n.t("list_remote.already_installed_suffix") + "\nGE-3\n")
    rr._apply_result(rr._gen, res)
    rr.select_all_check.set_active(True)
    got = rr.selected_names()
    assert got == ["GE-1", "GE-3"], got
    print("file/remote selectors: OK", got)
except Exception:
    errors.append("selectors:\n" + traceback.format_exc())

import util  # noqa: E402
import widgets_rows  # noqa: E402

try:
    calls = []
    widgets_rows.ask_keep_or_delete(win, "Title", "a\\nb", lambda: calls.append("del"))
    pump(0.2)
    assert util.json_result(types.SimpleNamespace(returncode=0, stdout='{"a": 1}')) == {"a": 1}
    assert util.json_result(types.SimpleNamespace(returncode=1, stdout='{"a": 1}')) == {}
    assert util.json_result(types.SimpleNamespace(returncode=0, stdout="not json")) == {}
    assert widgets_rows.sibling_files(["/nonexistent/x.zgp"], ".zgp") == ["/nonexistent/x.zgp"]
    print("dialog + utilities: OK")
except Exception:
    errors.append("utilities:\n" + traceback.format_exc())

# --- VSync page: pick a game, tick a box (immediate write), "Check all / uncheck all"
from gi.repository import Gtk  # noqa: E402


def walk(widget):
    child = widget.get_first_child()
    while child is not None:
        yield child
        yield from walk(child)
        child = child.get_next_sibling()


try:
    win.show_page("vsync")
    pump(0.6)
    vpage = win._built_pages["vsync"]
    vchecks = [w for w in walk(vpage) if type(w) is Gtk.CheckButton]
    assert len(vchecks) == 5, len(vchecks)
    assert not any(c.get_sensitive() for c in vchecks), "checkboxes enabled without a chosen game"
    vgame = next(w for w in walk(vpage) if isinstance(w, widgets_select.SingleGameSelect))
    mario_row = vgame._rows[vgame._slugs.index("mario")]
    vgame._listbox.select_row(mario_row)
    pump(1.5)
    assert all(c.get_sensitive() for c in vchecks), "checkboxes locked after choosing the game"
    assert not any(c.get_active() for c in vchecks), "checkboxes checked by default"
    ymlf = os.path.join(os.environ["HOME"], ".config/lutris/games/mario-1.yml")
    vchecks[0].set_active(True)
    pump(1.5)
    assert "presentInterval" in open(ymlf).read(), "the checkbox wrote nothing to the YAML"
    assert vchecks[0].get_active() and all(c.get_sensitive() for c in vchecks)
    vall = next(w for w in walk(vpage) if isinstance(w, Gtk.Button) and w.get_label() == i18n.t("gui.vsync.check_all"))
    vall.emit("clicked")
    pump(1.5)
    assert all(c.get_active() for c in vchecks), [c.get_active() for c in vchecks]
    assert vall.get_label() == i18n.t("gui.vsync.uncheck_all"), vall.get_label()
    assert "mario" in vgame._highlighted_slugs, "game not highlighted in bold"
    vall.emit("clicked")
    pump(1.5)
    assert not any(c.get_active() for c in vchecks)
    assert "presentInterval" not in open(ymlf).read() and "vblank_mode" not in open(ymlf).read()
    assert "mario" not in vgame._highlighted_slugs
    print("VSync page: OK")
except Exception:
    errors.append("VSync page:\n" + traceback.format_exc())

# --- Tools page: "Change runner" tool (no runner applied without an explicit choice)
try:
    win.show_page("tools")
    pump(0.6)
    tpage = win._built_pages["tools"]
    tgame = next(w for w in walk(tpage) if isinstance(w, widgets_select.SingleGameSelect))
    trunner = next(w for w in walk(tpage) if isinstance(w, widgets_select.RunnerCombo))
    ttool = next(w for w in walk(tpage) if type(w).__name__ == "SingleChoiceSelect")
    tgame._listbox.select_row(tgame._rows[tgame._slugs.index("mario")])
    pump(0.8)
    runner_idx = ttool.n_items() - 5
    ttool.set_selected(runner_idx)
    pump(0.5)
    assert trunner.get_visible(), "runner selector hidden"
    assert trunner.explicit_runner() is None, "runner applied without explicit choice"
    tpage.run_button.emit("clicked")
    pump(0.5)
    assert "GE-Other" not in open(os.path.join(os.environ["HOME"], ".config/lutris/games/mario-1.yml")).read(), "written without a choice"
    trunner.set_selected(trunner._runners.index("GE-Other") + 1)
    pump(0.2)
    assert trunner.explicit_runner() == "GE-Other", trunner.explicit_runner()
    tpage.run_button.emit("clicked")
    pump(2.0)
    ymlt = os.path.join(os.environ["HOME"], ".config/lutris/games/mario-1.yml")
    assert "GE-Other" in open(ymlt).read(), open(ymlt).read()
    print("runner tool: OK")
except Exception:
    errors.append("runner tool:\n" + traceback.format_exc())

# --- Tools page: "Launch options" tool (GameMode, Gamescope, Esync...) ------------------
try:
    # a successful run resets the page (game selection included): choose the game again
    tgame._listbox.select_row(tgame._rows[tgame._slugs.index("mario")])
    pump(0.8)
    ttool.set_selected(ttool.n_items() - 1)
    pump(3.0)
    from gi.repository import Adw
    def by_title(key):
        title = i18n.t("gui.tools.opt_" + key)
        return next(w for w in walk(tpage) if isinstance(w, (Adw.ComboRow, Adw.EntryRow)) and w.get_title() == title)
    orow = {k: by_title(k) for k in ("gamemode", "esync", "gamescope-fps")}
    import backend
    _r = backend.run_ludis(["tools", "mario", "options", "status"])
    assert _r.returncode == 0, "status failed: rc=%s out=%r err=%r" % (_r.returncode, _r.stdout, _r.stderr)
    assert orow["gamemode"].get_visible(), "options rows hidden"
    assert orow["gamemode"].get_sensitive(), "options not loaded (sensitive=%s)" % orow["gamemode"].get_sensitive()
    assert orow["gamemode"].get_selected() == 0, "gamemode should start on Default"
    orow["gamemode"].set_selected(1)      # On
    orow["esync"].set_selected(2)         # Off
    orow["gamescope-fps"].set_text("60")
    tpage.run_button.emit("clicked")
    pump(2.5)
    import yaml as _yaml
    d = _yaml.safe_load(open(os.path.join(os.environ["HOME"], ".config/lutris/games/mario-1.yml")))
    assert d["system"]["gamemode"] is True, d
    assert d["wine"]["esync"] is False, d
    assert d["system"]["gamescope_fps_limiter"] == "60", d
    assert d["wine"]["version"] == "GE-Other", d
    print("launch options tool: OK")
except Exception:
    errors.append("launch options tool:\n" + traceback.format_exc())

# --- Tools page: ready-made gamepad profiles ------------------------------------------------
try:
    from gi.repository import Adw
    tgame._listbox.select_row(tgame._rows[tgame._slugs.index("mario")])
    pump(0.8)
    ttool.set_selected(ttool.tools_index if hasattr(ttool, "tools_index") else 11)
    pump(3.0)
    trow = next(w for w in walk(tpage) if isinstance(w, Adw.ComboRow) and w.get_title() == i18n.t("gui.tools.gamepad_template_title"))
    assert trow.get_visible() and trow.get_sensitive(), "template list not loaded"
    labels = [trow.get_model().get_string(i) for i in range(trow.get_model().get_n_items())]
    assert any(l.startswith("LPM-FPS-ZQSD (") for l in labels), labels
    assert len(labels) >= 12, labels
    trow.set_selected(next(i for i, l in enumerate(labels) if l.startswith("LPM-Course-ZQSD")))
    apply_btn = next(w for w in walk(trow) if isinstance(w, Gtk.Button))
    apply_btn.emit("clicked")
    pump(2.5)
    prof = os.path.join(os.environ["HOME"], "Games/mario/ludis/gamepad/lpm-gamepad.gamecontroller.amgp")
    assert os.path.exists(prof) and "0x5a" in open(prof).read(), "template not copied"
    print("gamepad templates: OK")
except Exception:
    errors.append("gamepad templates:\n" + traceback.format_exc())

# --- Lutris defaults page -----------------------------------------------------------------
try:
    win.show_page("lutris-defaults")
    pump(1.5)
    dpage = win._built_pages["lutris-defaults"]
    import yaml as _yaml
    from gi.repository import Adw
    dwine = next(w for w in walk(dpage) if isinstance(w, Adw.ComboRow) and not isinstance(w, widgets_select.RunnerCombo))
    assert dwine.get_sensitive(), "winetricks choice not loaded"
    dwine.set_selected(1)  # system
    dpage.run_button.emit("clicked")
    pump(2.5)
    d = _yaml.safe_load(open(os.path.join(os.environ["HOME"], ".config/lutris/runners/wine.yml")))
    assert d["wine"]["system_winetricks"] is True, d
    print("Lutris defaults page: OK")
except Exception:
    errors.append("Lutris defaults page:\n" + traceback.format_exc())

# --- Game version page + install replace dialog ---------------------------------------------
try:
    win.show_page("game-version")
    pump(1.5)
    vpage = win._built_pages["game-version"]
    vsel = next(w for w in walk(vpage) if isinstance(w, widgets_select.SingleGameSelect))
    vsel.select_slug("mario")
    pump(1.5)
    from gi.repository import Adw
    ventry = next(w for w in walk(vpage) if isinstance(w, Adw.EntryRow))
    assert ventry.get_sensitive(), "version entry not enabled"
    ventry.set_text("3.1")
    vpage.run_button.emit("clicked")
    pump(2.5)
    vfile = os.path.join(os.environ["HOME"], "Games/mario/ludis/settings/game-version")
    assert open(vfile).read().strip() == "3.1", "version not saved"
    import pages_lifecycle
    rows = pages_lifecycle.InstallPage._parse_existing("EXISTS\x1fMario\x1fMario.zgp\x1fmario\x1f3.1\x1f\n")
    assert rows == [("Mario", "3.1", "")], rows
    fs = widgets_select.FileMultiSelect("t")
    fs.set_paths(["/x/Mario.zgp"])
    fs.set_versions({"/x/Mario.zgp": "3.1"})
    assert "Mario.zgp (v3.1)" in fs._row_by_path["/x/Mario.zgp"].get_title()
    print("game version page: OK")
except Exception:
    errors.append("game version page:\n" + traceback.format_exc())

# --- Rename page + sizes in the uninstall list --------------------------------------------
try:
    win.show_page("rename")
    pump(1.5)
    rpage = win._built_pages["rename"]
    rsel = next(w for w in walk(rpage) if isinstance(w, widgets_select.SingleGameSelect))
    rsel.select_slug("mario")
    pump(1.5)
    from gi.repository import Adw
    rentry = next(w for w in walk(rpage) if isinstance(w, Adw.EntryRow))
    rentry.set_text("Mario GUI")
    rpage.run_button.emit("clicked")
    pump(2.5)
    import subprocess
    out = subprocess.run([backend.BIN_Ludis, "list"], capture_output=True, text=True).stdout
    assert "Mario GUI" in out, out
    subprocess.run([backend.BIN_Ludis, "rename", "mario", "Mario"], capture_output=True)
    assert widgets_select.human_size(1536) == "1.5 KiB" and widgets_select.human_size(5 * 1024 ** 3) == "5.0 GiB"
    win.show_page("uninstall")
    pump(3)
    upage = win._built_pages["uninstall"]
    usel = next(w for w in walk(upage) if isinstance(w, widgets_select.GameMultiSelect))
    titles = [r.get_title() for r in usel._row_by_slug.values()]
    assert any(" — " in x for x in titles), titles
    print("rename page + sizes: OK")
except Exception:
    errors.append("rename page + sizes:\n" + traceback.format_exc())

# --- Home page: update button (hidden unless a newer version is known) -------------------
try:
    import pages_home
    import backend
    installed = backend.get_ludis_version()
    newer = "99.0.0"
    for info, want_visible in ((None, False), ({"latest": "0.0.1", "url": "", "method": "deb"}, False),
                               ({"latest": newer, "url": "", "method": "deb"}, True)):
        pages_home._check_update_async = lambda cb, _info=info: cb(_info)
        home = win.pages.page_home()
        buttons = [w for w in walk(home) if isinstance(w, Gtk.Button) and "suggested-action" in w.get_css_classes()]
        assert len(buttons) == 1, "update button missing"
        assert buttons[0].get_visible() == want_visible, (info, buttons[0].get_visible())
        if want_visible:
            assert newer in buttons[0].get_label(), buttons[0].get_label()
    print("update button: OK")
except Exception:
    errors.append("update button:\n" + traceback.format_exc())

# --- Progress window: the cancel question is in the window, same size, generic ------------
try:
    import progresswindow
    import operations
    import widgets_rows
    cancelled = []
    done_items = []
    pw = progresswindow.ProgressWindow("Some operation", True, cancelled.append, lambda: bool(done_items))
    pw.present()
    pump(0.4)
    size = (pw.get_width(), pw.get_height())
    pw.cancel_button.emit("clicked")
    pump(0.3)
    assert pw.stack.get_visible_child_name() == "confirm" and not pw.notice.get_visible() and pw.confirm_button.get_visible()
    assert (pw.get_width(), pw.get_height()) == size, ((pw.get_width(), pw.get_height()), size)
    pw.keep_button.emit("clicked")
    assert pw.stack.get_visible_child_name() == "progress" and not cancelled
    # nothing finished yet: cancelling is immediate
    pw.cancel_button.emit("clicked")
    pw.confirm_button.emit("clicked")
    assert cancelled == [None] and pw.stack.get_visible_child_name() == "progress", cancelled
    # something finished: a second step (same size) asks "stop here" / "undo all"
    pw.cancel_button.set_sensitive(True)
    done_items.append("game")
    pw.cancel_button.emit("clicked")
    pw.confirm_button.emit("clicked")
    pump(0.3)
    assert pw.stack.get_visible_child_name() == "choice" and cancelled == [None]
    assert pw._on_close_request(pw) is True and pw.stack.get_visible_child_name() == "choice", "the second question can be dodged"
    assert (pw.get_width(), pw.get_height()) == size, ((pw.get_width(), pw.get_height()), size)
    pw.undo_button.emit("clicked")
    assert cancelled == [None, "undo"] and pw.stack.get_visible_child_name() == "progress", cancelled
    pw.finish()
    # that choice answers the keep-or-delete question without any dialog
    deleted = []
    for choice, expect in (("undo", [1]), ("stop", []), (None, None)):
        operations.cancel_choice[0] = choice
        if choice is not None:
            widgets_rows.ask_keep_or_delete(win, "h", "b", lambda: deleted.append(1))
            assert deleted == expect, (choice, deleted)
            deleted.clear()
    operations.cancel_choice[0] = None
    print("cancel question in window: OK")
except Exception:
    errors.append("cancel question:\n" + traceback.format_exc())

# --- Operations: one at a time, own progress window, error window only on failure ------
try:
    import operations
    import progresswindow
    from i18n import t
    win.show_page("install")
    pump(0.3)
    ipage = win._built_pages["install"]
    toasts = []
    ipage.toast_overlay.add_toast = lambda toast: toasts.append(toast.get_title())

    def op_windows():
        return [w for w in win.get_application().get_windows() if isinstance(w, progresswindow.ProgressWindow)]

    # failure: an error window (not a toast), brought in front, with the command's error text
    ipage.run_command(["no-such-command-xyz"], "done")
    assert operations.is_busy(), "operation not registered"
    assert len(op_windows()) == 1, "no progress window"
    ipage.run_command(["list"], "done")  # refused: only 0 or 1 operation at a time
    assert len(op_windows()) == 1 and t("gui.op.already_running") in toasts, toasts
    pump(3.0)
    assert not operations.is_busy(), "operation not released"
    windows_now = op_windows()
    assert len(windows_now) == 1, "error window missing"
    labels = [w.get_label() for w in walk(windows_now[0]) if isinstance(w, Gtk.Label)]
    assert t("gui.op.error_heading") in labels and len(labels) >= 2 and labels[1].strip(), labels
    windows_now[0].close()
    pump(0.3)
    assert not op_windows(), "error window not closed"

    # success: the progress window goes away by itself, no error window
    notified = []
    operations.notify = lambda title, body: notified.append(body)
    ipage.run_command(["list"], "Finished OK")
    pump(3.0)
    assert not op_windows(), "window left open after a success"
    assert notified == ["Finished OK"], notified
    # an already-open file does not replace a running operation
    ipage.run_command(["no-such-command-xyz"], "x")
    win.open_install_for("/tmp/whatever.zgp")
    assert win._built_pages["install"] is ipage, "page replaced during an operation"
    pump(3.0)
    for extra in op_windows():
        extra.close()
    import guilog
    guilog._GUI_LOGGER.info("smoke probe")
    gui_log = os.path.join(os.path.expanduser("~"), ".local", "share", "ludis", "ludis-gui.log")
    assert os.path.getsize(gui_log) > 0, "ludis-gui.log stays empty"
    print("operations window + lock + gui log: OK")
except Exception:
    errors.append("operations:\n" + traceback.format_exc())

# --- Install: scripts embedded in archives are listed, then ONE confirmation -------------
try:
    import subprocess, tempfile, pages_lifecycle
    from gi.repository import Adw
    tmp = tempfile.mkdtemp()
    cfg = os.path.join(tmp, ".lpm-config.yml")
    with open(cfg, "w") as f:
        f.write("name: Hook Game\ngame:\n  exe: /x.exe\nsystem:\n  prelaunch_command: /bin/true\n")
    os.makedirs(os.path.join(tmp, "hookgame"))
    zgp = os.path.join(tmp, "Hook Game.zgp")
    subprocess.run("tar -C %s --zstd -cf '%s' .lpm-config.yml hookgame" % (tmp, zgp), shell=True, check=True)
    res = backend.run_ludis(["install", "-y", "--list-hooks", zgp])
    games = pages_lifecycle.InstallPage._parse_hooks(res.stdout)
    assert len(games) == 1 and games[0][0] == "Hook Game" and len(games[0][2]) == 1, games
    short, full = games[0][2][0]
    assert short == "/bin/true" and full == "/bin/true", games
    shown_dialogs = []
    Adw.AlertDialog.present = lambda self, parent=None: shown_dialogs.append(self)
    choices = []
    stub = types.SimpleNamespace(window=win)
    pages_lifecycle.InstallPage._ask_hooks(stub, games, 2, choices.append)
    dlg = shown_dialogs[0]
    assert "prelaunch_command" not in dlg.get_body() and dlg.get_extra_child() is not None
    assert dlg.get_default_response() == "without", dlg.get_default_response()
    for response in ("without", "allow", "cancel"):
        dlg.emit("response", response)
    assert choices == [False, True, None], choices
    print("install scripts confirmation: OK")
except Exception:
    errors.append("install scripts confirmation:\n" + traceback.format_exc())

# --- Closing the main window does not stop a running operation ----------------------------
try:
    import operations
    import progresswindow
    import backend
    from mainwindow import MainWindow
    slow = os.path.join(os.environ["HOME"], "bin", "slow-ludis")
    with open(slow, "w") as f:
        f.write("#!/bin/sh\nsleep 2\nexit 0\n")
    os.chmod(slow, 0o755)
    real_bin = backend.BIN_Ludis
    backend.BIN_Ludis = slow
    app = win.get_application()
    win2 = MainWindow(app)
    win2.show_page("install")
    pump(0.3)
    page2 = win2._built_pages["install"]
    page2.run_command(["x"], "ok")
    win2.destroy()
    pump(0.5)
    live = [w for w in app.get_windows() if isinstance(w, progresswindow.ProgressWindow)]
    assert operations.is_busy() and len(live) == 1, "operation stopped with the main window"
    pump(3.5)
    backend.BIN_Ludis = real_bin
    assert not operations.is_busy(), "operation never ended"
    assert not [w for w in app.get_windows() if isinstance(w, progresswindow.ProgressWindow)], "progress window left open"
    print("operation survives main window: OK")
except Exception:
    errors.append("operation survives main window:\n" + traceback.format_exc())

# --- Cancelling a batch with something already done: "undo all" reaches the handler --------
try:
    import operations
    import progresswindow
    import backend
    from mainwindow import MainWindow
    batch = os.path.join(os.environ["HOME"], "bin", "batch-ludis")
    with open(batch, "w") as f:
        f.write("#!/bin/sh\necho '[INSTALLED] foo'\nsleep 30\n")
    os.chmod(batch, 0o755)
    real_bin = backend.BIN_Ludis
    backend.BIN_Ludis = batch
    win3 = MainWindow(win.get_application())
    win3.show_page("install")
    pump(0.3)
    page3 = win3._built_pages["install"]
    seen = []
    page3.run_command(["x"], "ok", cancellable=True, undoable=True,
                      on_cancelled=lambda slugs: seen.append((slugs, operations.cancel_choice[0])))
    pump(1.0)
    pwin = next(w for w in win.get_application().get_windows() if isinstance(w, progresswindow.ProgressWindow))
    pwin.cancel_button.emit("clicked")
    pwin.confirm_button.emit("clicked")
    pump(0.3)
    assert pwin.stack.get_visible_child_name() == "choice", pwin.stack.get_visible_child_name()
    pwin.undo_button.emit("clicked")
    pump(3.0)
    backend.BIN_Ludis = real_bin
    assert seen == [(["foo"], "undo")], seen
    assert not operations.is_busy() and operations.cancel_choice[0] is None
    win3.destroy()
    print("cancel batch -> undo all: OK")
except Exception:
    errors.append("cancel batch undo:\n" + traceback.format_exc())

print("pages built: %d/%d" % (len(ok), len(page_ids)))
print("pages: " + ", ".join(ok))
if errors:
    print("ERRORS (%d):" % len(errors))
    for e in errors:
        print(e)
    sys.exit(1)
print("OK")
