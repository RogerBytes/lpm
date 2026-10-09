# lpm lsfg

Enables or disables lsfg-vk (Lossless Scaling frame generation) for one or more installed Wine/Proton games.

## Synopsis

```
lpm lsfg <slug>... on
lpm lsfg <slug>... off
lpm lsfg status
```

## Description

lsfg-vk is a Vulkan layer that generates intermediate frames. `lpm lsfg ... on` makes a game use it by copying the reference `lsfg-vk.dll` into the game's prefix and adding three environment variables to the game's Lutris configuration; `off` removes those variables again. The command only acts on Wine/Proton games (`runner='wine'`); games in shared store prefixes are included (the operation is not destructive).

The action word (`on` or `off`) must be the **last** argument and at least one slug is required. There is no interactive game selection.

The reference DLL must be the real `lsfg-vk.dll` from the Steam beta branch `lsfg-vk` of Lossless Scaling (game properties > Betas). The `Lossless.dll` of the public branch is refused (wrong name), because it lacks a shader needed by lsfg-vk 2.0.

## Arguments

- `<slug>...` : one or more Lutris slugs.
- `on` | `off` : the action, last argument.
- `status` : alone (no slug), prints whether the lsfg-vk Vulkan layer is present on the machine.

## Options

None. (`bin/lpm` generic options such as `-y` do not apply: confirmations are always asked, see Scripting notes.)

## Behavior

For `on` / `off`:

1. Syntax check: the last argument must be `on` or `off` and there must be at least one slug; otherwise the usage is printed and the status is 1.
2. Needs `python3`, `sqlite3` and the PyYAML module. Resolves Lutris (Flatpak or native) and reads its database.
3. Detects lsfg-vk (presence only, the version is not checked):
   - Flatpak Lutris: the extension `org.freedesktop.Platform.VulkanLayer.lsfgvk` is installed (`flatpak list --runtime`).
   - Native Lutris: a file whose name contains `lsfg` exists in one of `~/.local/share/vulkan/implicit_layer.d`, `/usr/share/vulkan/implicit_layer.d`, `/usr/local/share/vulkan/implicit_layer.d`, `/etc/vulkan/implicit_layer.d`.
4. If absent:
   - Flatpak: determines the freedesktop runtime version (that of an installed `VulkanLayer.*` extension, else the newest installed `org.freedesktop.Platform`), asks `Continue? [y/N] :`, then runs `flatpak remote-add --user --if-not-exists flathub ...` and `flatpak install --user -y flathub org.freedesktop.Platform.VulkanLayer.lsfgvk//<version>` (no root needed). Refusal or failure: status 1.
   - Native: prints the installation link (AUR page if `pacman` exists, otherwise `https://lsfg-vk.dev/docs/installation/`) and asks `Continue? [y/N] :`; after confirming, presence is re-checked ("lsfg-vk still could not be detected. Aborting." if still absent). Nothing is opened automatically: the link is only printed.
   - Any answer starting with `y`, `Y`, `o` or `O` means yes.
5. For `on` only: if the reference DLL `${XDG_CONFIG_HOME:-$HOME/.config}/lpm/lsfg-vk/lsfg-vk.dll` does not exist, asks `Path:` for its location; the file must exist and be named `lsfg-vk.dll` (case-insensitive), then it is copied there. An empty answer or a wrong file: status 1.
6. Lists Wine games. If there are none: "No Wine/Proton games found." (stderr), status 0. A game is "enabled" when `system.env.LSFGVK_ENV` is `1` in its Lutris YAML (read live each time, no separate state file).
7. Validates every slug **before** changing anything: unknown slug -> error, status 1; `on` for an already enabled game or `off` for a non-enabled game -> error, status 1 (the command is not idempotent).
8. For each slug:
   - `on`: creates `<game dir>/lsfg-vk/` and copies the reference DLL there (overwriting), then sets in the YAML `system.env`: `LSFGVK_ENV: '1'`, `LSFGVK_DLL_PATH: <game dir>/lsfg-vk/lsfg-vk.dll`, and `LSFGVK_MULTIPLIER: '2'` only if that key is absent (an existing value is kept).
   - `off`: removes `LSFGVK_ENV`, `LSFGVK_DLL_PATH` and `LSFGVK_MULTIPLIER` from `system.env`. The copied DLL is left in place.
   - The YAML is edited line by line (helper `lib/zgu-env-edit.py`, the one used by `lpm tools <slug> env`): YAML comments, including the `# lpm:hook-disabled` lines written by `lpm shortcut`, are preserved, and other keys are untouched. Only if this targeted edit is impossible does lpm fall back to rewriting the whole file with PyYAML (`yaml.dump`), which loses the comments.
   - Missing YAML or write failure: error for that game, others continue, final status 1.
   - Success is logged and `<name>: done.` is printed.

