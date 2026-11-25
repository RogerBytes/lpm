# lpm launcher

Enables or disables the LPM Launcher (a multi-executable picker run before each launch) for one or more installed Wine/Proton games, or lists the games that have it enabled.

## Synopsis

```
lpm launcher <slug>... on  [--if-needed]
lpm launcher <slug>... off [--if-needed]
lpm launcher status
```

## Description

With the LPM Launcher enabled, the lpm shortcut of the game (menu, desktop or any folder) reads the game's `lpm/launcher.yml` at every launch, writes `lpm-launch.bat` with the entry to run, and only then starts Lutris. There is no relay script and no Lutris prelaunch command. The menu therefore exists only when the game is started from an lpm shortcut; started from Lutris itself, the game runs the last chosen entry. With a single entry the game starts directly; with several entries (episodes, DLC, bonus content...) a picker lets the player choose which executable to run. On the loading screen, the label of the chosen entry is shown as a subtitle under the game name, except when it is exactly the game name (strict comparison): then there is no subtitle. The entries are therefore never fixed at activation time; edit `lpm/launcher.yml` by hand or with `lpm launcher-entries`.

Enabling is independent of lpm's loading screen (`lpm shortcut -n`, `lpm splash`, `lpm logo`): those work with or without the launcher.

Only Wine/Proton games (`runner='wine'`) are handled; shared store prefixes are included.

The action word (`on`/`off`) must be the last argument (ignoring `--if-needed`) and at least one slug is required. `status` is only accepted as the single argument. There is no interactive game selection.

## Arguments

- `<slug>...` : Lutris slugs.
- `on` | `off` : the action.
- `status` : alone; prints the slugs that currently have the launcher enabled.

## Options

| Option | Effect |
| --- | --- |
| `--if-needed` | Anywhere among the arguments. A game that is already in the requested state is silently skipped instead of causing an error. (Not listed in `lpm --help`.) |

## Behavior

Common to all forms: needs `python3`, `sqlite3` and PyYAML; resolves Lutris (Flatpak or native); reads `pga.db`. If there is no Wine game: "No Wine/Proton games found." on stderr, exit 0.

A game counts as **enabled** when its Lutris YAML has `game.exe` whose file name is `lpm-launch.bat`. This is re-read at each call; there is no separate state file.

**Games of lpm 0.9.5 and earlier** used a relay `scripts/lpm-launcher.sh` run by a Lutris `prelaunch_command`. They still count as enabled and are converted automatically: at their first launch from an lpm shortcut, when `lpm launcher <slug> on` is run, or when a package made then is installed, lpm removes that prelaunch command (only if it is the relay; a command of yours is never touched), deletes the relay, and aligns `bat_path` of `lpm/launcher.yml` on the `game.exe` of Lutris. This conversion is permanent: old packages can be installed years later.

`status`: prints the slug of every enabled game, one per line, in game-name order, and exits 0. Changes nothing.

`on` / `off`: all slugs are validated first. Unknown slug -> error, exit 1. Game already enabled (`on`) or not enabled (`off`) -> error, exit 1, unless `--if-needed` was given (then that game is skipped). Nothing is modified if validation fails.

Enabling a game (`on`):

1. Reads the game's current `game.exe`, `working_dir` (default: the exe's folder), `game.prefix` (default: game dir) and `wine.version` from its Lutris YAML. No executable: error "has no executable currently configured in Lutris".
2. Converts the exe and working directory to Windows paths. A path inside the prefix's `drive_c` is converted as plain text (`.../drive_c/Games/x.exe` becomes `C:\Games\x.exe`), so no Wine process is started and no Wine window can appear. Only a path outside `drive_c` uses `winepath -w` (the one next to the game's wine runner, else `winepath` from `PATH`). Failure: error "could not resolve the Windows path".
3. Writes `lpm-launch.bat` in `<prefix>/drive_c/Games/<top folder of the exe>/` (or, if the exe is not under `drive_c/Games/`, in the working directory; a warning is logged). It `cd`s to the working directory and `start`s the exe.
4. Creates `<game dir>/lpm/launcher.yml` **only if it does not exist yet**, containing `title` (game name), `prompt`, `original_exe`, `bat_path`, one auto-filled entry (label `Launch`) and a commented example entry. An existing file (and your entries) is never overwritten (`off` deletes it, so this only concerns a hand-written or restored file); only `bat_path` (always) and `original_exe` (unless `game.exe` already points to an `lpm-launch.bat`) are brought up to date in it, because they are absolute paths of this machine and a hand-written or imported file may lack them. The shortcut also aligns `bat_path` on the `game.exe` of Lutris at each launch.
5. Edits the game's Lutris YAML line by line (helper `lib/zgu-yaml-edit.py`): `game.exe` = the `lpm-launch.bat` path. Nothing else: no relay, no prelaunch command. YAML comments, including `# lpm:hook-disabled` lines, are preserved. Only if this targeted edit is impossible does lpm fall back to rewriting the whole file with PyYAML (`yaml.dump`), which loses the comments.
6. Removes an old-format relay if the game still has one (see above).
7. Prints `<name>: enabled. Edit <game dir>/lpm/launcher.yml to add or change entries.`

