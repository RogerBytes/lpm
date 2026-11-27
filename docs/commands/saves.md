# ludis saves

Backs up, restores, exports and imports the **saves** of one game (never the whole prefix), and sets the folder where the backups are kept.

## Synopsis

```
ludis saves dir [<folder>|default|none]
ludis saves auto [on|off]
ludis saves interval [<minutes>]
ludis saves <slug> [status]
ludis saves <slug> backup
ludis saves <slug> restore [<snapshot>]
ludis saves <slug> history
ludis saves <slug> initial
ludis saves <slug> reset [--yes]
ludis saves <slug> path
ludis saves <slug> export [<file>.zgs]
ludis saves <slug> import <file>.zgs [--folders zgs|keep|merge]
ludis saves <slug> auto [follow|on|off]
ludis saves <slug> folders [list|add <folder>|remove <folder>|reset]
ludis saves <slug> exclude [list|defaults|add <pattern>|remove <pattern>|reset]
ludis saves <slug> pull
ludis saves <slug> push
```

## Description

The saves of a game are, by default, the folders `AppData`, `Documents` and `Saved Games` of the Windows user of its prefix (`steamuser` under Proton, your Linux user name under Wine), minus what can be rebuilt (caches, shader caches, crash dumps, logs, Windows profile leftovers: see `exclude defaults`). Ludis cannot guess where a game saves: if one writes its saves elsewhere (another folder of the Windows user, or a folder of `drive_c`), add that folder yourself with `folders add` (see below). Files are stored with paths **relative to the Windows user folder**, so a backup made under one user name restores under any other.

`ludis saves` works with a **sync folder** that you choose once (`ludis saves dir`): typically a folder of your cloud client, so that two machines share the same saves. Each game gets its own sub-folder there.

```
<sync folder>/<slug>/current/    the latest backup (plain files)
<sync folder>/<slug>/previous/   older versions, compressed (<date>-<label>.tar.zst)
<sync folder>/<slug>/stamp       "<epoch> <host name>" of the latest backup
<sync folder>/<slug>/config      the folder choice of this game (see below)
```

The command also has an **automatic mode** that copies the saves at launch and during play (see Automatic mode). `export` and `import` make a single `.zgs` file you can send to someone else, independent of the sync folder.

Saves are copied, never linked: the prefix is left untouched, so a game exported with [`ludis pack`](pack.md) is not changed by this feature, and the `.zgp` does not depend on any sync folder.

> [!WARNING]
> A backup or a `.zgs` holds the files of the game's profile folders, which can contain launcher tokens or personal data some games write there. Share a `.zgs` only with people you trust.

## Arguments

| Argument | Meaning |
|---|---|
| `<slug>` | Slug of an installed game (see [`ludis list`](list.md)). Only the base name is used. An unknown slug gives `Error: no installed game with slug '<slug>'.` (exit 1). |
| `dir`, `auto`, `interval` | When one of these words is written **instead of a slug**, the command is global (see below). A game whose slug is exactly `dir`, `auto` or `interval` cannot be targeted. |

With a slug and no action, the action is `status`.

## Global commands

| Command | Meaning |
|---|---|
| `ludis saves dir` | Prints the sync folder (an empty line if none). |
| `ludis saves dir <folder>` | Sets it. The folder is created if needed and must be writable and given as an absolute path (`~` is accepted). Output: `Saves sync folder: <path>`. |
| `ludis saves dir default` | Sets `Ludis-saves` inside your Documents folder (`xdg-user-dir DOCUMENTS`, else `~/Documents`). |
| `ludis saves dir none` | Forgets the sync folder. Backups already made are left where they are. |
| `ludis saves auto` | Prints `on` or `off` (global automatic mode, default `off`). |
| `ludis saves auto on\|off` | Sets the global automatic mode. |
| `ludis saves interval` | Prints the number of minutes between two copies while playing (default `10`). |
| `ludis saves interval <n>` | Sets it: a whole number from `0` to `60` (`0` = only at launch and at the end). Anything else: `Error: '<n>' is not a valid interval (0 to 60 minutes).`, exit 1. |

These settings are in `~/.config/ludis/saves.conf` (`sync_dir=`, `auto=`, `interval=`).

## Actions on a game

