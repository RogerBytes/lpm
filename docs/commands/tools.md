# ludis tools

Runs a Wine maintenance tool (winetricks, regedit, winecfg, console, any .exe, folder, favorite folder, environment variables), changes the runner or switches the MangoHud FPS overlay of one installed game inside the prefix of one installed game.

## Synopsis

```
ludis tools <slug> winetricks
ludis tools <slug> regedit
ludis tools <slug> winecfg
ludis tools <slug> console
ludis tools <slug> exe <file.exe>
ludis tools <slug> folder
ludis tools <slug> favorite <directory>
ludis tools <slug> env list
ludis tools <slug> env set <KEY> <VALUE>
ludis tools <slug> env unset <KEY>
ludis tools <slug> env apply <file>
ludis tools <slug> runner <runner-name>
ludis tools <slug> mangohud [on|off|status]
ludis tools <slug> overlay [status|follow|on|off|global-on|global-off]
ludis tools <slug> gamepad [on|off|edit|status]
ludis tools <slug> game-version [<value>|--clear]
```

## Description

Mimics what Lutris does for its own Wine menu: the tool runs with the Wine binary of the runner configured **for that game** (the `wine.version` of its Lutris YAML), the game's prefix as `WINEPREFIX`, and a `WINEDLLOVERRIDES` rebuilt from the game's Wine overrides (with `winemenubuilder` always disabled). GUI tools are started detached in the background: the command returns immediately.

Both the slug and the tool are mandatory: there is no interactive menu (although `ludis --help` and the man page show them in brackets). Unlike `pack` or `uninstall`, games in shared store prefixes (Epic, EA, Ubisoft...) are accepted.

## Arguments

- `<slug>` : Lutris slug of an installed Wine game (only its last path component is used).
- `<tool>` : one of `winetricks`, `regedit`, `winecfg`, `console`, `exe`, `folder`, `favorite`, `env`, `runner`, `mangohud`, `overlay`, `gamepad`, `game-version`.
- Further arguments depend on the tool (below).

## Options

None. (`bin/ludis` generic options are not relevant; `-y` etc. are only consumed when placed right after `tools`, before the slug, and are then ignored.)

## Behavior

Common steps:

1. Needs a slug and a tool, otherwise prints the usage and exits 1. Needs `sqlite3`.
2. Resolves Lutris (Flatpak or native) and reads `pga.db`. If the database is missing: "Error: no installed game found in `<games dir>`." (exit 1).
3. Looks up the slug among Wine games; unknown slug: error, exit 1.
4. Resolves the prefix folder (the `directory` of the game). It must exist and be located inside the Lutris games folder (`~/Games` or `game_path:` of `system.yml`), otherwise "the prefix folder for '<name>' could not be found" (exit 1).
5. Reads the game's YAML (needs python3 + PyYAML): `wine.version`, `wine.system_winetricks`, `wine.overrides`. Without a configured version, the default runner is used: the `version:` of Lutris' `runners/wine.yml`, else `proton-cachyos-x86_64`.
6. Locates `<runners>/wine/<version>/bin/wine` (or `.../files/bin/wine`). If absent: "the Wine runner '<version>' configured for this game is no longer installed (ludis install-runner to reinstall it)", exit 1. **This check happens for every tool except `runner`, including `folder` and `env`**, and before the tool name is validated.
7. Runs the requested tool.

Tools:

