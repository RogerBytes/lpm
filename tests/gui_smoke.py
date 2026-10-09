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

import lpm_gtk  # noqa: E402


def pump(seconds):
    ctx = GLib.MainContext.default()
    end = time.time() + seconds
    while time.time() < end:
        while ctx.pending():
            ctx.iteration(False)
        time.sleep(0.01)


app = lpm_gtk.LpmApp()
app.register(None)
app.activate()
pump(0.5)
win = app.props.active_window
assert win is not None, "no window created"

page_ids = list(lpm_gtk.MainWindow.BUILDER_NAMES)
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
    ttool = next(w for w in walk(tpage) if type(w).__name__ == "ComboRow" and w.get_title() == i18n.t("gui.tools.tool_title"))
    tgame._listbox.select_row(tgame._rows[tgame._slugs.index("mario")])
    pump(0.8)
    runner_idx = ttool.get_model().get_n_items() - 1
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

# --- Home page: update button (hidden unless a newer version is known) -------------------
try:
    import pages_home
    import backend
    installed = backend.get_lpm_version()
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

print("pages built: %d/%d" % (len(ok), len(page_ids)))
print("pages: " + ", ".join(ok))
if errors:
    print("ERRORS (%d):" % len(errors))
    for e in errors:
        print(e)
    sys.exit(1)
print("OK")