| Action | Meaning |
|---|---|
| `status` | Two lines: `local=<n> sync_dir=<folder or none>` (`n` = number of save folders found in the prefix) and `backup=<date> previous=<n>` (or `backup=none`). |
| `backup` | Copies the saves to `<sync>/<slug>/current/`. The previous `current` becomes a compressed snapshot in `previous/`. If nothing changed: `Saves of '<name>' unchanged since the last backup.` and nothing is written. If the game has no save folder at all: `Error: no saves found for '<name>' ...`, exit 1. Needs a sync folder. |
| `restore [<snapshot>]` | Puts `current/` (or the snapshot of `previous/` whose name contains `<snapshot>`) back into the prefix. The local saves are **first kept** in `previous/` (label `before-restore`). Needs a sync folder. |
| `initial` | Keeps the initial state of the saves in the prefix, once (the launcher does it at the first launch). `Initial state of the saves of '<name>' kept.` or `... is already kept.` Works without a sync folder, and on a prefix that was never started (then the initial state is empty). |
| `reset [--yes]` | Puts the saves back to the initial state: removes the files that count as saves, then copies the initial ones. The current saves are **first kept once** (`previous/` of the sync folder if set, else `ludis/saves-before-reset/`). Asks `[y/N]` in a terminal; without a terminal it needs `--yes`. Error if no initial state was kept. |
| `history` | Lists the names of the snapshots in `previous/`, newest first. Needs a sync folder. |
| `path` | Prints the Windows user folder of the prefix. |
| `export [<file>]` | Writes a `.zgs` file (a zstd-compressed tar). Default name: `<slug>-saves.zgs` in the current folder; `.zgs` is added if missing. Does not need a sync folder. |
| `import <file> [--folders zgs\|keep\|merge]` | Puts the saves of a `.zgs` into the prefix. The `.zgs` also records the game's folder choice (`folders`, `exclude`). If the game has none, it takes them. If both have some and they differ, `--folders` decides: `zgs` (default) uses the archive's, `keep` keeps the game's, `merge` keeps both. In a terminal without `--folders`, you are asked. `import <file> --check` imports nothing and prints `differs` (exit 0) when the two differ, otherwise exit 1. The archive is inspected before anything is extracted: an absolute path, a `..` or any link refuses it entirely (`unsafe`). The local saves are first kept (in `previous/` if a sync folder is set, otherwise in `<prefix>/ludis/saves-before-import/<date>/`). |
| `auto [follow\|on\|off]` | Automatic mode for this game. Without a value: `game=<follow\|on\|off> global=<on\|off>`. `follow` (default) uses the global setting. |
| `folders ...`, `exclude ...` | Choose what is taken (see below). |
| `pull`, `push` | What the automatic mode does (see below). They can be run by hand. |

### Choosing the folders

```
ludis saves <slug> folders                       # list (same as "list")
ludis saves <slug> folders add "AppData/Roaming/Foo"
ludis saves <slug> folders add "drive_c:Games/Foo/save"
ludis saves <slug> folders remove "Saved Games"
ludis saves <slug> folders reset                 # back to the defaults
```

A folder is given relative to the Windows user folder, or as `drive_c:<path relative to drive_c>` for a game that keeps its saves elsewhere (for example in its own folder), or as an absolute path inside the prefix. A path outside the prefix, or containing `..`, is refused (`Error: '<x>' is not a valid folder ...`, exit 1). The first `add` of a folder inside the user folder writes the three default folders first, then your addition, because **a list replaces the defaults**. Folders of the `drive_c:` kind are added to whatever is chosen.

The choice lives in the prefix, in `ludis/settings/saves-folders.txt` and `saves-extra.txt`, and is copied next to every backup (`config`) and inside every `.zgs`. A prefix that has no choice of its own (a game that was just reinstalled) **adopts** the one recorded in the backup before it copies anything, so a reinstall never replaces a backup made with chosen folders by one made with the defaults.

### Excluding files

`exclude add <pattern>` adds a pattern (a `tar --exclude` pattern, so `*` is allowed; no `..`, no leading `/`) of files or folders **not** to take, on top of the built-in exclusions (`exclude defaults` prints them). `exclude list` shows yours, `exclude remove <pattern>` removes one, `exclude reset` removes them all. Stored in `ludis/settings/saves-exclude.txt`.

## Behavior