Disabling a game (`off`):

1. Needs `<game dir>/lpm/launcher.yml` with an `original_exe`; otherwise errors "lpm/launcher.yml not found for ..." or "no original executable saved for ..." (game left untouched).
2. Sets `game.exe` back to `original_exe`. If that key is missing (hand-written file), the exe of the first menu entry is used (only a `C:\...` path can be converted) and a message says so; with no usable entry: "no original executable saved". Removes `system.prelaunch_command` and `system.prelaunch_wait` only if the command contains `scripts/lpm-launcher.sh` (old format). The YAML is edited line by line as for `on` (comments preserved), with the same PyYAML-rewrite fallback.
3. Then **deletes the files the launcher added**, by name: `lpm/launcher.yml` (the entries go with it, a later `on` starts from a fresh file), `scripts/lpm-launcher.sh` (old format), every `lpm-launch.bat` (the one of `bat_path`, the one at the game folder root, those of `drive_c/Games/*/`) and the temporary `lpm/.launcher-choice`. The old `scripts/` folder is removed only if it is then empty, and the `lpm/` folder only if nothing is left in it. Never touched: the game's files, any other file of the prefix, `lpm/images/` (splash, logo, icon), `lpm/settings/`, and the other files of `lpm/scripts/` (loading screen). No confirmation is asked.
4. Prints `<name>: disabled.`

A per-game failure is reported and the other games continue; the final status is 1 if any failed.

## Shortcuts and LPM menu while the game runs

When the LPM Launcher is enabled, two small watchers run for the whole play session. They read the pad through SDL2 without grabbing it, so the game and tools like AntiMicroX keep working, and they stop by themselves a few seconds after the game ends. Keys are sent with `xdotool` on X11 and `ydotool` on Wayland (which needs its `ydotoold` service).

**Window switch** (`lib/zgu-gamepad-alttab-watcher.py`): hold **L1 + L2 + R1 + R2 + R3**, then D-pad left / right sends Shift+Tab / Tab, as with Alt held: the window switcher moves back / forward. Releasing the combo validates the selection.

**Shortcuts while holding the window-switch combo**: D-pad down opens the virtual keyboard (it appears at the bottom; the same shortcut closes it again), D-pad up turns the gamepad mouse on or off (same as the two menu entries).

**LPM menu** (`lib/zgu-gamepad-exit-watcher.py` opens `lib/zgu-game-menu.py`): press **L1 + L2 + R1 + R2 + L3 + R3** together (or **Ctrl+Shift+M** on the keyboard; pressed again while the virtual keyboard is open, it closes the virtual keyboard instead) and a menu appears over the game. The game is not paused. Move with the D-pad (or the arrows), validate with A (or Enter or a click), go back with B (or Esc). The menu closes by itself when it loses the focus (a click on the game, Alt+Tab...) and when the game ends.

| Entry | Does |
|---|---|
| Window › | Alt+Enter, F4 (alone), F11: the key is sent to the game once the menu is closed. (Alt+Tab stays the hold combo above.) |
| Virtual keyboard | Opens an on-screen keyboard (keys in the real order, aligned in columns so up / down lands on the key above or below) driven by the pad (D-pad / left stick to move, A key, B Backspace, X Space, Y Shift (held: shift lock for letters, Y again to release), Start Enter, L1/R1 cursor left/right, Select closes; the keyboard hotkey, Ctrl+Shift+M, closes it too and is shown at the bottom of the keyboard). On X11 the keyboard never takes the focus away from the game (window hints, works with any window manager), so a key is sent at once with no flicker; if the focus ends up on the keyboard, it is given back to the game before each key. On Wayland the keyboard window is started as an X11 window (XWayland, when available; the keys are still sent the Wayland way, so native Wayland games get them) and the same method is tried. If the compositor gives the focus to the keyboard anyway (it cannot be given back to a native Wayland game), or without XWayland, the keyboard hides for a moment (`keyboard_delay_ms`), the key is sent to the game, and the keyboard comes back. Labels follow the real layout (AZERTY...), read through GDK on X11 and Wayland; if it cannot be detected a notice is shown and a US layout is used. |
| Gamepad mouse (switch) | Both sticks move the pointer (they add up), A or R2 left click, B or L2 right click, Y middle click, X Enter, L1 / R1 wheel up / down, Start Esc, Select shows the virtual keyboard (Select closes it). A small notice in the top right corner (about 2 s) confirms each on / off (on Wayland the compositor chooses where it goes). While the virtual keyboard or the LPM menu is open the mouse is suspended (a simulated click would close them), and resumes when it closes. The game still receives the pad buttons. |
| FPS overlay: Off / Hidden / On | Three-choice selector (left / right, Enter, or a click on a choice). **Off**: MangoHud is not loaded (the default). **Hidden**: loaded but invisible. **On**: FPS shown (F12 with Right Shift is injected for you). Hidden / On switch at once when MangoHud was loaded at start; otherwise (or when choosing Off while it is loaded) the choice is saved for this game and the entry says "next launch". Saved in `<prefix>/lpm/settings/overlay-fps`; a game without that file follows the global setting (`lpm tools <slug> overlay`, off by default). Listed when MangoHud is installed and keys can be sent (X11, or ydotool on Wayland), and Lutris' own MangoHud option is off (that one is always visible). Vulkan games only. |
| Volume (slider) + Mute (switch) | Machine master volume through `wpctl` (PipeWire) or `pactl`: left / right (D-pad or stick, key arrows) change it by 5 %, up to 100 %. Only listed when one of them is available. |
| Quit the game › | Esc, Alt+F4 (asks for a confirmation, then is sent to the game), or **Force quit the game**: asks for a confirmation, then stops the Wine processes of the game's prefix (like `wineserver -k`). Each one closes the menu. |

