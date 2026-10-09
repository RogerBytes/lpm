# lpm shortcut

(Re)generates the application-menu and/or desktop shortcuts (`.desktop` files) of games that are already registered in Lutris.

## Synopsis

```
lpm shortcut [options] <slug>... 
lpm shortcut [options] --all
```

Options: `-s|--shortcut=<menu|desktop|both|none>`, `-n|--no-loadingscreen`, `-k|--allow-hooks`, `--desktop-dir=<path>`.

## Description

For each selected game, `lpm shortcut` writes a `.desktop` launcher whose `Exec=` line points to lpm's launcher orchestrator (`lib/zgl-launcher-orchestrator.sh <lutris game id> <package|flatpak>`), so that the game starts through lpm's loading screen and then through Lutris. It is useful to refresh a shortcut after changing a game's icon (`lpm icon`), or for a Wine game that was added to Lutris by some other means than lpm.

The command only handles Wine games (`runner='wine'` in Lutris' database). Games that live in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect, Battle.net, Steam, or several Lutris entries sharing one directory) are never processed. The store names are matched as whole words in the game name ("Steam" or "Steam Client" are excluded, "SteamWorld Dig" is not); see [`lpm list`](list.md).

It also (re)applies two per-game settings at the same time: the loading-screen marker file and the launch-hook policy (see Behavior).

## Arguments

- `<slug>...` : one or more Lutris game slugs (see `lpm list`).
- `--all` : every eligible Wine game. It is only recognised as the **first** target; placed after a slug it is treated as a slug named `--all` and fails with "Game not found".

Options may be mixed freely with the targets.

## Options

| Option | Effect |
| --- | --- |
| `-s MODE`, `--shortcut MODE`, `--shortcut=MODE` | Where to write shortcuts: `menu`, `desktop`, `both` (default) or `none`. Any other value is rejected. With the separate-word form, the value is the next argument. |
| `-n`, `--no-loadingscreen` | Disable lpm's loading screen for the selected game(s): creates the empty marker file `<game dir>/.lpm-no-loadingscreen`. Without `-n`, the marker is removed (loading screen enabled). |
| `-k`, `--allow-hooks` | Allow the Lutris launch hooks already configured for the game(s). Without `-k` they are neutralised (see Behavior). |
| `--desktop-dir=<path>` | Folder where the desktop shortcut is written instead of the auto-detected desktop folder. Only the `=` form exists. No effect when the mode is `menu` or `none`. |

`-y`, `--allow-scripts`, `--ignore-hash`, `--hash` and `-<level>` are parsed by `bin/lpm` but have no effect here (no confirmation is ever asked). Note that `bin/lpm` only consumes them when they come right after `shortcut`.

## Behavior

1. Checks that `sqlite3` is installed, then resolves which Lutris to use (Flatpak or native, see Scripting notes) and reads Lutris' `pga.db`. The games folder is `~/Games` unless `game_path:` is set in Lutris' `system.yml`.
2. Lists Wine games, excluding shared-store prefixes. If none: prints "No Wine game found in the Lutris database." on stderr and exits 0.
3. Validates **all** targets before writing anything: the first unknown or excluded slug aborts the whole run with exit status 1 (nothing was created for the previous slugs either).
4. For each game (in name order for `--all`, in the given order otherwise):
   - Icon: the first `*.png`, `*.ico`, `*.svg` or `*.xpm` found in `<game dir>/icon/`; otherwise the generic icon name `lpm-game-generic`.
   - Window class: `StartupWMClass` is the file name of the game's executable recorded in Lutris. For a Proton runner (a `toolmanifest.vdf` exists in the runner folder) and when python3 with PyYAML is available, lpm instead uses `steam_app_<game id>` and, if the game's Lutris YAML has no `system.env.GAMEID`, **adds** `GAMEID: umu-<game id>` to it.
   - Menu shortcut: if the mode includes the menu, writes `~/.local/share/applications/net.lutris.<slug>.desktop` and runs `update-desktop-database` (errors ignored). If the mode does not include the menu and that file exists, it is **deleted**.
   - Desktop shortcut: if the mode includes the desktop, writes `<desktop dir>/<slug>.desktop`, makes it executable and marks it trusted with `gio` (errors ignored). It is silently skipped if the desktop folder does not exist. If the game has an `extras/` folder, a symlink `<Game name> Bonus` to it is (re)created next to the shortcut. A desktop shortcut is never deleted by this command, even with `-s menu` or `-s none`.
   - Desktop folder auto-detection: `xdg-user-dir DESKTOP` (when it is not `$HOME`), else `~/Bureau`, else `~/Desktop`, else `$HOME`.
   - Loading-screen marker: created (`-n`) or removed (no `-n`) in the game directory.
   - Hook policy: if the game has a Lutris YAML (`configpath`), then without `-k` every line whose key is `prelaunch_command`, `prelaunch_wait` or `postexit_command` is commented out and tagged `# lpm:hook-disabled (...)`; with `-k` lines previously tagged are restored. Exception: if `prelaunch_command` ends with `/scripts/lpm-launcher.sh` (the relay installed by `lpm launcher ... on`), hooks are treated as allowed, so nothing is disabled. The `# lpm:hook-disabled` comments are kept intact by [`lpm lsfg`](lsfg.md) and [`lpm launcher`](launcher.md), which edit the YAML line by line.
   - Prints the confirmation line (also when the mode is `none`).

## Output

All on stdout, one line per game:

```
Shortcut created for 'Foo Game'.
```

Errors (stderr, red on a terminal, also logged in `lpm.log`):

```
Error: invalid value "bogus" for --shortcut (accepted values: menu, desktop, both, none).
Error: Game not found in Lutris with slug: nosuch
Error: 'name' is part of a shared store prefix (Epic Games Store, EA App, Ubisoft Connect...) and is not managed by lpm.
Error: 'sqlite3' is not installed on this system.
Error: Lutris is not installed on this system.
Error: Lutris database not found: <path>
No Wine game found in the Lutris database.
```

Messages follow the system language (`LC_ALL`, `LC_MESSAGES`, `LANG`); use `LC_ALL=C` to get the English text above.

## Exit status

- `0` : success, including "no Wine game in the database".
- `1` : no target given (neither a slug nor `--all`), invalid `--shortcut` value, `sqlite3` missing, Lutris missing, Lutris database missing, unknown or excluded slug.

## Scripting notes

- No confirmation prompt exists. The only possible prompt is the dual-Lutris question: when Lutris is installed both as Flatpak and natively, with no saved choice, lpm asks `Use [1] Flatpak (default) or [2] the native package? :`. Avoid it with `LPM_LUTRIS_VERSION=flatpak` or `LPM_LUTRIS_VERSION=native` in the environment, or once with `lpm lutris-version flatpak|native` (saved in `~/.config/lpm/lutris-version`). With empty stdin / no TTY the answer is empty, which selects Flatpak and **saves** that choice.
- Running with no target and no `--all` prints `nothing to do, no target given` and exits 1.
- `-s` or `--shortcut` given as the very last argument (no value) uses the default mode `both`.
- A non-existent `--desktop-dir` is silently ignored (no desktop file, still exit 0).
- Re-running without `-n` re-enables the loading screen and re-neutralises hooks: pass the same `-n`/`-k` every time.
- Stable output: the `Shortcut created for '<name>'.` lines (name, not slug).

## Examples

```
lpm shortcut my-game
lpm shortcut --all
lpm shortcut --shortcut=menu my-game other-game
lpm shortcut -s desktop --desktop-dir="$HOME/Desktop" my-game
lpm shortcut -n -k my-game
LPM_LUTRIS_VERSION=native LC_ALL=C lpm shortcut --all
```

## Files and data touched

- Read: Lutris `pga.db`, `system.yml`, game YAML (`~/.config/lutris/games/<configpath>.yml` native, `~/.var/app/net.lutris.Lutris/data/lutris/games/` Flatpak), runner folder.
- Written: `~/.local/share/applications/net.lutris.<slug>.desktop`, `<desktop dir>/<slug>.desktop`, `<desktop dir>/<Name> Bonus` symlink, `<game dir>/.lpm-no-loadingscreen`, the game's Lutris YAML (hook comments, possibly `GAMEID`), `~/.local/share/lpm/lpm.log` (errors).

## See also

`lpm icon`, `lpm launcher`, `lpm list`, `lpm lutris-version`, `lpm install`
