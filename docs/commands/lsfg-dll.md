# lpm lsfg-dll

Advanced command: reads or stores the reference `lsfg-vk.dll` that `lpm lsfg ... on` copies into game prefixes. Not listed in `lpm --help`; it exists mainly for the graphical interface and for scripting.

## Synopsis

```
lpm lsfg-dll get
lpm lsfg-dll set <path>
```

## Description

`lpm lsfg-dll` is the non-interactive counterpart of the `Path:` prompt of `lpm lsfg <slug> on`. It only reads or writes the stored reference DLL; it never enables lsfg-vk for any game.

## Arguments

- `get` : prints the stored DLL location as JSON.
- `set <path>` : validates and stores the DLL found at `<path>`.

## Options

None.

## Behavior

- `get`: prints `{"path": "<absolute path>"}` if the reference DLL exists, `{"path": ""}` otherwise. Always exits 0. (It does not need Lutris.)
- `set <path>`:
  1. `<path>` must be an existing regular file, otherwise "Error: file not found: ..." (exit 1; an empty or missing argument gives `Error: file not found: ` with nothing after it).
  2. Its file name must be `lsfg-vk.dll`, compared case-insensitively. Anything else (for instance `Lossless.dll` from the public Steam branch of Lossless Scaling) is rejected, since only the DLL from the beta branch `lsfg-vk` (game properties > Betas) contains the required shader. Only the name is checked, not the content.
  3. Creates `${XDG_CONFIG_HOME:-$HOME/.config}/lpm/lsfg-vk/` if needed and copies the file there as `lsfg-vk.dll`, overwriting any previous one (file mode follows the copy, no `chmod`).
- Any other first argument (or none): prints the usage and exits 1.

## Output

```
{"path": "/home/me/.config/lpm/lsfg-vk/lsfg-vk.dll"}
```

`set` prints nothing on success. Errors (stderr):

```
Usage: lpm lsfg-dll get|set <path>
Error: file not found: <path>
Error: the selected file ("<name>") is not "lsfg-vk.dll". Switch the "Lossless Scaling" game to the Steam beta branch "lsfg-vk" (Properties > Betas), then select the "lsfg-vk.dll" file that appears in its install folder.
Error: could not copy the DLL to the local storage folder.
```

## Exit status

- `0` : `get` always; `set` when the DLL was stored.
- `1` : usage error, file not found, wrong file name, copy failure.

## Scripting notes

- No interactive prompt, no network, no Lutris detection (so no dual-Lutris question).
- `get` output is a single-line JSON object with exactly one key, `path`; it is `""` when no valid reference DLL is stored. If `python3` were missing, `get` would print nothing and still exit 0.
- `set` is idempotent and safe to repeat.
- Error text follows the system language; `LC_ALL=C` for English.

## Examples

```
lpm lsfg-dll set "$HOME/.steam/steam/steamapps/common/Lossless Scaling/lsfg-vk.dll"
lpm lsfg-dll get
```

## Files and data touched

- `${XDG_CONFIG_HOME:-~/.config}/lpm/lsfg-vk/lsfg-vk.dll` (written by `set`, read by `get`).
- The error lines are also appended to `~/.local/share/lpm/lpm.log`.

## See also

`lpm lsfg`