The shortcuts are the same for every game and can be changed in `~/.config/lpm/menu.conf` (or `$XDG_CONFIG_HOME/lpm/menu.conf`):

```
gamepad_combo=L1,R1,L2,R2,L3,R3
keyboard_hotkey=ctrl+shift+m
mouse_speed=1.0
keyboard_delay_ms=50
keyboard_mode=auto
overlay_fps=off
```

`overlay_fps=on` loads the FPS overlay (hidden) in every game (default: off; a game can still say otherwise). `keyboard_mode=hide` forces the hide / show method everywhere (if the no-focus keyboard misbehaves on some window manager). `keyboard_hotkey=none` turns the keyboard hotkey off. `backdrop=off` forces the small window: by default (`backdrop=auto`), when the desktop supports transparency, the menu is a fullscreen dark translucent veil (darker toward the edges) with the menu card in the middle, outlined by a thin border and a soft glow (a click on the veil closes it). The keyboard is read from `/dev/input/event*`, the only way that works on X11 and Wayland; if the user cannot read those files (usually group `input`), only the gamepad combo works. The GUI offers to fix that at startup (one system password prompt, then log out and back in): it adds the user to the `input` group. While the loading screen is shown and a pad is detected, a tip at the bottom left shows the two gamepad combos one at a time.

### If a fullscreen game reacts badly to the menu window

Not seen yet; to try in this order (none is implemented, see the header of `lib/zgu-game-menu.py`):

1. **X11**: mark the menu window "always on top" (`_NET_WM_STATE_ABOVE`, sent from outside with libX11 through ctypes, or `wmctrl -i -r <id> -b add,above`). GTK4 removed `set_keep_above()`.
2. **Wayland**: an overlay layer surface (wlr-layer-shell, `gtk4-layer-shell`). Works on KDE and wlroots compositors (sway...), not on GNOME.
3. **Last resort**: `backdrop=off` in `menu.conf` (small window instead of the veil).

## Output

stdout:

```
Foo Game: enabled. Edit /home/me/Games/foo/lpm/launcher.yml to add or change entries.
Foo Game: disabled.
foo
```

(the last line is a `status` line: a slug.) The first two use the display name.

stderr:

```
Usage: lpm launcher <slug...> on|off
Error: the "<cmd>" command is required and was not found.
Error: the PyYAML Python module is required (pip install pyyaml, or your distribution's python3-yaml package).
Error: Lutris was not found on this machine.
Error: Lutris database not found at: <path>
Error: game "<slug>" not found.
Error: the LPM Launcher is already enabled for "<slug>".
Error: the LPM Launcher is not enabled for "<slug>".
Error: Lutris configuration file missing for "<slug>".
Error: "<slug>" has no executable currently configured in Lutris.
Error: could not resolve the Windows path for "<slug>" (winepath unavailable or failed).
Error: could not write lpm/launcher.yml for "<slug>".
Error: could not update the Lutris configuration for "<slug>".
Error: lpm/launcher.yml not found for "<slug>" -- cannot restore the original executable.
Error: no original executable saved for "<slug>".
No Wine/Proton games found.
```


## Exit status

- `0` : success (including `status`, skipped games with `--if-needed`, and "No Wine/Proton games found").
- `1` : usage error, missing dependency, Lutris/database missing, unknown slug, game in the wrong state (without `--if-needed`), or any per-game failure.

## Scripting notes

- Prompts: only the dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`). Avoid the latter with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`.
- Use `--if-needed` to make `on`/`off` idempotent in scripts.
- `status` output is stable: only slugs, one per line, nothing else on stdout.
- With no arguments the command prints a bash "bad array subscript" warning on stderr before the usage message (harmless, exit status 1).
- `LC_ALL=C` forces English messages.

## Examples

```
lpm launcher my-game on
lpm launcher my-game other-game off
lpm launcher my-game on --if-needed
lpm launcher status
```

## Files and data touched

- The game's Lutris YAML (`game.exe`; the old relay's `system.prelaunch_command`/`prelaunch_wait` are removed), edited in place line by line (comments kept).
- `<game dir>/lpm/launcher.yml` (created if missing), `<prefix>/drive_c/Games/<folder>/lpm-launch.bat`.
- `~/.local/share/lpm/lpm.log`.

## See also

`lpm launcher-entries`, `lpm splash`, `lpm logo`, `lpm shortcut`, `lpm lutris-version`