- **Snapshots.** Before a `backup` replaces `current/`, the old one can become the "previous" one, `previous/<date>-backup.tar.zst`: only when the last "previous" is **at least 15 minutes old** (otherwise the old `current/` is simply replaced). So `previous/` holds at most **two** snapshots: the previous backup, and the last safety copy made before a `restore`, a `pull`, a `reset` or an `import` (names containing `before-` or `conflict`). Older ones are deleted. Backups made every few minutes therefore never pile up, and a crash that spoils the saves leaves an older copy (15 to 25 minutes old at the most while the automatic mode runs).
- **Initial state.** The first time a game is launched through Ludis (automatic mode or not, before any `pull`), the saves are kept once in `<prefix>/ludis/saves-initial/` (empty if there were none), and never deleted by Ludis. `reset` puts them back. It is not exported in the `.zgp`. For a game launched before this feature existed, it is the state of the saves at its next launch.
- **Safety.** Nothing outside the Windows user folder (and the `drive_c` folders you listed) is ever written; links found in a backup or an archive are deleted, never followed; a `.zgs` can never choose where its extra folders land (only those listed in the prefix's `saves-extra.txt` are accepted).
- **Writes are atomic**: the new backup is built next to `current/` and swapped in by a rename.
- **Per-machine memory**: the time this machine last pushed or pulled a game is kept in `~/.local/share/ludis/saves-state/<slug>`, never in the prefix (so it is not exported with the game).

## Automatic mode

When a sync folder is set and the mode is `on` for the game (its own setting, else the global one), launching the game **from a Ludis shortcut** (menu or desktop, see [`ludis shortcut`](shortcut.md)) does this:

1. **Before the game starts**, `pull`: if the sync folder holds a backup newer than the last one this machine made or took, it is brought in; the local saves are kept first (label `before-pull`, or `conflict` if the local ones had also changed since). If the prefix has no saves (a game just reinstalled), the backup is always brought in. This step waits 60 seconds at most.
2. **While the game runs**, a small background monitor runs `push` every `<interval>` minutes.
3. **When the game has ended**, one last `push`.

`push` is a quiet `backup` that waits (up to 12 seconds) until the files have stopped changing. `pull` prints one status line: `pull=no-backup`, `pull=up-to-date`, `pull=local-newer`, `pull=restored label=<label>`, or `pull=failed` (exit 1).

A game started from Lutris itself (not from a Ludis shortcut) does not trigger the automatic mode; use `backup` and `restore` by hand, or the shortcut.

## Output

Results go to stdout, errors to stderr. Examples (English, `LC_ALL=C`):

```
$ ludis saves dir ~/Documents/Ludis-saves
Saves sync folder: /home/you/Documents/Ludis-saves
$ ludis saves zelda backup
Saves of 'Zelda' backed up to /home/you/Documents/Ludis-saves/zelda/current
$ ludis saves zelda status
local=3 sync_dir=/home/you/Documents/Ludis-saves
backup=2026-11-25 23:43:05 previous=0
$ ludis saves zelda history
20261125-234306-before-restore
$ ludis saves zelda export ~/z
Saves of 'Zelda' exported to /home/you/z.zgs
```

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success (including "unchanged since the last backup" and an empty `history`). |
| 1 | No sync folder set (for the actions that need one), unknown game, no save folder found, invalid folder, interval or `.zgs`, unsafe or unreadable archive, write failure, `pull=failed`, or an unknown action. |

## Scripting notes

- No prompt, ever (except `reset` and `import` in a terminal). `restore` and `import` overwrite the saves in the prefix (after keeping them first), so ask your user before calling them.
- The first word after `saves` is read as a slug unless it is `dir`, `auto` or `interval`.
- `status`, `history`, `path`, `folders list`, `exclude list` print plain lines meant to be parsed. Their text is not translated.
- Messages (`backed up`, `restored`, errors) follow the locale; use `LC_ALL=C` to get the English strings quoted here.
- The sync folder is shared between all games; each game uses `<sync>/<slug>`, so two machines must use the same slug for the same game.
- Errors and actions are written to the ludis log (`ludis log --grep saves`).

## Examples

```
# Choose the folder once (a folder of your cloud client works well)
ludis saves dir ~/Documents/Ludis-saves

# Back up, then restore on another machine that shares the folder
ludis saves mariovania backup
ludis saves mariovania restore

# Go back to an older version
ludis saves mariovania history
ludis saves mariovania restore 20261125-2143

# A game that keeps its saves in its own folder
ludis saves mariovania folders add "drive_c:Games/Mario Vania/save"

# Do not take the screenshots
ludis saves mariovania exclude add "Documents/My Games/Screenshots"

# Automatic mode for everything, every 5 minutes
ludis saves auto on
ludis saves interval 5

# Send your saves to a friend
ludis saves mariovania export ~/mariovania-saves.zgs
ludis saves mariovania import ~/mariovania-saves.zgs
```

## Files and data touched

- Reads/writes: `<sync folder>/<slug>/` (`current/`, `previous/`, `stamp`, `config`), the exported `.zgs`.
- Reads: the Lutris database, the Windows user folder of the prefix (`drive_c/users/<user>/`) and the `drive_c` folders you listed.
- Writes into the prefix: the restored or imported saves, and `ludis/settings/saves-folders.txt`, `saves-extra.txt`, `saves-exclude.txt`, `saves-auto`; `ludis/saves-initial/`, `ludis/saves-before-reset/` and `ludis/saves-before-import/` for an import without a sync folder.
- Writes elsewhere: `~/.config/ludis/saves.conf`, `~/.local/share/ludis/saves-state/<slug>`, `~/.local/share/ludis/ludis.log`.
- Lutris is not stopped.

## See also

[`ludis pack`](pack.md), [`ludis uninstall`](uninstall.md) (asks whether to back up the saves first), [`ludis install`](install.md) (replacing an installed game: optional saves backup and restore), [`ludis shortcut`](shortcut.md), [`ludis list`](list.md), [Archives](archives.md) (`.zgs`).
