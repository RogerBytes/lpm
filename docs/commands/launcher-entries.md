# lpm launcher-entries

Prints or replaces the picker entries (title, prompt, executables) stored in a game's `lpm-launcher.yml`, as JSON.

## Synopsis

```
lpm launcher-entries <slug> get
lpm launcher-entries <slug> set <file.json>
```

## Description

The counterpart of editing `lpm-launcher.yml` by hand: `get` exports the picker configuration as a JSON document, `set` replaces it from a JSON document of the same shape. It never enables or disables the LPM Launcher (use `lpm launcher`). Works on Wine/Proton games only; the game needs a Lutris configuration file.

## Arguments

- `<slug>` : Lutris slug of a Wine game.
- `get` | `set` : the action.
- `<file.json>` : for `set`, the JSON file to read.

## Options

None.

## Behavior

Common: needs `python3`, `sqlite3`, PyYAML; resolves Lutris (Flatpak or native); finds the game (`runner='wine'`, unknown slug = error); needs its Lutris YAML; reads `game.prefix` from it (default: the game dir) to locate `<prefix>/drive_c`. The file handled is `<game dir>/lpm-launcher.yml`.

`get`:
- Prints one line of JSON (see Output). A missing or unreadable `lpm-launcher.yml` yields empty `title`/`prompt` and an empty `entries` list, not an error.
- `exe_linux` / `workdir_linux` are computed by plain text replacement of `C:\` by `<prefix>/drive_c/`; no Wine process is started. Any other drive letter gives an empty string.

`set`:
- Reads the JSON file; the top level must be an object and `entries` a list (otherwise "could not write").
- Replaces `title`, `prompt` and `entries` in `lpm-launcher.yml`, keeping other existing keys (notably `original_exe` and `bat_path`). Creates the file (and the game dir) if missing. The file is re-dumped with PyYAML, so comments of the YAML (such as the commented example entry) are lost.
- Entry rules: an entry needs a non-empty `label` and an executable (`exe_win` or `exe_linux`), otherwise it is silently dropped. Per entry:
  - executable: `exe_win` if given (literal Windows path), else `exe_linux` converted to `C:\...` when it is under `<prefix>/drive_c` (a Linux path outside it is stored unchanged);
  - working directory: `workdir_win` if given, else `workdir_linux` converted the same way, else the folder of `exe_linux`, else the folder part of `exe_win`;
  - `args` (optional free text appended after the executable in the generated `.bat`): stored only if non-empty.
  - All strings are trimmed.
- Prints the confirmation. Does not touch the Lutris YAML or the relay.

## Output

`get` (stdout, one line, shown wrapped here):

```
{"title": "Foo Game",
 "prompt": "Which one do you want to launch?",
 "drive_c": "/home/me/Games/foo/drive_c",
 "entries": [
   {"label": "Launch", "args": "",
    "exe_win": "C:\\Games\\Foo\\foo.exe", "workdir_win": "C:\\Games\\Foo",
    "exe_linux": "/home/me/Games/foo/drive_c/Games/Foo/foo.exe",
    "workdir_linux": "/home/me/Games/foo/drive_c/Games/Foo"}]}
```

Keys: `title`, `prompt`, `drive_c` (Linux path of the prefix's `C:`), `entries[]` with `label`, `args`, `exe_win`, `workdir_win`, `exe_linux`, `workdir_linux` (all strings, possibly empty). Output is produced by `json.dumps` (non-ASCII is escaped as `\uXXXX`).

`set` input file: same shape; only `title`, `prompt` and `entries[]` with `label`, `exe_win`/`exe_linux`, `workdir_win`/`workdir_linux`, `args` are read:

```json
{
  "title": "My Game",
  "prompt": "Which one do you want to launch?",
  "entries": [
    {"label": "Episode 1", "exe_win": "C:\\Games\\My\\ep1.exe"},
    {"label": "Episode 2", "exe_linux": "/home/me/Games/my/drive_c/Games/My/ep2.exe", "args": "-windowed"}
  ]
}
```

`set` success (stdout): `LPM Launcher entries updated for "<slug>".`

Errors (stderr):

```
Usage: lpm launcher-entries <slug> get|set <file.json>
Error: the "<cmd>" command is required and was not found.
Error: the PyYAML Python module is required (pip install pyyaml, or your distribution's python3-yaml package).
Error: Lutris was not found on this machine.
Error: Lutris database not found at: <path>
Error: game "<slug>" not found.
Error: Lutris configuration file missing for "<slug>".
Error: could not read LPM Launcher entries for "<slug>".
Error: JSON file not found.
Error: could not write LPM Launcher entries for "<slug>".
```

## Exit status

- `0` : `get` printed the JSON; `set` wrote the file.
- `1` : usage error, missing dependency, Lutris/database/game/YAML not found, unreadable or invalid JSON, write failure.

## Scripting notes

- No confirmation and no prompt, except the dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`); avoid it with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`.
- `set` reads a file path only; it does not read stdin. Use process substitution or a temporary file.
- `get` followed by `set` with the same document is a faithful round trip because `exe_win`/`workdir_win` take priority over the `_linux` fields.
- `set` replaces all entries: an entry list that ends up empty (all entries dropped) leaves the file with no entry, and at the next game start the relay finds no valid entry, logs an error, and the game starts with the existing `.bat`.
- The `get` JSON is the parseable, stable interface (single line on stdout; exit 0).
- `LC_ALL=C` forces English messages.

## Examples

```
lpm launcher-entries my-game get
lpm launcher-entries my-game get | python3 -m json.tool
lpm launcher-entries my-game set entries.json
lpm launcher-entries my-game get > backup.json && lpm launcher-entries my-game set backup.json
```

## Files and data touched

- Read: Lutris `pga.db`, the game's Lutris YAML (for `game.prefix`), `<game dir>/lpm-launcher.yml`.
- Written by `set`: `<game dir>/lpm-launcher.yml`.

## See also

`lpm launcher`, `lpm tools`, `lpm splash`