- `winetricks` : uses Lutris' bundled `winetricks` (`<lutris data>/runtime/winetricks/winetricks`), unless the game enables `system_winetricks` or the bundled one is missing, in which case `winetricks` from `PATH` is used (error if none). Runs with `WINEPREFIX`, `WINE=<game's wine>`, `WINEDLLOVERRIDES`. Refuses to start if a winetricks is already running for this same prefix.
- `regedit` : `wine regedit.exe` in the prefix; refuses if a regedit is already running for this prefix.
- `winecfg` : `wine winecfg.exe`; refuses if already running for this prefix.
- `console` : `wine wineconsole cmd`, started from `<prefix>/drive_c` (or the prefix root if `drive_c` is missing).
- `exe <file>` : `wine <file>` in the prefix. The file must exist (path as seen from the host, absolute or relative to the current directory). Missing/empty argument: "Error: file not found: ...".
- `folder` : opens the prefix folder with `xdg-open`.
- `favorite <directory>` : adds the real Linux directory as the first slot (`Place0`) of the classic Windows Open/Save dialogs' places bar of this prefix. The path is converted with `winepath -w` (the `winepath` next to the game's wine, else the one in `PATH`), then written with `wine reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Comdlg32\Placesbar" /v Place0 /t REG_SZ /d <path> /f`. `Place0` is overwritten at every use; the other slots are never touched. The directory must exist.
- `env <action>` : edits the game's environment variables (`system.env` in its Lutris YAML) through text-level editing that preserves YAML comments. Needs python3 + PyYAML and an existing YAML config for the game.
  - `env list` : prints one `KEY=VALUE` line per variable (nothing if there are none).
  - `env set <KEY> <VALUE>` : adds or replaces one variable. `KEY` must match `[A-Za-z_][A-Za-z0-9_]*`; `VALUE` may be empty (`env set KEY ""` stores an empty string) but must contain no newline; the value argument itself is required (`env set KEY` alone fails with the editor's usage message, exit 1). Values are stored as quoted strings.
  - `env unset <KEY>` : removes one variable (succeeds even if absent).
  - `env apply <file>` : **replaces the whole `system.env`** by the variables of the file: one `KEY=VALUE` per line (split at the first `=`, key trimmed, value kept as is), blank lines ignored, no comment syntax. Variables not in the file are removed.
  - The result is re-parsed before writing; on any mismatch nothing is changed. The file is replaced atomically with the original permissions.
- `runner <name>` : changes the runner of the game, i.e. sets `wine.version` in its Lutris YAML (comments are preserved, the file is replaced atomically). `<name>` must be the name of an installed runner as printed by `ludis list-runner`; a name containing `/` or starting with `.` is refused. **This tool is handled right after step 3 (slug lookup), before steps 4 to 6**: it works even when the runner currently configured for the game is no longer installed (the usual reason to change it), and it needs neither the prefix nor the old runner. Only the YAML is changed; the prefix is not touched. Close Lutris first, or it may overwrite the change.
- `mangohud [on|off|status]` : MangoHud (FPS overlay) for this game, i.e. the Lutris option `system.mangohud` of its YAML (comments preserved). `on` sets it to `true`, `off` removes the key (Lutris default: off), `status` (the default) prints `on` or `off`. Like `runner`, handled before the prefix and runner checks: only the YAML is changed. ludis does not install MangoHud: if it cannot be found (native Lutris: no `mangohud` in `PATH`; Flatpak Lutris: no `org.freedesktop.Platform.VulkanLayer.MangoHud`), `on` still saves the setting and prints a warning on stderr saying it has no effect until MangoHud is installed. Close Lutris first, or it may overwrite the change.
- `overlay [status|follow|on|off|global-on|global-off]` : FPS overlay (MangoHud) of the in-game Ludis menu, not the Lutris option above. When enabled, MangoHud is loaded hidden when the game starts and shown or hidden from the in-game menu (the menu entry is there even when it is off, to turn it on for the next launch). `on`/`off` force it for this game, `follow` (default) uses the global setting (**off** by default), `global-on`/`global-off` change that global setting. Stored in ludis's own files (the game's `ludis` folder and `menu.conf`), never in the Lutris config. `status` (the default) prints `game=<follow|on|off> global=<on|off>`. The menu entry only appears if MangoHud is installed (Vulkan games).
- `gamepad [on|off|edit|status]` : AntiMicroX profile for this game, i.e. the Lutris option `system.antimicro_config` of its YAML (Lutris then starts AntiMicroX with that profile when the game runs). `on` creates a blank profile `<prefix>/ludis/gamepad/lpm-gamepad.gamecontroller.amgp` only if it does not exist yet (an existing profile is never overwritten) and points the option to it. `off` removes the option only if it points to that profile; the profile file is kept. `edit` opens that profile in AntiMicroX (native `antimicrox`/`antimicro`, or the Flatpak `io.github.antimicrox.antimicrox`) and returns at once, nothing is watched. `status` (the default) prints `on`, `off`, or `other` when `antimicro_config` points to a profile that is not ludis's: that one is never replaced or removed, `on` and `off` then fail with an error and leave it alone. Handled before the prefix and runner checks like `mangohud`, except that the prefix folder must be found. ludis does not install AntiMicroX; if it cannot be found, `on` warns on stderr but still saves.
- `game-version [<value>|--clear]` : shows, sets or removes the version number of the game, stored in `<prefix>/ludis/settings/game-version`. Same as [`ludis game-version`](game-version.md), which documents the accepted values. Only the prefix's own file is changed, not the Lutris YAML.

## Output