`lpm lsfg status` prints `{"installed": true}` or `{"installed": false}` and exits 0; it never prompts about installing.

Two further sub-actions exist for the graphical interface: `lpm lsfg install-info` (JSON describing how lsfg-vk can be installed) and `lpm lsfg install-flatpak <runtime_version>` (non-interactive Flatpak install, prints `{"ok": true}` or `{"ok": false, "error": "..."}`). Both always exit 0 after printing.

## Output

stdout:

```
Foo Game: done.
{"installed": true}
```

stderr (main messages):

```
Usage: lpm lsfg <slug...> on|off|status
Error: the "python3" command is required and was not found.
Error: the PyYAML Python module is required (pip install pyyaml, or your distribution's python3-yaml package).
Error: Lutris was not found on this machine.
Error: Lutris database not found at: <path>
lsfg-vk was not found. Install the Flatpak Vulkan layer (runtime <version>) now? No password will be required.
lsfg-vk was not found. Install it from this page (<label>):
<link>
Once installed, confirm to continue.
Continue? [y/N] :
lsfg-vk still could not be detected. Aborting.
Error: could not determine the Flatpak runtime version used by Lutris.
Error: Flatpak installation of the lsfg-vk layer failed.
Path to the lsfg-vk.dll file (Steam beta branch "lsfg-vk" of Lossless Scaling):
Error: file not found: <path>
Error: the selected file ("<name>") is not "lsfg-vk.dll". Switch the "Lossless Scaling" game to the Steam beta branch "lsfg-vk" (Properties > Betas), then select the "lsfg-vk.dll" file that appears in its install folder.
Error: could not copy the DLL to the local storage folder.
Error: game "<slug>" not found.
Error: lsfg-vk is already enabled for "<slug>".
Error: lsfg-vk is not enabled for "<slug>".
Error: Lutris configuration file missing for "<slug>".
Error: could not update the configuration for "<slug>".
No Wine/Proton games found.
```

## Exit status

- `0` : all requested games updated; `status`; "No Wine/Proton games found."
- `1` : usage error, missing dependency, Lutris/database missing, lsfg-vk installation refused/failed, DLL missing/invalid, unknown slug, wrong current state, or any per-game failure.

## Scripting notes

- Interactive prompts that can occur with `on`/`off`:
  1. `Continue? [y/N] :` when lsfg-vk is not installed (Flatpak install confirmation, or native "installed it yourself" confirmation). No flag skips it; install lsfg-vk beforehand (`lpm lsfg status` tells whether it is detected) so that the prompt never appears.
  2. `Path:` when the reference DLL is not stored yet (`on` only). Avoid it by running `lpm lsfg-dll set /path/to/lsfg-vk.dll` first.
  3. The dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`) when Lutris is installed both ways with no saved choice; avoid with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`. This also applies to `status` and `install-info` (the question goes to stderr).
- Without a TTY or with empty stdin, `read` returns an empty answer: prompt 1 is a refusal (status 1), prompt 2 gives status 1, prompt 3 selects Flatpak and saves it.
- `on` fails with status 1 on an already enabled game and `off` on a game that is not enabled; in scripts, check state with `lpm tools <slug> env list` (look for `LSFGVK_ENV=1`) or treat the status as informational. Nothing is modified when validation fails.
- Stable output: `lpm lsfg status` JSON; the `<name>: done.` lines use the display name.
- `LC_ALL=C` forces English messages.

## Examples

```
lpm lsfg status
lpm lsfg-dll set "$HOME/Downloads/lsfg-vk.dll"
lpm lsfg my-game on
lpm lsfg my-game other-game off
```

## Files and data touched

- `${XDG_CONFIG_HOME:-~/.config}/lpm/lsfg-vk/lsfg-vk.dll` (reference DLL, created by `on` if missing).
- `<game dir>/lsfg-vk/lsfg-vk.dll` (copied by `on`, never deleted).
- The game's Lutris YAML (`system.env` keys `LSFGVK_ENV`, `LSFGVK_DLL_PATH`, `LSFGVK_MULTIPLIER`), edited line by line (comments kept).
- Flatpak: `flathub` user remote and the `org.freedesktop.Platform.VulkanLayer.lsfgvk` user extension when installed by lpm.
- `~/.local/share/lpm/lpm.log`.

## See also

`lpm lsfg-dll`, `lpm tools` (env), `lpm check`, `lpm lutris-version`
