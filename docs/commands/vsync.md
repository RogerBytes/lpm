# lpm vsync

Forces VSync off for one installed Wine/Proton game by setting environment variables in its Lutris configuration, or lists the games that already have such a setting.

## Synopsis

```
lpm vsync status
lpm vsync <slug> [status]
lpm vsync <slug> on  [setting...]
lpm vsync <slug> off [setting...]
```

## Description

Some games have no VSync option in their graphics settings. This command writes, in the `system.env` of the game's Lutris YAML, the variable that makes each graphics layer stop waiting for the screen's vertical refresh. One game at a time; the same variables can be edited by hand with `lpm tools <slug> env`.

A game only uses one graphics API, and each variable is read by one layer only, so the five settings can be enabled together without conflict: the layers the game does not use ignore theirs. (This is reasoned from how each layer reads its own variable, not something the upstream projects state explicitly.)

Enabling VSync-off does not by itself produce visible tearing: whether tearing shows depends on the desktop compositor (X11 or Wayland). The game simply stops waiting for the vertical refresh, so its frame rate is no longer capped by it.

Close Lutris before changing these settings, or it may overwrite them when it saves its own configuration.

## Arguments

- `status` (alone) : prints the slugs of the games that have at least one setting enabled, one per line (nothing if none).
- `<slug>` : Lutris slug of an installed Wine game (only its last path component is used).
- `status` | `on` | `off` : the action; `status` is the default when only a slug is given. `status` accepts no setting.
- `[setting...]` : one or more of the settings below. With `on` or `off` and no setting, all five are used.

## Settings

| Setting | Variable written | Layer | Source |
| --- | --- | --- | --- |
| `d3d9` | `DXVK_CONFIG` : `d3d9.presentInterval = 0` | DXVK, Direct3D 9 | `dxvk.conf` of DXVK |
| `d3d11` | `DXVK_CONFIG` : `dxgi.syncInterval = 0` | DXVK, Direct3D 10 and 11 | `dxvk.conf` of DXVK |
| `d3d12` | `VKD3D_SWAPCHAIN_PRESENT_MODE=IMMEDIATE` | VKD3D-Proton, Direct3D 12 | README of VKD3D-Proton |
| `gl-nvidia` | `__GL_SYNC_TO_VBLANK=0` | OpenGL, NVIDIA proprietary driver | README of the NVIDIA driver |
| `gl-mesa` | `vblank_mode=0` | OpenGL, Mesa | Mesa bug tracker and user reports; not in Mesa's environment variable documentation |

`MESA_VK_WSI_PRESENT_MODE=immediate` (documented by Mesa) is deliberately not written: it only works on Mesa Vulkan drivers and duplicates the Vulkan layers above.

Having both the NVIDIA proprietary driver and Mesa installed is fine: setting both OpenGL variables is harmless, the driver actually used by the game reads its own and ignores the other.

## Behavior

1. Needs `sqlite3`, `python3` with PyYAML and Lutris (Flatpak or native); it does not need the Wine runner or the prefix.
2. Looks the slug up among Wine games (`runner='wine'`) and reads the game's Lutris YAML. Shared store prefixes are accepted.
3. `on` / `off` edit the YAML by text-level line editing (same editor as `lpm tools <slug> env`): comments, including the `# lpm:hook-disabled` markers, are preserved, the result is re-parsed before writing, and the file is replaced atomically.

`DXVK_CONFIG` is **merged, never overwritten**: `on` adds or corrects only the DXVK options above (running it twice does not duplicate them) and keeps any other option already there (for example `dxgi.hideAmdGpu = True`); `off` removes only those options and deletes `DXVK_CONFIG` if nothing else remains.

The other variables are removed by `off` only if their value is exactly the one written by `on`: a different value chosen by the user (for example `VKD3D_SWAPCHAIN_PRESENT_MODE=MAILBOX`) is never touched. `on` overwrites a different value, since that is the explicit request.

A setting is reported as `on` when its option is present in `DXVK_CONFIG` with value `0`, or when its variable has the written value (`IMMEDIATE` is compared case-insensitively).

## Output

`lpm vsync <slug>` and `lpm vsync <slug> status` print five lines, always in this order:

```
d3d9=off
d3d11=on
d3d12=off
gl-nvidia=off
gl-mesa=off
```

`on` and `off` print one line on success:

```
VSync settings enabled for 'Foo Game'.
VSync settings removed for 'Foo Game'.
```

Errors (stderr):

```
Usage: lpm vsync status | lpm vsync <slug> [status] | lpm vsync <slug> on|off [d3d9|d3d11|d3d12|gl-nvidia|gl-mesa...]
Error: unknown action '<action>' (expected: status, on or off).
Error: unknown setting '<setting>' (expected: d3d9, d3d11, d3d12, gl-nvidia or gl-mesa).
Error: no installed game with slug '<slug>'.
Error: the Lutris configuration for '<name>' could not be found.
Error: python3 with PyYAML is required for environment variables.
Error: could not save the environment variables of '<name>' (configuration unchanged).
```

## Exit status

- `0` : success (including `status` with no game listed).
- `1` : usage error, unknown action or setting, missing Lutris/database/game/configuration, or write failure.

## Scripting notes

- The `status` outputs are stable and parseable (`setting=on|off`, or one slug per line).
- `on` is idempotent. `off` on a game without these settings succeeds and changes nothing.
- No confirmation and no interactive prompt, except the dual-Lutris question when Lutris exists in both forms and nothing was saved: avoid it with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`.
- To check the effect in a game that is capped at the screen refresh rate, show its frame rate (for DXVK games, `DXVK_HUD=fps`): it should go above the refresh rate.

## GUI

The "Disable VSync" page picks one game (games that already have a setting are shown in bold) and shows the five settings as check boxes, checked according to the game's YAML. Checking or unchecking a box applies immediately (no validate button); a "Check all" / "Uncheck all" button sets or clears the five at once.

## Examples

```
lpm vsync status
lpm vsync my-game
lpm vsync my-game on
lpm vsync my-game on d3d9 d3d11
lpm vsync my-game off gl-mesa
lpm vsync my-game off
```
