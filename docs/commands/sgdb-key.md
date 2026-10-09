# lpm sgdb-key

Advanced command: reads, saves or clears the personal SteamGridDB API key used by `lpm icon`, `lpm splash`, `lpm logo` and `lpm sgdb-images`. Not listed in `lpm --help`; it exists mainly for the graphical interface and for scripting.

## Synopsis

```
lpm sgdb-key get
lpm sgdb-key set <key>
lpm sgdb-key set ""
```

## Description

The key is personal and never shipped with lpm. You obtain it by creating a free SteamGridDB account and copying the key from https://www.steamgriddb.com/profile/preferences/api. It is stored in a single-line file, `${XDG_CONFIG_HOME:-$HOME/.config}/lpm/steamgriddb.key`, with mode 600. This command is the non-interactive way to manage that file; `icon`, `splash` and `logo` otherwise ask for the key themselves on first use.

## Arguments

- `get` : prints the saved key as JSON.
- `set <key>` : validates and saves the key; an empty key deletes the saved one.

## Options

None.

## Behavior

- `get`: reads the first line of the key file with all whitespace removed and prints `{"key": "<key>"}`; `{"key": ""}` if there is no file. **The key is printed in clear text.** The key is not tested against the API. Always exits 0.
- `set <key>`:
  1. Removes all spaces, tabs and line breaks from the argument.
  2. Empty result (including `set ""` or `set` alone): deletes the key file (no error if absent), exit 0.
  3. Otherwise tests the key with a real request, `GET https://www.steamgriddb.com/api/v2/search/autocomplete/a` with `Authorization: Bearer <key>` (10 s timeout). Only HTTP 200 is valid. Invalid or unreachable service: error, exit 1, the saved key is left unchanged.
  4. Valid: creates the folder if needed, writes the key (one line) and sets mode 600.
- Any other first argument (or none): prints the usage and exits 1.

## Output

`get` (stdout):

```
{"key": "<the saved key, or empty string>"}
```

Errors (stderr):

```
Usage: lpm sgdb-key get|set <key>
Error: invalid or unreachable SteamGridDB API key.
```

`set` prints nothing on success.

## Exit status

- `0` : `get`; `set` saved or cleared the key.
- `1` : usage error; `set` with a key rejected by the API (or the API unreachable).

## Scripting notes

- No interactive prompt, no confirmation (an empty `set` deletes the key at once). No Lutris detection.
- `get` is a pure local read and always exits 0, whether or not a key exists: test the `key` value for emptiness. Treat the output as a secret (do not log it).
- `set` passes the key as a command-line argument, which other users of the machine may see in the process list.
- `set` needs network access to steamgriddb.com; offline it fails with the "invalid or unreachable" error.
- If `python3` is missing, `get` prints nothing yet exits 0.
- `LC_ALL=C` forces English messages.

## Examples

```
lpm sgdb-key set "$STEAMGRIDDB_KEY"
lpm sgdb-key get
lpm sgdb-key set ""
```

## Files and data touched

- `${XDG_CONFIG_HOME:-~/.config}/lpm/steamgriddb.key` (read, written, or deleted).
- Network: steamgriddb.com (only for `set`).
- Error lines are appended to `~/.local/share/lpm/lpm.log`.

## See also

`lpm icon`, `lpm splash`, `lpm logo`, `lpm sgdb-images`