```
Launched for Foo Game.
Favorite folder saved for Foo Game: /home/me/Music
Environment variables of 'Foo Game' saved.
Runner of 'Foo Game' changed to 'GE-Proton10-1'.
```

`env list` prints raw `KEY=VALUE` lines on stdout.

Errors (stderr):

```
Usage: ludis tools <slug> <winetricks|regedit|winecfg|console|exe|folder|favorite|env|runner|mangohud|overlay|gamepad> [path|action|runner] [key|file] [value]
Error: no installed game with slug '<slug>'.
Error: the prefix folder for '<name>' could not be found.
Error: the Wine runner '<version>' configured for this game is no longer installed (ludis install-runner to reinstall it).
Error: unknown tool '<tool>' (expected: winetricks, regedit, winecfg, console, exe, folder, favorite, env, runner, mangohud, overlay or gamepad).
Error: winetricks could not be found, neither bundled by Lutris nor installed on the system.
Already running for '<name>'.
Error: file not found: <path>
Error: folder not found: <path>
Error: cannot find "winepath" (neither next to this game's Wine runner, nor in PATH).
Error: could not convert path <path> to a Windows path.
Error: writing to the Wine registry failed.
Error: the Lutris configuration for '<name>' could not be found.
Error: python3 with PyYAML is required for environment variables.
Error: unknown action '<action>' (expected: list, set, unset or apply).
Error: unknown overlay action '<action>' (expected: status, follow, on, off, global-on or global-off).
Error: could not save the environment variables of '<name>' (configuration unchanged).
Error: give the name of an installed runner (see 'ludis list-runner').
Error: the runner '<name>' is not installed (see 'ludis list-runner', or 'ludis install-runner').
Error: could not change the runner of '<name>' (configuration unchanged).
```

For `env set/unset/apply` failures, the reason (for example `invalid variable name: 1BAD` or the editor's usage line) is printed by the editor just before the "could not save" line.

## Exit status

- `0` : the tool was launched / the operation succeeded. For detached GUI tools this only means "started", not that the tool ended well.
- `1` : usage error, missing Lutris/database/game/prefix/runner, unknown tool, tool-specific failure (already running, file or folder not found, winepath/registry failure, env error).

## Scripting notes

- No confirmation and no interactive prompt, except the dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`) when Lutris exists in both forms and nothing was saved: avoid it with `LUDIS_LUTRIS_VERSION=flatpak|native` or `ludis lutris-version`. With EOF it selects and saves Flatpak.
- `winetricks`, `regedit`, `winecfg`, `console`, `exe` and `folder` start GUI programs and return at once with all output discarded; they need a graphical session.
- `env set KEY ""` stores an empty value. (`env apply` with a file line `KEY=` also does, but it replaces the whole environment.) A comment line (`# ...`) in an `apply` file is an error ("invalid line (expected KEY=VALUE)"); a missing file produces a Python traceback followed by the "could not save" line.
- `env list` output is stable and parseable (`KEY=VALUE`, one per line; values with `=` are kept whole after the first `=`).
- `env apply` is destructive for variables not listed; run `env list > backup.env` first, then reuse the file with `apply`.
- A successful `env unset` of a non-existent key still prints "Environment variables ... saved."

## Examples

```
ludis tools my-game winecfg
ludis tools my-game winetricks
ludis tools my-game exe "$HOME/Downloads/vcredist_x64.exe"
ludis tools my-game favorite "$HOME/Music"
ludis tools my-game folder
ludis tools my-game runner GE-Proton10-1
ludis tools my-game env list
ludis tools my-game env set DXVK_HUD fps
ludis tools my-game env unset DXVK_HUD
ludis tools my-game env list > my-game.env && ludis tools my-game env apply my-game.env
```

## Files and data touched

- Read: Lutris `pga.db`, `system.yml`, the game's YAML, `runners/wine.yml`, the runner folder, `/proc/<pid>/environ` (running-instance check).
- Written by Wine inside the prefix (registry, installed software) for the Wine tools; `HKCU\...\Comdlg32\Placesbar\Place0` for `favorite`.
- `env set|unset|apply`: the game's Lutris YAML (`~/.config/lutris/games/<configpath>.yml` native, `~/.var/app/net.lutris.Lutris/data/lutris/games/<configpath>.yml` Flatpak), via a temporary `.ludis-env-*` file in the same folder.
- `game-version`: `<prefix>/ludis/settings/game-version`.
- `~/.local/share/ludis/ludis.log` (error lines only).

## See also

`ludis list`, `ludis info`, `ludis install-runner`, `ludis killwine`, `ludis lutris-version`
