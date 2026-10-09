# lpm killwine

Immediately kills every running Wine, Winetricks, umu-run and Lutris-launched Proton process, whatever game or prefix they belong to (panic button for a stuck game).

## Synopsis

```
lpm killwine [-y]
```

## Description

Unlike `lpm tools`, which targets one game, `killwine` is deliberately global. It sends `SIGKILL` (signal 9) to the matching processes: unsaved game progress is lost and nothing can be undone. It needs `pgrep`.

## Arguments

None. Any extra argument is ignored.

## Options

| Option | Effect |
| --- | --- |
| `-y` | Skip the confirmation question. It must come **immediately after** `killwine`; after any other argument it is not recognised (and the question is asked). |

## Behavior

1. Checks that `pgrep` exists (otherwise error, exit 1).
2. Unless `-y` was given, prints a warning and asks `Continue? [y/N]`. An answer that is exactly `y`, `Y`, `o` or `O` continues; anything else (including an empty answer or end of input) prints `Cancelled.` and **exits 0** without killing anything.
3. Kills, with `kill -9`, every process whose command line matches one of these names as a path component or command word: `wine`, `wine64`, `wine-preloader`, `wine64-preloader`, `wineserver`, `winetricks`, `umu-run`. The killer script itself and its parent are never killed.
4. Kills the Winetricks helper window: the `.../winetricks.<random>/w.<user>.<pid>/zenity.sh` wrapper and its direct child processes.
5. Kills processes whose command line contains `proton` **and** a path under Lutris' Wine runner folder (`~/.var/app/net.lutris.Lutris/data/lutris/runners/wine` or `~/.local/share/lutris/runners/wine`). Other "proton" programs (VPN, mail...) are left alone.
6. Prints the number of processes killed and, when at least one was killed, also sends a desktop notification with `notify-send` (errors ignored).

Both the Flatpak and the native runner folders are always checked, whichever Lutris is active; no Lutris detection is done.

## Output

```
This will immediately kill every running Wine/Winetricks/umu-run/Proton (Lutris) process. Any unsaved progress will be lost.
Continue? [y/N]
Cancelled.
3 process(es) killed.
No Wine/Proton process running.
```

Error (stderr): `Error: 'pgrep' is not installed on this system.`

## Exit status

- `0` : processes killed, nothing was running, or the user cancelled.
- `1` : `pgrep` missing.

The status does not tell whether anything was killed, nor whether the user cancelled; read the output.

## Scripting notes

- The only interactive prompt is the confirmation `Continue? [y/N]`, avoided by `-y` (placed right after `killwine`). Without a TTY or with empty stdin, the answer is empty: the command cancels and exits 0 without killing. A script must therefore always pass `-y`.
- Piping `y` on stdin also confirms (`echo y | lpm killwine`), but `-y` is the supported way.
- The count line is `N process(es) killed.` (N >= 1) or `No Wine/Proton process running.`; use `LC_ALL=C` for stable English text.

## Examples

```
lpm killwine
lpm killwine -y
```

## Files and data touched

No file is written except error lines in `~/.local/share/lpm/lpm.log`. Reads `/proc/<pid>/cmdline`.

## See also

`lpm tools`, `lpm uninstall`
