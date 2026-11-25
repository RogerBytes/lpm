#!/usr/bin/env python3
"""Generates the ready-made AntiMicroX profiles shipped in lib/data/gamepad-LPM-*.amgp.

Run from the repo root:  python3 tools/gen-gamepad-profiles.py
Layout: Xbox / XInput controller (SDL game controller numbering used by AntiMicroX:
buttons 1 A, 2 B, 3 X, 4 Y, 5 Back, 7 Start, 8 L3, 9 R3, 10 LB, 11 RB; sticks 1 = left,
2 = right, stick directions 1 up, 3 right, 5 down, 7 left; d-pad 1 up, 2 right, 4 down,
8 left; triggers 5 = LT, 6 = RT). Key codes are Qt key codes, as written by AntiMicroX itself
(letters = ASCII capital, 0x20 space, 0x1000000 and up for special keys); mouse movement 1 up,
2 down, 3 left, 4 right; mouse buttons 1 left, 3 right.

Every keyboard profile exists twice: WASD (QWERTY) and ZQSD (AZERTY: Z and Q replace W and A; the
keys are sent by letter, so they follow the keyboard layout in use).
Key choices follow the defaults common to PC games (WASD, Space jump, Shift sprint, Ctrl crouch,
E use, R reload, Tab inventory, 1-4 weapon slots, left click fire / right click aim ...), see
the sources in the commit message / docs. The 2D platformer profile follows Hollow Knight's
defaults (arrows, Z jump, X attack, C dash).
"""
import os
from xml.sax.saxutils import escape

K = {c: ord(c) for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"}
K.update({"Space": 0x20, "Esc": 0x1000000, "Tab": 0x1000001, "Return": 0x1000004,
          "Left": 0x1000012, "Up": 0x1000013, "Right": 0x1000014, "Down": 0x1000015,
          "Shift": 0x1000020, "Ctrl": 0x1000021})
BUTTON = {"A": 1, "B": 2, "X": 3, "Y": 4, "Back": 5, "Start": 7, "L3": 8, "R3": 9, "LB": 10, "RB": 11}
DIRS = {"up": 1, "right": 3, "down": 5, "left": 7}          # stick directions
DPAD = {"up": 1, "right": 2, "down": 4, "left": 8}          # d-pad directions
MOUSE_MOVE = {"up": 1, "down": 2, "left": 3, "right": 4}
HEADER = """<?xml version="1.0" encoding="UTF-8"?>
<gamecontroller configversion="19" appversion="3.6.1">
    <stickAxisAssociation index="1" xAxis="1" yAxis="2"/>
    <stickAxisAssociation index="2" xAxis="3" yAxis="4"/>
    <vdpadButtonAssociations index="1">
        <vdpadButtonAssociation axis="0" button="12" direction="1"/>
        <vdpadButtonAssociation axis="0" button="13" direction="4"/>
        <vdpadButtonAssociation axis="0" button="14" direction="8"/>
        <vdpadButtonAssociation axis="0" button="15" direction="2"/>
    </vdpadButtonAssociations>
    <names>
        <controlstickname index="1">Stick 1</controlstickname>
        <controlstickname index="2">Stick 2</controlstickname>
    </names>
"""


def slot(kind, code):
    # kind: key | move | click
    mode = {"key": "keyboard", "move": "mousemovement", "click": "mousebutton"}[kind]
    code = ("0x%x" % code) if kind == "key" else str(code)
    return "<slots><slot><code>%s</code><mode>%s</mode></slot></slots>" % (code, mode)


def key(name):
    return ("key", K[name])


def build(spec):
    """spec: dict with optional 'lstick', 'rstick' ({dir: (kind, code)}), 'dpad', 'buttons',
    'triggers' ({'LT': ..., 'RT': ...})."""
    out = [HEADER, "    <sets>\n        <set index=\"1\">\n"]
    for idx, name in ((1, "lstick"), (2, "rstick")):
        if name in spec:
            out.append("            <stick index=\"%d\">\n" % idx)
            for d, (kind, code) in spec[name].items():
                out.append("                <stickbutton index=\"%d\">%s</stickbutton>\n" % (DIRS[d], slot(kind, code)))
            out.append("            </stick>\n")
    if "dpad" in spec:
        out.append("            <dpad index=\"1\">\n")
        for d, (kind, code) in spec["dpad"].items():
            out.append("                <dpadbutton index=\"%d\">%s</dpadbutton>\n" % (DPAD[d], slot(kind, code)))
        out.append("            </dpad>\n")
    for trig, tidx in (("LT", 5), ("RT", 6)):
        if trig in spec.get("triggers", {}):
            kind, code = spec["triggers"][trig]
            out.append("            <trigger index=\"%d\">\n                <deadZone>2000</deadZone>\n"
                       "                <throttle>positivehalf</throttle>\n"
                       "                <triggerbutton index=\"2\">%s</triggerbutton>\n            </trigger>\n"
                       % (tidx, slot(kind, code)))
    for b, (kind, code) in spec.get("buttons", {}).items():
        out.append("            <button index=\"%d\">%s</button>\n" % (BUTTON[b], slot(kind, code)))
    out.append("        </set>\n    </sets>\n</gamecontroller>\n")
    return "".join(out)


def wasd(layout):
    up, left = ("W", "A") if layout == "WASD" else ("Z", "Q")
    return {"up": key(up), "left": key(left), "down": key("S"), "right": key("D")}


MOUSE = {"up": ("move", 1), "down": ("move", 2), "left": ("move", 3), "right": ("move", 4)}
ARROWS = {"up": key("Up"), "down": key("Down"), "left": key("Left"), "right": key("Right")}
SLOTS = {"up": key("1"), "right": key("2"), "down": key("3"), "left": key("4")}
CLICKS = {"LT": ("click", 3), "RT": ("click", 1)}   # right click / left click


def profiles():
    result = {}
    for layout in ("WASD", "ZQSD"):
        move = wasd(layout)
        result["FPS-" + layout] = {
            "lstick": move, "rstick": MOUSE, "dpad": SLOTS, "triggers": CLICKS,
            "buttons": {"A": key("Space"), "B": key("Ctrl"), "X": key("E"), "Y": key("R"),
                        "L3": key("Shift"), "LB": key("G"), "Start": key("Esc"), "Back": key("Tab")}}
        result["Action3D-" + layout] = {
            "lstick": move, "rstick": MOUSE, "dpad": SLOTS, "triggers": CLICKS,
            "buttons": {"A": key("Space"), "B": key("Ctrl"), "X": key("E"), "Y": key("C"),
                        "L3": key("Shift"), "Start": key("Esc"), "Back": key("Tab")}}
        result["RPG-" + layout] = {
            "lstick": move, "rstick": MOUSE, "dpad": SLOTS, "triggers": CLICKS,
            "buttons": {"A": key("Space"), "B": key("Esc"), "X": key("E"), "Y": key("I"),
                        "LB": key("M"), "RB": key("J"), "L3": key("Shift"), "Start": key("Esc"), "Back": key("Tab")}}
        result["Simulation-" + layout] = {
            "lstick": move, "rstick": MOUSE, "dpad": SLOTS, "triggers": CLICKS,
            "buttons": {"A": key("Space"), "X": key("E"), "Y": key("Tab"), "L3": key("Shift"),
                        "Start": key("Esc")}}
        up, left = ("W", "A") if layout == "WASD" else ("Z", "Q")
        # Racing: steer with the stick (left/right), RT accelerates, LT brakes.
        result["Course-" + layout] = {
            "lstick": {"left": key(left), "right": key("D")},
            "triggers": {"RT": key(up), "LT": key("S")},
            "buttons": {"A": key("Space"), "B": key("Shift"), "Start": key("Esc")}}
    result["Strategie"] = {
        "lstick": MOUSE, "rstick": ARROWS, "dpad": SLOTS, "triggers": CLICKS,
        "buttons": {"A": key("Space"), "Start": key("Esc")}}
    result["Souris"] = {
        "lstick": MOUSE, "dpad": ARROWS,
        "buttons": {"A": ("click", 1), "B": ("click", 3), "Start": key("Esc")}}
    result["Plateforme2D"] = {
        "lstick": ARROWS, "dpad": ARROWS,
        "triggers": {"RT": key("E")},
        "buttons": {"A": key("Z"), "X": key("X"), "B": key("C"), "Y": key("A"), "RB": key("S"),
                    "LB": key("D"), "L3": key("I"), "Start": key("Esc"), "Back": key("Tab")}}
    return result


def main():
    dest = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "data")
    for name, spec in profiles().items():
        path = os.path.join(dest, "gamepad-LPM-%s.amgp" % name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(build(spec))
        print(path)


if __name__ == "__main__":
    main()
